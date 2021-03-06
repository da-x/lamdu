{-# LANGUAGE NoImplicitPrelude, NamedFieldPuns, OverloadedStrings #-}
module Lamdu.Sugar.Convert.Apply
    ( convert
    ) where

import           Prelude.Compat

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad (guard, unless)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Either.Utils (runMatcherT, justToLeft)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Control.Monad.Trans.State (evalStateT, runStateT)
import qualified Data.Foldable as Foldable
import qualified Data.Map as Map
import           Data.Maybe.Utils (maybeToMPlus)
import qualified Data.Set as Set
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import           Data.UUID.Types (UUID)
import qualified Lamdu.Builtins.Anchors as Builtins
import           Lamdu.Calc.Type (Type)
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.Expr.Load as Load
import qualified Lamdu.Expr.Pure as P
import qualified Lamdu.Expr.RecordVal as RecordVal
import qualified Lamdu.Expr.UniqueId as UniqueId
import qualified Lamdu.Infer as Infer
import           Lamdu.Infer.Unify (unify)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Hole as ConvertHole
import qualified Lamdu.Sugar.Convert.Hole.Suggest as Suggest
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types

type T = Transaction

convert ::
    (Monad m, Monoid a) => V.Apply (Val (Input.Payload m a)) ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convert app@(V.Apply funcI argI) exprPl =
    runMatcherT $
    do
        (funcS, argS) <-
            do
                argS <- lift $ ConvertM.convertSubexpression argI
                justToLeft $ convertAppliedHole app argS exprPl
                funcS <- ConvertM.convertSubexpression funcI & lift
                protectedSetToVal <- lift ConvertM.typeProtectedSetToVal
                let setToFuncAction =
                        funcI ^. Val.payload . Input.stored
                        & Property.value
                        & protectedSetToVal (exprPl ^. Input.stored)
                        <&> EntityId.ofValI
                        & SetToInnerExpr
                if Lens.has (rBody . _BodyHole) argS
                    then
                    return
                    ( funcS & rPayload . plActions . setToHole .~ AlreadyAppliedToHole
                    , argS & rPayload . plActions . setToInnerExpr .~ setToFuncAction
                    )
                    else return (funcS, argS)
        justToLeft $ convertAppliedCase funcS (funcI ^. Val.payload) argS exprPl
        justToLeft $ convertLabeled funcS argS argI exprPl
        lift $ convertPrefix funcS argS exprPl

noRepetitions :: Ord a => [a] -> Bool
noRepetitions x = length x == Set.size (Set.fromList x)

convertLabeled ::
    (Monad m, Monoid a) =>
    ExpressionU m a -> ExpressionU m a -> Val (Input.Payload m a) -> Input.Payload m a ->
    MaybeT (ConvertM m) (ExpressionU m a)
convertLabeled funcS argS argI exprPl =
    do
        guard $ Lens.has (Val.body . V._BLeaf . V._LRecEmpty) recordTail
        guard $ Lens.has (rBody . _BodyGetVar . _GetBinder . bvForm . _GetDefinition) funcS
        record <- maybeToMPlus $ argS ^? rBody . _BodyRecord
        guard $ length (record ^. rItems) >= 2
        let getArg field =
                AnnotatedArg
                    { _aaTag = field ^. rfTag
                    , _aaExpr = field ^. rfExpr
                    }
        let args = map getArg $ record ^. rItems
        let tags = args ^.. Lens.traversed . aaTag . tagVal
        unless (noRepetitions tags) $ error "Repetitions should not type-check"
        protectedSetToVal <- lift ConvertM.typeProtectedSetToVal
        let setToInnerExprAction =
                case (filter (Lens.nullOf ExprLens.valHole) . map snd . Map.elems) fieldsI of
                [x] ->
                    x ^. Val.payload . Input.stored & Property.value
                    & protectedSetToVal (exprPl ^. Input.stored)
                    <&> EntityId.ofValI
                    & SetToInnerExpr
                _ -> NoInnerExpr
        BodyApply Apply
            { _aFunc = funcS
            , _aSpecialArgs = NoSpecialArgs
            , _aAnnotatedArgs = args
            }
            & lift . addActions exprPl
            <&> rPayload %~
                ( plData <>~ argS ^. rPayload . plData ) .
                ( plActions . setToInnerExpr .~ setToInnerExprAction
                )
    where
        (fieldsI, recordTail) = RecordVal.unpack argI

convertPrefix ::
    (Monad m, Monoid a) =>
    ExpressionU m a -> ExpressionU m a ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convertPrefix funcS argS applyPl =
    addActions applyPl $ BodyApply Apply
    { _aFunc = funcS
    , _aSpecialArgs = ObjectArg argS
    , _aAnnotatedArgs = []
    }

orderedInnerHoles :: Val a -> [Val a]
orderedInnerHoles e =
    case e ^. Val.body of
    V.BLeaf V.LHole -> [e]
    V.BApp (V.Apply func@(Val _ (V.BLeaf V.LHole)) arg) ->
        orderedInnerHoles arg ++ [func]
    body -> Foldable.concatMap orderedInnerHoles body

unwrap ::
    Monad m =>
    ExprIRef.ValIProperty m ->
    ExprIRef.ValIProperty m ->
    Val (Input.Payload n a) ->
    T m EntityId
unwrap outerP argP argExpr =
    do
        res <- DataOps.replace outerP (Property.value argP)
        return $
            case orderedInnerHoles argExpr of
            (x:_) -> x ^. Val.payload . Input.entityId
            _ -> EntityId.ofValI res

checkTypeMatch :: Monad m => Type -> Type -> ConvertM m Bool
checkTypeMatch x y =
    do
        inferContext <- (^. ConvertM.scInferContext) <$> ConvertM.readContext
        return $ Lens.has Lens._Right $ evalStateT (Infer.run (unify x y)) inferContext

mkAppliedHoleOptions ::
    Monad m =>
    ConvertM.Context m ->
    Val (Input.Payload m a) ->
    Expression name m a ->
    Input.Payload m a ->
    ExprIRef.ValIProperty m ->
    [HoleOption UUID m]
mkAppliedHoleOptions sugarContext argI argS exprPl stored =
    [ P.app P.hole P.hole | Lens.nullOf (rBody . _BodyLam) argS ] ++
    [ P.record
      [ (Builtins.headTag, P.hole)
      , ( Builtins.tailTag
        , P.inject Builtins.nilTag P.recEmpty
          & P.abs "nilNullArg"
          & P.toNom Builtins.streamTid
        )
      ]
      & P.inject Builtins.consTag
      & P.abs "consNullArg"
      & P.toNom Builtins.streamTid
    ]
    <&> ConvertHole.SeedExpr
    <&> ConvertHole.mkHoleOption sugarContext (Just argI) exprPl stored

mkAppliedHoleSuggesteds ::
    Monad m =>
    ConvertM.Context m ->
    Val (Input.Payload m a) ->
    Input.Payload m a ->
    ExprIRef.ValIProperty m ->
    T m [HoleOption UUID m]
mkAppliedHoleSuggesteds sugarContext argI exprPl stored =
    Suggest.valueConversion Load.nominal Nothing (argI <&> onPl)
    <&> (`runStateT` (sugarContext ^. ConvertM.scInferContext))
    <&> Lens.mapped %~ onSuggestion
    where
        onPl pl = (pl ^. Input.inferred, Just pl)
        onSuggestion (sugg, newInferCtx) =
            ConvertHole.mkHoleOptionFromInjected
            (sugarContext & ConvertM.scInferContext .~ newInferCtx)
            exprPl stored
            (sugg <&> Lens._1 %~ (^. Infer.plType))

convertAppliedHole ::
    (Monad m, Monoid a) =>
    V.Apply (Val (Input.Payload m a)) -> ExpressionU m a ->
    Input.Payload m a ->
    MaybeT (ConvertM m) (ExpressionU m a)
convertAppliedHole (V.Apply funcI argI) argS exprPl =
    do
        guard $ Lens.has ExprLens.valHole funcI
        isTypeMatch <-
            checkTypeMatch (argI ^. Val.payload . Input.inferredType)
            (exprPl ^. Input.inferredType) & lift
        let holeArg = HoleArg
                { _haExpr =
                      argS
                      & rPayload . plActions . wrap .~ WrappedAlready storedEntityId
                      & rPayload . plActions . setToHole .~
                        SetWrapperToHole
                        ( exprPl ^. Input.stored & DataOps.setToHole <&> uuidEntityId )
                , _haUnwrap =
                      if isTypeMatch
                      then unwrap (exprPl ^. Input.stored)
                           (argI ^. Val.payload . Input.stored) argI & UnwrapAction
                      else UnwrapTypeMismatch
                }
        do
            sugarContext <- ConvertM.readContext
            hole <- ConvertHole.convertCommon (Just argI) exprPl
            suggesteds <-
                mkAppliedHoleSuggesteds sugarContext
                argI exprPl (exprPl ^. Input.stored)
                & ConvertM.liftTransaction
            hole
                & rBody . _BodyHole . holeActions . holeOptions . Lens.mapped
                    %~  ConvertHole.addSuggestedOptions suggesteds
                    .   mappend (mkAppliedHoleOptions sugarContext
                        argI argS exprPl (exprPl ^. Input.stored))
                & return
            & lift
            <&> rBody . _BodyHole . holeMArg .~ Just holeArg
            <&> rPayload . plData <>~ funcI ^. Val.payload . Input.userData
            <&> rPayload . plActions . wrap .~ WrapperAlready storedEntityId
    where
        storedEntityId = exprPl ^. Input.stored & Property.value & uuidEntityId
        uuidEntityId valI = (UniqueId.toUUID valI, EntityId.ofValI valI)

convertAppliedCase ::
    (Monad m, Monoid a) =>
    ExpressionU m a -> Input.Payload m a -> ExpressionU m a -> Input.Payload m a ->
    MaybeT (ConvertM m) (ExpressionU m a)
convertAppliedCase funcS funcPl argS exprPl =
    do
        caseB <- funcS ^? rBody . _BodyCase & maybeToMPlus
        Lens.has (cKind . _LambdaCase) caseB & guard
        protectedSetToVal <- lift ConvertM.typeProtectedSetToVal
        caseB
            & cKind .~ CaseWithArg
                CaseArg
                { _caVal = argS
                , _caToLambdaCase =
                    protectedSetToVal (exprPl ^. Input.stored)
                    (funcPl ^. Input.stored & Property.value) <&> EntityId.ofValI
                }
            & BodyCase
            & lift . addActions exprPl
    <&> rPayload . plData <>~ funcS ^. rPayload . plData
