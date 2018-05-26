module Main where

import qualified Control.Monad.Metrics as Metrics
import System.Environment

import Types
import Connection
import Tests
import Monitoring

run :: Int -> (Metrics.Metrics -> ProcessConfig -> IO ()) -> IO ()
run port runner = do
  metrics <- setupMetrics port
  let cfg = ProcessConfig 9090 9100 40
  runner metrics cfg

main :: IO ()
main = do
  [arg] <- getArgs
  case arg of
    "client" -> run 8000 runClient
    "server" -> run 8080 runServer

