{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
module Graphics.UI.Bottle.Widgets
    ( makeTextView, makeTextViewWidget, makeLabel
    , makeFocusableView
    , makeFocusableTextView, makeFocusableLabel
    , makeTextEdit
    , makeTextEditor, makeLineEdit, makeWordEdit
    , makeFocusDelegator
    , makeChoiceWidget
    , stdFontHeight
    , stdSpacing
    , stdHSpaceWidth, stdHSpaceView
    , stdVSpaceHeight, stdVSpaceView
    , hspaceWidget, vspaceWidget, vspacer
    , hboxSpaced, hboxCenteredSpaced
    , gridHSpaced, gridHSpacedCentered
    , liftLayerInterval
    , respondToCursorPrefix
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad (when)
import           Data.ByteString.Char8 (pack)
import           Data.List (intersperse)
import           Data.Store.Property (Property)
import qualified Data.Store.Property as Property
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import           Graphics.UI.Bottle.Animation (AnimId)
import qualified Graphics.UI.Bottle.EventMap as EventMap
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import           Graphics.UI.Bottle.View (View)
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.Choice as Choice
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified Graphics.UI.Bottle.Widgets.Grid as Grid
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer
import qualified Graphics.UI.Bottle.Widgets.TextEdit as TextEdit
import qualified Graphics.UI.Bottle.Widgets.TextView as TextView
import           Graphics.UI.Bottle.WidgetsEnvT (WidgetEnvT)
import qualified Graphics.UI.Bottle.WidgetsEnvT as WE
import qualified Graphics.UI.GLFW as GLFW

import           Prelude.Compat

makeTextView ::
    Monad m => String -> AnimId -> WidgetEnvT m View
makeTextView text myId = do
    style <- WE.readTextStyle
    return $
        TextView.make (style ^. TextEdit.sTextViewStyle) text myId

makeTextViewWidget :: Monad m => String -> AnimId -> WidgetEnvT m (Widget f)
makeTextViewWidget text myId =
    Widget.fromView <$> makeTextView text myId

makeLabel :: Monad m => String -> AnimId -> WidgetEnvT m (Widget f)
makeLabel text prefix =
    makeTextViewWidget text $ mappend prefix [pack text]

liftLayerInterval :: Monad m => WidgetEnvT m (Widget f -> Widget f)
liftLayerInterval =
    do
        env <- WE.readEnv
        let layerDiff = WE.layerInterval env
        Widget.animLayers -~ layerDiff & return

readEnv :: Monad m => WidgetEnvT m Widget.Env
readEnv = WE.readEnv <&> (^. WE.envCursor) <&> Widget.Env

respondToCursorPrefix ::
    Monad m => Widget.Id -> WidgetEnvT m (Widget f -> Widget f)
respondToCursorPrefix myIdPrefix =
    readEnv <&> Widget.respondToCursorPrefix myIdPrefix

makeFocusableView ::
    (Monad m, Applicative f) =>
    Widget.Id ->
    WidgetEnvT m (Widget (f Widget.EventResult) -> Widget (f Widget.EventResult))
makeFocusableView myIdPrefix =
    respondToCursorPrefix myIdPrefix
    <&>
    -- TODO: make it non-prefix-related?
    fmap (Widget.takesFocus (const (pure myIdPrefix)))

makeFocusableTextView ::
    (Monad m, Applicative f) =>
    String -> Widget.Id -> WidgetEnvT m (Widget (f Widget.EventResult))
makeFocusableTextView text myId =
    makeFocusableView myId
    <*> makeTextViewWidget text (Widget.toAnimId myId)

makeFocusableLabel ::
    (Monad m, Applicative f) =>
    String -> Widget.Id -> WidgetEnvT m (Widget (f Widget.EventResult))
makeFocusableLabel text myIdPrefix =
    makeFocusableTextView text (Widget.joinId myIdPrefix [pack text])

makeFocusDelegator ::
    (Monad m, Applicative f) =>
    FocusDelegator.Config ->
    FocusDelegator.FocusEntryTarget ->
    Widget.Id ->
    WidgetEnvT m (Widget (f Widget.EventResult) -> Widget (f Widget.EventResult))
makeFocusDelegator fdConfig focusEntryTarget myId =
    readEnv <&> FocusDelegator.make fdConfig focusEntryTarget myId

makeTextEdit ::
    Monad m =>
    String -> Widget.Id ->
    WidgetEnvT m (Widget (String, Widget.EventResult))
makeTextEdit text myId =
    do
        style <- WE.readTextStyle
        env <- readEnv
        TextEdit.make style text myId env & return

makeTextEditor ::
    (Monad m, Applicative f) =>
    Property f String -> Widget.Id ->
    WidgetEnvT m (Widget (f Widget.EventResult))
makeTextEditor textRef myId =
    makeTextEdit (Property.value textRef) myId
    <&> Widget.events %~ setter
    where
        setter (newText, eventRes) =
            eventRes <$
            when (newText /= Property.value textRef) (Property.set textRef newText)

deleteKeyEventHandler :: ModKey -> Widget a -> Widget a
deleteKeyEventHandler key =
    Widget.mFocus . Lens._Just . Widget.eventMap %~
    EventMap.deleteKey (EventMap.KeyEvent GLFW.KeyState'Pressed key)

-- TODO: Editor, not Edit (consistent with makeTextEditor vs. makeTextEdit)
makeLineEdit ::
    (Monad m, Applicative f) =>
    Property f String ->
    Widget.Id ->
    WidgetEnvT m (Widget (f Widget.EventResult))
makeLineEdit textRef myId =
    makeTextEditor textRef myId <&> deleteKeyEventHandler (ModKey mempty GLFW.Key'Enter)

makeWordEdit ::
    (Monad m, Applicative f) =>
    Property f String ->
    Widget.Id ->
    WidgetEnvT m (Widget (f Widget.EventResult))
makeWordEdit textRef myId =
    makeLineEdit textRef myId <&> deleteKeyEventHandler (ModKey mempty GLFW.Key'Space)

hspaceWidget :: Widget.R -> Widget f
hspaceWidget = Widget.fromView . Spacer.makeHorizontal

vspaceWidget :: Widget.R -> Widget f
vspaceWidget = Widget.fromView . Spacer.makeVertical

stdFont :: Monad m => WidgetEnvT m Draw.Font
stdFont = WE.readEnv <&> (^. WE.envTextStyle . TextEdit.sTextViewStyle . TextView.styleFont)

stdFontHeight :: Monad m => WidgetEnvT m Double
stdFontHeight = stdFont <&> Draw.fontHeight

stdVSpaceHeight :: Monad m => WidgetEnvT m Double
stdVSpaceHeight =
    (*)
    <$> stdFontHeight
    <*> (WE.readEnv <&> WE.stdSpacing <&> (^. _2))

stdHSpaceWidth :: Monad m => WidgetEnvT m Double
stdHSpaceWidth =
    (*)
    <$> (stdFont <&> (`Draw.textAdvance` " "))
    <*> (WE.readEnv <&> WE.stdSpacing <&> (^. _1))

stdSpacing :: Monad m => WidgetEnvT m (Vector2 Double)
stdSpacing = Vector2 <$> stdHSpaceWidth <*> stdVSpaceHeight

stdHSpaceView :: Monad m => WidgetEnvT m View
stdHSpaceView = stdHSpaceWidth <&> (`Vector2` 0) <&> Spacer.make

stdVSpaceView :: Monad m => WidgetEnvT m View
stdVSpaceView = stdVSpaceHeight <&> Vector2 0 <&> Spacer.make

-- | Vertical spacer as ratio of line height
vspacer :: Monad m => Double -> WidgetEnvT m (Widget f)
vspacer ratio = stdFontHeight <&> (ratio *) <&> vspaceWidget

hboxSpaced :: Monad m => [(Box.Alignment, Widget f)] -> WidgetEnvT m (Widget f)
hboxSpaced widgets =
    stdHSpaceView
    <&> Widget.fromView
    <&> Box.hbox . (`intersperse` widgets) . (,) 0.5

hboxCenteredSpaced :: Monad m => [Widget f] -> WidgetEnvT m (Widget f)
hboxCenteredSpaced widgets =
    stdHSpaceView
    <&> Widget.fromView
    <&> Box.hboxAlign 0.5 . (`intersperse` widgets)

gridHSpaced :: Monad m => [[(Grid.Alignment, Widget f)]] -> WidgetEnvT m (Widget f)
gridHSpaced xs =
    stdHSpaceView
    <&> Widget.fromView <&> (,) 0
    <&> intersperse <&> (`map` xs)
    <&> Grid.make
    <&> Grid.toWidget

gridHSpacedCentered :: Monad m => [[Widget f]] -> WidgetEnvT m (Widget f)
gridHSpacedCentered = gridHSpaced . (map . map) ((,) 0.5)

makeChoiceWidget ::
    (Eq a, Monad m, Applicative f) =>
    (a -> f ()) -> [(a, Widget (f Widget.EventResult))] -> a ->
    Choice.Config -> Widget.Id -> WidgetEnvT m (Widget (f Widget.EventResult))
makeChoiceWidget choose children curChild choiceConfig myId =
    do
        widgetEnv <- readEnv
        Choice.make choiceConfig (children <&> annotate) myId widgetEnv
            & return
    where
        annotate (item, widget) =
            ( if item == curChild then Choice.Selected else Choice.NotSelected
            , choose item
            , widget
            )
