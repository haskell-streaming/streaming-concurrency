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
    -- $mapping
  , withStreamMap
  , withStreamMapM
  , withStreamTransform
    -- *** Primitives
  , joinBuffers
  , joinBuffersM
  , joinBuffersStream
  ) where

import           Streaming             (Of, Stream)
import           Streaming.Concurrent  (Buffer, InBasket(..), OutBasket(..),
                                        bounded, joinBuffers, joinBuffersM,
                                        joinBuffersStream, latest, newest,
                                        unbounded)
import qualified Streaming.Concurrent  as SC
import           Streaming.With.Lifted (Withable(..))

import Control.Monad.Base          (MonadBase)
import Control.Monad.Trans.Control (MonadBaseControl)

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

-- | Write a single stream to a buffer.
--
--   Type written to make it easier if this is the only stream being
--   written to the buffer.
writeStreamBasket :: (Withable w, MonadBase IO (WithMonad w))
                     => Stream (Of a) (WithMonad w) r -> InBasket a -> w ()
writeStreamBasket stream ib = liftAction (SC.writeStreamBasket stream ib)

-- | Read the output of a buffer into a stream.
--
--   Note that there is no requirement that @m ~ WithMonad w@.
--
--   @since 0.2.0.0
withStreamBasket :: (Withable w, MonadBase IO m) => OutBasket a -> w (Stream (Of a) m ())
withStreamBasket ob = liftWith (SC.withStreamBasket ob)

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

{- $mapping

These functions provide (concurrency-based rather than
parallelism-based) pseudo-equivalents to
<http://hackage.haskell.org/package/parallel/docs/Control-Parallel-Strategies.html#v:parMap parMap>.

Note however that in practice, these seem to be no better than - and
indeed often worse - than using 'S.map' and 'S.mapM'.  A benchmarking
suite is available with this library that tries to compare different
scenarios.

These implementations try to be relatively conservative in terms of
memory usage; it is possible to get better performance by using an
'unbounded' 'Buffer' but if you feed elements into a 'Buffer' much
faster than you can consume them then memory usage will increase.

The \"Primitives\" available below can assist you with defining your
own custom mapping function in conjunction with
'withBufferedTransform'.

-}

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
