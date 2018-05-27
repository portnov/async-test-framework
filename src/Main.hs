module Main where

import qualified Control.Monad.Metrics as Metrics
import System.Environment

import Types
import Connection
import Tests
import Monitoring
import Config

run :: FilePath -> (Metrics.Metrics -> ProcessConfig -> IO ()) -> IO ()
run path runner = do
  config <- readConfig path
  metrics <- setupMetrics (fromIntegral $ pcEkgPort config)
  runner metrics config

main :: IO ()
main = do
  [arg] <- getArgs
  case arg of
    "client" -> run "client.yaml" runClient
    "server" -> run "server.yaml" runServer

