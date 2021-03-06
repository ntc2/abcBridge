{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{- |
Module      : Data.ABC.GIA
Copyright   : Galois, Inc. 2010-2014
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)

'Data.ABC.GIA' defines a set of functions for manipulating
scalable and-inverter graph networks directly from ABC.  This module
should be imported @qualified@, e.g.

> import Data.ABC.GIA (GIA)
> import qualified Data.ABC.GIA as GIA

Scalable and-inverter graphs are briefly described at the Berkeley
Verification and Synthesis Research Center's website.
<http://bvsrc.org/research.html#AIG%20Package>  It is a more memory
efficient method of storing AIG graphs.


-}
module Data.ABC.GIA
    ( GIA
    , newGIA
      -- * Building lits
    , Lit
    , true
    , false
    , proxy
      -- * Inspection
    , AIG.LitView(..)
    , litView
      -- * File IO
    , readAiger
    , writeAigerWithLatches
    , writeCNF
      -- * QBF
    , check_exists_forall
      -- * Re-exports
    , AIG.Proxy
    , AIG.SomeGraph(..)
    , AIG.IsLit(..)
    , AIG.IsAIG(..)
    , AIG.Network(..)
    , AIG.SatResult(..)
    , AIG.VerifyResult(..)
    ) where

import Prelude hiding (and, not, or)
import qualified Prelude


import Control.Exception hiding (evaluate)
import Control.Monad
import Control.Applicative
import qualified Data.Map as Map
import           Data.IORef
import qualified Data.AIG as AIG
import           Data.AIG.Interface (LitView(..))
import qualified Data.AIG.Trace as Tr

import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Unboxed.Mutable as VM
import Foreign hiding (void, xor)
import System.Directory

import Data.ABC.Internal.ABC
import Data.ABC.Internal.ABCGlobal
import Data.ABC.Internal.AIG
import Data.ABC.Internal.CEC
import Data.ABC.Internal.Field
import Data.ABC.Internal.GIA
import Data.ABC.Internal.GiaAig
import Data.ABC.Internal.Main
import Data.ABC.Internal.Orphan
import Data.ABC.Internal.VecInt
import qualified Data.ABC.AIG as AIG
import Data.ABC.Util

enumRange :: (Eq a, Enum a) => a -> a -> [a]
enumRange i n | i == n = []
              | otherwise = i : enumRange (succ i) n


-- | An and-invertor graph network in GIA form.
newtype GIA s = GIA { _giaPtr :: ForeignPtr Gia_Man_t_ }

-- | Represent a literal.
newtype Lit s = L { _unLit :: GiaLit }
  deriving (Eq, Storable, Ord)

proxy :: AIG.Proxy Lit GIA
proxy = AIG.Proxy id

withGIAPtr :: GIA s -> (Gia_Man_t -> IO a) -> IO a
withGIAPtr (GIA g) m = withForeignPtr g m

-- | Build a new empty GIA graph
newGIA :: IO (AIG.SomeGraph GIA)
newGIA = do
  abcStart
  p <- giaManStart 4096
  giaManHashAlloc p
  AIG.SomeGraph . GIA <$> newForeignPtr p_giaManStop p

-- | Read an AIGER file into a GIA graph
readAiger :: FilePath -> IO (AIG.Network Lit GIA)
readAiger path = do
  abcStart
  b <- doesFileExist path
  unless b $ do
    fail $ "Data.ABC.GIA.readAiger: file does not exist"
  let skipStrash = False
  bracketOnError (giaAigerRead path skipStrash False) giaManStop $ \p -> do
    rn <- getGiaManRegNum p
    when (rn /= 0) $ fail "Networks do not yet support latches."

    cov <- giaManCos p

    co_num <- fromIntegral <$> vecIntSize cov
    outputs <- forN co_num $ \i -> do
      idx <- GiaVar <$> vecIntEntry cov (fromIntegral i)
      o <- giaManObj p idx
      L <$> fanin0Lit o idx

    -- Delete all Pos
    clearVecInt cov

    -- Return new pointer.
    fp <- newForeignPtr p_giaManStop p
    return (AIG.Network (GIA fp) outputs)

instance AIG.IsLit Lit where
  not (L x) = L (giaLitNot x)
  L x === L y = x == y

-- | Constant true node.
true :: Lit s
true = L giaManConst1Lit

-- | Constant false node
false :: Lit s
false = L giaManConst0Lit

instance Tr.Traceable Lit where
  compareLit x y = compare x y
  showLit x = show (unGiaLit (_unLit x))

-- | Write an AIGER file with the given number of latches.
-- If the number of latches is denoted by "n", then the last n inputs and last n outputs
-- are treated as the latch input and outputs respectively.  The other inputs and outputs
-- represent primary inputs and outputs.
writeAigerWithLatches :: FilePath
                      -> AIG.Network Lit GIA
                      -> Int -- ^ Number of latches.
                      -> IO ()
writeAigerWithLatches path ntk latchCount =
  withNetworkPtr ntk $ \p -> do
    flip finally (setGiaManRegNum p 0) $ do
      ci_num <- giaManCiNum p
      let co_num = AIG.networkOutputCount ntk
      when (latchCount < 0) $ fail "Latch count must be positive."
      when (fromIntegral latchCount > ci_num) $ do
        fail "Latch count exceeds number of inputs."
      when (latchCount > co_num) $ do
        fail "Latch count exceeds number of outputs."
      setGiaManRegNum p (fromIntegral latchCount)
      giaAigerWrite p path False False

instance AIG.IsAIG Lit GIA where

  newGraph _ = newGIA

  trueLit  _ = true
  falseLit _ = false

  newInput g = L <$> withGIAPtr g giaManAppendCi
  and g (L x) (L y) = withGIAPtr g $ \p -> L <$> giaManHashAnd p x y
  xor g (L x) (L y) = withGIAPtr g $ \p -> L <$> giaManHashXor p x y
  mux g (L c) (L x) (L y) = withGIAPtr g $ \p -> L <$> giaManHashMux p c x y

  inputCount g = fromIntegral <$> withGIAPtr g giaManCiNum
  getInput g i =
    withGIAPtr g $ \p -> do
        cnt <- giaManCiNum p
        assert (0 <= i && i < fromIntegral cnt) $
          L . giaVarLit <$> giaManCiVar p (fromIntegral i)

  aigerNetwork _ = readAiger

  abstractEvaluateAIG (GIA fp) = litEvaluator fp

  writeAiger path g = do
    withNetworkPtr g $ \p -> do
      giaAigerWrite p path False False

  checkSat ntk l = do
    withGIAPtr ntk $ \ntk_p -> do
    input_count <- giaManCiNum ntk_p
    bracket (giaManStart 4096) giaManStop $ \p -> do
      mapM_ (\_ -> giaManAppendCi p) [1 .. input_count]
      p' <- newForeignPtr_ p
      r <- AIG.cec (AIG.Network ntk [l]) (AIG.Network (GIA p') [false])
      return $! case r of
        AIG.Valid -> AIG.Unsat
        AIG.Invalid bs -> AIG.Sat bs
        AIG.VerifyUnknown -> AIG.SatUnknown

  cec gx gy = do
    withNetworkPtr gx $ \x -> do
    withNetworkPtr gy $ \y -> do

    input_count_x <- giaManCiNum x
    input_count_y <- giaManCiNum y

    output_count_x <- vecIntSize =<< giaManCos x
    output_count_y <- vecIntSize =<< giaManCos y

    assert (input_count_x == input_count_y) $ do
    assert (output_count_x == output_count_y) $ do

    bracket (giaManMiter x y 0 True False False False) giaManStop $ \m -> do
    r <- cecManVerify m cecManCecDefaultParams
    case r of
      1 -> return AIG.Valid
      0 -> do
        pCex <- giaManCexComb m
        when (pCex == nullPtr) $ error "cec: Generated counter-example was invalid"
        cex <- peekAbcCex pCex
        let r2 = pData'inputs'Abc_Cex cex
        case r2 of
          []   -> return (AIG.Invalid [])
          [bs] -> return (AIG.Invalid bs)
          _ -> error "cec: Generated counter example has too many frames"
      -1 -> fail "cec: failed"
      _  -> error "cec: Unrecognized return code"

  evaluator g inputs = do
    withGIAPtr g $ \p -> do
    vecSize <- fromIntegral <$> giaManObjNum p
    vec <- VM.replicate vecSize False
    input_count <- fromIntegral <$> giaManCiNum p
    when (length inputs /= input_count) $ do
      fail $ "evaluate given " ++ show (length inputs)
          ++ " when " ++ show input_count ++ " expected."
    -- initialize inputs
    forM_ ([0..] `zip` inputs) $ \(i, b) -> do
      cid <- giaVarIndex <$> giaManCiVar p i
      assert (0 <= cid && cid < vecSize) $ do
      VM.write vec cid b
    -- Run and gates
    forM_ (enumRange 1 vecSize) $ \i -> do
      let var = GiaVar (fromIntegral i)
      o <- giaManObj p var
      isAnd <- giaObjIsAndOrConst0 o
      when isAnd $ do
        i0 <- giaVarIndex <$> giaObjFaninId0 o var
        c0 <- giaObjFaninC0 o
        i1 <- giaVarIndex <$> giaObjFaninId1 o var
        c1 <- giaObjFaninC1 o
        assert (0 <= i0 && i0 < vecSize) $ do
        b0 <- VM.read vec i0
        assert (0 <= i1 && i1 < vecSize) $ do
        b1 <- VM.read vec i1
        let r = (c0 /= b0) && (c1 /= b1)
        VM.write vec i r
    -- return the outputs
    pureEvaluateFn <$> V.freeze vec

-- | Evaluate a literal on an assignment.
pureEvaluateFn :: V.Vector Bool -> Lit s -> Bool
pureEvaluateFn v (L l) = assert inRange (c /= (v V.! i))
  where i = fromIntegral $ unGiaVar $ giaLitVar l
        c = giaLitIsCompl l
        inRange = 0 <= i && i < V.length v

-- | Run computation with a Gia_Man_t containing the given network.
withNetworkPtr :: AIG.Network Lit GIA -> (Gia_Man_t -> IO a) -> IO a
withNetworkPtr = withNetworkPtr_Munge

-- A safer alternative...
--withNetworkPtr = withNetworkPtr_Copy


-- This is a safer method for implementing withNetworkPtr; it copies the
-- entire graph before adding the required COs and disposes of the copied
-- graph afterwards.  Obviously, this has substantial memory usage implications.
_withNetworkPtr_Copy :: AIG.Network Lit GIA -> (Gia_Man_t -> IO a) -> IO a
_withNetworkPtr_Copy (AIG.Network ntk out) m = do
  withGIAPtr ntk $ \p -> do
     ncos <- vecIntSize =<< giaManCos p
     assert( ncos == 0 ) $ do
     bracket (giaManDupNormalize p) giaManStop
         (\p' -> mapM_ (\(L o) -> giaManAppendCo p' o) out >> m p')


-- This is a somewhat risky method to build a Gia network containing
-- the required output COs.  Initially, we assume the network has no COs.
-- Then, we add enough COs to account for the list of "out" literals.
-- We then run the given computation on the updated network; this computation
-- is assumed not to change the structure of the graph.  Finally, we
-- "deallocate" the COs we added.  This final step is a bit dubious; the Gia
-- graph data was not designed with deallocation in mind, and we are abusing
-- our ability to reach in and muck with the details.

withNetworkPtr_Munge :: AIG.Network Lit GIA -> (Gia_Man_t -> IO a) -> IO a
withNetworkPtr_Munge (AIG.Network ntk out) m = do
  withGIAPtr ntk $ \p -> do
    -- Get original number of objects
    orig_oc <- readAt giaManNObjs p

    let reset = do
          n <- readAt giaManNObjs p

          cov <- giaManCos p
          ncos <- vecIntSize cov

          -- it should be that the only new objects are the COs we add
          assert (orig_oc == n - ncos) $ do

          -- clear the objects for reuse
          forN_ (fromIntegral ncos) $ \i -> do
             var <- vecIntEntry cov (fromIntegral i)
             -- Assert that all the objects we are clearing are above the old object count;
             -- that is, they must have been allocated when we shoved in the new COs.
             assert (var >= orig_oc) $ do
             -- clear the memory assocaited with the GIA object
             clearGiaObj =<< giaManObj p (GiaVar var)

          -- empty the CO vector
          clearVecInt cov

          -- Reset object count, effectively deallocating the objects
          writeAt giaManNObjs p orig_oc

    -- Run computation, then reset.
    bracket_
      -- Add combinational outputs.
      (mapM_ (\(L o) -> giaManAppendCo p o) out)
      -- reset the graph afterwards
      reset
      -- Run computation.
      (m p)

-- | Run a computation with an AIG man created from a GIA netowrk.
giaNetworkAsAIGMan :: AIG.Network Lit GIA
                   -> (Aig_Man_t -> IO a)
                   -> IO a
giaNetworkAsAIGMan ntk m = do
  -- Get a GIA network pointer.
  withNetworkPtr ntk $ \p -> do
    -- Convert GIA to AIG.
    bracket (giaManToAig p 0) aigManStop m

giaVarIndex :: GiaVar -> Int
giaVarIndex = fromIntegral . unGiaVar

fanin0Lit :: Gia_Obj_t -> GiaVar -> IO GiaLit
fanin0Lit o v = do
  v0 <- giaObjFaninId0 o v
  c0 <- giaObjFaninC0 o
  return $ giaLitNotCond (giaVarLit v0) c0

fanin1Lit :: Gia_Obj_t -> GiaVar -> IO GiaLit
fanin1Lit o v = do
  v0 <- giaObjFaninId1 o v
  c0 <- giaObjFaninC1 o
  return $ giaLitNotCond (giaVarLit v0) c0


litEvaluator :: ForeignPtr Gia_Man_t_ -> (LitView a -> IO a) -> IO (Lit s -> IO a)
litEvaluator fp viewFn = do
  let memo r o t = do
        m <- readIORef r
        writeIORef r $! Map.insert o t m
        return t
  r <- newIORef Map.empty
  let objTerm o = do
        m0 <- readIORef r
        case Map.lookup o m0 of
          Just t -> return t
          _ -> do
            let c = giaIsComplement o
            let o' = if c then giaRegular o else o
            isTerm <- giaObjIsTerm o'
            d0 <- giaObjDiff0 o'
            case () of
              _ | Prelude.not isTerm && d0 /= gia_none -> do -- And gate
                    x <- objTerm =<< giaObjChild0 o'
                    y <- objTerm =<< giaObjChild1 o'
                    let and_ = if c then NotAnd else And
                    memo r o =<< viewFn (and_ x y)
                | isTerm && d0 /= gia_none -> do -- Primary output
                    -- This is a primary output, so we just get the lit
                    -- for the gate that it is attached to.

                    -- FIXME? is this the right thing to do WRT complement?
                    objTerm =<< giaObjChild0 o'
                | Prelude.not isTerm -> do -- Constant value
                    memo r o =<< viewFn (if c then TrueLit else FalseLit)
                | otherwise -> do -- Primary input
                    memo r o =<< viewFn . (if c then NotInput else Input) . fromIntegral
                              =<< giaObjDiff1 o'
  return $ (\(L l) -> withForeignPtr fp $ \p -> objTerm =<< giaObjFromLit p l)


-- | Return a representation of how lit was constructed.
litView :: GIA s -> Lit s -> IO (LitView (Lit s))
litView g (L l)
  | l == giaManConst0Lit = return FalseLit
  | l == giaManConst1Lit = return TrueLit
  | otherwise = do
    let c = giaLitIsCompl l
    let v = giaLitVar l
    withGIAPtr g $ \p -> do
    o <- giaManObj p v
    t <- giaObjIsTerm o
    d0 <- giaObjDiff0 o
    if t && (d0 == gia_none) then do
      idx <- fromIntegral <$> giaObjDiff1 o
      return $ if c then NotInput idx else Input idx
    else if t then do
      l0 <- L <$> fanin0Lit o v
      l1 <- L <$> fanin1Lit o v
      return $ if c then NotAnd l0 l1 else And l0 l1
    else
      error $ "Invalid literal"


-- | Allocate a vec int array from Boolean list.
withBoolAsVecInt :: [Bool]
                 -> (Vec_Int_t -> IO a)
                 -> IO a
withBoolAsVecInt l f = do
  let assign_vals :: [CInt]
      assign_vals = fromIntegral . fromEnum <$> l
  withArray assign_vals $ \pval -> do
  withVecInt (fromIntegral (length l)) pval f

-- | Allocate a vec int array from Boolean list.
getVecIntAsBool :: Vec_Int_t
                -> IO [Bool]
getVecIntAsBool v = do
  sz <- vecIntSize v
  forM [0..sz-1] $ \i -> do
    e <- vecIntEntry v i
    case e of
      -1 -> return True
      0 -> return False
      1 -> return True
      _ -> fail $ "getVecAsBool given bad value " ++ show e

-- | Write a CNF file to the given path.
--   Returns vector mapping combinational inputs to CNF Variable numbers.
writeCNF :: GIA s -> Lit s -> FilePath -> IO [Int]
writeCNF ntk l f = do
  giaNetworkAsAIGMan (AIG.Network ntk [l]) $ \pMan -> do
    vars <- AIG.writeAIGManToCNFWithMapping pMan f
    ciCount <- aigManCiNum pMan
    forM [0..(ciCount - 1)] $ \i -> do
      ci <- aigManCi pMan (fromIntegral i)
      ((vars SV.!) . fromIntegral) `fmap` (aigObjId ci)

data PartialSatResult
-- | Check a formula of the form Ex.Ay p(x,y)@.
-- This function takes a network where input variables are used to
-- represent both the existentially and the universally quantified variables.
-- The existentially quantified variables must precede the universally quantified
-- variables, and the number of extential variables is defined by an extra @Int@
-- paramter.
check_exists_forall :: GIA s
                       -- ^ The GIA network used to store the terms.
                    -> Int
                       -- ^ The number of existential variables.
                    -> Lit s
                       -- ^ The proposition to verify.
                    -> [Bool]
                       -- ^ Initial value to use in search for universal variables.
                       -- (should equal number of universal variables.).
                    -> CInt
                       -- ^ Number of iterations to try solver.
                    -> IO (Either String AIG.SatResult)
check_exists_forall ntk exists_cnt prop init_assign iter_cnt = do
  -- Get number of inputs
  ic <- AIG.inputCount ntk
  -- Check parameters
  when (exists_cnt > ic) $ do
    fail $ "Number of extential variables exceeds number of variables."
  when (exists_cnt + length init_assign /= ic) $ do
    fail $ "Mismatch between number of variables and initial assignment."
  -- Create an AIG manager for network.
  giaNetworkAsAIGMan (AIG.Network ntk [prop]) $ \pMan -> do
  -- Allocate a pointer to an ABC network.
  bracket (abcNtkFromAigPhase pMan) abcNtkDelete $ \p -> do
  -- Allocate an array storing this information.
  let elts = replicate exists_cnt False ++ init_assign
  withBoolAsVecInt elts $ \v -> do
  -- Call QBF function
  r <- abcNtkQbf p exists_cnt iter_cnt v
  case r of
    1 -> return $ Right AIG.Unsat
    0 -> Right . AIG.Sat . take exists_cnt <$> getVecIntAsBool v
    -1 -> return $ Left "Iteration limit reached."
    -2 -> return $ Left "Solver timeout."
    _ -> fail "internal: Unexpected value returned by abcNtkQbf."