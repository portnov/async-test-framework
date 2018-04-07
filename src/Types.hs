{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module Types where

import Control.Monad.Reader
import Control.Concurrent
import Control.Concurrent.STM
import Control.Distributed.Process hiding (bracket, mask, catch)
import Control.Monad.Catch 
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Typeable
import Data.Binary
import qualified Data.ByteString.Lazy as L
import Network.Socket
import System.Log.Heavy
import System.Log.Heavy.Instances.Binary
import System.Log.Heavy.Instances.Throw
import Data.Text.Format.Heavy
import GHC.Generics

data ExtPort =
  ClientPort PortNumber Socket
  | ServerPort PortNumber Socket Socket
  deriving (Eq, Show)

type MatchKey = L.ByteString

class Binary m => IsMessage m where
  isResponse :: m -> Bool
  isAdministrative :: m -> Bool
  getMatchKey :: m -> MatchKey

class IsFrame f where
  recvMessage :: IsMessage m => Socket -> f -> IO m
  sendMessage :: IsMessage m => Socket -> f -> m -> IO ()

data PoolSettings = PoolSettings {
    pIsClient :: Bool
  , pHost :: String
  , pMinPort :: PortNumber
  , pMaxPort :: PortNumber
  }
  deriving (Eq, Show)

data ConnectionPool = ConnectionPool {
    cpSettings :: PoolSettings,
    cpPorts :: M.Map PortNumber ExtPort
  }

data SimpleLogMessage = SimpleLogMessage Level (Either String ProcessId) TL.Text
  deriving (Eq, Show, Typeable, Generic)

deriving instance Typeable LogMessage

instance Binary SimpleLogMessage

type AProcess a = LoggingT Process a

spawnAProcess :: AProcess () -> AProcess ProcessId
spawnAProcess proc = do
  lts <- LoggingT ask
  lift $ spawnLocal $ do
      self <- getSelfPid
      let frame = LogContextFrame [("thread", Variable (show self))] noChange
      let lts' = lts {ltsContext = frame : ltsContext lts}
      runLoggingT proc lts'

