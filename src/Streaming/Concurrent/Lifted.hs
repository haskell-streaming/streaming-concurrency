{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, TypeFamilies #-}

{- |
   Module      : Streaming.Concurrent.Lifted
   Description : Lifted variants of functions in "Streaming.Concurrent"
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   This module defines variants of those in "Streaming.Concurrent" for
   use with the 'Withable' class, found in the @streaming-with@
   package.

 -}
module Streaming.Concurrent.Lifted
  ( -- * Buffers
    Buffer
  , unbounded
  , bounded
  , latest
  , newest
    -- * Using a buffer
  , withBuffer
  , withBufferedTransform
  , InBasket(..)
  , OutBasket(..)
    -- * Stream support
  , writeStreamBasket
  , withStreamBasket
  , withMergedStreams
    -- ** Mapping
  , withStreamMap
  , withStreamMapM
  , withStreamTransform
    -- * ByteString support
  , writeByteStringBasket
  , withByteStringBasket
  , withMergedByteStrings
    -- ** Mapping
    -- $bytestringtransform
  ) where

import           Data.ByteString.Streaming (ByteString)
import           Streaming                 (Of, Stream)
import           Streaming.Concurrent      (Buffer, InBasket(..), OutBasket(..),
                                            bounded, latest, newest, unbounded)
import qualified Streaming.Concurrent      as SC
import           Streaming.With.Lifted     (Withable(..))

import Control.Monad.Base          (MonadBase)
import Control.Monad.Trans.Control (MonadBaseControl)

import qualified Data.ByteString as B

--------------------------------------------------------------------------------

-- | Concurrently merge multiple streams together.
--
--   The resulting order is unspecified.
--
--   @since 0.2.0.0
withMergedStreams :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO m, Foldable t)
                     => Buffer a -> t (Stream (Of a) (WithMonad w) v)
                     -> w (Stream (Of a) m ())
withMergedStreams buff strs = liftWith (SC.withMergedStreams buff strs)

-- | A streaming 'ByteString' variant of 'withMergedStreams'.
--
--   @since 0.2.0.0
withMergedByteStrings :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n, Foldable t)
                         => Buffer B.ByteString -> t (ByteString (WithMonad w) v)
                         -> w (ByteString n ())
withMergedByteStrings buff bss = liftWith (SC.withMergedByteStrings buff bss)

-- | Write a single stream to a buffer.
--
--   Type written to make it easier if this is the only stream being
--   written to the buffer.
writeStreamBasket :: (Withable w, MonadBase IO (WithMonad w))
                     => Stream (Of a) (WithMonad w) r -> InBasket a -> w ()
writeStreamBasket stream ib = liftAction (SC.writeStreamBasket stream ib)

-- | A streaming 'ByteString' variant of 'writeStreamBasket'.
writeByteStringBasket :: (Withable w, MonadBase IO (WithMonad w))
                         => ByteString (WithMonad w) r -> InBasket B.ByteString -> w ()
writeByteStringBasket bs ib = liftAction (SC.writeByteStringBasket bs ib)

-- | Read the output of a buffer into a stream.
--
--   Note that there is no requirement that @m ~ WithMonad w@.
--
--   @since 0.2.0.0
withStreamBasket :: (Withable w, MonadBase IO m) => OutBasket a -> w (Stream (Of a) m ())
withStreamBasket ob = liftWith (SC.withStreamBasket ob)

-- | A streaming 'ByteString' variant of 'withStreamBasket'.
--
--   @since 0.2.0.0
withByteStringBasket :: (Withable w, MonadBase IO m)
                        => OutBasket B.ByteString -> w (ByteString m ())
withByteStringBasket ob = liftWith (SC.withByteStringBasket ob)

-- | Use buffers to concurrently transform the provided data.
--
--   In essence, this is a @demultiplexer -> multiplexer@
--   transformation: the incoming data is split into @n@ individual
--   segments, the results of which are then merged back together
--   again.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withBufferedTransform :: (Withable w, MonadBaseControl IO (WithMonad w))
                         => Int
                            -- ^ How many concurrent computations to run.
                         -> (OutBasket a -> InBasket b -> WithMonad w ab)
                            -- ^ What to do with each individual concurrent
                            --   computation; result is ignored.
                         -> (InBasket a -> WithMonad w i)
                            -- ^ Provide initial data; result is ignored.
                         -> w (OutBasket b)
withBufferedTransform n transform feed =
  liftWith (SC.withBufferedTransform n transform feed)

-- | Concurrently map a function over all elements of a 'Stream'.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamMap :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
                 => Int -- ^ How many concurrent computations to run.
                 -> (a -> b)
                 -> Stream (Of a) (WithMonad w) i
                 -> w (Stream (Of b) n ())
withStreamMap n f inp = liftWith (SC.withStreamMap n f inp)

-- | Concurrently map a monadic function over all elements of a
--   'Stream'.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamMapM :: (Withable w, MonadBaseControl IO (WithMonad w), MonadBase IO n)
                  => Int -- ^ How many concurrent computations to run.
                  -> (a -> WithMonad w b)
                  -> Stream (Of a) (WithMonad w) i
                  -> w (Stream (Of b) n ())
withStreamMapM n f inp = liftWith (SC.withStreamMapM n f inp)

-- | Concurrently split the provided stream into @n@ streams and
--   transform them all using the provided function.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamTransform :: ( Withable w, m ~ WithMonad w, MonadBaseControl IO m
                       , MonadBase IO n)
                       => Int -- ^ How many concurrent computations to run.
                       -> (Stream (Of a) m () -> Stream (Of b) m t)
                       -> Stream (Of a) m i
                       -> w (Stream (Of b) n ())
withStreamTransform n f inp = liftWith (SC.withStreamTransform n f inp)

{- $bytestringtransform

No 'ByteString' equivalents of 'withStreamMap', etc. are provided as
it is very rare for individual chunks of a 'ByteString' - the sizes of
which can vary - to be independent of their position within the
overall stream.

If you can make such guarantees (e.g. you know that each chunk is a
distinct line and the ordering of these doesn't matter) then you can
use 'withBufferedTransform' to write your own.

-}

-- | Use a buffer to asynchronously communicate.
--
--   Two functions are taken as parameters:
--
--   * How to provide input to the buffer (the result of this is
--     discarded)
--
--   * How to take values from the buffer
--
--   As soon as one function indicates that it is complete then the
--   other is terminated.  This is safe: trying to write data to a
--   closed buffer will not achieve anything.
--
--   However, reading a buffer that has not indicated that it is
--   closed (e.g. waiting on an action to complete to be able to
--   provide the next value) but contains no values will block.
withBuffer :: (Withable w, MonadBaseControl IO (WithMonad w))
              => Buffer a -> (InBasket a -> WithMonad w i) -> w (OutBasket a)
withBuffer buffer sendIn = liftWith (SC.withBuffer buffer sendIn)
