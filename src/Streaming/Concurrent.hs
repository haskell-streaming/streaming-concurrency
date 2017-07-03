{-# LANGUAGE FlexibleContexts #-}

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
  , InBasket(..)
  , OutBasket(..)
    -- * Stream support
  , writeStreamBasket
  , readStreamBasket
  , mergeStreams
  ) where

import           Streaming
import qualified Streaming.Prelude as S

import Control.Concurrent.Async.Lifted (concurrently, forConcurrently_)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Base (liftBase, MonadBase)
import Control.Concurrent.STM
import Control.Monad.Catch             (MonadMask, bracket, bracket_)
import Control.Monad (when)

--------------------------------------------------------------------------------

-- | Concurrently merge multiple streams together.
--
--   The resulting order is unspecified.
mergeStreams :: (MonadMask m, MonadBaseControl IO m)
                => Buffer a -> [Stream (Of a) m v]
                -> (Stream (Of a) m () -> m r) -> m r
mergeStreams buff strs f = withBuffer buff
                                      (forConcurrently_ strs . flip writeStreamBasket)
                                      (f . readStreamBasket)

-- | Write a single stream to a buffer.
--
--   Type written to make it easier if this is the only stream being
--   written to the buffer.
writeStreamBasket :: (MonadBase IO m) => Stream (Of a) m r -> InBasket a -> m ()
writeStreamBasket stream (InBasket send) = go stream
  where
    go str = do eNxt <- S.next str -- uncons requires r ~ ()
                case eNxt of
                  Left  _         -> return ()
                  Right (a, str') -> do
                    continue <- liftBase (atomically (send a))
                    when continue (go str')

-- | Read the output of a buffer into a stream.
readStreamBasket :: (MonadBase IO m) => OutBasket a -> Stream (Of a) m ()
readStreamBasket (OutBasket receive) = S.untilRight getNext
  where
    getNext = maybe (Right ()) Left <$> liftBase (atomically receive)

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
--   which could result in a system that hang.
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
newtype OutBasket a = OutBasket { receiveMsg :: STM (Maybe a) }

-- | An exhaustible sink of values.
--
--   'sendMsg' returns 'False' if the sink is exhausted.
newtype InBasket a = InBasket { sendMsg :: a -> STM Bool }

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
    (\(_, _, _, seal) -> liftBase (atomically seal)) $
      \(writeB, readB, sealed, seal) ->
        snd <$> concurrently (withIn writeB sealed seal)
                             (withOut readB sealed seal)
  where
    openBasket = do
      (writeB, readB) <- case buffer of
        Bounded n -> do
            q <- newTBQueueIO n
            return (writeTBQueue q, readTBQueue q)
        Unbounded -> do
            q <- newTQueueIO
            return (writeTQueue q, readTQueue q)
        Single    -> do
            m <- newEmptyTMVarIO
            return (putTMVar m, takeTMVar m)
        Latest a  -> do
            t <- newTVarIO a
            return (writeTVar t, readTVar t)
        New       -> do
            m <- newEmptyTMVarIO
            return (\x -> tryTakeTMVar m *> putTMVar m x, takeTMVar m)
        Newest n  -> do
            q <- newTBQueueIO n
            let writeB x = writeTBQueue q x <|> (tryReadTBQueue q *> writeB x)
            return (writeB, readTBQueue q)

      -- We use this TVar as the communication mechanism between
      -- inputs and outputs as to whether either sub-continuation has
      -- finished.
      sealed <- newTVarIO False
      let seal = writeTVar sealed True

      return (writeB, readB, sealed, seal)

    withIn writeB sealed seal =
      bracket_ (return ())
               (liftBase (atomically seal))
               (sendIn (InBasket sendOrEnd))
      where
        sendOrEnd a = do
          canWrite <- not <$> readTVar sealed
          when canWrite (writeB a)
          return canWrite

    withOut readB sealed seal =
      bracket_ (return ())
               (liftBase (atomically seal))
               (readOut (OutBasket readOrEnd))
      where
        readOrEnd = (Just <$> readB) <|> (do
          b <- readTVar sealed
          check b
          return Nothing )
{-# INLINABLE withBuffer #-}
