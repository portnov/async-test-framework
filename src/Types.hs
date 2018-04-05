{-# LANGUAGE OverloadedStrings #-}

module Types where

import Control.Monad.Reader
import Control.Concurrent
import Control.Concurrent.STM
import Control.Distributed.Process hiding (bracket, mask, catch)
import Control.Monad.Catch 
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Binary
import qualified Data.ByteString.Lazy as L
import Network.Socket
import System.Log.Heavy
import Data.Text.Format.Heavy

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

instance MonadThrow m => MonadThrow (LoggingT m) where
  throwM e = LoggingT $ lift $ throwM e

instance MonadCatch m => MonadCatch (LoggingT m) where
  catch (LoggingT (ReaderT m)) c = LoggingT $ ReaderT $ \r -> m r `catch` \e -> runLoggingT (c e) r

instance MonadMask m => MonadMask (LoggingT m) where
  mask a = LoggingT $ ReaderT $ \lts -> mask $ \u -> runLoggingT (a $ q u) lts
    where q :: (m a -> m a) -> LoggingT m a -> LoggingT m a
          q u (LoggingT (ReaderT b)) = LoggingT (ReaderT (u . b))

  uninterruptibleMask a = LoggingT $ ReaderT $ \lts -> uninterruptibleMask $ \u -> runLoggingT (a $ q u) lts
    where q :: (m a -> m a) -> LoggingT m a -> LoggingT m a
          q u (LoggingT (ReaderT b)) = LoggingT (ReaderT (u . b))

type AProcess a = LoggingT Process a

spawnAProcess :: AProcess () -> AProcess ProcessId
spawnAProcess proc = do
  lts <- LoggingT ask
  lift $ spawnLocal $ do
      self <- getSelfPid
      let frame = LogContextFrame [("thread", Variable (show self))] noChange
      let lts' = lts {ltsContext = frame : ltsContext lts}
      runLoggingT proc lts'

