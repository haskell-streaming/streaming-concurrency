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

   Suffixes used:

   [@B@] Uses bounded buffers (buffers are the same size as the number of
         concurrent tasks).

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

import           Control.Concurrent.Async.Lifted (replicateConcurrently_)
import           Control.Concurrent.STM          (atomically)
import           Control.Monad                   (forM_, when)
import           Control.Monad.Base              (liftBase)
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
    compareFuncAllIO "show"      (pureMap 10 show inputs S.toList_) normalFormIO
    mapM_ compFib [10]
  where
    compFib n = compareFuncAllIO ("fibonacci (" ++ show n ++ " tasks)")
                                 (pureMap n fib  inputs S.toList_)
                                 normalFormIO

-- | We use the same value repeated to avoid having to sort the
--   results, as that would give the non-concurrent variants an
--   advantage.
inputs :: Stream (Of Int) IO ()
inputs = S.replicate 10000 30

--------------------------------------------------------------------------------

data PureMap = NonConcurrent
             | BoundedImmediate
             | BoundedStreamed
             | UnboundedImmediate
             | UnboundedStreamed
  deriving (Eq, Ord, Show, Read, Bounded, Enum)

pureMap :: Int -> (a -> b) -> Stream (Of a) IO () -> (Stream (Of b) IO () -> IO r)
           -> PureMap -> IO r
pureMap n f inp cont pm = go pm n f inp cont
  where
    go NonConcurrent      = withStreamMapN
    go BoundedImmediate   = withStreamMapBI
    go BoundedStreamed    = withStreamMapBS
    go UnboundedImmediate = withStreamMapUI
    go UnboundedStreamed  = withStreamMapUS

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
  withBufferedTransformB n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = liftBase go
      where
        go = do ma <- atomically (receiveMsg obA)
                forM_ ma $ \a ->
                  do s <- atomically (sendMsg ibB (f a))
                     when s go

    consume = flip withStreamBasket cont

withStreamMapMBI :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMBI n f inp cont =
  withBufferedTransformB n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = go
      where
        go = do ma <- liftBase (atomically (receiveMsg obA))
                forM_ ma $ \a ->
                  do b <- f a
                     s <- liftBase (atomically (sendMsg ibB b))
                     when s go

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
  withBufferedTransformB n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = withStreamBasket obA
                          (flip writeStreamBasket ibB . f)

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

withStreamMapUI :: (MonadMask m, MonadBaseControl IO m)
                   => Int -- ^ How many concurrent computations to run.
                   -> (a -> b)
                   -> Stream (Of a) m ()
                   -> (Stream (Of b) m () -> m r) -> m r
withStreamMapUI n f inp cont =
  withBufferedTransformU n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = liftBase go
      where
        go = do ma <- atomically (receiveMsg obA)
                forM_ ma $ \a ->
                  do s <- atomically (sendMsg ibB (f a))
                     when s go

    consume = flip withStreamBasket cont

withStreamMapMUI :: (MonadMask m, MonadBaseControl IO m)
                    => Int -- ^ How many concurrent computations to run.
                    -> (a -> m b)
                    -> Stream (Of a) m ()
                    -> (Stream (Of b) m () -> m r) -> m r
withStreamMapMUI n f inp cont =
  withBufferedTransformU n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = go
      where
        go = do ma <- liftBase (atomically (receiveMsg obA))
                forM_ ma $ \a ->
                  do b <- f a
                     s <- liftBase (atomically (sendMsg ibB b))
                     when s go

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
  withBufferedTransformU n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = withStreamBasket obA
                          (flip writeStreamBasket ibB . f)

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

streamBaseline :: (Eq v, Eq r) => String -> a -> CompParams a (Stream (Of v) IO r)
streamBaseline = baselineWith (\s1 s2 -> equalItems s1 s2 @? "Streams have different values")

equalItems :: (Monad m, Eq a, Eq r)
              => Stream (Of a) m r -> Stream (Of a) m r -> m Bool
equalItems = go
  where
    go s1 s2 = do n1 <- S.next s1
                  n2 <- S.next s2
                  case (n1, n2) of
                    (Left r1, Left r2) -> return (r1 == r2)
                    (Right (a1,s1'), Right (a2,s2'))
                      | a1 == a2       -> go s1' s2'
                    _                  -> return False
