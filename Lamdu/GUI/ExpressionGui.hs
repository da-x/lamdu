{-# LANGUAGE NoImplicitPrelude, RecordWildCards, OverloadedStrings, RankNTypes, TypeFamilies, LambdaCase, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Lamdu.GUI.ExpressionGui
    ( ExpressionGui, egWidget, egAlignment
    -- General:
    , fromValueWidget, addBelow, addAbove
    , scale
    , pad
    , stdHSpace, stdVSpace
    , hbox, hboxSpaced
    , vboxTopFocal, vboxTopFocalSpaced, vboxTopFocalAlignedTo
    , spacedHPair
    , listWithDelDests
    , makeLabel
    , grammarLabel
    , addValBG, addValFrame, addValPadding
    , addValBGWithColor
    , liftLayers
    -- Lifted widgets:
    , makeFocusDelegator
    , makeFocusableView
    , makeNameView
    , makeNameEdit, makeNameEditWith
    , makeNameOriginEdit
    -- Info adding
    , annotationSpacer
    , NeighborVals(..)
    , EvalAnnotationOptions(..), maybeAddAnnotationWith
    , WideAnnotationBehavior(..), wideAnnotationBehaviorFromSelected
    , makeTypeView
    , evaluationResult
    -- Expression wrapping
    , MyPrecedence(..), ParentPrecedence(..), Precedence(..), Precedence.precLeft, Precedence.precRight
    , wrapExprEventMap
    , maybeAddAnnotationPl
    , stdWrap
    , parentDelegator
    , stdWrapParentExpr
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Data.Binary.Utils (encodeS)
import           Data.CurAndPrev (CurAndPrev(..), CurPrevTag(..), curPrevTag, fallbackToPrev)
import qualified Data.List as List
import qualified Data.List.Utils as ListUtils
import           Data.Store.Property (Property(..))
import           Data.Store.Transaction (Transaction)
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import           Graphics.UI.Bottle.Animation (AnimId)
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import qualified Graphics.UI.Bottle.View as View
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets as BWidgets
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified Graphics.UI.Bottle.Widgets.Layout as Layout
import qualified Graphics.UI.Bottle.Widgets.TextEdit as TextEdit
import qualified Graphics.UI.Bottle.WidgetsEnvT as WE
import qualified Graphics.UI.GLFW as GLFW
import           Lamdu.Calc.Type (Type)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Eval.Results as ER
import qualified Lamdu.GUI.CodeEdit.Settings as CESettings
import qualified Lamdu.GUI.EvalView as EvalView
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Types (ExpressionGui, ShowAnnotation(..), EvalModeShow(..), egWidget, egAlignment)
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import           Lamdu.GUI.Precedence (MyPrecedence(..), ParentPrecedence(..), Precedence(..))
import qualified Lamdu.GUI.Precedence as Precedence
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Style as Style
import           Lamdu.Sugar.Names.Types (Name(..), NameSource(..), NameCollision(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Prelude.Compat

type T = Transaction

fromValueWidget :: Widget (T m Widget.EventResult) -> ExpressionGui m
fromValueWidget = Layout.fromCenteredWidget

alignAdd ::
    (t -> ExpressionGui m -> b) -> Widget.R ->
    t -> ExpressionGui m -> b
alignAdd addFunc hAlign widgets eg =
    eg & egAlignment . _1 .~ hAlign & addFunc widgets

addAbove ::
    (Layout.AddLayout w, Layout.LayoutType w ~ ExpressionGui m) =>
    Widget.R -> [w] -> ExpressionGui m -> ExpressionGui m
addAbove = alignAdd (Layout.addBefore Layout.Vertical)

addBelow ::
    (Layout.AddLayout w, Layout.LayoutType w ~ ExpressionGui m) =>
    Widget.R -> [w] -> ExpressionGui m -> ExpressionGui m
addBelow = alignAdd (Layout.addAfter Layout.Vertical)

scale :: Vector2 Widget.R -> ExpressionGui m -> ExpressionGui m
scale = Layout.scale

pad :: Vector2 Widget.R -> ExpressionGui m -> ExpressionGui m
pad = Layout.pad

hbox :: [ExpressionGui m] -> ExpressionGui m
hbox = Layout.hbox 0.5

stdHSpace :: Monad m => ExprGuiM m (Layout.Layout f)
stdHSpace =
    ExprGuiM.widgetEnv BWidgets.stdHSpaceView
    <&> Widget.fromView
    <&> Layout.fromCenteredWidget

stdVSpace :: Monad m => ExprGuiM m (ExpressionGui f)
stdVSpace =
    ExprGuiM.widgetEnv BWidgets.stdVSpaceView
    <&> Widget.fromView
    <&> Layout.fromCenteredWidget

hboxSpaced :: Monad m => ExprGuiM m ([ExpressionGui f] -> ExpressionGui f)
hboxSpaced =
    stdHSpace
    <&> List.intersperse
    <&> fmap hbox

vboxTopFocalAlignedTo :: Widget.R -> [ExpressionGui m] -> ExpressionGui m
vboxTopFocalAlignedTo hAlign guis =
    guis <&> egAlignment . _1 .~ hAlign & vboxTopFocal

vboxTopFocal :: [ExpressionGui m] -> ExpressionGui m
vboxTopFocal [] = Layout.empty
vboxTopFocal (gui:guis) = gui & Layout.addAfter Layout.Vertical guis

vboxTopFocalSpaced ::
    Monad m => ExprGuiM m ([ExpressionGui f] -> ExpressionGui f)
vboxTopFocalSpaced =
    stdVSpace
    <&> List.intersperse
    <&> fmap vboxTopFocal

-- | Pair an item with a mid-space that becomes the combined alignment
-- point
spacedHPair :: Monad m => ExprGuiM m (ExpressionGui f -> ExpressionGui f -> ExpressionGui f)
spacedHPair =
    stdHSpace
    <&> \space x y ->
    space
    & Layout.addBefore Layout.Horizontal [x]
    & Layout.addAfter Layout.Horizontal [y]

addAnnotationBackgroundH :: (Config -> Draw.Color) -> Config -> AnimId -> ExpressionGui m -> ExpressionGui m
addAnnotationBackgroundH getColor config animId =
    egWidget %~ Widget.backgroundColor bgLayer bgAnimId bgColor
    where
        bgAnimId = animId ++ ["annotation background"]
        bgLayer = Config.layerAnnotations $ Config.layers config
        bgColor = getColor config

addAnnotationBackground :: Config -> AnimId -> ExpressionGui m -> ExpressionGui m
addAnnotationBackground = addAnnotationBackgroundH Config.valAnnotationBGColor

addAnnotationHoverBackground :: Config -> AnimId -> ExpressionGui m -> ExpressionGui m
addAnnotationHoverBackground = addAnnotationBackgroundH Config.valAnnotationHoverBGColor

data WideAnnotationBehavior
    = ShrinkWideAnnotation
    | HoverWideAnnotation
    | KeepWideAnnotation

wideAnnotationBehaviorFromSelected :: Bool -> WideAnnotationBehavior
wideAnnotationBehaviorFromSelected False = ShrinkWideAnnotation
wideAnnotationBehaviorFromSelected True = HoverWideAnnotation

-- NOTE: Also adds the background color, because it differs based on
-- whether we're hovering
applyWideAnnotationBehavior ::
    Monad m =>
    AnimId -> WideAnnotationBehavior ->
    ExprGuiM m (Vector2 Widget.R -> ExpressionGui f -> ExpressionGui f)
applyWideAnnotationBehavior _ KeepWideAnnotation = return (const id)
applyWideAnnotationBehavior animId ShrinkWideAnnotation =
    ExprGuiM.readConfig
    <&>
    \config shrinkRatio eg ->
    Layout.scaleAround (Vector2 0.5 0) shrinkRatio eg
    & addAnnotationBackground config animId
applyWideAnnotationBehavior animId HoverWideAnnotation =
    do
        config <- ExprGuiM.readConfig
        lifter <- liftLayers
        shrinker <- applyWideAnnotationBehavior animId ShrinkWideAnnotation
        return $
            \shrinkRatio eg ->
                lifter eg
                & addAnnotationHoverBackground config animId
                & (`Layout.hoverInPlaceOf` shrinker shrinkRatio eg)

processAnnotationGui ::
    Monad m =>
    AnimId -> WideAnnotationBehavior ->
    ExprGuiM m (Widget.R -> ExpressionGui f -> ExpressionGui f)
processAnnotationGui animId wideAnnotationBehavior =
    f
    <$> ExprGuiM.readConfig
    <*> applyWideAnnotationBehavior animId wideAnnotationBehavior
    where
        f config applyWide minWidth annotationEg =
            maybeTooNarrow annotationEg & maybeTooWide
            where
                annotationWidth = annotationEg ^. Layout.width
                width = max annotationWidth minWidth
                expansionLimit =
                    Config.valAnnotationWidthExpansionLimit config & realToFrac
                maxWidth = minWidth + expansionLimit
                shrinkAtLeast = Config.valAnnotationShrinkAtLeast config & realToFrac
                shrinkRatio =
                    annotationWidth - shrinkAtLeast & min maxWidth & max minWidth
                    & (/ annotationWidth) & pure
                maybeTooNarrow
                    | minWidth > annotationWidth = pad (Vector2 ((width - annotationWidth) / 2) 0)
                    | otherwise = id
                maybeTooWide
                    | annotationWidth > minWidth + max shrinkAtLeast expansionLimit =
                        applyWide shrinkRatio
                    | otherwise = addAnnotationBackground config animId

data EvalResDisplay = EvalResDisplay
    { erdScope :: ER.ScopeId
    , erdSource :: CurPrevTag
    , erdVal :: ER.Val Type
    }

makeEvaluationResultView ::
    Monad m => AnimId -> EvalResDisplay -> ExprGuiM m (ExpressionGui f)
makeEvaluationResultView animId res =
    do
        config <- ExprGuiM.readConfig
        view <- EvalView.make (animId ++ [encodeS (erdScope res)]) (erdVal res)
        view
            & case erdSource res of
            Current -> id
            Prev -> View.tint (Config.staleResultTint (Config.eval config))
            & return
    <&> Widget.fromView
    <&> fromValueWidget

makeTypeView :: Monad m => Type -> AnimId -> ExprGuiM m (ExpressionGui f)
makeTypeView typ animId =
    TypeView.make animId typ <&> fromValueWidget . Widget.fromView

data NeighborVals a = NeighborVals
    { prevNeighbor :: a
    , nextNeighbor :: a
    } deriving (Functor, Foldable, Traversable)

makeEvalView ::
    Monad m =>
    NeighborVals (Maybe EvalResDisplay) -> EvalResDisplay ->
    AnimId -> ExprGuiM m (ExpressionGui f)
makeEvalView (NeighborVals mPrev mNext) evalRes animId =
    do
        config <- ExprGuiM.readConfig
        let Config.Eval{..} = Config.eval config
        let makeEvaluationResultViewBG res =
                makeEvaluationResultView animId res
                <&> addAnnotationBackground config (animId ++ [encodeS (erdScope res)])
        let neighbourViews n =
                n ^.. Lens._Just
                <&> makeEvaluationResultViewBG
                <&> Lens.mapped %~
                    pad (neighborsPadding <&> realToFrac) .
                    scale (neighborsScaleFactor <&> realToFrac)
        prevs <- sequence (neighbourViews mPrev)
        nexts <- sequence (neighbourViews mNext)
        evalView <- makeEvaluationResultView animId evalRes
        evalView
            & Layout.addBefore Layout.Horizontal prevs
            & Layout.addAfter Layout.Horizontal nexts
            & (`Layout.hoverInPlaceOf` evalView)
            & return

annotationSpacer :: Monad m => ExprGuiM m (ExpressionGui f)
annotationSpacer = ExprGuiM.vspacer Config.valAnnotationSpacing <&> fromValueWidget

addAnnotationH ::
    Monad m =>
    (AnimId -> ExprGuiM m (ExpressionGui f)) ->
    WideAnnotationBehavior -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
addAnnotationH f wideBehavior entityId =
    do
        vspace <- annotationSpacer
        annotationEg <- f animId
        processAnn <- processAnnotationGui animId wideBehavior
        return $
            \eg ->
            vboxTopFocal
            [ eg & egAlignment . _1 .~ 0.5
            , vspace
            , processAnn (eg ^. Layout.width) annotationEg
            ]
    where
        animId = WidgetIds.fromEntityId entityId & Widget.toAnimId

addInferredType ::
    Monad m =>
    Type -> WideAnnotationBehavior -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
addInferredType typ = addAnnotationH (makeTypeView typ)

addEvaluationResult ::
    Monad m =>
    Type -> NeighborVals (Maybe EvalResDisplay) -> EvalResDisplay ->
    WideAnnotationBehavior -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
-- REVIEW(Eyal): This is misleading when it refers to Previous results
addEvaluationResult typ neigh resDisp wideBehavior entityId =
    case (erdVal resDisp ^. ER.payload, erdVal resDisp ^. ER.body) of
    (T.TRecord T.CEmpty, _) ->
        addValBGWithColor Config.evaluatedPathBGColor (WidgetIds.fromEntityId entityId)
        <&> (egWidget %~)
    (_, ER.RFunc{}) ->
        addAnnotationH (makeTypeView typ) wideBehavior entityId
    _ -> addAnnotationH (makeEvalView neigh resDisp) wideBehavior entityId

parentExprFDConfig :: Config -> FocusDelegator.Config
parentExprFDConfig config = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = Config.enterSubexpressionKeys config
    , FocusDelegator.focusChildDoc = E.Doc ["Navigation", "Enter subexpression"]
    , FocusDelegator.focusParentKeys = Config.leaveSubexpressionKeys config
    , FocusDelegator.focusParentDoc = E.Doc ["Navigation", "Leave subexpression"]
    }

disallowedNameChars :: String
disallowedNameChars = "[]\\`()"

nameEditFDConfig :: FocusDelegator.Config
nameEditFDConfig = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = [ModKey mempty GLFW.Key'Enter]
    , FocusDelegator.focusChildDoc = E.Doc ["Edit", "Rename"]
    , FocusDelegator.focusParentKeys = [ModKey mempty GLFW.Key'Escape]
    , FocusDelegator.focusParentDoc = E.Doc ["Edit", "Done renaming"]
    }

makeNameOriginEdit ::
    Monad m => Name m -> Widget.Id -> ExprGuiM m (Widget (T m Widget.EventResult))
makeNameOriginEdit name myId =
    do
        style <- ExprGuiM.readStyle
        let textEditStyle =
                case nNameSource name of
                NameSourceAutoGenerated -> Style.styleAutoNameOrigin style
                NameSourceStored -> Style.styleNameOrigin style
        makeNameEdit name myId -- myId goes directly to name edit
            & ExprGuiM.localEnv (WE.envTextStyle .~ textEditStyle)

makeNameEdit ::
    Monad m => Name m -> Widget.Id -> ExprGuiM m (Widget (T m Widget.EventResult))
makeNameEdit = makeNameEditWith id

makeNameEditWith ::
    Monad m =>
    (Widget (T m Widget.EventResult) -> Widget (T m Widget.EventResult)) ->
    Name m -> Widget.Id -> ExprGuiM m (Widget (T m Widget.EventResult))
makeNameEditWith onActiveEditor (Name nameSrc nameCollision setName name) myId =
    ExprGuiM.makeFocusDelegator nameEditFDConfig
    FocusDelegator.FocusEntryParent myId
    <*>
    do
        collisionSuffixes <-
            makeCollisionSuffixLabels nameCollision (Widget.toAnimId myId)
        nameEdit <-
            makeWordEdit (Property storedName setName) (WidgetIds.nameEditOf myId)
            & WE.localEnv emptyStringEnv
            & ExprGuiM.widgetEnv
        return . Box.hboxCentered $ nameEdit : collisionSuffixes
    <&> onActiveEditor
    where
        emptyStringEnv env = env
            & WE.envTextStyle . TextEdit.sEmptyFocusedString .~ ""
            & WE.envTextStyle . TextEdit.sEmptyUnfocusedString .~ name
        storedName =
            case nameSrc of
            NameSourceAutoGenerated -> ""
            NameSourceStored -> name
        makeWordEdit =
            BWidgets.makeWordEdit
            <&> Lens.mapped . Lens.mapped . Widget.mFocus . Lens._Just . Widget.eventMap
                %~ E.filterChars (`notElem` disallowedNameChars)

stdWrap ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m) ->
    ExprGuiM m (ExpressionGui m)
stdWrap pl mkGui = maybeAddAnnotationPl pl <*> mkGui & wrapExprEventMap pl

makeFocusDelegator ::
    (Monad m, Monad f) =>
    FocusDelegator.Config ->
    FocusDelegator.FocusEntryTarget ->
    Widget.Id ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
makeFocusDelegator =
    ExprGuiM.makeFocusDelegator
    <&> Lens.mapped . Lens.mapped . Lens.mapped %~ (egWidget %~)

parentDelegator ::
    (Monad f, Monad m) => Widget.Id ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
parentDelegator myId =
    do
        config <- ExprGuiM.readConfig
        makeFocusDelegator (parentExprFDConfig config)
            FocusDelegator.FocusEntryChild (WidgetIds.notDelegatingId myId)

stdWrapParentExpr ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload ->
    (Widget.Id -> ExprGuiM m (ExpressionGui m)) ->
    ExprGuiM m (ExpressionGui m)
stdWrapParentExpr pl mkGui =
    parentDelegator myId <*> mkGui innerId
    & stdWrap pl
    & ExprGuiM.assignCursor myId innerId
    where
        myId = WidgetIds.fromExprPayload pl
        innerId = WidgetIds.delegatingId myId

makeFocusableView ::
    (Monad m, Monad f) =>
    Widget.Id -> ExprGuiM m (ExpressionGui f -> ExpressionGui f)
makeFocusableView myId =
    ExprGuiM.widgetEnv (BWidgets.makeFocusableView myId)
    <&> (egWidget %~)

makeLabel :: Monad m => String -> AnimId -> ExprGuiM m (ExpressionGui f)
makeLabel text animId = ExprGuiM.makeLabel text animId <&> fromValueWidget

grammarLabel :: Monad m => String -> AnimId -> ExprGuiM m (ExpressionGui f)
grammarLabel text animId =
    do
        config <- ExprGuiM.readConfig
        makeLabel text animId
            & ExprGuiM.localEnv (WE.setTextColor (Config.grammarColor config))

addValBG :: Monad m => Widget.Id -> ExprGuiM m (Widget f -> Widget f)
addValBG myId = addValBGWithColor Config.valFrameBGColor myId

addValBGWithColor ::
    Monad m =>
    (Config -> Draw.Color) -> Widget.Id -> ExprGuiM m (Widget f -> Widget f)
addValBGWithColor color myId =
    do
        config <- ExprGuiM.readConfig
        let layer = Config.layerValFrameBG $ Config.layers config
        Widget.backgroundColor layer animId (color config) & return
    where
        animId = Widget.toAnimId myId ++ ["val"]

addValPadding :: Monad m => ExprGuiM m (ExpressionGui n -> ExpressionGui n)
addValPadding =
    ExprGuiM.readConfig <&> Config.valFramePadding <&> fmap realToFrac <&> pad

liftLayers :: Monad m => ExprGuiM m (ExpressionGui n -> ExpressionGui n)
liftLayers =
    ExprGuiM.widgetEnv BWidgets.liftLayerInterval
    <&> (egWidget %~)

addValFrame ::
    Monad m => Widget.Id -> ExprGuiM m (ExpressionGui f -> ExpressionGui f)
addValFrame myId =
    (.)
    <$> (addValBG myId <&> (egWidget %~))
    <*> addValPadding

-- TODO: This doesn't belong here
makeNameView ::
    (Monad m, Monad n) =>
    Name n -> AnimId -> ExprGuiM m (Widget f)
makeNameView (Name _ collision _ name) animId =
    do
        label <- BWidgets.makeLabel name animId & ExprGuiM.widgetEnv
        suffixLabels <- makeCollisionSuffixLabels collision $ animId ++ ["suffix"]
        Box.hboxCentered (label : suffixLabels) & return

-- TODO: This doesn't belong here
makeCollisionSuffixLabels ::
    Monad m => NameCollision -> AnimId -> ExprGuiM m [Widget f]
makeCollisionSuffixLabels NoCollision _ = return []
makeCollisionSuffixLabels (Collision suffix) animId =
    do
        config <- ExprGuiM.readConfig
        let Config.Name{..} = Config.name config
            onSuffixWidget =
                Widget.backgroundColor (Config.layerNameCollisionBG (Config.layers config))
                    animId collisionSuffixBGColor .
                Widget.scale (realToFrac <$> collisionSuffixScaleFactor)
        BWidgets.makeLabel (show suffix) animId
            & WE.localEnv (WE.setTextColor collisionSuffixTextColor)
            <&> (:[]) . onSuffixWidget
            & ExprGuiM.widgetEnv

wrapExprEventMap ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m) ->
    ExprGuiM m (ExpressionGui m)
wrapExprEventMap pl action =
    do
        (res, resultPickers) <- ExprGuiM.listenResultPickers action
        exprEventMap <- ExprEventMap.make resultPickers pl
        res
            & egWidget %~ Widget.weakerEvents exprEventMap
            & return

maybeAddAnnotationPl ::
    Monad m =>
    Sugar.Payload x ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotationPl pl =
    do
        wideAnnotationBehavior <-
            if showAnnotation ^. ExprGuiT.showExpanded
            then return KeepWideAnnotation
            else ExprGuiM.isExprSelected pl <&> wideAnnotationBehaviorFromSelected
        maybeAddAnnotation wideAnnotationBehavior
            showAnnotation
            (pl ^. Sugar.plAnnotation)
            (pl ^. Sugar.plEntityId)
    where
        showAnnotation = pl ^. Sugar.plData . ExprGuiT.plShowAnnotation

evaluationResult ::
    Monad m =>
    Sugar.Payload m ExprGuiT.Payload -> ExprGuiM m (Maybe (ER.Val Type))
evaluationResult pl =
    ExprGuiM.readMScopeId
    <&> valOfScope (pl ^. Sugar.plAnnotation)
    <&> Lens.mapped %~ erdVal

data EvalAnnotationOptions
    = NormalEvalAnnotation
    | WithNeighbouringEvalAnnotations (NeighborVals (Maybe Sugar.BinderParamScopeId))

maybeAddAnnotation ::
    Monad m =>
    WideAnnotationBehavior -> ShowAnnotation -> Sugar.Annotation -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotation = maybeAddAnnotationWith NormalEvalAnnotation

data AnnotationMode
    = AnnotationModeNone
    | AnnotationModeTypes
    | AnnotationModeEvaluation (NeighborVals (Maybe EvalResDisplay)) EvalResDisplay

getAnnotationMode :: Monad m => EvalAnnotationOptions -> Sugar.Annotation -> ExprGuiM m AnnotationMode
getAnnotationMode opt annotation =
    do
        settings <- ExprGuiM.readSettings
        case settings ^. CESettings.sInfoMode of
            CESettings.None -> return AnnotationModeNone
            CESettings.Types -> return AnnotationModeTypes
            CESettings.Evaluation ->
                ExprGuiM.readMScopeId <&> valOfScope annotation
                <&> maybe AnnotationModeNone (AnnotationModeEvaluation neighbourVals)
    where
        neighbourVals =
            case opt of
            NormalEvalAnnotation -> NeighborVals Nothing Nothing
            WithNeighbouringEvalAnnotations neighbors ->
                neighbors <&> (>>= valOfScopePreferCur annotation . (^. Sugar.bParamScopeId))

maybeAddAnnotationWith ::
    Monad m =>
    EvalAnnotationOptions -> WideAnnotationBehavior -> ShowAnnotation ->
    Sugar.Annotation -> Sugar.EntityId ->
    ExprGuiM m (ExpressionGui f -> ExpressionGui f)
maybeAddAnnotationWith opt wideAnnotationBehavior ShowAnnotation{..} annotation entityId =
    getAnnotationMode opt annotation
    >>= \case
    AnnotationModeNone
        | _showExpanded -> withType
        | otherwise -> noAnnotation
    AnnotationModeEvaluation n v ->
        case _showInEvalMode of
        EvalModeShowNothing -> noAnnotation
        EvalModeShowType -> withType
        EvalModeShowEval -> withVal n v
    AnnotationModeTypes
        | _showInTypeMode -> withType
        | otherwise -> noAnnotation
    where
        noAnnotation = pure id
        -- concise mode and eval mode with no result
        inferredType = annotation ^. Sugar.aInferredType
        withType =
            addInferredType inferredType wideAnnotationBehavior entityId
        withVal neighborVals scopeAndVal =
            addEvaluationResult inferredType neighborVals scopeAndVal
            wideAnnotationBehavior entityId

valOfScope :: Sugar.Annotation -> CurAndPrev (Maybe ER.ScopeId) -> Maybe EvalResDisplay
valOfScope annotation mScopeIds =
    go
    <$> curPrevTag
    <*> annotation ^. Sugar.aMEvaluationResult
    <*> mScopeIds
    & fallbackToPrev
    where
        go _ _ Nothing = Nothing
        go tag ann (Just scopeId) =
            ann ^? Lens._Just . Lens.at scopeId . Lens._Just
            <&> EvalResDisplay scopeId tag

valOfScopePreferCur :: Sugar.Annotation -> ER.ScopeId -> Maybe EvalResDisplay
valOfScopePreferCur annotation = valOfScope annotation . pure . Just

listWithDelDests :: k -> k -> (a -> k) -> [a] -> [(k, k, a)]
listWithDelDests = ListUtils.withPrevNext
