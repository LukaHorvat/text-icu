{-# LANGUAGE BangPatterns, EmptyDataDecls, MagicHash, RecordWildCards,
    ScopedTypeVariables #-}

-- |
-- Module      : Data.Text.ICU.Regex.IO
-- Copyright   : (c) 2010 Bryan O'Sullivan
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Regular expression support for Unicode, implemented as bindings to
-- the International Components for Unicode (ICU) libraries.
--
-- The syntax and behaviour of ICU regular expressions are Perl-like.
-- For complete details, see the ICU User Guide entry at
-- <http://userguide.icu-project.org/strings/regexp>.
--
-- /Note/: The functions in this module are not thread safe.  For
-- thread safe use, see 'clone' below.

module Data.Text.ICU.Regex.IO
    (
    -- * Types
      Option(..)
    , ParseError(errError, errLine, errOffset)
    , Regex
    -- * Functions
    -- ** Construction
    , regex
    , regex'
    , clone
    -- ** Managing text to search
    , setText
    , getText
    -- ** Inspection
    , pattern
    -- ** Searching
    , find
    , findNext
    -- ** Match groups
    -- $groups
    , groupCount
    , start
    , end
    ) where

import Data.Text.ICU.Regex.Internal
import Control.Exception (catch)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Foreign as T
import Data.Text.Foreign (I16)
import Data.Text.ICU.Internal (UBool, UChar, asBool)
import Data.Text.ICU.Error (isRegexError)
import Data.Text.ICU.Error.Internal (ParseError(..), UParseError, UErrorCode,
                                     handleError, handleParseError)
import Data.Word (Word16, Word32)
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, touchForeignPtr,
                           withForeignPtr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (FunPtr, Ptr)
import Foreign.Storable (peek)
import Prelude hiding (catch)
import System.IO.Unsafe (unsafePerformIO)
                   
-- $groups
--
-- Capturing groups are numbered starting from zero.  Group zero is
-- always the entire matching text.  Groups greater than zero contain
-- the text matching each capturing group in a regular expression.

-- | Compile a regular expression with the given options.  This is
-- safest to use when the pattern is constructed at run time.
regex' :: [Option] -> Text -> IO (Either ParseError Regex)
regex' opts pat = (Right `fmap` regex opts pat) `catch` \(err::ParseError) ->
                  return (Left err)

-- | Set the subject text string upon which the regular expression
-- will look for matches.  This function may be called any number of
-- times, allowing the regular expression pattern to be applied to
-- different strings.
setText :: Regex -> Text -> IO ()
setText Regex{..} t = do
  (hayfp, hayLen) <- T.asForeignPtr t
  withForeignPtr reRe $ \rePtr ->
    withForeignPtr hayfp $ \hayPtr -> handleError $
      uregex_setText rePtr hayPtr (fromIntegral hayLen)
  writeIORef reText hayfp

-- | Get the subject text that is currently associated with this
-- regular expression object.
getText :: Regex -> IO (ForeignPtr Word16, Int)
getText Regex{..} =
  alloca $ \lenPtr -> do
    _ <- withForeignPtr reRe $ \rePtr -> handleError $
         uregex_getText rePtr lenPtr
    len <- peek lenPtr
    fp <- readIORef reText
    return (fp, fromIntegral len)

-- | Return the source form of the pattern used to construct this
-- regular expression or match.
pattern :: Regex -> IO Text
pattern Regex{..} = withForeignPtr reRe $ \rePtr ->
  alloca $ \lenPtr -> do
    textPtr <- handleError $ uregex_pattern rePtr lenPtr
    (T.fromPtr textPtr . fromIntegral) =<< peek lenPtr

-- | Find the first matching substring of the input string that
-- matches the pattern.
--
-- If /n/ is non-negative, the search for a match begins at the
-- specified index, and any match region is reset.
--
-- If /n/ is -1, the search begins at the start of the input region,
-- or at the start of the full string if no region has been specified.
--
-- If a match is found, 'start', 'end', and 'group' will provide more
-- information regarding the match.
find :: Regex -> Int -> IO Bool
find Regex{..} n =
    fmap asBool . withForeignPtr reRe $ \rePtr -> handleError $
    uregex_find rePtr (fromIntegral n)

-- | Find the next pattern match in the input string.  Begin searching
-- the input at the location following the end of he previous match,
-- or at the start of the string (or region) if there is no previous
-- match.
--
-- If a match is found, 'start', 'end', and 'group' will provide more
-- information regarding the match.
findNext :: Regex -> IO Bool
findNext Regex{..} =
    fmap asBool . withForeignPtr reRe $ handleError . uregex_findNext

-- | Make a copy of a compiled regular expression.  Cloning a regular
-- expression is faster than opening a second instance from the source
-- form of the expression, and requires less memory.
--
-- Note that the current input string and the position of any matched
-- text within it are not cloned; only the pattern itself and and the
-- match mode flags are copied.
--
-- Cloning can be particularly useful to threaded applications that
-- perform multiple match operations in parallel.  Each concurrent RE
-- operation requires its own instance of a 'Regex'.
clone :: Regex -> IO Regex
{-# INLINE clone #-}
clone Regex{..} = do
  fp <- newForeignPtr uregex_close =<< withForeignPtr reRe (handleError . uregex_clone)
  Regex fp `fmap` newIORef emptyForeignPtr

-- | Return the number of capturing groups in this regular
-- expression's pattern.
groupCount :: Regex -> IO Int
groupCount Regex{..} =
    fmap fromIntegral . withForeignPtr reRe $ handleError . uregex_groupCount

-- | Returns the index in the input string of the start of the text
-- matched by the specified capture group during the previous match
-- operation.  Returns 'Nothing' if the capture group was not part of
-- the last match.
start :: Regex -> Int -> IO (Maybe I16)
start Regex{..} n = do
  idx <- fmap fromIntegral . withForeignPtr reRe $ \rePtr -> handleError $
         uregex_start rePtr (fromIntegral n)
  return $! if idx == -1 then Nothing else Just idx

-- | Returns the index in the input string of the end of the text
-- matched by the specified capture group during the previous match
-- operation.  Returns 'Nothing' if the capture group was not part of
-- the last match.
end :: Regex -> Int -> IO (Maybe I16)
end Regex{..} n = do
  idx <- fmap fromIntegral . withForeignPtr reRe $ \rePtr -> handleError $
         uregex_end rePtr (fromIntegral n)
  return $! if idx == -1 then Nothing else Just idx