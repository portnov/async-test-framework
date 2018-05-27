{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Monitoring where

import qualified Control.Monad.Metrics as Metrics
import Control.Monad
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import qualified System.Remote.Monitoring as EKG
import qualified System.Metrics as EKG
import qualified System.Metrics.Gauge as Gauge
-- import qualified System.Metrics.Distribution as EKG
import Lens.Micro
import Data.Int

import Types
import Framework

setupMetrics :: Int -> IO Metrics.Metrics
setupMetrics port = do
  store <- EKG.newStore
  EKG.registerGcMetrics store
  metrics <- Metrics.initializeWith store
  EKG.forkServerWith store "localhost" port 
  return metrics

collectQueueSize :: ProcessMonad m => [String] -> m Int64
collectQueueSize names = do
  sizes <- forM names $ \name -> do
               mbPid <- liftP $ whereis name
               case mbPid of
                 Nothing -> return 0
                 Just pid -> do
                   mbProcessInfo <- liftP $ getProcessInfo pid
                   case mbProcessInfo of
                     Nothing -> return 0
                     Just info -> return $ fromIntegral $ infoMessageQueueLength info
  return $ sum sizes

globalCollector :: (ProcessMonad m) => m ()
globalCollector = do
  metrics <- Metrics.getMetrics
  let store = metrics ^. Metrics.metricsStore
  writerMailboxSize <- liftIO $ EKG.createGauge "writer.mailbox.size" store
  workerMailboxSize <- liftIO $ EKG.createGauge "worker.mailbox.size" store
  forever $ do
    liftIO $ threadDelay $ 1000 * 1000
    writerNames <- getAllWriterNames
    writersSize <- collectQueueSize writerNames
    liftIO $ Gauge.set writerMailboxSize writersSize
    workerNames <- getAllWorkerNames
    workersSize <- collectQueueSize workerNames
    liftIO $ Gauge.set workerMailboxSize workersSize
    


