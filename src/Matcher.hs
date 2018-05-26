{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Matcher where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Monad.Trans
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Process.Node
import Control.Monad.Catch (bracket, finally)
import qualified Control.Monad.Metrics as Metrics
import Data.Binary
import Data.Maybe
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as L
import Network.Socket (PortNumber)
import Data.String
import GHC.Generics
import System.Random
import Text.Printf
import System.Log.Heavy
-- import System.Log.Heavy.Shortcuts
import Data.Text.Format.Heavy
import Data.Typeable
import Data.IORef

import Types
import Connection
import Pool
import Logging

data WhoSentRq = WhoSentRq ProcessId MatchKey
  deriving (Typeable, Generic)

instance Binary WhoSentRq

data RegisterRq = RegisterRq ProcessId MatchKey
  deriving (Typeable, Generic)

instance Binary RegisterRq

type MatcherState = IORef (M.Map MatchKey ProcessId)

matcher :: PortNumber -> Process ()
matcher port = do
  self <- getSelfPid
  let myName = "matcher:" ++ show port
  register myName self
  st <- liftIO $ newIORef M.empty

  forever $ do
    receiveWait [
        match (whoSentRq st),
        match (registerRq st)
      ]
  where
    whoSentRq :: MatcherState -> WhoSentRq -> Process ()
    whoSentRq st (WhoSentRq caller key) = do
      m <- liftIO $ readIORef st
      let res = M.lookup key m
      send caller res

    registerRq :: MatcherState -> RegisterRq -> Process ()
    registerRq st (RegisterRq sender key) = do
      liftIO $ modifyIORef st $ \m -> M.insert key sender m

registerRq :: ProcessMonad m => PortNumber -> MatchKey -> m ()
registerRq port key = do
  Metrics.increment "matcher.registration.size"
  Metrics.timed "matcher.registration.duration" $ do
    self <- liftP getSelfPid
    let name = "matcher:" ++ show port
    liftP $ nsend name (RegisterRq self key)

whoSentRq :: ProcessMonad m => PortNumber -> MatchKey -> m (Maybe ProcessId)
whoSentRq port key = Metrics.timed "matcher.request.duration" $ do
  self <- liftP getSelfPid
  let name = "matcher:" ++ show port
  liftP $ nsend name (WhoSentRq self key)
  liftP expect

