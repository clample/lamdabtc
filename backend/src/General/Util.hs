{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module General.Util
  ( Payload(..)
  , Prefix(..)
  , maybeRead
  , encodeBase58Check
  , decodeBase58Check
  , showBool
  , VarInt(..)
  , putWithLength
  , roll
  , unroll
  , unrollWithPad
  , reverseLookup
  , Endian(..)
  , Addr(..)
  , IP(..)
  , Port(..)
  , Tree(..)
  , node
  , subTree
  , getBranch
  , branches) where

import Prelude hiding (take)

import General.Hash (CheckSum(..), checksum)

import Data.Maybe (listToMaybe)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as T
import Data.Base58String.Bitcoin (fromBytes, toBytes, toText, fromText)
import Data.Binary (Binary(..), Word8)
import Data.Binary.Get (Get)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (shiftR, shiftL, (.|.))
import Data.List (unfoldr)
import Data.Tuple (swap)
import Control.Lens (makeLenses, (^.))
import Data.Word(Word64)

import Test.QuickCheck.Arbitrary (Arbitrary(..))
import Test.QuickCheck.Gen (choose, elements)

newtype Payload = Payload ByteString
  deriving (Show, Eq)

putPayload :: Payload -> Put
putPayload (Payload bs) = Put.putByteString bs

newtype Prefix = Prefix Word8
  deriving (Show, Eq)

instance Binary Prefix where
  get = getPrefix
  put = putPrefix

getPrefix :: Get Prefix
getPrefix = Prefix <$> Get.getWord8

putPrefix :: Prefix -> Put
putPrefix (Prefix w8) = Put.putWord8 w8

maybeRead :: Read a => String -> Maybe a
maybeRead = fmap fst . listToMaybe . reads
  
-- https://github.com/bitcoinbook/bitcoinbook/blob/first_edition/ch04.asciidoc#base58-and-base58check-encoding
encodeBase58Check :: Prefix -> Payload -> T.Text
encodeBase58Check prefix payload =
  toText . fromBytes . BL.toStrict . Put.runPut $ do
    put prefix
    putPayload payload
    put $ checksum' prefix payload
  where
   checksum' (Prefix pr) (Payload pay) = checksum $ pr `BS.cons` pay 

-- all components are binary encoded rather than hex
decodeBase58Check :: T.Text -> (Prefix, Payload, CheckSum)
decodeBase58Check b58 = flip Get.runGet content $ do
      prefix <- get
      payload <- Payload <$> Get.getByteString (fromIntegral $ BL.length content - nNonPayloadBytes)
      checksum <- get
      return (prefix, payload, checksum)
  where content = BL.fromChunks [(toBytes . fromText) b58]
        nNonPayloadBytes = 1 + 4

putWithLength :: Put -> Put
putWithLength putM = do
  let payload = BL.toStrict . Put.runPut $ putM
  put . VarInt . fromIntegral . BS.length $ payload
  Put.putByteString payload

showBool :: Bool -> ByteString
showBool True  = "01"
showBool False = "00"

newtype VarInt = VarInt Word64
  deriving (Eq, Show)

instance Binary VarInt where
  get = getVarInt
  put = putVarInt

getVarInt :: Get VarInt
getVarInt = do
  firstByte <- fromIntegral <$> Get.getWord8
  VarInt <$> varInt firstByte
  where
    varInt firstByte
      | firstByte < 0xFD  = return firstByte
      | firstByte == 0xFD = fromIntegral <$> Get.getWord16le
      | firstByte == 0xFE = fromIntegral <$> Get.getWord32le 
      | firstByte == 0xFF = fromIntegral <$> Get.getWord64le
      | otherwise = error "Unable to parse VarInt. This should not happen"

putVarInt :: VarInt -> Put
putVarInt (VarInt i)
  | i < 0xFD =
      Put.putWord8 . fromIntegral $ i
  | i <= 0xFFFF =  do
      Put.putWord8 0xFD
      Put.putWord16le . fromIntegral $ i
  | i <= 0xFFFFFFFF = do
      Put.putWord8 0xFE
      Put.putWord32le . fromIntegral $ i
  | otherwise = do
      Put.putWord8 0xFF
      Put.putWord64le . fromIntegral $ i

data Endian = BE | LE
  deriving (Show, Eq)

-- Taken from src of Data.Binary
-- http://hackage.haskell.org/package/binary-0.4.1/docs/src/Data-Binary.html#Binary
-- NOTE: unroll seems to require a positive integer!
unroll :: Endian -> Integer -> ByteString
unroll LE = BS.pack . unfoldr step
  where
    step 0 = Nothing
    step i = Just (fromIntegral i, i `shiftR` 8)
unroll BE = BS.reverse . unroll LE


unrollWithPad :: Endian -> Int -> Integer -> ByteString
unrollWithPad BE paddingBytes i =
  leadingNullBytes `BS.append` base
  where
    base = unroll BE i
    leadingNullBytes = BS.pack $ replicate (paddingBytes - BS.length base) 0
unrollWithPad LE paddingBytes i = BS.reverse $ unrollWithPad BE paddingBytes i

roll :: Endian -> ByteString -> Integer
roll LE = foldr unstep 0 . BS.unpack
  where
    unstep b a = a `shiftL` 8 .|. fromIntegral b

roll BE = roll LE . BS.reverse

reverseLookup :: Eq b => b -> [(a, b)]  -> Maybe a
reverseLookup b table = lookup b table'
  where
    table' = map swap table

data Addr = Addr IP Port
  deriving (Show, Eq)

type IP = (Int, Int, Int, Int)

type Port = Int

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

instance Arbitrary Endian where
  arbitrary = elements [BE, LE]

instance Arbitrary Prefix where
  arbitrary = Prefix <$> arbitrary
    
instance Arbitrary Payload where
  arbitrary = do
    str <- arbitrary
    return (Payload $ Char8.pack str)

data Tree a = Tree
  { _node    :: a
  , _subTree :: [Tree a]
  } deriving (Show, Eq)

makeLenses ''Tree

getBranch :: [Int] -> Tree a -> Maybe [a]
getBranch is tree = reverse <$> getBranchStep [] is tree

getBranchStep :: [a] -> [Int] -> Tree a -> Maybe [a]
getBranchStep acc (i:is) tree = do
  let val = tree^.node
  subTree' <- getSubTree i tree
  getBranchStep (val:acc) is subTree'

getSubTree :: Int -> Tree a -> Maybe (Tree a)
getSubTree i tree =
  if i < 0 || length (tree^.subTree) <= i 
  then Just $ (tree^.subTree) !! i
  else Nothing

branches :: Tree a -> [[a]]
branches (Tree a []) = [[a]]
branches (Tree a ts) = concat $ map (\t -> map (a:) (branches t)) ts
