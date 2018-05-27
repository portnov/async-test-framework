{-# LANGUAGE OverloadedStrings #-}

module Config where

import Data.Aeson
import Data.Yaml
import Data.Word
import Network.Socket

import Types

instance FromJSON ProcessConfig where
  parseJSON = withObject "Config" $ \v -> ProcessConfig
    <$> v .: "is-generator"
    <*> v .:? "generator-enabled" .!= False
    <*> v .:? "min-port" .!= 9090
    <*> v .:? "max-port" .!= 9100
    <*> v .:? "workers" .!= 10
    <*> v .:? "monitor-delay" .!= 1000
    <*> v .:? "processor-delay-min" .!= 0
    <*> v .:? "processor-delay-max" .!= 100
    <*> v .:? "monitor-port" .!= 8000

instance FromJSON PortNumber where
  parseJSON o = fromIntegral `fmap` (parseJSON o :: Parser Word16)

readConfig :: FilePath -> IO ProcessConfig
readConfig path = do
  r <- decodeFileEither path
  case r of
    Left err -> fail $ show err
    Right cfg -> return cfg

