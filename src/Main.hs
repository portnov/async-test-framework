module Main where

import System.Environment

import Types
import Connection
import Tests
import Monitoring

mkConfig :: Int -> IO ProcessConfig
mkConfig port = do
  metrics <- setupMetrics port
  let cfg = ProcessConfig [] metrics 9090 9100 40
  return cfg

main :: IO ()
main = do
  [arg] <- getArgs
  case arg of
    "client" -> runClient =<< mkConfig 8000
    "server" -> runServer =<< mkConfig 8080

