{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.CodeGen.Fold
-- Copyright   : [2014..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.CodeGen.Fold
  where

import Data.Array.Accelerate.Representation.Array
import Data.Array.Accelerate.Representation.Shape
import Data.Array.Accelerate.Representation.Type
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.LLVM.CodeGen.Arithmetic                as A
import Data.Array.Accelerate.LLVM.CodeGen.Array
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Constant
import Data.Array.Accelerate.LLVM.CodeGen.Environment
import Data.Array.Accelerate.LLVM.CodeGen.Exp
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Sugar
import Data.Array.Accelerate.LLVM.Compile.Cache

import Data.Array.Accelerate.LLVM.Native.CodeGen.Base
import Data.Array.Accelerate.LLVM.Native.CodeGen.Generate
import Data.Array.Accelerate.LLVM.Native.CodeGen.Loop
import Data.Array.Accelerate.LLVM.Native.Target                     ( Native )

import Control.Applicative
import Prelude                                                      as P hiding ( length )


-- Reduce an array along the innermost dimension. The reduction
-- function must be associative to allow for an efficient parallel
-- implementation. When an initial value is given, the input can be
-- empty. The initial element does not need to be a neutral element of
-- the operator. When no initial value is given, the array must be
-- non-empty
--
mkFold
    :: UID
    -> Gamma             aenv
    -> ArrayR (Array sh e)
    -> IRFun2       Native aenv (e -> e -> e)
    -> Maybe (IRExp Native aenv e)
    -> MIRDelayed   Native aenv (Array (sh, Int) e)
    -> CodeGen      Native      (IROpenAcc Native aenv (Array sh e))
mkFold uid aenv repr f z arr
  -- When an initial value is given, the input can be empty. We
  -- compile a fill kernel to handle that.
  | Just z' <- z
  = (+++) <$> codeFold
          <*> mkFoldFill uid aenv repr z'

  -- When no initial value is given, we only have to generate the
  -- actual fold kernel.
  | otherwise
  = codeFold
  where
    -- Code for a non-empty fold
    codeFold = case repr of
      ArrayR ShapeRz tp -> mkFoldAll uid aenv tp   f z arr
      _                 -> mkFoldDim uid aenv repr f z arr


-- Reduce a multidimensional (>1) array along the innermost dimension.
--
-- For simplicity, each element of the output (reduction along the entire length
-- of an innermost-dimension index) is computed by a single thread.
--
mkFoldDim
  :: UID
  -> Gamma aenv
  -> ArrayR (Array sh e)
  -> IRFun2     Native aenv (e -> e -> e)
  -> MIRExp     Native aenv e
  -> MIRDelayed Native aenv (Array (sh, Int) e)
  -> CodeGen    Native      (IROpenAcc Native aenv (Array sh e))
mkFoldDim uid aenv repr@(ArrayR _ tp) combine mseed mdelayed =
  let
      (start, end, paramGang) = gangParam    dim1
      (arrOut, paramOut)      = mutableArray repr "out"
      (arrIn,  paramIn)       = delayedArray      "in"  mdelayed
      paramEnv                = envParam aenv
  in
  makeOpenAcc uid "fold" (paramGang ++ paramOut ++ paramIn ++ paramEnv) $ do

    sz <- indexHead <$> delayedExtent arrIn

    imapFromTo (indexHead start) (indexHead end) $ \seg -> do
      from <- mul numType seg  sz
      to   <- add numType from sz
      --
      r    <- case mseed of
                Just seed -> do z <- seed
                                reduceFromTo  tp from to (app2 combine) z (app1 (delayedLinearIndex arrIn))
                Nothing   ->    reduce1FromTo tp from to (app2 combine)   (app1 (delayedLinearIndex arrIn))
      writeArray TypeInt arrOut seg r
    return_


-- Reduce an array to single element.
--
-- Since reductions consume arrays that have been fused into them,
-- a parallel fold requires two passes. At an example, take vector dot
-- product:
--
-- > dotp xs ys = fold (+) 0 (zipWith (*) xs ys)
--
--   1. The first pass reads in the fused array data, in this case corresponding
--   to the function (\i -> (xs!i) * (ys!i)).
--
--   2. The second pass reads in the manifest array data from the first step and
--   directly reduces the array. This second step should be small and so is
--   usually just done by a single core.
--
-- Note that the first step is split into two kernels, the second of which
-- reads a carry-in value of that thread's partial reduction, so that
-- threads can still participate in work-stealing. These kernels must not
-- be invoked over empty ranges.
--
-- The final step is sequential reduction of the partial results. If this
-- is an exclusive reduction, the seed element is included at this point.
--
mkFoldAll
    :: UID
    -> Gamma aenv                                   -- ^ array environment
    -> TypeR e
    -> IRFun2     Native aenv (e -> e -> e)         -- ^ combination function
    -> MIRExp     Native aenv e                     -- ^ seed element, if this is an exclusive reduction
    -> MIRDelayed Native aenv (Vector e)            -- ^ input data
    -> CodeGen    Native      (IROpenAcc Native aenv (Scalar e))
mkFoldAll uid aenv tp combine mseed mdelayed =
  foldr1 (+++) <$> sequence [ mkFoldAllS  uid aenv tp combine mseed mdelayed
                            , mkFoldAllP1 uid aenv tp combine       mdelayed
                            , mkFoldAllP2 uid aenv tp combine mseed
                            ]


-- Sequential reduction of an entire array to a single element
--
mkFoldAllS
    :: UID
    -> Gamma aenv                                   -- ^ array environment
    -> TypeR e
    -> IRFun2     Native aenv (e -> e -> e)         -- ^ combination function
    -> MIRExp     Native aenv e                     -- ^ seed element, if this is an exclusive reduction
    -> MIRDelayed Native aenv (Vector e)            -- ^ input data
    -> CodeGen    Native      (IROpenAcc Native aenv (Scalar e))
mkFoldAllS uid aenv tp combine mseed mdelayed  =
  let
      (start, end, paramGang) = gangParam    dim1
      (arrOut, paramOut)      = mutableArray (ArrayR dim0 tp) "out"
      (arrIn,  paramIn)       = delayedArray                  "in" mdelayed
      paramEnv                = envParam aenv
      zero                    = liftInt 0
  in
  makeOpenAcc uid "foldAllS" (paramGang ++ paramOut ++ paramIn ++ paramEnv) $ do
    r <- case mseed of
           Just seed -> do z <- seed
                           reduceFromTo  tp (indexHead start) (indexHead end) (app2 combine) z (app1 (delayedLinearIndex arrIn))
           Nothing   ->    reduce1FromTo tp (indexHead start) (indexHead end) (app2 combine)   (app1 (delayedLinearIndex arrIn))
    writeArray TypeInt arrOut zero r
    return_

-- Parallel reduction of an entire array to a single element, step 1.
--
-- Threads reduce each stripe of the input into a temporary array, incorporating
-- any fused functions on the way.
--
mkFoldAllP1
    :: UID
    -> Gamma             aenv                       -- ^ array environment
    -> TypeR e
    -> IRFun2     Native aenv (e -> e -> e)         -- ^ combination function
    -> MIRDelayed Native aenv (Vector e)            -- ^ input data
    -> CodeGen    Native      (IROpenAcc Native aenv (Scalar e))
mkFoldAllP1 uid aenv tp combine mdelayed =
  let
      (start, end, paramGang) = gangParam    dim1
      (arrTmp, paramTmp)      = mutableArray (ArrayR dim1 tp) "tmp"
      (arrIn,  paramIn)       = delayedArray                  "in" mdelayed
      piece                   = local     (TupRsingle scalarTypeInt) "ix.piece"
      paramPiece              = parameter (TupRsingle scalarTypeInt) "ix.piece"
      paramEnv                = envParam aenv
  in
  makeOpenAcc uid "foldAllP1" (paramGang ++ paramPiece ++ paramTmp ++ paramIn ++ paramEnv) $ do

    -- A thread reduces a sequential (non-empty) stripe of the input and stores
    -- that value into a temporary array at a specific index. This method thus
    -- supports non-commutative operators because the order of operations
    -- remains left-to-right.
    --
    r <- reduce1FromTo tp (indexHead start) (indexHead end) (app2 combine) (app1 (delayedLinearIndex arrIn))
    writeArray TypeInt arrTmp piece r

    return_

-- Parallel reduction of an entire array to a single element, step 2.
--
-- A single thread reduces the temporary array to a single element.
--
-- During execution, we choose a stripe size in phase 1 so that the temporary is
-- small-ish and thus suitable for sequential reduction. An alternative would be
-- to keep the stripe size constant and, for if the partial reductions array is
-- large, continuing reducing it in parallel.
--
mkFoldAllP2
    :: UID
    -> Gamma          aenv                          -- ^ array environment
    -> TypeR e
    -> IRFun2  Native aenv (e -> e -> e)            -- ^ combination function
    -> MIRExp  Native aenv e                        -- ^ seed element, if this is an exclusive reduction
    -> CodeGen Native      (IROpenAcc Native aenv (Scalar e))
mkFoldAllP2 uid aenv tp combine mseed =
  let
      (start, end, paramGang) = gangParam    dim1
      (arrTmp, paramTmp)      = mutableArray (ArrayR dim1 tp) "tmp"
      (arrOut, paramOut)      = mutableArray (ArrayR dim0 tp) "out"
      paramEnv                = envParam aenv
      zero                    = liftInt 0
  in
  makeOpenAcc uid "foldAllP2" (paramGang ++ paramTmp ++ paramOut ++ paramEnv) $ do
    r <- case mseed of
           Just seed -> do z <- seed
                           reduceFromTo  tp (indexHead start) (indexHead end) (app2 combine) z (readArray TypeInt arrTmp)
           Nothing   ->    reduce1FromTo tp (indexHead start) (indexHead end) (app2 combine)   (readArray TypeInt arrTmp)
    writeArray TypeInt arrOut zero r
    return_


-- Exclusive reductions over empty arrays (of any dimension) fill the lower
-- dimensions with the initial element
--
mkFoldFill
    :: UID
    -> Gamma aenv
    -> ArrayR (Array sh e)
    -> IRExp   Native aenv e
    -> CodeGen Native      (IROpenAcc Native aenv (Array sh e))
mkFoldFill uid aenv repr seed =
  mkGenerate uid aenv repr (IRFun1 (const seed))

-- Reduction loops
-- ---------------

-- Reduction of a (possibly empty) index space.
--
reduceFromTo
    :: TypeR a
    -> Operands Int                                              -- ^ starting index
    -> Operands Int                                              -- ^ final index (exclusive)
    -> (Operands a -> Operands a -> CodeGen Native (Operands a)) -- ^ combination function
    -> Operands a                                                -- ^ initial value
    -> (Operands Int -> CodeGen Native (Operands a))             -- ^ function to retrieve element at index
    -> CodeGen Native (Operands a)
reduceFromTo tp m n f z get =
  iterFromTo tp m n z $ \i acc -> do
    x <- get i
    y <- f acc x
    return y

-- Reduction of an array over a _non-empty_ index space. The array must
-- contain at least one element.
--
reduce1FromTo
    :: TypeR a
    -> Operands Int                                              -- ^ starting index
    -> Operands Int                                              -- ^ final index
    -> (Operands a -> Operands a -> CodeGen Native (Operands a)) -- ^ combination function
    -> (Operands Int -> CodeGen Native (Operands a))             -- ^ function to retrieve element at index
    -> CodeGen Native (Operands a)
reduce1FromTo tp m n f get = do
  z  <- get m
  m1 <- add numType m (ir numType (num numType 1))
  reduceFromTo tp m1 n f z get

