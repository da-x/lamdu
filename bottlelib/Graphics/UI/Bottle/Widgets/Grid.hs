{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, OverloadedStrings, RecordWildCards, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Graphics.UI.Bottle.Widgets.Grid
    ( Grid, KGrid(..)
    , make, makeKeyed, makeAlign, makeCentered
    , unkey
    , Alignment
    , gridMCursor, gridSize, gridContent
    , Element
    , elementAlign, elementRect, elementOriginalWidget
    , Cursor
    , Keys(..), stdKeys
    , toWidget, toWidgetWithKeys
    , toWidgetBiased, toWidgetBiasedWithKeys
    ) where

import           Prelude.Compat

import           Control.Applicative (liftA2)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad (msum)
import           Data.Function (on)
import           Data.List (foldl', transpose, find)
import           Data.List.Utils (groupOn, sortOn, minimumOn)
import           Data.MRUMemo (memo)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Vector.Vector2 (Vector2(..))
import qualified Data.Vector.Vector2 as Vector2
import           Graphics.UI.Bottle.Direction (Direction)
import qualified Graphics.UI.Bottle.Direction as Direction
import qualified Graphics.UI.Bottle.EventMap as EventMap
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import qualified Graphics.UI.Bottle.ModKey as ModKey
import           Graphics.UI.Bottle.Rect (Rect(..))
import qualified Graphics.UI.Bottle.Rect as Rect
import           Graphics.UI.Bottle.View (View(..))
import           Graphics.UI.Bottle.Widget (R, Widget(Widget))
import qualified Graphics.UI.Bottle.Widget as Widget
import           Graphics.UI.Bottle.Widgets.GridView (Alignment)
import qualified Graphics.UI.Bottle.Widgets.GridView as GridView
import           Graphics.UI.Bottle.Widgets.StdKeys (DirKeys(..), stdDirKeys)
import qualified Graphics.UI.GLFW as GLFW

type Cursor = Vector2 Int

length2d :: [[a]] -> Vector2 Int
length2d xs = Vector2 (foldl' max 0 . map length $ xs) (length xs)

capCursor :: Vector2 Int -> Vector2 Int -> Vector2 Int
capCursor size = fmap (max 0) . liftA2 min (subtract 1 <$> size)

data NavDests a = NavDests
    { leftOfCursor
    , aboveCursor
    , rightOfCursor
    , belowCursor
    , topCursor
    , leftMostCursor
    , bottomCursor
    , rightMostCursor :: Maybe (Widget.EnterResult a)
    }

mkNavDests ::
    Widget.Size -> Rect -> [[Maybe (Direction -> Widget.EnterResult a)]] ->
    Cursor -> NavDests a
mkNavDests widgetSize prevFocalArea mEnterss cursor@(Vector2 cursorX cursorY) = NavDests
    { leftOfCursor    = givePrevFocalArea . reverse $ take cursorX curRow
    , aboveCursor     = givePrevFocalArea . reverse $ take cursorY curColumn
    , rightOfCursor   = givePrevFocalArea $ drop (cursorX+1) curRow
    , belowCursor     = givePrevFocalArea $ drop (cursorY+1) curColumn

    , topCursor       = giveEdge (Vector2 Nothing (Just 0)) $ take (min 1 cursorY) curColumn
    , leftMostCursor  = giveEdge (Vector2 (Just 0) Nothing) $ take (min 1 cursorX) curRow
    , bottomCursor    = giveEdge (Vector2 Nothing (Just 1)) . take 1 . reverse $ drop (cursorY+1) curColumn
    , rightMostCursor = giveEdge (Vector2 (Just 1) Nothing) . take 1 . reverse $ drop (cursorX+1) curRow
    }
    where
        curRow = fromMaybe [] $ mEnterss ^? Lens.ix cappedY
        curColumn = fromMaybe [] $ transpose mEnterss ^? Lens.ix cappedX
        Vector2 cappedX cappedY = capCursor size cursor
        size = length2d mEnterss

        give rect = fmap ($ Direction.PrevFocalArea rect) . msum
        givePrevFocalArea = give prevFocalArea
        giveEdge edge = give Rect
            { Rect._topLeft =
                    liftA2 fromMaybe (Rect._topLeft prevFocalArea) $
                    liftA2 (fmap . (*)) widgetSize edge
            , Rect._size =
                    liftA2 fromMaybe (Rect._size prevFocalArea) $
                    (fmap . fmap) (const 0) edge
            }

data Keys key = Keys
    { keysDir :: DirKeys key
    , keysMoreLeft :: [key]
    , keysMoreRight :: [key]
    , keysLeftMost :: [key]
    , keysRightMost :: [key]
    , keysTop :: [key]
    , keysBottom :: [key]
    } deriving (Functor, Foldable, Traversable)

stdKeys :: Keys ModKey
stdKeys = Keys
    { keysDir = k <$> stdDirKeys
    , keysMoreLeft = [k GLFW.Key'Home]
    , keysMoreRight = [k GLFW.Key'End]
    , keysLeftMost = [ctrlK GLFW.Key'Home]
    , keysRightMost = [ctrlK GLFW.Key'End]
    , keysTop = [k GLFW.Key'PageUp]
    , keysBottom = [k GLFW.Key'PageDown]
    }
    where
        k = ModKey mempty
        ctrlK = ModKey.ctrl

addNavEventmap ::
    Keys ModKey -> NavDests a -> Widget.EventMap a -> Widget.EventMap a
addNavEventmap Keys{..} navDests eMap =
    strongMap <> eMap <> weakMap
    where
        weakMap =
            [ movement "left"       (keysLeft  keysDir) leftOfCursor
            , movement "right"      (keysRight keysDir) rightOfCursor
            , movement "up"         (keysUp    keysDir) aboveCursor
            , movement "down"       (keysDown  keysDir) belowCursor
            , movement "more left"  keysMoreLeft        leftMostCursor
            , movement "more right" keysMoreRight       rightMostCursor
            ] ^. Lens.traverse . Lens._Just
        strongMap =
            [ movement "top"       keysTop       topCursor
            , movement "bottom"    keysBottom    bottomCursor
            , movement "leftmost"  keysLeftMost  leftMostCursor
            , movement "rightmost" keysRightMost rightMostCursor
            ] ^. Lens.traverse . Lens._Just
        movement dirName events f =
            (EventMap.keyPresses
              events
              (EventMap.Doc ["Navigation", "Move", dirName]) .
              (^. Widget.enterResultEvent)) <$>
            f navDests

enumerate2d :: [[a]] -> [(Vector2 Int, a)]
enumerate2d xss =
    xss ^@.. Lens.traversed <.> Lens.traversed
    <&> _1 %~ uncurry (flip Vector2)

index2d :: [[a]] -> Vector2 Int -> a
index2d xss (Vector2 x y) = xss !! y !! x

getCursor :: [[Widget k]] -> Maybe Cursor
getCursor widgets =
    widgets
    & enumerate2d
    & find (Widget.isFocused . snd)
    <&> fst

data Element a = Element
    { __elementAlign :: Alignment
    , __elementRect :: Rect
    , __elementOriginalWidget :: Widget a
    }

data KGrid key a = KGrid
    { __gridMCursor :: Maybe Cursor
    , __gridSize :: Widget.Size
    , __gridContent :: [[(key, Element a)]]
    }

Lens.makeLenses ''Element
Lens.makeLenses ''KGrid

{-# INLINE elementAlign #-}
elementAlign :: Lens.Getter (Element f) Alignment
elementAlign = _elementAlign

{-# INLINE elementRect #-}
elementRect :: Lens.Getter (Element f) Rect
elementRect = _elementRect

{-# INLINE elementOriginalWidget #-}
elementOriginalWidget :: Lens.Getter (Element f) (Widget f)
elementOriginalWidget = _elementOriginalWidget

{-# INLINE gridMCursor #-}
gridMCursor :: Lens.Getter (KGrid key f) (Maybe Cursor)
gridMCursor = _gridMCursor

{-# INLINE gridSize #-}
gridSize :: Lens.Getter (KGrid key f) Widget.Size
gridSize = _gridSize

{-# INLINE gridContent #-}
gridContent :: Lens.Getter (KGrid key f) [[(key, Element f)]]
gridContent = _gridContent

type Grid = KGrid ()

makeKeyed :: [[(key, (Alignment, Widget f))]] -> KGrid key f
makeKeyed children = KGrid
    { __gridMCursor = getCursor $ (map . map) (snd . snd) children
    , __gridSize = size
    , __gridContent = content
    }
    where
        (size, content) =
            children
            & Lens.mapped . Lens.mapped %~ toTriplet
            & GridView.makePlacements
            & _2 . Lens.mapped . Lens.mapped %~ toElement
        toTriplet (key, (alignment, widget)) =
            (alignment, widget ^. Widget.size, (key, widget))
        toElement (alignment, rect, (key, widget)) =
            (key, Element alignment rect widget)

unkey :: [[(Alignment, Widget f)]] -> [[((), (Alignment, Widget f))]]
unkey = (map . map) ((,) ())

make :: [[(Alignment, Widget f)]] -> Grid f
make = makeKeyed . unkey

makeAlign :: Alignment -> [[Widget f]] -> Grid f
makeAlign alignment = make . (map . map) ((,) alignment)

makeCentered :: [[Widget f]] -> Grid f
makeCentered = makeAlign 0.5

type CombineEnters a =
    Widget.Size -> [[Maybe (Direction -> Widget.EnterResult a)]] ->
    Maybe (Direction -> Widget.EnterResult a)

toWidgetCommon :: Keys ModKey -> CombineEnters a -> KGrid key a -> Widget a
toWidgetCommon keys combineEnters (KGrid mCursor size sChildren) =
    Widget
    { _view = View size frame
    , _mEnter = combineEnters size mEnterss
    , _mFocus = mFocus
    }
    where
        frame = widgets ^. Lens.traverse . Lens.traverse . Widget.animFrame
        translateChildWidget (_key, Element _align rect widget) =
            Widget.translate (rect ^. Rect.topLeft) widget
        widgets =
            sChildren & Lens.mapped . Lens.mapped %~ translateChildWidget
        mEnterss = widgets & Lens.mapped . Lens.mapped %~ (^. Widget.mEnter)
        mFocus =
            case mCursor of
            Nothing -> Nothing
            Just cursor ->
                selectedWidgetFocus
                & Widget.eventMap %~ addNavEventmap keys navDests
                & Just
                where
                    selectedWidgetFocus =
                        selectedWidget ^. Widget.mFocus
                        & fromMaybe (error "selected unfocused widget?")
                    selectedWidget = index2d widgets cursor
                    navDests =
                        mkNavDests size (selectedWidgetFocus ^. Widget.focalArea)
                        mEnterss cursor

groupSortOn :: Ord b => (a -> b) -> [a] -> [[a]]
groupSortOn f = groupOn f . sortOn f

combineEntersBiased :: Cursor -> CombineEnters f
combineEntersBiased (Vector2 x y) size children =
    combineMEnters size children <&> maybeOverride
    where
        biased dir =
            case children ^? Lens.ix y . Lens.ix x . Lens._Just of
            Nothing -> id
            Just childEnter -> const (childEnter dir)
        unbiased = id
        maybeOverride enter dir =
            enter dir
            & case dir of
                Direction.Outside -> biased dir
                Direction.PrevFocalArea _ -> biased dir
                Direction.Point _ -> unbiased

-- ^ If unfocused, will enters the given child when entered
toWidgetBiasedWithKeys :: Keys ModKey -> Cursor -> KGrid key a -> Widget a
toWidgetBiasedWithKeys keys cursor =
    toWidgetCommon keys (combineEntersBiased cursor)

toWidgetBiased :: Cursor -> KGrid key a -> Widget a
toWidgetBiased = toWidgetBiasedWithKeys stdKeys

toWidgetWithKeys :: Keys ModKey -> KGrid key a -> Widget a
toWidgetWithKeys keys = toWidgetCommon keys combineMEnters

toWidget :: KGrid key f -> Widget f
toWidget = toWidgetWithKeys stdKeys

combineMEnters :: CombineEnters f
combineMEnters size children = chooseClosest childEnters
    where
        childEnters =
                (enumerate2d children <&> Lens.sequenceAOf _2)
                ^.. Lens.traverse . Lens._Just

        chooseClosest [] = Nothing
        chooseClosest _ = Just byDirection

        byDirection dir =
            minimumOn
            (Vector2.uncurry (+) . abs . modifyDistance .
              distance dirRect . (^. Widget.enterResultRect)) .
            map ($ dir) $ filteredByEdge edge
            where
                removeUninterestingAxis :: Vector2 R -> Vector2 R
                removeUninterestingAxis = ((1 - abs (fromIntegral <$> edge)) *)
                (modifyDistance, dirRect) = case dir of
                    Direction.Outside -> (id, Rect 0 0)
                    Direction.PrevFocalArea x -> (removeUninterestingAxis, x)
                    Direction.Point x -> (id, Rect x 0)
                edge = asEdge size dirRect

        distance = (-) `on` (^. Rect.center)

        filteredByEdge = memo $ \(Vector2 hEdge vEdge) ->
            map snd .
            safeHead . groupSortOn ((* (-hEdge)) . (^._1._1)) .
            safeHead . groupSortOn ((* (-vEdge)) . (^._1._2)) $
            childEnters

safeHead :: Monoid a => [a] -> a
safeHead = mconcat . take 1

asEdge :: Vector2 R -> Rect -> Vector2 Int
asEdge size rect =
    Vector2 hEdge vEdge
    where
        hEdge = boolToInt rightEdge - boolToInt leftEdge
        vEdge = boolToInt bottomEdge - boolToInt topEdge
        boolToInt False = 0
        boolToInt True = 1
        Vector2 leftEdge topEdge =
            (<= 0) <$> (rect ^. Rect.bottomRight)
        Vector2 rightEdge bottomEdge =
            liftA2 (>=) (rect ^. Rect.topLeft) size
