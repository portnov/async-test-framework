{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Network.Concurrent.Ampf.Monitoring where

import qualified Control.Monad.Metrics as Metrics
import Control.Monad
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import qualified System.Remote.Monitoring as EKG
import qualified System.Metrics as EKG
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Distribution as Distribution
import Lens.Micro
import Data.Int

import Network.Concurrent.Ampf.Types
import Network.Concurrent.Ampf.Utils

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
    processorMailboxSize <- liftIO $ EKG.createGauge "processor.mailbox.size" store
    generatorMailboxSize <- liftIO $ EKG.createGauge "generator.mailbox.size" store
    matcherSizeDistrib <- liftIO $ EKG.createDistribution "matcher.registration.size" store
    forever $ do
      delay <- asksConfig pcMonitorDelay
      liftIO $ threadDelay $ delay * 1000
      liftP $ receiveWait [
                match (matcherSize matcherSizeDistrib)
              ]
      writersSize <- collectQueueSize =<< getAllWriterNames
      liftIO $ Gauge.set writerMailboxSize writersSize
      processorsSize <- collectQueueSize =<< getAllProcessorNames
      liftIO $ Gauge.set processorMailboxSize processorsSize
      generatorsSize <- collectQueueSize =<< getAllGeneratorNames
      liftIO $ Gauge.set generatorMailboxSize generatorsSize

--       sample <- liftIO $ EKG.sampleAll store
--       case H.lookup "writer.sent.messages" sample of
--         Nothing -> return ()
--         Just (EKG.Counter currentCount) -> do
--           st <- gets psRpsStats
--           nsendCapable "rps controller" 
--           liftIO $ modifyIORef st $ \(prev,last) -> (last, currentCount)

  where
    matcherSize :: Distribution.Distribution -> MatcherStats -> Process ()
    matcherSize distrib (MatcherStats size) = do
      liftIO $ Distribution.add distrib (fromIntegral size)

