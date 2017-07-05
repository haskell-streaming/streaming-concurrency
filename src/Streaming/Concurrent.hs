{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses #-}

{- |
   Module      : Streaming.Concurrent
   Description : Concurrency support for the streaming ecosystem
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com

   Consider a physical desk for someone that has to deal with
   correspondence.

   A typical system is to have two baskets\/trays: one for incoming
   papers that still needs to be processed, and another for outgoing
   papers that have already been processed.

   We use this metaphor for dealing with 'Buffer's: data is fed into
   one using the 'InBasket' (until the buffer indicates that it has
   had enough) and taken out from the 'OutBasket'.

 -}
module Streaming.Concurrent
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
  ) where

import           Streaming         (Of, Stream)
import qualified Streaming.Prelude as S

import           Control.Applicative             ((<|>))
import           Control.Concurrent.Async.Lifted (concurrently,
                                                  forConcurrently_,
                                                  replicateConcurrently_)
import qualified Control.Concurrent.STM          as STM
import           Control.Monad                   (when)
import           Control.Monad.Base              (MonadBase, liftBase)
import           Control.Monad.Catch             (MonadMask, bracket, finally)
import           Control.Monad.Trans.Control     (MonadBaseControl)
import           Data.Foldable                   (forM_)

--------------------------------------------------------------------------------

-- | Concurrently merge multiple streams together.
--
--   The resulting order is unspecified.
--
--   Note that the monad of the resultant Stream can be different from
--   the final result.
--
--   @since 0.2.0.0
withMergedStreams :: (MonadMask m, MonadBaseControl IO m, MonadBase IO n, Foldable t)
                     => Buffer a -> t (Stream (Of a) m v)
                     -> (Stream (Of a) n () -> m r) -> m r
withMergedStreams buff strs f = withBuffer buff
                                           (forConcurrently_ strs . flip writeStreamBasket)
                                           (`withStreamBasket` f)

-- | Write a single stream to a buffer.
--
--   Type written to make it easier if this is the only stream being
--   written to the buffer.
writeStreamBasket :: (MonadBase IO m) => Stream (Of a) m r -> InBasket a -> m ()
writeStreamBasket stream (InBasket send) = go stream
  where
    go str = do eNxt <- S.next str -- uncons requires r ~ ()
                forM_ eNxt $ \(a, str') -> do
                  continue <- liftBase (STM.atomically (send a))
                  when continue (go str')

-- | Read the output of a buffer into a stream.
--
--   @since 0.2.0.0
withStreamBasket :: (MonadBase IO m) => OutBasket a
                    -> (Stream (Of a) m () -> r)
                    -> r
withStreamBasket (OutBasket receive) f = f (S.untilRight getNext)
  where
    getNext = maybe (Right ()) Left <$> liftBase (STM.atomically receive)

--------------------------------------------------------------------------------

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
withBufferedTransform :: (MonadMask m, MonadBaseControl IO m)
                         => Int
                            -- ^ How many concurrent computations to run.
                         -> (OutBasket a -> InBasket b -> m ab)
                            -- ^ What to do with each individual concurrent
                            --   computation; result is ignored.
                         -> (InBasket a -> m i)
                            -- ^ Provide initial data; result is ignored.
                         -> (OutBasket b -> m r) -> m r
withBufferedTransform n transform feed consume =
  withBuffer buff feed $ \obA ->
    withBuffer buff (replicateConcurrently_ n . transform obA)
      consume
  where
    buff :: Buffer v
    buff = bounded n

-- | Concurrently map a function over all elements of a 'Stream'.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamMap :: (MonadMask m, MonadBaseControl IO m, MonadBase IO n)
                 => Int -- ^ How many concurrent computations to run.
                 -> (a -> b)
                 -> Stream (Of a) m i
                 -> (Stream (Of b) n () -> m r) -> m r
withStreamMap n f inp cont =
  withBufferedTransform n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = liftBase go
      where
        go = do ma <- STM.atomically (receiveMsg obA)
                forM_ ma $ \a ->
                  do s <- STM.atomically (sendMsg ibB (f a))
                     when s go

    consume = flip withStreamBasket cont

-- | Concurrently map a monadic function over all elements of a
--   'Stream'.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamMapM :: (MonadMask m, MonadBaseControl IO m, MonadBase IO n)
                  => Int -- ^ How many concurrent computations to run.
                  -> (a -> m b)
                  -> Stream (Of a) m i
                  -> (Stream (Of b) n () -> m r) -> m r
withStreamMapM n f inp cont =
  withBufferedTransform n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = go
      where
        go = do ma <- liftBase (STM.atomically (receiveMsg obA))
                forM_ ma $ \a ->
                  do b <- f a
                     s <- liftBase (STM.atomically (sendMsg ibB b))
                     when s go

    consume = flip withStreamBasket cont

-- | Concurrently split the provided stream into @n@ streams and
--   transform them all using the provided function.
--
--   Note: ordering of elements in the output is undeterministic.
--
--   @since 0.2.0.0
withStreamTransform :: (MonadMask m, MonadBaseControl IO m, MonadBase IO n)
                       => Int -- ^ How many concurrent computations to run.
                       -> (Stream (Of a) m () -> Stream (Of b) m t)
                       -> Stream (Of a) m i
                       -> (Stream (Of b) n () -> m r) -> m r
withStreamTransform n f inp cont =
  withBufferedTransform n transform feed consume
  where
    feed = writeStreamBasket inp

    transform obA ibB = withStreamBasket obA
                          (flip writeStreamBasket ibB . f)

    consume = flip withStreamBasket cont

--------------------------------------------------------------------------------
-- This entire section is almost completely taken from
-- pipes-concurrent by Gabriel Gonzalez:
-- https://github.com/Gabriel439/Haskell-Pipes-Concurrency-Library

-- | 'Buffer' specifies how to buffer messages between our 'InBasket'
--   and our 'OutBasket'.
data Buffer a
    = Unbounded
    | Bounded Int
    | Single
    | Latest a
    | Newest Int
    | New

-- | Store an unbounded number of messages in a FIFO queue.
unbounded :: Buffer a
unbounded = Unbounded

-- | Store a bounded number of messages, specified by the 'Int'
--   argument.
--
--   A buffer size @<= 0@ will result in a permanently empty buffer,
--   which could result in a system that hangs.
bounded :: Int -> Buffer a
bounded 1 = Single
bounded n = Bounded n

-- | Only store the \"latest\" message, beginning with an initial
--   value.
--
--   This buffer is never empty nor full; as such, it is up to the
--   caller to ensure they only take as many values as they need
--   (e.g. using @'S.print' . 'readStreamBasket'@ as the final
--   parameter to 'withBuffer' will -- after all other values are
--   processed -- keep printing the last value over and over again).
latest :: a -> Buffer a
latest = Latest

-- | Like 'bounded', but 'sendMsg' never fails (the buffer is never
--   full).  Instead, old elements are discard to make room for new
--   elements.
--
--   As with 'bounded', providing a size @<= 0@ will result in no
--   values being provided to the buffer, thus no values being read
--   and hence the system will most likely hang.
newest :: Int -> Buffer a
newest 1 = New
newest n = Newest n

-- | An exhaustible source of values.
--
--   'receiveMsg' returns 'Nothing' if the source is exhausted.
newtype OutBasket a = OutBasket { receiveMsg :: STM.STM (Maybe a) }

-- | An exhaustible sink of values.
--
--   'sendMsg' returns 'False' if the sink is exhausted.
newtype InBasket a = InBasket { sendMsg :: a -> STM.STM Bool }

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
withBuffer :: (MonadMask m, MonadBaseControl IO m)
              => Buffer a -> (InBasket a -> m i)
              -> (OutBasket a -> m r) -> m r
withBuffer buffer sendIn readOut =
  bracket
    (liftBase openBasket)
    (\(_, _, _, seal) -> liftBase (STM.atomically seal)) $
      \(writeB, readB, sealed, seal) ->
        snd <$> concurrently (withIn writeB sealed seal)
                             (withOut readB sealed seal)
  where
    openBasket = do
      (writeB, readB) <- case buffer of
        Bounded n -> do
            q <- STM.newTBQueueIO n
            return (STM.writeTBQueue q, STM.readTBQueue q)
        Unbounded -> do
            q <- STM.newTQueueIO
            return (STM.writeTQueue q, STM.readTQueue q)
        Single    -> do
            m <- STM.newEmptyTMVarIO
            return (STM.putTMVar m, STM.takeTMVar m)
        Latest a  -> do
            t <- STM.newTVarIO a
            return (STM.writeTVar t, STM.readTVar t)
        New       -> do
            m <- STM.newEmptyTMVarIO
            return (\x -> STM.tryTakeTMVar m *> STM.putTMVar m x, STM.takeTMVar m)
        Newest n  -> do
            q <- STM.newTBQueueIO n
            let writeB x = STM.writeTBQueue q x <|> (STM.tryReadTBQueue q *> writeB x)
            return (writeB, STM.readTBQueue q)

      -- We use this TVar as the communication mechanism between
      -- inputs and outputs as to whether either sub-continuation has
      -- finished.
      sealed <- STM.newTVarIO False
      let seal = STM.writeTVar sealed True

      return (writeB, readB, sealed, seal)

    withIn writeB sealed seal =
      sendIn (InBasket sendOrEnd)
      `finally`
      liftBase (STM.atomically seal)
      where
        sendOrEnd a = do
          canWrite <- not <$> STM.readTVar sealed
          when canWrite (writeB a)
          return canWrite

    withOut readB sealed seal =
      readOut (OutBasket readOrEnd)
      `finally`
      liftBase (STM.atomically seal)
      where
        readOrEnd = (Just <$> readB) <|> (do
          b <- STM.readTVar sealed
          STM.check b
          return Nothing )
{-# INLINABLE withBuffer #-}
