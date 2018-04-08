{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}

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

deriving instance Generic PortNumber

instance Binary PortNumber

data ProcessConfig = ProcessConfig {
    pcContext :: LogContext,
    pcMinPort :: PortNumber,
    pcMaxPort :: PortNumber,
    pcWorkersCount :: Int
  }

type AProcess a = ReaderT ProcessConfig Process a

instance HasLogContext (ReaderT ProcessConfig Process) where
  getLogContext = asks pcContext

  withLogContext frame = local (\cfg -> cfg {pcContext = frame : pcContext cfg})

spawnAProcess :: Show idx => String -> idx -> AProcess () -> AProcess ProcessId
spawnAProcess name idx proc = do
  cfg <- ask
  lift $ spawnLocal $ do
      self <- getSelfPid
      let frame = LogContextFrame [
                    ("pid", Variable (show self)),
                    ("thread", Variable name),
                    ("index", Variable (show idx))
                  ] noChange
      let cfg' = cfg {pcContext = frame : pcContext cfg}
      runReaderT proc cfg'

runAProcess :: ProcessConfig -> AProcess () -> Process ()
runAProcess cfg proc = runReaderT proc cfg

