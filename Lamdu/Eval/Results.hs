module Lamdu.Eval.Results where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Monoid (Monoid(..))
import           Lamdu.Eval.Val (ValBody, ValHead, ScopeId, ThunkId)
import qualified Lamdu.Eval.Val as EvalVal

data ComputedVal pl
    = NotYet
    | ComputedVal (ValBody (ComputedVal pl) pl)

instance Show pl => Show (ComputedVal pl) where
    show NotYet = "Computing..."
    show (ComputedVal val) = show val

instance Functor ComputedVal where
    fmap _ NotYet = NotYet
    fmap f (ComputedVal valBody) =
        valBody
        <&> f
        & EvalVal.children . Lens.mapped %~ f
        & ComputedVal

data EvalResults pl =
    EvalResults
    { erExprValues :: Map pl (Map ScopeId (ComputedVal ()))
    , erLambdaParams :: Map pl (Map ScopeId (ComputedVal ()))
    }

instance Ord pl => Monoid (EvalResults pl) where
    mempty =
        EvalResults
        { erExprValues = Map.empty
        , erLambdaParams = Map.empty
        }
    mappend x y =
        EvalResults
        { erExprValues = mappend (erExprValues x) (erExprValues y)
        , erLambdaParams = mappend (erLambdaParams x) (erLambdaParams y)
        }

derefThunkId :: Map ThunkId (ValHead pl) -> ThunkId -> ComputedVal pl
derefThunkId thunkMap thunkId =
    thunkMap ^. Lens.at thunkId
    & maybe NotYet (derefValHead thunkMap)

derefValHead :: Map ThunkId (ValHead pl) -> ValHead pl -> ComputedVal pl
derefValHead thunkMap valHead =
    valHead & EvalVal.children %~ derefThunkId thunkMap & ComputedVal