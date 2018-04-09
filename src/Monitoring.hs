{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Monitoring where

import qualified Control.Monad.Metrics as Metrics
import qualified System.Remote.Monitoring as EKG
import qualified System.Metrics as EKG
-- import qualified System.Metrics.Distribution as EKG

import Types

setupMetrics :: Int -> IO Metrics.Metrics
setupMetrics port = do
  store <- EKG.newStore
  EKG.registerGcMetrics store
  metrics <- Metrics.initializeWith store
  EKG.forkServerWith store "localhost" port 
  return metrics

