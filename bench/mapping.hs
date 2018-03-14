{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses #-}

{- |
   Module      : Main
   Description : Benchmark how to concurrently map a function
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   This duplicates a lot of functionality from Streaming.Concurrent to
   help verify that the right design choices were made (we don't
   import existing definitions in case of locality\/inlining\/etc.).

   To be also able to better match the behaviour of the non-concurrent
   variants, the type signatures of all functions have been
   specialised slightly.

   Note that for the cases of @n = 1@, the concurrent variants have a
   slight advantage in that - despite the overhead of concurrency -
   three threads (one for writing, one for mapping and one for
   reading) are used.  If @replicateConcurrently_ n@ is removed and
   the benchmarks manually re-run, one of these threads are removed
   and the overhead becomes more apparent.

   Suffixes used:

   [@B@] Uses bounded buffers (buffers are the same size as the number of
         concurrent tasks).

   [@D@] As with @B@ but uses buffers that are double the size of the
         number of concurrent tasks.

   [@U@] Uses unbounded buffers.

   [@S@] Uses 'Stream's between the two buffers.

   [@I@] Does not use 'Stream's between the two buffers (read a value,
         operates, immediately writes to the next buffer).

   [@N@] Non-concurrent (i.e. uses definition from "Streaming.Prelude")

 -}
module Main (main) where

import Streaming.Concurrent (Buffer, InBasket(..), OutBasket(..), bounded,
                             unbounded, withBuffer, withStreamBasket,
                             writeStreamBasket)

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async.Lifted (replicateConcurrently_)
import           Control.Concurrent.STM          (atomically)
import           Control.Monad                   (forM_, when)
import           Control.Monad.Base              (MonadBase, liftBase)
import           Control.Monad.Catch             (MonadMask)
import           Control.Monad.Trans.Control     (MonadBaseControl)
import           Streaming
import qualified Streaming.Prelude               as S

import Test.HUnit ((@?))
import TestBench

--------------------------------------------------------------------------------

main :: IO ()
main = testBench $ do
  collection "Pure maps" $ do
    compareFuncAllIO "show" (pureMap 10 show inputs S.toList_) normalFormIO
    collection "Fibonacci" $
      mapM_ compFib numThreads
  collection "Monadic maps" $ do
    collection "Fibonacci (return'ed)" $
      mapM_ compFibM numThreads
    collection "Identical sleep" $
      mapM_ compDelaySame numThreads
    collection "Different sleep" $
      mapM_ compDelayDiffer numThreads
  where
    compFib n = compareFuncAllIO (show n ++ " tasks")
                                 (pureMap n fib inputs S.toList_)
                                 normalFormIO

    compFibM n = compareFuncAllIO (show n ++ " tasks")
                                  (monadicMap n (return . fib) inputs S.toList_)
                                  normalFormIO

    compDelaySame n = compareFuncAllIO (show n ++ " tasks")
                                       (monadicMap n delayReturn inputs S.toList_)
                                       normalFormIO

    compDelayDiffer n = compareFuncAllIO (show n ++ " tasks")
                                         (monadicMap n ensureDelay mixedInputs S.length_)
                                         normalFormIO

    numThreads = [1, 5, 10]

-- | We use the same value repeated to avoid having to sort the
--   results, as that would give the non-concurrent variants an
--   advantage.
inputs :: Stream (Of Int) IO ()
inputs = S.replicate 1000 20

delayReturn :: Int -> IO Int
delayReturn n = threadDelay n `seq` return n

-- For when ordering can't be enforced.
ensureDelay :: Int -> IO ()
ensureDelay n = threadDelay n `seq` return ()

mixedInputs :: Stream (Of Int) IO ()
mixedInputs = S.concat (S.replicate 123 [10..17])

--------------------------------------------------------------------------------

data MapType = NonConcurrent
             | BoundedImmediate
             | BoundedStreamed
             | DoubleImmediate
             | DoubleStreamed
             | UnboundedImmediate
             | UnboundedStreamed
  deriving (Eq, Ord, Show, Read, Bounded, Enum)

pureMap :: Int -> (a -> b) -> Stream (Of a) IO () -> (Stream (Of b) IO () -> IO r)
           -> MapType -> IO r
pureMap n f inp cont pm = go pm n f inp cont
  where
    go NonConcurrent      = withStreamMapN
    go BoundedImmediate   = withStreamMapBI
    go BoundedStreamed    = withStreamMapBS
    go DoubleImmediate    = withStreamMapDI
    go DoubleStreamed     = withStreamMapDS
    go UnboundedImmediate = withStreamMapUI
    go UnboundedStreamed  = withStreamMapUS

monadicMap :: Int -> (a -> IO b) -> Stream (Of a) IO () -> (Stream (Of b) IO () -> IO r)
              -> MapType -> IO r
monadicMap n f inp cont pm = go pm n f inp cont
  where
    go NonConcurrent      = withStreamMapMN
    go BoundedImmediate   = withStreamMapMBI
    go BoundedStreamed    = withStreamMapMBS
    go DoubleImmediate    = withStreamMapMDI
    go DoubleStreamed     = withStreamMapMDS
    go UnboundedImmediate = withStreamMapMUI
    go UnboundedStreamed  = withStreamMapMUS

-- Naive fibonacci implementation
fib :: Int -> Int
fib 0 = 1
fib 1 = 1
fib n = fib (n-1) + fib (n-2)

--------------------------------------------------------------------------------
-- Non-concurrent variants.  Take an unused Int just to match the types.

withStreamMapN :: (Monad m) => Int -> (a -> b) -> Stream (Of a) m ()
                  -> (Stream (Of b) m () -> m r) -> m r
withStreamMapN _ f str cont = cont (S.map f str)

withStreamMapMN :: (Monad m) => Int -> (a -> m b) -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMN _ f str cont = cont (S.mapM f str)

--------------------------------------------------------------------------------
-- Bounded buffer variants

withStreamMapBI :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapBI n f inp cont =
  withBufferedTransformB n (joinBuffers f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapMBI :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMBI n f inp cont =
  withBufferedTransformB n (joinBuffersM f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapBS :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapBS n = withStreamTransformB n . S.map

withStreamMapMBS :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMBS n = withStreamTransformB n . S.mapM

withStreamTransformB :: (MonadMask m, MonadBaseControl IO m)
                        => Int -- ^ How many concurrent computations to run.
                        -> (Stream (Of a) m () -> Stream (Of b) m t)
                        -> Stream (Of a) m ()
                        -> (Stream (Of b) m () -> m r) -> m r
withStreamTransformB n f inp cont =
  withBufferedTransformB n (joinBuffersStream f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withBufferedTransformB :: (MonadMask m, MonadBaseControl IO m)
                          => Int
                             -- ^ How many concurrent computations to run.
                          -> (OutBasket a -> InBasket b -> m ab)
                             -- ^ What to do with each individual concurrent
                             --   computation; result is ignored.
                          -> (InBasket a -> m ())
                             -- ^ Provide initial data; result is ignored.
                          -> (OutBasket b -> m r) -> m r
withBufferedTransformB n transform feed consume =
  withBuffer buff feed $ \obA ->
    withBuffer buff (replicateConcurrently_ n . transform obA)
      consume
  where
    buff :: Buffer v
    buff = bounded n

--------------------------------------------------------------------------------
-- Double-Bounded buffer variants

withStreamMapDI :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapDI n f inp cont =
  withBufferedTransformD n (joinBuffers f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapMDI :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMDI n f inp cont =
  withBufferedTransformD n (joinBuffersM f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapDS :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapDS n = withStreamTransformD n . S.map

withStreamMapMDS :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMDS n = withStreamTransformD n . S.mapM

withStreamTransformD :: (MonadMask m, MonadBaseControl IO m)
                        => Int -- ^ How many concurrent computations to run.
                        -> (Stream (Of a) m () -> Stream (Of b) m t)
                        -> Stream (Of a) m ()
                        -> (Stream (Of b) m () -> m r) -> m r
withStreamTransformD n f inp cont =
  withBufferedTransformD n (joinBuffersStream f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withBufferedTransformD :: (MonadMask m, MonadBaseControl IO m)
                          => Int
                             -- ^ How many concurrent computations to run.
                          -> (OutBasket a -> InBasket b -> m ab)
                             -- ^ What to do with each individual concurrent
                             --   computation; result is ignored.
                          -> (InBasket a -> m ())
                             -- ^ Provide initial data; result is ignored.
                          -> (OutBasket b -> m r) -> m r
withBufferedTransformD n transform feed consume =
  withBuffer buff feed $ \obA ->
    withBuffer buff (replicateConcurrently_ n . transform obA)
      consume
  where
    buff :: Buffer v
    buff = bounded (2*n)

--------------------------------------------------------------------------------

withStreamMapUI :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapUI n f inp cont =
  withBufferedTransformU n (joinBuffers f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapMUI :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMUI n f inp cont =
  withBufferedTransformU n (joinBuffersM f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withStreamMapUS :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapUS n = withStreamTransformU n . S.map

withStreamMapMUS :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMUS n = withStreamTransformU n . S.mapM

withStreamTransformU :: (MonadMask m, MonadBaseControl IO m)
                        => Int -- ^ How many concurrent computations to run.
                        -> (Stream (Of a) m () -> Stream (Of b) m t)
                        -> Stream (Of a) m ()
                        -> (Stream (Of b) m () -> m r) -> m r
withStreamTransformU n f inp cont =
  withBufferedTransformU n (joinBuffersStream f) feed consume
  where
    feed = writeStreamBasket inp

    consume = flip withStreamBasket cont

withBufferedTransformU :: (MonadMask m, MonadBaseControl IO m)
                          => Int
                             -- ^ How many concurrent computations to run.
                          -> (OutBasket a -> InBasket b -> m ab)
                             -- ^ What to do with each individual concurrent
                             --   computation; result is ignored.
                          -> (InBasket a -> m ())
                             -- ^ Provide initial data; result is ignored.
                          -> (OutBasket b -> m r) -> m r
withBufferedTransformU n transform feed consume =
  withBuffer buff feed $ \obA ->
    withBuffer buff (replicateConcurrently_ n . transform obA)
      consume
  where
    buff :: Buffer v
    buff = unbounded

--------------------------------------------------------------------------------

joinBuffers :: (MonadBase IO m) => (a -> b) -> OutBasket a -> InBasket b -> m ()
joinBuffers f obA ibB = liftBase go
  where
    go = do ma <- atomically (receiveMsg obA)
            forM_ ma $ \a ->
              do s <- atomically (sendMsg ibB (f a))
                 when s go

joinBuffersM :: (MonadBase IO m) => (a -> m b) -> OutBasket a -> InBasket b -> m ()
joinBuffersM f obA ibB = go
  where
    go = do ma <- liftBase (atomically (receiveMsg obA))
            forM_ ma $ \a ->
              do b <- f a
                 s <- liftBase (atomically (sendMsg ibB b))
                 when s go

joinBuffersStream :: (MonadBase IO m) => (Stream (Of a) m () -> Stream (Of b) m t)
                     -> OutBasket a -> InBasket b -> m ()
joinBuffersStream f obA ibB = withStreamBasket obA
                                (flip writeStreamBasket ibB . f)
