{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}

module Network.Concurrent.Ampf.Types where

import Control.Monad.Reader
import Control.Monad.State as St
import Control.Monad.Catch 
import Control.Distributed.Process hiding (bracket, mask, catch)
import qualified Control.Monad.Metrics as Metrics
import qualified Data.Map as M
import qualified Data.Text.Lazy as TL
import Data.Typeable
import Data.Binary
import Data.Int
import Data.IORef
import qualified Data.ByteString.Lazy as L
import Network.Socket
import System.Log.Heavy
import System.Log.Heavy.Instances.Binary () -- import instances only
import GHC.Generics

data ExtPort =
  ClientPort PortNumber Socket
  | ServerPort PortNumber Socket Socket
  deriving (Eq, Show)

type MatchKey = L.ByteString

data MatcherStats = MatcherStats Int
  deriving (Typeable, Generic)

instance Binary MatcherStats

class (Binary m, Typeable m) => IsMessage m where
  isResponse :: m -> Bool
  isAdministrative :: m -> Bool
  getMatchKey :: m -> MatchKey

class IsFrame f where
  recvMessage :: IsMessage m => Socket -> f -> IO m
  sendMessage :: IsMessage m => Socket -> f -> m -> IO ()

class (Monad m, MonadIO m, HasLogContext m, Metrics.MonadMetrics m, MonadMask m) => ProcessMonad m where
  liftP :: Process a -> m a
  askConfig :: m ProcessConfig
  -- spawnP :: m () -> m ProcessId

class (IsFrame (ProtocolFrame proto), IsMessage (ProtocolMessage proto))
    => Protocol proto where
  type ProtocolFrame proto
  type ProtocolMessage proto
  data ProtocolSettings proto
  type ProtocolState proto

  getFrame :: proto -> ProtocolM (ProtocolState proto) (ProtocolFrame proto)

  -- initProtocol :: ProtocolSettings proto -> ProtocolM (ProtocolState proto) ()

  initialState :: ProtocolSettings proto -> ProtocolState proto

  makeLogonMsg :: proto -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)

  generateRq :: proto -> Int -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)

  processRq :: proto -> ProtocolMessage proto -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)

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
    pcIsGenerator :: Bool,
    pcIsProcessor :: Bool,
    pcGeneratorEnabled :: Bool,
    pcGeneratorTargetRps :: Int,
    pcHost :: String,
    pcMinPort :: PortNumber,
    pcMaxPort :: PortNumber,
    pcWorkersCount :: Int,
    pcMonitorDelay :: Int,
    pcProcessorMinDelay :: Int,
    pcProcessorMaxDelay :: Int,
    pcEkgPort :: PortNumber,
    pcMatcherTimeout :: Int,
    pcGeneratorTimeout :: Int,
    pcLogFilePath :: FilePath,
    pcLogLevel :: Level,
    pcUseRepl :: Bool
  }
  deriving (Show)

-- this is ProtocolM-specific
data ProcessState st = ProcessState {
    psContext :: LogContext,
    psMetrics :: Metrics.Metrics,
    psConfig :: ProcessConfig,
    psGeneratorEnabled :: Bool,
    psGeneratorDelay :: Int,
    psTargetRps :: Int,
    psRpsStats :: IORef (Int64, Int64),
    psState :: st
  }

data GeneratorCommand =
    StartGenerator
  | StopGenerator
  | SetTargetRps Int
  deriving (Typeable, Generic)

instance Binary GeneratorCommand

type ProtocolM st a = StateT (ProcessState st) Process a

getP :: ProtocolM st st
getP = gets psState

putP :: st -> ProtocolM st ()
putP x = modify $ \st -> st {psState = x}

instance HasLogContext (StateT (ProcessState st) Process) where
  getLogContext = gets psContext

  withLogContext frame actions = do
    context <- gets psContext
    let context' = frame : context
    modify $ \cfg -> cfg {psContext = context'}
    result <- actions
    modify $ \cfg -> cfg {psContext = context}
    return result

instance Metrics.MonadMetrics (StateT (ProcessState st) Process) where
  getMetrics = gets psMetrics

instance ProcessMonad (StateT (ProcessState st) Process) where
  liftP = lift

  askConfig = gets psConfig

asksConfig :: ProcessMonad m => (ProcessConfig -> a) -> m a
asksConfig fn = do
  cfg <- askConfig
  return $ fn cfg

spawnAProcess :: Show idx => String -> idx -> ProtocolM st () -> ProtocolM st ProcessId
spawnAProcess name idx proc = do
    cfg <- St.get
    lift $ spawnLocal $ do
             self <- getSelfPid
             runAProcess cfg $ withContext self proc
  where
    withContext pid =
          withLogVariable "pid" (show pid) .
          withLogVariable "thread" name .
          withLogVariable "index" (show idx)

-- spawnAProcess :: forall m idx. (MonadBaseControl Process m, HasLogContext m, Show idx) => String -> idx -> m () -> m ProcessId
-- spawnAProcess name idx proc = do
-- 
--     -- Outside `control' call, we're in the `m' monad
--     liftBaseWith $ \runInProcess -> do -- runInProcess :: m a -> Process (StM m a)
--       -- here we're in the Process monad
--       self <- getSelfPid
--       step1 runInProcess self
-- 
--   where
--     step1 :: RunInBase m Process -> ProcessId -> Process ProcessId
--     step1 runInProcess self = do
--       spawnLocal $ do
--                 -- stm :: StM m ()
--                 stm <- runInProcess $ -- runInProcess (something :: m a) :: Process (StM m a)
--                         -- here we're in the `m' monad again
--                         withContext self proc
--                 return (restoreM stm) --  Process (m ())
-- 
--     withContext pid =
--           withLogVariable "pid" (show pid) .
--           withLogVariable "thread" name .
--           withLogVariable "index" (show idx)
    
runAProcess :: ProcessState st -> ProtocolM st () -> Process ()
runAProcess cfg proc = evalStateT proc cfg

