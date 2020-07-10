{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-unused-imports   #-}
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.Plugin
-- Copyright   : [2017..2020] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.Plugin (

  plugin,

) where

import Data.Array.Accelerate.Error
import Data.Array.Accelerate.LLVM.Native.Plugin.Annotation
import Data.Array.Accelerate.LLVM.Native.Plugin.BuildInfo

import Control.Monad
import Data.IORef
import Data.List
import qualified Data.Map                                           as Map

import GhcPlugins
import Linker
import SysTools


-- | This GHC plugin is required to support ahead-of-time compilation for the
-- accelerate-llvm-native backend. In particular, it tells GHC about the
-- additional object files generated by
-- 'Data.Array.Accelerate.LLVM.Native.runQ'* which must be linked into the final
-- executable.
--
-- To use it, add the following to the .cabal file of your project:
--
-- > ghc-options: -fplugin=Data.Array.Accelerate.LLVM.Native.Plugin
--
plugin :: HasCallStack => Plugin
plugin = defaultPlugin
  { installCoreToDos = install
#if __GLASGOW_HASKELL__ >= 806
  , pluginRecompile  = purePlugin
#endif
  }

install :: HasCallStack => [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
install _ rest = do
  let this (CoreDoPluginPass "accelerate-llvm-native" _) = True
      this _                                             = False
  --
  return $ CoreDoPluginPass "accelerate-llvm-native" pass : filter (not . this) rest

pass :: HasCallStack => ModGuts -> CoreM ModGuts
pass guts = do
  -- Determine the current build environment
  --
  hscEnv   <- getHscEnv
  dynFlags <- getDynFlags
  this     <- getModule

  -- Gather annotations for the extra object files which must be supplied to the
  -- linker in order to complete the current module.
  --
  paths   <- nub . concat <$> mapM (objectPaths guts) (mg_binds guts)

  when (not (null paths))
    $ debugTraceMsg
    $ hang (text "Data.Array.Accelerate.LLVM.Native.Plugin: linking module" <+> quotes (pprModule this) <+> text "with:") 2 (vcat (map text paths))

  -- The linking method depends on the current build target
  --
  case hscTarget dynFlags of
    HscNothing     -> return ()
    HscInterpreted ->
      -- We are in interactive mode (ghci)
      --
      when (not (null paths)) . liftIO $ do
        let opts  = ldInputs dynFlags
            objs  = map optionOfPath paths
        --
        linkCmdLineLibs
               $ hscEnv { hsc_dflags = dynFlags { ldInputs = opts ++ objs }}

    -- This case is not necessary for GHC-8.6 and above.
    --
    -- We are building to object code.
    --
    -- Because of separate compilation, we will only encounter the annotation
    -- pragmas on files which have changed between invocations. This applies to
    -- both @ghc --make@ as well as the separate compile/link phases of building
    -- with @cabal@ (and @stack@). Note that whenever _any_ file is updated we
    -- must make sure that the linker options contains the complete list of
    -- objects required to build the entire project.
    --
    _ -> liftIO $ do
#if __GLASGOW_HASKELL__ < 806
      -- Read the object file index and update (we may have added or removed
      -- objects for the given module)
      --
      let buildInfo = mkBuildInfoFileName (objectMapPath dynFlags)
      abi <- readBuildInfo buildInfo
      --
      let abi'      = if null paths
                        then Map.delete this       abi
                        else Map.insert this paths abi
          allPaths  = nub (concat (Map.elems abi'))
          allObjs   = map optionOfPath allPaths
      --
      writeBuildInfo buildInfo abi'

      -- Make sure the linker flags are up-to-date.
      --
      when (not (isNoLink (ghcLink dynFlags))) $ do
        linker_info <- getLinkerInfo dynFlags
        writeIORef (rtldInfo dynFlags)
          $ Just
          $ case linker_info of
              GnuLD     opts -> GnuLD     (nub (opts ++ allObjs))
              GnuGold   opts -> GnuGold   (nub (opts ++ allObjs))
              DarwinLD  opts -> DarwinLD  (nub (opts ++ allObjs))
              SolarisLD opts -> SolarisLD (nub (opts ++ allObjs))
              AixLD     opts -> AixLD     (nub (opts ++ allObjs))
              LlvmLLD   opts -> LlvmLLD   (nub (opts ++ allObjs))
              UnknownLD      -> UnknownLD  -- no linking performed?
#endif
      return ()

  return guts

objectPaths :: ModGuts -> CoreBind -> CoreM [FilePath]
objectPaths guts (NonRec b _) = objectAnns guts b
objectPaths guts (Rec bs)     = concat <$> mapM (objectAnns guts) (map fst bs)

objectAnns :: ModGuts -> CoreBndr -> CoreM [FilePath]
objectAnns guts bndr = do
  anns  <- getAnnotations deserializeWithData guts
  return [ path | Object path <- lookupWithDefaultUFM anns [] (varUnique bndr) ]

objectMapPath :: DynFlags -> FilePath
objectMapPath DynFlags{..}
  | Just p <- objectDir = p
  | Just p <- dumpDir   = p
  | otherwise           = "."

optionOfPath :: FilePath -> Option
optionOfPath = FileOption []

