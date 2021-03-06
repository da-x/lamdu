-- Constant tag names which have special support in the runtime or the sugaring.
-- Those which are supported in the runtime are repeated in JS in rts.js.

module Lamdu.Builtins.Anchors
    ( objTag, infixlTag, infixrTag
    , bytesTid, floatTid, streamTid, textTid, arrayTid
    , headTag, tailTag, consTag, nilTag, trueTag, falseTag, justTag, nothingTag
    , startTag, stopTag, indexTag
    , valTypeParamId
    , Order, anchorTags
    ) where

import           Data.List.Utils (rightPad)
import           Data.String (IsString(..))
import           Lamdu.Calc.Type (Tag)
import qualified Lamdu.Calc.Type as T

-- We want the translation to UUID and back to not be lossy, so we
-- canonize to UUID format
bi :: IsString a => String -> a
bi = fromString . rightPad uuidLength '\x00' . ("BI:" ++)
    where
        uuidLength = 16

objTag :: Tag
objTag = bi "object"

infixlTag :: Tag
infixlTag = bi "infixl"

infixrTag :: Tag
infixrTag = bi "infixr"

indexTag :: Tag
indexTag = bi "index"

startTag :: Tag
startTag = bi "start"

stopTag :: Tag
stopTag = bi "stop"

bytesTid :: T.NominalId
bytesTid = bi "bytes"

floatTid :: T.NominalId
floatTid = bi "float"

streamTid :: T.NominalId
streamTid = bi "stream"

textTid :: T.NominalId
textTid = bi "text"

arrayTid :: T.NominalId
arrayTid = bi "array"

headTag :: Tag
headTag = bi "head"

tailTag :: Tag
tailTag = bi "tail"

consTag :: Tag
consTag = bi "cons"

nilTag :: Tag
nilTag = bi "nil"

trueTag :: Tag
trueTag = bi "true"

falseTag :: Tag
falseTag = bi "false"

justTag :: Tag
justTag = bi "just"

nothingTag :: Tag
nothingTag = bi "nothing"

valTypeParamId :: T.ParamId
valTypeParamId = bi "val"

type Order = Int

anchorTags :: [(Order, Tag, String)]
anchorTags =
    [ (0, objTag, "object")
    , (1, startTag, "start")
    , (2, stopTag, "stop")
    , (1, indexTag, "index")
    , (0, infixlTag, "infixl")
    , (1, infixrTag, "infixr")
    , (0, headTag, "head")
    , (1, tailTag, "tail")
    , (0, nilTag, "Empty")
    , (1, consTag, "NonEmpty")
    , (0, trueTag, "True")
    , (1, falseTag, "False")
    , (0, nothingTag, "Nothing")
    , (1, justTag, "Just")
    ]
