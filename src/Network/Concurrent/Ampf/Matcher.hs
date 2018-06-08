{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Concurrent.Ampf.Matcher where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Backend.P2P
import qualified Control.Monad.Metrics as Metrics
import Data.Binary
import qualified Data.Map as M
import Network.Socket (PortNumber)
import GHC.Generics
import Data.Typeable
import Data.IORef
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

type MatcherState = IORef (M.Map MatchKey MessageInfo)

matcher :: PortNumber -> Int -> Process ()
matcher port timeout = do
  self <- getSelfPid
  let myName = "matcher:" ++ show port
  register myName self
  st <- liftIO $ newIORef M.empty

  spawnLocal $ forever $ do
    liftIO $ threadDelay $ 1000 * 1000
    cleanup st

  forever $ do
    receiveWait [
        match (whoSentRq st),
        match (registerRq st)
      ]
  where
    whoSentRq :: MatcherState -> WhoSentRq -> Process ()
    whoSentRq st (WhoSentRq caller key) = do
      now <- liftIO $ getCurrentTime
      res <- liftIO $ atomicModifyIORef' st $ \m ->
               let maybeMi = M.lookup key m
                   m' = M.delete key m
               in  case maybeMi of
                     Nothing -> (m', Nothing)
                     Just mi ->
                       if miExpirationTime mi > now
                         then (m', Just (miSenderPid mi))
                         else (m', Nothing)
      send caller res

    registerRq :: MatcherState -> RegisterRq -> Process ()
    registerRq st (RegisterRq sender key) = do
      now <- liftIO $ getCurrentTime
      let expiration = addUTCTime (fromIntegral timeout / 1000) now
      liftIO $
        atomicModifyIORef' st $ \m ->
          let m' = M.insert key (MessageInfo sender expiration) m
          in (m', ())

    cleanup :: MatcherState -> Process ()
    cleanup st = do
      oldSize <- liftIO $ M.size `fmap` readIORef st
      liftIO $ do
        now <- getCurrentTime
        atomicModifyIORef' st $ \m ->
          let m' = M.filter (\mi -> miExpirationTime mi > now) m
          in (m', ())
      newSize <- liftIO $ M.size `fmap` readIORef st
      -- liftIO $ putStrLn $ show (oldSize - newSize)
      nsendCapable "monitor" (MatcherStats newSize) 

registerRq :: ProcessMonad m => PortNumber -> MatchKey -> m ()
registerRq port key = do
  Metrics.increment "matcher.registration.count"
  Metrics.timed "matcher.registration.duration" $ do
    self <- liftP getSelfPid
    let name = "matcher:" ++ show port
    liftP $ nsendCapable name (RegisterRq self key)

whoSentRq :: ProcessMonad m => PortNumber -> MatchKey -> m (Maybe ProcessId)
whoSentRq port key = Metrics.timed "matcher.request.duration" $ do
  self <- liftP getSelfPid
  let name = "matcher:" ++ show port
  liftP $ nsendCapable name (WhoSentRq self key)
  liftP expect

