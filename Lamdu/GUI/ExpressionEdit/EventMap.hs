{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.GUI.ExpressionEdit.EventMap
    ( make
    , modifyEventMap
    , jumpHolesEventMap
    , extractCursor
    ) where

import           Control.Applicative (liftA2)
import           Control.Lens.Operators
import qualified Data.Store.Transaction as Transaction
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import qualified Graphics.UI.Bottle.Widget as Widget
import           Lamdu.CharClassification (operatorChars)
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.GUI.ExpressionEdit.HoleEdit.State (HoleState(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.State as HoleEditState
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM, HolePickers)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.Types as Sugar

import           Prelude.Compat

type T = Transaction.Transaction

data IsHoleResult = HoleResult | NotHoleResult

make ::
    (Monad m, Monad f) =>
    HolePickers f -> Sugar.Payload f ExprGuiT.Payload ->
    ExprGuiM m (Widget.EventMap (T f Widget.EventResult))
make holePickers pl =
    mconcat <$> sequenceA
    [ actionsEventMap holePickers isHoleResult (pl ^. Sugar.plActions)
    , jumpHolesEventMapIfSelected pl
    , replaceOrComeToParentEventMap pl
    ]
    where
        isHoleResult
            | ExprGuiT.plOfHoleResult pl = HoleResult
            | otherwise = NotHoleResult

mkEventMapWithPickers ::
    (Functor f, Monad m) =>
    HolePickers m ->
    [ModKey] -> E.Doc ->
    (f Sugar.EntityId -> T m Widget.Id) ->
    f Sugar.EntityId -> Widget.EventMap (T m Widget.EventResult)
mkEventMapWithPickers holePickers keys doc f =
    E.keyPresses keys doc .
    liftA2 mappend (ExprGuiM.holePickersAction holePickers) .
    fmap Widget.eventResultFromCursor . f

jumpHolesEventMap ::
    (Monad m, Monad f) =>
    NearestHoles -> ExprGuiM m (Widget.EventMap (T f Widget.EventResult))
jumpHolesEventMap hg =
    do
        config <- ExprGuiM.readConfig <&> Config.hole
        let jumpEventMap keys dirStr lens =
                maybe mempty
                (Widget.keysEventMapMovesCursor (keys config)
                  (E.Doc ["Navigation", jumpDoc dirStr]) . pure . WidgetIds.fromEntityId) $
                hg ^. lens
        mconcat
            [ jumpEventMap Config.holeJumpToNextKeys "next" NearestHoles.next
            , jumpEventMap Config.holeJumpToPrevKeys "previous" NearestHoles.prev
            ] & return
    where
        jumpDoc :: String -> String
        jumpDoc dirStr = "Jump to " ++ dirStr ++ " hole"

jumpHolesEventMapIfSelected ::
    (Monad m, Monad f) =>
    Sugar.Payload dummy ExprGuiT.Payload ->
    ExprGuiM m (Widget.EventMap (T f Widget.EventResult))
jumpHolesEventMapIfSelected pl =
    do
        isSelected <- ExprGuiM.isExprSelected pl
        if isSelected
            then pl ^. Sugar.plData . ExprGuiT.plNearestHoles & jumpHolesEventMap
            else pure mempty

extractCursor :: Sugar.ExtractToDestination -> Widget.Id
extractCursor (Sugar.ExtractToLet letId) = WidgetIds.fromEntityId letId
extractCursor (Sugar.ExtractToDef defId) =
    WidgetIds.nameEditOf (WidgetIds.fromEntityId defId)

extractEventMap ::
    Functor m =>
    Config -> Sugar.Actions m -> Widget.EventMap (T m Widget.EventResult)
extractEventMap config actions =
    actions ^. Sugar.extract <&> extractCursor
    & Widget.keysEventMapMovesCursor keys doc
    where
        doc = E.Doc ["Edit", "Extract"]
        keys = Config.extractKeys config

replaceOrComeToParentEventMap ::
    (Monad m, Monad f) =>
    Sugar.Payload f ExprGuiT.Payload ->
    ExprGuiM m (Widget.EventMap (T f Widget.EventResult))
replaceOrComeToParentEventMap pl =
    do
        config <- ExprGuiM.readConfig
        isSelected <- ExprGuiM.isExprSelected pl
        return $
            if isSelected
            then replaceEventMap config (pl ^. Sugar.plActions)
            else
                Widget.keysEventMapMovesCursor (Config.delKeys config)
                (E.Doc ["Navigation", "Select parent"]) selectParent
    where
        selectParent =
            WidgetIds.fromExprPayload pl
            & WidgetIds.notDelegatingId
            & return

actionsEventMap ::
    (Monad m, Monad f) =>
    HolePickers f -> IsHoleResult -> Sugar.Actions f ->
    ExprGuiM m (Widget.EventMap (T f Widget.EventResult))
actionsEventMap holePickers isHoleResult actions =
    do
        config <- ExprGuiM.readConfig
        return $ mconcat
            [ wrapEventMap holePickers config
            , applyOperatorEventMap holePickers
            , case isHoleResult of
              HoleResult -> mempty
              NotHoleResult -> extractEventMap config
            ] actions

applyOperatorEventMap ::
    Monad m =>
    HolePickers m -> Sugar.Actions m -> Widget.EventMap (T m Widget.EventResult)
applyOperatorEventMap holePickers actions =
    case actions ^. Sugar.wrap of
    Sugar.WrapAction wrap -> action wrap
    Sugar.WrapperAlready holeId -> action $ return holeId
    Sugar.WrappedAlready holeId -> action $ return holeId
    Sugar.WrapNotAllowed -> mempty
    where
        doc = E.Doc ["Edit", ExprGuiM.holePickersAddDocPrefix holePickers "Apply operator"]
        action wrap =
            E.charGroup "Operator" doc operatorChars $ \c ->
                mappend
                <$> ExprGuiM.holePickersAction holePickers
                <*> do
                    (uuid, entityId) <- wrap
                    cursor <- HoleEditState.setHoleStateAndJump uuid (HoleState [c]) entityId
                    return $ Widget.eventResultFromCursor cursor

wrapEventMap ::
    Monad m =>
    HolePickers m -> Config ->
    Sugar.Actions m -> Widget.EventMap (T m Widget.EventResult)
wrapEventMap holePickers config actions =
    case actions ^. Sugar.wrap of
    Sugar.WrapAction wrap ->
        mkEventMapWithPickers holePickers
        (Config.wrapKeys config)
        (E.Doc ["Edit", ExprGuiM.holePickersAddDocPrefix holePickers "Wrap"])
        (fmap (HoleWidgetIds.hidOpen . HoleWidgetIds.make)) (snd <$> wrap)
    Sugar.WrapperAlready _ -> mempty
    Sugar.WrappedAlready _ -> mempty
    Sugar.WrapNotAllowed -> mempty

replaceEventMap ::
    Functor m =>
    Config -> Sugar.Actions m -> Widget.EventMap (T m Widget.EventResult)
replaceEventMap config actions =
    mconcat
    [ case actions ^. Sugar.setToInnerExpr of
      Sugar.SetToInnerExpr action ->
          mk "Replace with inner expression" delKeys action
      Sugar.NoInnerExpr -> mempty
    , case actions ^. Sugar.setToHole of
      Sugar.SetToHole action ->
          mk "Delete expression" delKeys (fmap snd action)
      Sugar.SetWrapperToHole action ->
          mk "Delete outer hole" delKeys (fmap snd action)
      Sugar.AlreadyAHole -> mempty
      Sugar.AlreadyAppliedToHole -> mempty
    ]
    where
        mk doc keys = mkEventMap keys (E.Doc ["Edit", doc])
        delKeys = Config.delKeys config
        mkEventMap keys doc =
            Widget.keysEventMapMovesCursor keys doc .
            fmap WidgetIds.fromEntityId

modifyEventMap ::
    Monad m =>
    HolePickers m -> Config ->
    Sugar.Actions m -> Widget.EventMap (T m Widget.EventResult)
modifyEventMap holePickers config =
    mconcat
    [ wrapEventMap holePickers config
    , applyOperatorEventMap holePickers
    , replaceEventMap config
    ]
