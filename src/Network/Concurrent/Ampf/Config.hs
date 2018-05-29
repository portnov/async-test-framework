{-# LANGUAGE OverloadedStrings #-}

module Network.Concurrent.Ampf.Config where

import Data.Aeson as Aeson
import Data.Aeson.Types as Aeson
import Data.Yaml
import Data.Word
import Network.Socket
import System.Log.Heavy
-- import qualified System.Posix.Syslog as Syslog

import Network.Concurrent.Ampf.Types

instance FromJSON ProcessConfig where
  parseJSON = withObject "Config" $ \v -> ProcessConfig
    <$> v .: "is-generator"
    <*> v .: "is-processor"
    <*> v .:? "generator-enabled" .!= False
    <*> v .:? "generator-target-rps" .!= 100
    <*> v .:? "host" .!= "127.0.0.1"
    <*> v .:? "min-port" .!= 9090
    <*> v .:? "max-port" .!= 9100
    <*> v .:? "workers" .!= 10
    <*> v .:? "monitor-delay" .!= 1000
    <*> v .:? "processor-delay-min" .!= 0
    <*> v .:? "processor-delay-max" .!= 100
    <*> v .:? "monitor-port" .!= 8000
    <*> v .:? "matcher-timeout" .!= 1500
    <*> v .:? "generator-timeout" .!= 2
    <*> v .: "log-file"
    <*> v .:? "log-level" .!= info_level
    <*> v .:? "enable-repl" .!= True

instance FromJSON PortNumber where
  parseJSON o = fromIntegral `fmap` (parseJSON o :: Parser Word16)

-- | EVENT logging level
-- event_level :: Level
-- event_level = Level "EVENT" 350 Syslog.Info

-- | VERBOSE logging level
-- verbose_level :: Level
-- verbose_level = Level "VERBOSE" 450 Syslog.Info

-- | CONFIG logging level
-- config_level :: Level
-- config_level = Level "CONFIG" 700 Syslog.Debug

instance FromJSON Level where
  parseJSON (Aeson.String "debug") = return debug_level
  parseJSON (Aeson.String "info") = return info_level
  parseJSON (Aeson.String "warning") = return warn_level
  parseJSON (Aeson.String "error") = return error_level
  parseJSON (Aeson.String "fatal") = return fatal_level
  parseJSON (Aeson.String "disable") = return disable_logging
  parseJSON invalid = Aeson.typeMismatch "logging level" invalid

readConfig :: FilePath -> IO ProcessConfig
readConfig path = do
  r <- decodeFileEither path
  case r of
    Left err -> fail $ show err
    Right cfg -> return cfg

