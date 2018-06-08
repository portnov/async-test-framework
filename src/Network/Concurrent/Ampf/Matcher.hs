{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Concurrent.Ampf.Matcher where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Backend.P2P
import qualified Control.Monad.Metrics as Metrics
import Data.Binary
import qualified Data.Map as M
import Network.Socket (PortNumber)
import GHC.Generics
import Data.Typeable
import Data.Time.Clock

import Network.Concurrent.Ampf.Types

data WhoSentRq = WhoSentRq ProcessId MatchKey
  deriving (Typeable, Generic)

instance Binary WhoSentRq

data RegisterRq = RegisterRq ProcessId MatchKey
  deriving (Typeable, Generic)

instance Binary RegisterRq

data MessageInfo = MessageInfo {
    miSenderPid :: ProcessId,
    miExpirationTime :: UTCTime
  }
  deriving (Show)

type MatcherState = TVar (M.Map MatchKey MessageInfo)

matcher :: PortNumber -> Process MatcherState
matcher port = do
    st <- liftIO $ newTVarIO M.empty

    spawnLocal $ forever $ do
      liftIO $ threadDelay $ 1000 * 1000
      cleanup st

    return st
  where
    cleanup :: MatcherState -> Process ()
    cleanup st = do
      now <- liftIO getCurrentTime
      newSize <- liftIO $ atomically $ do
                   m <- readTVar st
                   writeTVar st $ M.filter (\mi -> miExpirationTime mi > now) m
                   return $ M.size m
      nsendCapable "monitor" (MatcherStats newSize) 

registerRq :: ProcessMonad m => MatcherState -> PortNumber -> MatchKey -> ProcessId -> m ()
registerRq st port key sender = do
  Metrics.increment "matcher.registration.count"
  Metrics.timed "matcher.registration.duration" $ do
    now <- liftIO getCurrentTime
    timeout <- asksConfig pcMatcherTimeout
    let expiration = addUTCTime (fromIntegral timeout / 1000) now
    liftIO $ atomically $ modifyTVar' st $ \m ->
               M.insert key (MessageInfo sender expiration) m

whoSentRq :: ProcessMonad m => MatcherState -> PortNumber -> MatchKey -> m (Maybe ProcessId)
whoSentRq st port key = Metrics.timed "matcher.request.duration" $ do
  now <- liftIO getCurrentTime
  liftIO $ atomically $ do
    m <- readTVar st
    writeTVar st $ M.delete key m
    case M.lookup key m of
      Nothing -> return Nothing
      Just mi ->
        if miExpirationTime mi > now
          then return $ Just (miSenderPid mi)
          else return Nothing

