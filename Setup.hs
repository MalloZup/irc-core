{-|
Module      : Main
Description : Custom setup script
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This is a default setup script except that it checks that all
transitive dependencies of this package use free licenses and
generates a Build module detailing the versions of build tools
and transitive library dependencies.

-}

module Main (main) where

import           Control.Monad (unless)
import           Data.Char (isAlphaNum)
import           Data.List (delete)
import           Distribution.InstalledPackageInfo (InstalledPackageInfo, sourcePackageId, license)
import qualified Distribution.ModuleName as ModuleName
import           Distribution.PackageDescription hiding (license)
import           Distribution.Simple
import           Distribution.Simple.LocalBuildInfo (LocalBuildInfo, installedPkgs, withLibLBI)
import           Distribution.Simple.PackageIndex (allPackages)
import           Distribution.Simple.Setup (configVerbosity, fromFlag)
import           Distribution.Simple.Utils (createDirectoryIfMissingVerbose, rewriteFileEx)
import           Distribution.Verbosity (Verbosity)
import           System.FilePath ((</>), (<.>))

import           Distribution.Simple.BuildPaths (autogenComponentModulesDir)

import qualified Distribution.SPDX               as SPDX


-- | Default Setup main extended to generate a Build module and to validate
-- the licenses of transitive dependencies.
main :: IO ()
main = defaultMainWithHooks simpleUserHooks

  { postConf = \args flags pkg lbi ->
      do let pkgs = allPackages (installedPkgs lbi)
         validateLicenses pkgs
         generateBuildModule (fromFlag (configVerbosity flags)) pkg lbi pkgs
         postConf simpleUserHooks args flags pkg lbi

  , sDistHook = \pkg mbLbi hooks flags ->
      do let pkg' = forgetBuildModule pkg
         sDistHook simpleUserHooks pkg' mbLbi hooks flags
  }


-- | Remove the Build module from the package description. This is needed
-- when building a source distribution tarball because the Build module
-- should be generated dynamically at configuration time.
forgetBuildModule ::
  PackageDescription {- ^ package description with Build module    -} ->
  PackageDescription {- ^ package description without Build module -}
forgetBuildModule pkg = pkg
  { library     = forgetInLibrary    <$> library     pkg
  , executables = forgetInExecutable <$> executables pkg
  , benchmarks  = forgetInBenchmark  <$> benchmarks  pkg
  , testSuites  = forgetInTestSuite  <$> testSuites  pkg
  }
  where
    forget = delete (ModuleName.fromString (buildModuleName pkg))

    forgetInBuildInfo x = x
      { otherModules = forget (otherModules x) }

    forgetInLibrary x = x
      { exposedModules = forget (exposedModules x)
      , libBuildInfo   = forgetInBuildInfo (libBuildInfo x) }

    forgetInTestSuite x = x
      { testBuildInfo = forgetInBuildInfo (testBuildInfo x) }

    forgetInBenchmark x = x
      { benchmarkBuildInfo = forgetInBuildInfo (benchmarkBuildInfo x) }

    forgetInExecutable x = x
      { buildInfo = forgetInBuildInfo (buildInfo x) }


-- | Compute the name of the Build module for a given package
buildModuleName ::
  PackageDescription {- ^ package description -} ->
  String             {- ^ module name         -}
buildModuleName pkg = "Build_" ++ map clean (unPackageName (pkgName (package pkg)))
  where
    clean x | isAlphaNum x = x
            | otherwise    = '_'


-- | Generate the Build_package module for the given package information.
--
-- This module will export `deps :: [(String,[Int])]`
generateBuildModule ::
  Verbosity              {- ^ build verbosity                 -} ->
  PackageDescription     {- ^ package description             -} ->
  LocalBuildInfo         {- ^ local build information         -} ->
  [InstalledPackageInfo] {- ^ transitive package dependencies -} ->
  IO ()
generateBuildModule verbosity pkg lbi pkgs =
  withLibLBI pkg lbi $ \_lib clbi ->
  do let dir = autogenComponentModulesDir lbi clbi
         modname = buildModuleName pkg
         file    = dir </> modname <.> "hs"
     createDirectoryIfMissingVerbose verbosity True dir
     rewriteFileEx verbosity file
       $ unlines
       [ "{-|"
       , "Module      : " ++ modname
       , "Description : Dynamically generated configuration module"
       , "-}"
       , "module " ++ modname ++ " (deps) where"
       , ""
       , "-- | Transitive dependencies for this package computed at configure-time"
       , "deps :: [(String,[Int])] -- ^ package name, version number"
       , "deps = " ++ renderDeps pkgs
       ]


-- | Render the transitive package dependencies as a Haskell expression
renderDeps ::
  [InstalledPackageInfo] {- ^ transitive package dependencies -} ->
  String                 {- ^ haskell syntax                  -}
renderDeps pkgs =
  show [ (unPackageName (pkgName p), versionNumbers (pkgVersion p))
       | p <- sourcePackageId <$> pkgs
       ]

-- | Check that all transitive dependencies are available under an acceptable
-- license. Raises a user-error on failure.
validateLicenses ::
  [InstalledPackageInfo] {- ^ transitive package dependencies -} ->
  IO ()
validateLicenses pkgs =
  do let toLicense = either licenseFromSPDX id
         p pkg   = toLicense (license pkg) `notElem` freeLicenses
         badPkgs = filter p pkgs

     unless (null badPkgs) $
       do mapM_ print [ toLicense (license p) | p <- badPkgs ]
          fail "BAD LICENSE"


-- | The set of permissive licenses that are acceptable for transitive dependencies
-- of this package: BSD2, BSD3, ISC, MIT, PublicDomain
freeLicenses :: [License]
freeLicenses = [BSD2, BSD3, ISC, MIT, PublicDomain, UnknownLicense "LicenseRefPublicDomain"]
