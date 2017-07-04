{- |
   Module      : Main
   Description : Stream merging tests
   Copyright   : Ivan Lazar Miljenovic
   License     : MIT
   Maintainer  : Ivan.Miljenovic@gmail.com



 -}
module Main (main) where

import Streaming.Concurrent

import Data.ByteString.Streaming (fromStrict, toStrict_)
import Streaming.Prelude         (each, toList_)

import qualified Data.ByteString as B

import Data.Function             (on)
import Data.List                 (concat, sort)
import Data.Monoid               (mconcat)
import Test.Hspec                (describe, hspec)
import Test.Hspec.QuickCheck     (prop)
import Test.QuickCheck           (Property, ioProperty)
import Test.QuickCheck.Instances ()

--------------------------------------------------------------------------------

main :: IO ()
main = hspec $ do
  describe "Merging retains all elements" $ do
    prop "Stream" (mergeCheck :: [[Int]] -> Property)
    prop "ByteString" mergeBSCheck

mergeCheck :: (Ord a) => [[a]] -> Property
mergeCheck ass = ioProperty (mergeStreams unbounded
                                          (map each ass)
                                          (eqOn sort as . toList_))
  where
    as = concat ass

mergeBSCheck :: [B.ByteString] -> Property
mergeBSCheck bss = ioProperty (mergeByteStrings unbounded
                                                (map fromStrict bss)
                                                (eqOn B.sort bs . toStrict_))
  where
    bs = mconcat bss

eqOn :: (Eq b, Functor f) => (a -> b) -> a -> f a -> f Bool
eqOn f a = fmap (((==)`on`f) a)
