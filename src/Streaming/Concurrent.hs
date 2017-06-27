{- |
   Module      : Streaming.Concurrent
   Description : Concurrency support for the streaming ecosystem
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com



 -}
module Streaming.Concurrent where

import           Streaming
import qualified Streaming.Prelude as P

import Control.Concurrent.STM
import Control.Monad.Catch    (MonadMask, bracket, finally)

--------------------------------------------------------------------------------

-- | Consider a physical desk for someone that has to deal with
--   correspondence.
--
--   A typical system is to have two baskets\/trays: one for incoming
--   papers that still needs to be processed, and another for outgoing
--   papers that have already been processed.
--
--   We use this metaphor for dealing with 'Buffer's: data is fed into
--   one using the 'inBasket' (until the buffer indicates that it has
--   had enough) and taken out from the 'outBasket'.
data Baskets a = Baskets
  { inBasket  :: !(a -> STM Bool)
    -- ^ Feed input into a buffer.  Returns 'False' if no more input
    --   is accepted.
  , outBasket :: !(STM (Maybe a))
    -- ^ Remove a value from a buffer.  Returns 'Nothing' if no more
    --   values are available.
  }

withBuffer :: (MonadMask m, MonadIO m)
              => Buffer a
              -> (Baskets a -> m r)
              -> m r
withBuffer buf f = bracket (liftIO (spawnBaskets buf))
                           (liftIO . atomically . snd)
                           (f . fst)

--------------------------------------------------------------------------------
-- This entire section is almost completely taken from
-- pipes-concurrent by Gabriel Gonzalez:
-- https://github.com/Gabriel439/Haskell-Pipes-Concurrency-Library

-- | 'Buffer' specifies how to buffer messages stored within the mailbox
data Buffer a
    = Unbounded
    | Bounded Int
    | Single
    | Latest a
    | Newest Int
    | New

-- | Store an unbounded number of messages in a FIFO queue
unbounded :: Buffer a
unbounded = Unbounded

-- | Store a bounded number of messages, specified by the 'Int' argument
bounded :: Int -> Buffer a
bounded 1 = Single
bounded n = Bounded n

{-| Only store the 'Latest' message, beginning with an initial value
    'Latest' is never empty nor full.
-}
latest :: a -> Buffer a
latest = Latest

{-| Like @Bounded@, but 'send' never fails (the buffer is never full).
    Instead, old elements are discard to make room for new elements
-}
newest :: Int -> Buffer a
newest 1 = New
newest n = Newest n

spawnBaskets :: Buffer a -> IO (Baskets a, STM ())
spawnBaskets buffer = do
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

    sealed <- newTVarIO False
    let seal = writeTVar sealed True

    {- Use weak TVars to keep track of whether the 'Input' or 'Output' has been
       garbage collected.  Seal the mailbox when either of them becomes garbage
       collected.
    -}
    rSend <- newTVarIO ()
    void $ mkWeakTVar rSend (atomically seal)
    rRecv <- newTVarIO ()
    void $ mkWeakTVar rRecv (atomically seal)

    let sendOrEnd a = do
            b <- readTVar sealed
            if b
                then return False
                else do
                    writeB a
                    return True
        readOrEnd = (Just <$> readB) <|> (do
            b <- readTVar sealed
            check b
            return Nothing )
        inp a = sendOrEnd a <* readTVar rSend
        out   = readOrEnd   <* readTVar rRecv
    return (Baskets inp out, seal)
{-# INLINABLE spawnBaskets #-}
