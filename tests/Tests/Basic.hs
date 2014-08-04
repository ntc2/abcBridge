module Tests.Basic
  ( basic_tests
  ) where

import Control.Applicative
import Control.Exception
import Control.Monad
import System.Directory
import System.IO
import Test.Framework
import Test.Framework.Providers.HUnit
import Test.Framework.Providers.QuickCheck2
import Test.HUnit (assertEqual)
import Test.QuickCheck

import qualified Data.ABC as ABC

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

basic_tests :: ABC.Proxy l g -> [Test.Framework.Test]
basic_tests proxy@(ABC.Proxy f) = f $
  [ testCase "test_true" $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      let n = ABC.Network g [ABC.trueLit g]
      assertEqual "test_true" [True] =<< ABC.evaluate n []
  , testCase "test_false" $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      let n = ABC.Network g [ABC.falseLit g]
      assertEqual "test_false" [False] =<< ABC.evaluate n []
  , testProperty "test_constant"$ \b -> ioProperty $do
      ABC.SomeGraph g <- ABC.newGraph proxy
      let n = ABC.Network g [ABC.constant g b]
      (==[b]) <$> ABC.evaluate n []
  , testProperty "test_not" $ \b0 -> ioProperty $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      i0 <- ABC.newInput g
      let n = ABC.Network g [ABC.not i0]
      r <- ABC.evaluate n [b0]
      return $ r == [not b0]
  , testProperty "test_and" $ \b1 b2 -> ioProperty $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      i0 <- ABC.newInput g
      i1 <- ABC.newInput g
      x <- ABC.and g i0 i1
      let n = ABC.Network g [x]
      r <- ABC.evaluate n [b1, b2]
      return $ r == [b1 && b2]
  , testProperty "test_xor" $ \b1 b2 -> ioProperty $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      i0 <- ABC.newInput g
      i1 <- ABC.newInput g
      x <- ABC.xor g i0 i1
      let n = ABC.Network g [x]
      r <- ABC.evaluate n [b1, b2]
      return $ r == [b1 /= b2]
  , testProperty "test_mux" $ \b0 b1 b2 -> ioProperty $ do
      ABC.SomeGraph g <- ABC.newGraph proxy
      i0 <- ABC.newInput g
      i1 <- ABC.newInput g
      i2 <- ABC.newInput g
      o <- ABC.mux g i0 i1 i2

      let n = ABC.Network g [o]
      r <- ABC.evaluate n [b0, b1, b2]
      return $ r == [if b0 then b1 else b2]
  , testCase "test_cec" $ do
     r <- join $ ABC.cec <$> cecNetwork proxy <*> cecNetwork' proxy
     assertEqual "test_cec" (ABC.Invalid (toEnum <$> [0,0,0,1,0,0,0])) r
  , testCase "test_aiger" $ do
      -- XXX: cwd unfriendly
      n1 <- ABC.aigerNetwork proxy "tests/eijk.S298.S.aig"
      tmpdir <- getTemporaryDirectory
      (path, hndl) <- openTempFile tmpdir "aiger.aig"
      hClose hndl
      ABC.writeAiger path n1
      n2 <- ABC.aigerNetwork proxy path
      assertEqual "test_aiger" ABC.Valid =<< ABC.cec n1 n2
      removeFile path
  , testCase "bad_aiger" $ do
      me <- tryIO $ ABC.aigerNetwork proxy "Nonexistent AIGER!"
      case me of
        Left{} -> return ()
        Right{} -> fail "Expected error when opening AIGER"
  , testCase "test_sat" $ do
     ABC.SomeGraph g <- ABC.newGraph proxy
     rt <- ABC.checkSat g (ABC.trueLit g)
     case rt of
       ABC.Sat{} -> return ()
       ABC.Unsat{} -> fail "trueLit is unsat"
     rf <- ABC.checkSat g (ABC.falseLit g)
     case rf of
       ABC.Sat{} -> fail "falseLit is sat"
       ABC.Unsat{} -> return ()
  ]

cecNetwork :: ABC.IsAIG l g => ABC.Proxy l g -> IO (ABC.Network l g)
cecNetwork proxy = do
  ABC.SomeGraph g <- ABC.newGraph proxy
  [n2, n3, n4, n5, n6, n7, n8] <- replicateM 7 $ ABC.newInput g

  n14 <- ABC.ands g [ ABC.not n2
                    , ABC.not n3
                    , ABC.not n4
                    , n5
                    , ABC.not n6
                    , ABC.not n7
                    , ABC.not n8
                    ]
  let r = [n14] ++ replicate 6 (ABC.falseLit g)
  return (ABC.Network g r)

cecNetwork' :: ABC.IsAIG l g => ABC.Proxy l g -> IO (ABC.Network l g)
cecNetwork' proxy = do
  ABC.SomeGraph g <- ABC.newGraph proxy
  replicateM_ 7 $ ABC.newInput g
  let r = replicate 7 $ ABC.falseLit g
  return (ABC.Network g r)