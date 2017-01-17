{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Server.Handlers where

import Network.HTTP.Types.Status (internalServerError500, ok200)
import Data.Aeson (object, (.=), Value (Null), FromJSON)
import Server.Config
import Web.Scotty.Trans (status, showError, json, jsonData)
import GHC.Generics
import Util (maybeRead)
import Keys

defaultH :: Environment -> Error -> Action
defaultH e x = do
  status internalServerError500
  let o = case e of
        Development -> object ["error" .= showError x]
        Production -> Null
        Test -> object ["error" .= showError x]
  json o


postFundRequestsH :: Action
postFundRequestsH = do
--  address <- 
--  fundRequestRaw <- jsonData
--  let either = validateFundRequest fundRequestRaw
  status ok200
  
-- Documented in BIP 0021
-- All elements should be UTF-8
-- and Percent Encoded as in RFC 3986
data FundRequest = FundRequest
  { label :: String
  , message :: String
  , amount :: Double
  , address :: Address
  , requestURI :: String }

data FundRequestRaw = FundRequestRaw
  { labelRaw :: String
  , messageRaw :: String
  , amountRaw :: String }
  deriving (Generic, Show)

instance FromJSON FundRequestRaw

validateFundRequest :: Address -> FundRequestRaw -> Either Error FundRequest
validateFundRequest address fundRequestRaw@(FundRequestRaw labelR messageR amountR) =
  let
    ma :: Maybe Double
    ma = maybeRead (amountR)
    uri = "bitcoin:"-- ++ address
  in
    case ma of
      Nothing -> Left "Unable to parse amount"
      Just a -> Right $
        FundRequest labelR messageR a address uri