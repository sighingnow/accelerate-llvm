{-# LANGUAGE CPP                      #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE TypeOperators            #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.Execute
-- Copyright   : [2014..2016] Trevor L. McDonell
--               [2014..2014] Vinod Grover (NVIDIA Corporation)
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.Execute (

  executeAcc, executeAfun1,

  executeOp,

) where

-- accelerate
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Analysis.Match


import Data.Array.Accelerate.LLVM.State
import Data.Array.Accelerate.LLVM.Execute

import Data.Array.Accelerate.LLVM.Native.CodeGen.Fold               ( matchShapeType )
import Data.Array.Accelerate.LLVM.Native.Compile
import Data.Array.Accelerate.LLVM.Native.Execute.Async
import Data.Array.Accelerate.LLVM.Native.Execute.Environment
import Data.Array.Accelerate.LLVM.Native.Execute.Marshal
import Data.Array.Accelerate.LLVM.Native.Target
import qualified Data.Array.Accelerate.LLVM.Native.Debug            as Debug

-- Use work-stealing scheduler
import Data.Range.Range                                             ( Range(..) )
import Control.Parallel.Meta                                        ( runExecutable, Finalise(..) )
import Control.Parallel.Meta.Worker                                 ( gangSize )
import Data.Array.Accelerate.LLVM.Native.Execute.LBS

-- library
import Data.Monoid                                                  ( mempty )
import Data.Word                                                    ( Word8 )
import Control.Monad.State                                          ( gets )
import Control.Monad.Trans                                          ( liftIO )
import Prelude                                                      hiding ( map, scanl, scanr, init, seq )
import qualified Data.Vector                                        as V
import qualified Prelude                                            as P

import Foreign.C
import Foreign.LibFFI                                               ( Arg )
import Foreign.Ptr

#if !MIN_VERSION_llvm_general(3,3,0)
import Data.Word
import Data.Maybe
import qualified LLVM.General.Context                               as LLVM
#endif


-- Array expression evaluation
-- ---------------------------

-- Computations are evaluated by traversing the AST bottom up, and for each node
-- distinguishing between three cases:
--
--  1. If it is a Use node, we return a reference to the array data. Even though
--     we execute with multiple cores, we assume a shared memory multiprocessor
--     machine.
--
--  2. If it is a non-skeleton node, such as a let binding or shape conversion,
--     then execute directly by updating the environment or similar.
--
--  3. If it is a skeleton node, then we need to execute the generated LLVM
--     code.
--
instance Execute Native where
  map           = simpleOp
  generate      = simpleOp
  transform     = simpleOp
  backpermute   = simpleOp
  fold          = foldOp
  fold1         = fold1Op
  -- permute       = permuteOp
  -- scanl1        = scanl1Op
  stencil1      = stencil1Op
  stencil2      = stencil2Op


-- Skeleton implementation
-- -----------------------

-- Simple kernels just needs to know the shape of the output array.
--
simpleOp
    :: (Shape sh, Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> sh
    -> LLVM Native (Array sh e)
simpleOp NativeR{..} gamma aenv () sh = do
  native <- gets llvmTarget
  liftIO $ do
    out <- allocateArray sh
    executeMain executableR $ \f ->
      executeOp defaultLargePPT native f mempty gamma aenv (IE 0 (size sh)) out
    return out

simpleNamed
    :: (Shape sh, Elt e)
    => String
    -> ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> sh
    -> LLVM Native (Array sh e)
simpleNamed fun NativeR{..} gamma aenv () sh = do
  native <- gets llvmTarget
  liftIO $ do
    out <- allocateArray sh
    execute executableR fun $ \f ->
      executeOp defaultLargePPT native f mempty gamma aenv (IE 0 (size sh)) out
    return out


-- Note: [Reductions]
--
-- There are two flavours of reduction:
--
--   1. If we are collapsing to a single value, then threads reduce strips of
--      the input in parallel, and then a single thread reduces the partial
--      reductions to a single value. Load balancing occurs over the input
--      stripes.
--
--   2. If this is a multidimensional reduction, then each inner dimension is
--      handled by a single thread. Load balancing occurs over the outer
--      dimension indices.
--
-- The entry points to executing the reduction are 'foldOp' and 'fold1Op', for
-- exclusive and inclusive reductions respectively. These functions handle
-- whether the input array is empty. If the input and output arrays are
-- non-empty, we then further dispatch (via 'foldCore') to 'foldAllOp' or
-- 'foldDimOp' for single or multidimensional reductions, respectively.
-- 'foldAllOp' in particular must execute specially whether the gang has
-- multiple worker threads which can process the array in parallel.
--

fold1Op
    :: (Shape sh, Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM Native (Array sh e)
fold1Op kernel gamma aenv stream sh@(sx :. sz)
  = $boundsCheck "fold1" "empty array" (sz > 0)
  $ case size sh of
      0 -> liftIO $ allocateArray sx   -- empty, but possibly with non-zero dimensions
      _ -> foldCore kernel gamma aenv stream sh

foldOp
    :: (Shape sh, Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM Native (Array sh e)
foldOp kernel gamma aenv stream sh@(sx :. _)
  = case size sh of
      0 -> simpleNamed "generate" kernel gamma aenv stream (listToShape (P.map (max 1) (shapeToList sx)))
      _ -> foldCore kernel gamma aenv stream sh

foldCore
    :: (Shape sh, Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM Native (Array sh e)
foldCore kernel gamma aenv stream sh
  | Just REFL <- matchShapeType sh (undefined::DIM1)
  = foldAllOp kernel gamma aenv stream sh
  --
  | otherwise
  = foldDimOp kernel gamma aenv stream sh

foldAllOp
    :: forall aenv e. Elt e
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> DIM1
    -> LLVM Native (Scalar e)
foldAllOp NativeR{..} gamma aenv () (Z :. sz) = do
  par   <- gets llvmTarget
  liftIO $ case gangSize (theGang par) of

    -- Sequential reduction
    1    -> do
      out <- allocateArray Z
      execute executableR "foldAllS" $ \f ->
        executeOp 1 par f mempty gamma aenv (IE 0 sz) out
      return out

    -- Parallel reduction
    ncpu -> do
      let
          stripe  = max defaultLargePPT (sz `div` (ncpu * 16))
          steps   = (sz + stripe - 1) `div` stripe
          seq     = par { theGang = V.take 1 (theGang par) }

      out <- allocateArray Z
      tmp <- allocateArray (Z :. steps) :: IO (Vector e)

      execute  executableR "foldAllP1" $ \f1 -> do
       execute executableR "foldAllP2" $ \f2 -> do
        executeOp 1 par f1 mempty gamma aenv (IE 0 steps) (sz, stripe, tmp)
        executeOp 1 seq f2 mempty gamma aenv (IE 0 steps) (tmp, out)

      return out


foldDimOp
    :: (Shape sh, Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> (sh :. Int)
    -> LLVM Native (Array sh e)
foldDimOp NativeR{..} gamma aenv () (sh :. sz) = do
  native <- gets llvmTarget
  liftIO $ do
    out <- allocateArray sh
    executeMain executableR $ \f ->
      executeOp defaultSmallPPT native f mempty gamma aenv (IE 0 (size sh)) (sz, out)
    return out


{--
-- Forward permutation, specified by an indexing mapping into an array and a
-- combination function to combine elements.
--
permuteOp
    :: (Shape sh, Shape sh', Elt e)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> sh
    -> Array sh' e
    -> LLVM Native (Array sh' e)
permuteOp kernel gamma aenv () shIn dfs = do
  let n                         = size (shape dfs)
      unlocked                  = 0
  --
  out    <- cloneArray dfs
  native <- gets llvmTarget
  liftIO $ do
    barrier@(Array _ adata) <- liftIO $ allocateArray (Z :. n)  :: IO (Vector Word8)
    memset (ptrsOfArrayData adata) unlocked n
    executeOp native kernel mempty gamma aenv (IE 0 (size shIn)) (barrier, out)
  return out
--}
{--
-- Left inclusive scan
--
scanl1Op
    :: forall aenv e. Elt e
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> DIM1
    -> LLVM Native (Vector e)
scanl1Op (NativeR k) gamma aenv () (Z :. sz) = do
  native@Native{..} <- gets llvmTarget

  -- sequential reduction
  if gangSize theGang == 1 || sz < defaultLargePPT
     then liftIO $ do
            out <- allocateArray (Z :. sz)
            executeNamedFunction k "scanl1Seq" $ \f ->
              callFFI f retVoid =<< marshal native () (0::Int, sz, out, (gamma,aenv))

            return out

  -- Parallel reduction
     else let chunkSize = defaultLargePPT
              chunks    = sz `div` chunkSize
          in
          liftIO $ do
            tmp <- allocateArray (Z :. (chunks-1))      :: IO (Vector e)
            out <- allocateArray (Z :. sz)

            executeNamedFunction k "scanl1Pre"           $ \f -> do
              runExecutable fillP 1 (IE 0 chunks) mempty $ \start end _ -> do
                callFFI f retVoid =<< marshal native () (start,end,chunkSize,tmp,(gamma,aenv))

            executeNamedFunction k "scanl1Post"          $ \f ->
              runExecutable fillP 1 (IE 0 chunks) mempty $ \start end _ -> do
                callFFI f retVoid =<< marshal native () (start,end,(chunks-1),chunkSize,sz,tmp,out,(gamma,aenv))

            return out
--}

stencil1Op
    :: (Shape sh, Elt a, Elt b)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> Array sh a
    -> LLVM Native (Array sh b)
stencil1Op kernel gamma aenv stream arr
  = simpleOp kernel gamma aenv stream (shape arr)

stencil2Op
    :: (Shape sh, Elt a, Elt b, Elt c)
    => ExecutableR Native
    -> Gamma aenv
    -> Aval aenv
    -> Stream
    -> Array sh a
    -> Array sh b
    -> LLVM Native (Array sh c)
stencil2Op kernel gamma aenv stream arr brr
  = simpleOp kernel gamma aenv stream (shape arr `intersect` shape brr)


-- Skeleton execution
-- ------------------

-- Execute the given function distributed over the available threads.
--
executeOp
    :: Marshalable args
    => Int
    -> Native
    -> ([Arg] -> IO ())
    -> Finalise
    -> Gamma aenv
    -> Aval aenv
    -> Range
    -> args
    -> IO ()
executeOp ppt native@Native{..} f finish gamma aenv r args =
  runExecutable fillP ppt r finish Nothing $ \start end _tid ->
  monitorProcTime                          $
    f =<< marshal native () (start, end, args, (gamma, aenv))


-- Standard C functions
-- --------------------

memset :: Ptr Word8 -> Word8 -> Int -> IO ()
memset p w s = c_memset p (fromIntegral w) (fromIntegral s) >> return ()

foreign import ccall unsafe "string.h memset" c_memset
    :: Ptr Word8 -> CInt -> CSize -> IO (Ptr Word8)


-- Debugging
-- ---------

monitorProcTime :: IO a -> IO a
monitorProcTime = Debug.withProcessor Debug.Native

