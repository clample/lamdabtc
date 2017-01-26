module MessageTest where

import TestUtil
import Messages (Command(..), commandTable, Network(..), networkTable, Header(..), showHeader, Addr(..), networkAddress, VersionMessage(..), showVersionMessage, MessageBody(..), MessageContext(..), Message(..), showMessage)
import Protocol.Parser (parseHeader, parseAddr, parseVersionMessage, parseMessage)
import Text.Megaparsec (parseMaybe)
import qualified Data.ByteString.Char8 as Char8
import Data.Time.Clock (NominalDiffTime(..))

instance Arbitrary Message where
  arbitrary = Message <$> arbitrary <*> arbitrary

instance Arbitrary MessageBody where
  arbitrary = oneof [Version <$> arbitrary, return Verack]

instance Arbitrary MessageContext where
  arbitrary = do
    network <- arbitrary
    time <- choose (0, maxTime) :: Gen Integer
    return $ MessageContext network (realToFrac time)
    where
      maxTime = 0xffffffffffffffff -- 8 bytes

instance Arbitrary VersionMessage where
  arbitrary = do
    version    <- choose (0, maxVersion)
    nonceInt   <- choose (0, maxNonce) :: Gen Integer
    lastBlockN <- choose (0, maxBlock)
    senderAddr <- arbitrary
    peerAddr   <- arbitrary
    relay      <- arbitrary
    return $ VersionMessage version nonceInt lastBlockN senderAddr peerAddr relay
    where
      maxVersion = 0xffffffff         -- 4 bytes
      maxNonce   = 0xffffffffffffffff -- 8 bytes
      maxBlock   = 0xffffffff         -- 4 bytes

instance Arbitrary Network where
  arbitrary = do
    let networks = map fst networkTable
    elements networks

instance Arbitrary Addr where
  arbitrary = do
    a <- chooseIpComponent
    b <- chooseIpComponent
    c <- chooseIpComponent
    d <- chooseIpComponent
    port <- choosePort
    return $ Addr (a, b, c, d) port
    where
      chooseIpComponent = choose (0, 255)
      choosePort = choose (0, 65535)

messageInvertible = testProperty
  "It should be possible to encode and decode messages"
  prop_messageInvertible

prop_messageInvertible :: Message -> Bool
prop_messageInvertible message@(Message messageBody _) =
  case maybeMessageBody of
    Nothing -> False
    Just (parsedMessageBody) -> parsedMessageBody == messageBody
  where
    messageString = (Char8.unpack . showMessage) message
    maybeMessageBody = parseMessage messageString
