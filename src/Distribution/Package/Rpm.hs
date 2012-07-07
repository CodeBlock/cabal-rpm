{-# LANGUAGE CPP #-}

-- |
-- Module      :  Distribution.Package.Rpm
-- Copyright   :  Bryan O'Sullivan 2007, 2008
--
-- Maintainer  :  Bryan O'Sullivan <bos@serpentine.com>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Support for building RPM packages.  Can also generate
-- an RPM spec file if you need a basic one to hand-customize.

-- This software may be used and distributed according to the terms of
-- the GNU General Public License, incorporated herein by reference.

module Distribution.Package.Rpm (
      createSpecFile
    , rpm
    , rpmBuild
    ) where

import Control.Exception (bracket)
import Control.Monad (forM_, liftM, mapM, when, unless)
import Data.Char (toLower)
import Data.List (intersperse, isPrefixOf, sort)
import Data.Maybe
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (formatTime)
import Data.Version (Version(..), showVersion)
import System.Cmd (system)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         doesDirectoryExist, doesFileExist,
                         getDirectoryContents)
import System.Exit (ExitCode(..))
import System.IO (IOMode(..), hClose, hGetLine, hPutStr, hPutStrLn, openFile,
                 stderr)
import System.Locale (defaultTimeLocale)
import System.Process (runInteractiveCommand, waitForProcess)

import System.FilePath ((</>))
import Distribution.Simple.Compiler (CompilerFlavor(..), Compiler(..),
                                     compilerVersion)
import Distribution.License (License(..))
import Distribution.Package (PackageIdentifier(..))
import Distribution.Simple.PreProcess (knownSuffixHandlers)
import Distribution.Simple.Program (defaultProgramConfiguration)
import Distribution.Simple.Configure (configCompiler, configure,
                                      maybeGetPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo, distPref)
import Distribution.Simple.SrcDist (createArchive, prepareTree, tarBallName)
import Distribution.Simple.Utils (copyDirectoryRecursiveVerbose,
                                  copyFileVerbose, die, warn)
import Distribution.PackageDescription (BuildInfo(..),
                                        GenericPackageDescription(..),
                                        Library(..),
                                        PackageDescription(..),
                                        emptyHookedBuildInfo,
                                        exeName, finalizePackageDescription,
                                        hasLibs, setupMessage, withExe,
                                        withLib)
import Distribution.Verbosity (Verbosity, deafening)
import Distribution.Version (Dependency(..), VersionRange(..))
import Distribution.Simple.Setup (configConfigurationsFlags, emptyConfigFlags)
import Distribution.Package.Rpm.Bundled (bundledWith, isBundled)
import Distribution.Package.Rpm.Setup (RpmFlags(..))
import System.Posix.Files (setFileCreationMask)

commaSep :: [String] -> String
commaSep = concat . intersperse ", "

simplePackageDescription :: GenericPackageDescription -> RpmFlags
                         -> IO (Compiler, PackageDescription)
simplePackageDescription genPkgDesc flags = do
    (compiler, _) <- configCompiler (rpmCompiler flags) Nothing Nothing
                     defaultProgramConfiguration
                     (rpmVerbosity flags)
    let bundled = bundledWith compiler
    case finalizePackageDescription (rpmConfigurationsFlags flags)
         bundled "" "" ("", Version [] []) genPkgDesc of
      Left deps -> do hPutStrLn stderr "Missing dependencies: "
                      let c = virtualPackage compiler
                      forM_ deps $ \dep -> do
                        s <- commaSep `liftM` showRpmReq deafening c dep
                        hPutStrLn stderr $ "  " ++ s
                      die "cannot continue due to missing dependencies"
      Right (pd, _) -> return (compiler, pd)
    
rpm :: GenericPackageDescription -- ^info from the .cabal file
    -> RpmFlags                 -- ^rpm flags
    -> IO ()

rpm genPkgDesc flags = do
    let comp = rpmCompiler flags
    case comp of
      Just GHC -> return ()
      Just c -> die ("the " ++ show c ++ " compiler is not yet supported")
      _ -> die "no compiler information provided"
    if rpmGenSpec flags
      then do
        (compiler, pkgDesc) <- simplePackageDescription genPkgDesc flags
        (name, extraDocs) <- createSpecFile False pkgDesc flags compiler "."
        putStrLn $ "Spec file created: " ++ name
        when ((not . null) extraDocs) $ do
            putStrLn "NOTE: docs packaged, but not in .cabal file:"
            mapM_ putStrLn $ sort extraDocs
        return ()
      else rpmBuild genPkgDesc flags

-- | Copy a file or directory (recursively, in the latter case) to the
-- same name in the target directory.  Arguments flipped from the
-- conventional order.

copyTo :: Verbosity -> FilePath -> FilePath -> IO ()

copyTo verbose dest src = do
    isFile <- doesFileExist src
    let destDir = dest </> src
    if isFile
      then copyFileVerbose verbose src destDir
      else copyDirectoryRecursiveVerbose verbose src destDir

autoreconf :: Verbosity -> PackageDescription -> IO ()

autoreconf verbose pkgDesc = do
    ac <- doesFileExist "configure.ac"
    when ac $ do
        c <- doesFileExist "configure"
        when (not c) $ do
            setupMessage verbose "Running autoreconf" pkgDesc
            ret <- system "autoreconf"
            case ret of
              ExitSuccess -> return ()
              ExitFailure n -> die ("autoreconf failed with status " ++ show n)

localBuildInfo :: PackageDescription -> RpmFlags -> IO LocalBuildInfo
localBuildInfo pkgDesc flags = do
  mb_lbi <- maybeGetPersistBuildConfig
  case mb_lbi of
    Just lbi -> return lbi
    Nothing -> configure (Right pkgDesc, emptyHookedBuildInfo)
               ((emptyConfigFlags defaultProgramConfiguration)
                { configConfigurationsFlags = rpmConfigurationsFlags flags })

rpmBuild :: GenericPackageDescription -> RpmFlags -> IO ()

rpmBuild genPkgDesc flags = do
    tgtPfx <- canonicalizePath (maybe distPref id $ rpmTopDir flags)
    (compiler, pkgDesc) <- simplePackageDescription genPkgDesc flags
    let verbose = rpmVerbosity flags
        tmpDir = tgtPfx </> "src"
    flip mapM_ ["BUILD", "RPMS", "SOURCES", "SPECS", "SRPMS"] $ \ subDir -> do
      createDirectoryIfMissing True (tgtPfx </> subDir)
    let specsDir = tgtPfx </> "SPECS"
    lbi <- localBuildInfo pkgDesc flags
    bracket (setFileCreationMask 0o022) setFileCreationMask $ \ _ -> do
      autoreconf verbose pkgDesc
      (specFile, extraDocs) <- createSpecFile True pkgDesc flags compiler
                               specsDir
      tree <- prepareTree pkgDesc verbose (Just lbi) False tmpDir
              knownSuffixHandlers 0
      mapM_ (copyTo verbose tree) extraDocs
      createArchive pkgDesc verbose (Just lbi) tmpDir (tgtPfx </> "SOURCES")
      ret <- system ("rpmbuild -ba --define \"_topdir " ++ tgtPfx ++ "\" " ++
                     specFile)
      case ret of
        ExitSuccess -> return ()
        ExitFailure n -> die ("rpmbuild failed with status " ++ show n)

defaultRelease :: UTCTime -> IO String

defaultRelease now = do
    darcsRepo <- doesDirectoryExist "_darcs"
    return $ if darcsRepo
               then formatTime defaultTimeLocale "0.%Y%m%d" now
               else "1"

rstrip :: (Char -> Bool) -> String -> String

rstrip p = reverse . dropWhile p . reverse

joinConfigurations :: [(String, Bool)] -> String
joinConfigurations = unwords . map warm
    where warm (name, True) = name
          warm (name, _) = '-' : name

createSpecFile :: Bool                -- ^whether to forcibly create file
               -> PackageDescription  -- ^info from the .cabal file
               -> RpmFlags            -- ^rpm flags
               -> Compiler            -- ^compiler details
               -> FilePath            -- ^directory in which to create file
               -> IO (FilePath, [FilePath])

createSpecFile force pkgDesc flags compiler tgtPfx = do
    now <- getCurrentTime
    defRelease <- defaultRelease now
    let pkg = package pkgDesc
        verbose = rpmVerbosity flags
        origName = pkgName pkg
        name = maybe (map toLower origName) id (rpmName flags)
        version = maybe ((showVersion . pkgVersion) pkg) id (rpmVersion flags)
        release = maybe defRelease id (rpmRelease flags)
        specPath = tgtPfx </> name ++ ".spec"
        group = "Development/Languages"
        buildRoot = "%{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)"
        cmplrVersion = compilerVersion compiler
        doHaddock = rpmHaddock flags && hasLibs pkgDesc
        flavor = compilerFlavor compiler
        isExec = isExecutable pkgDesc
        subPackage = if isExec then "-n %{hsc_name}-%{lc_name}" else ""
    (cmplr, runner) <- case flavor of
                         GHC -> return ("ghc", "runghc")
                         Hugs -> return ("hugs", "runhugs")
                         JHC -> return ("jhc", "runjhc")
                         NHC -> return ("nhc", "runnhc")
                         (OtherCompiler s) -> return (s, "run" ++ s)
                         _ -> die $ show flavor ++ " is not supported"
    unless force $ do
        specAlreadyExists <- doesFileExist specPath
        when specAlreadyExists $
            die $ "spec file already exists: " ++ specPath
    h <- openFile specPath WriteMode
    buildReq <- showBuildReq verbose doHaddock compiler pkgDesc
    runtimeReq <- showRuntimeReq verbose compiler pkgDesc
    let putHdr hdr val = hPutStrLn h (hdr ++ ": " ++ val)
        putHdr_ hdr val = when (not $ null val) $
                              hPutStrLn h (hdr ++ ": " ++ val)
        putHdrD hdr val dfl = hPutStrLn h (hdr ++ ": " ++
                                           if null val then dfl else val)
        putNewline = hPutStrLn h ""
        put s = hPutStrLn h s
        putDef v s = put $ "%define " ++ v ++ ' ' : s
        putSetup s = put $ runner ++ " Setup " ++ s
        date = formatTime defaultTimeLocale "%a %b %d %Y" now
    putDef "hsc_name" cmplr
    putDef "hsc_version" $ showVersion cmplrVersion
    putDef "hsc_namever" $ compilerNameVersion compiler
    put "# Original Haskell package name, and lowercased form."
    putDef "pkg_name" origName
    putDef "lc_name" name
    putDef "pkg_libdir" "%{_libdir}/%{hsc_name}-%{hsc_version}/%{pkg_name}-%{version}"
    putDef "tar_dir" "%{_builddir}/%{?buildsubdir}"
    putNewline
    put "# Haskell compilers do not emit debug information."
    putDef "debug_package" "%{nil}"
    putNewline
    
    when isExec $ do
      putHdr "Name" "%{lc_name}"
    unless isExec $ do
      putHdr "Name" "%{hsc_name}-%{lc_name}"
    putHdr "Version" version
    putHdr "Release" $ release ++ "%{?dist}"
    putHdr "License" $ (showLicense . license) pkgDesc
    putHdr "Group" group
    putHdr_ "URL" $ homepage pkgDesc
    putHdr "Source" $ tarBallName pkgDesc
    -- Some packages conflate the synopsis and description fields.  Ugh.
    let syn = synopsis pkgDesc
    (syn', synTooLong) <- case lines syn of
              (x:_) -> return (x, x /= syn)
              _ -> do warn verbose "This package has no synopsis."
                      return ("This package has no synopsis.", False)
    let summary = if synTooLong
                  then syn' ++ " [...]"
                  else rstrip (== '.') syn'
    when synTooLong $
        warn verbose "The synopsis for this package spans multiple lines."
    putHdrD "Summary" summary "This package has no summary"
    putHdr "BuildRoot" buildRoot
    putHdr "BuildRequires" buildReq
    -- External libraries incur both build-time and runtime
    -- dependencies.  The latter only need to be made explicit for the
    -- built library, as RPM is smart enough to ferret out good
    -- dependencies for binaries.
    extDeps <- withLib pkgDesc [] (findLibDeps .libBuildInfo)
    let extraReq = commaSep extDeps
    putHdr_ "BuildRequires" extraReq
    unless isExec $ do
      putHdr_ "Requires" extraReq
      putHdr_ "Requires" runtimeReq
      putHdr "Provides" "%{pkg_name}-%{hsc_namever} = %{version}"

    putNewline
    putNewline

    let putDesc = do
        put $ if (null . description) pkgDesc
              then if synTooLong
                   then syn
                   else "This package does not have a description."
              else description pkgDesc
    put "%description"
    putDesc
    putNewline
    putNewline

    {- Compiler-specific library data goes into a package of its own.

       Unlike a library for a traditional language, the library
       package depends on the compiler, because when installed, it
       has to register itself with the compiler's own package
       management system. -}

    when isExec $ withLib pkgDesc () $ \_ -> do
        put "%package -n %{hsc_name}-%{lc_name}"
        putHdrD "Summary" summary "This library package has no summary"
        putHdr "Group" "Development/Libraries"
        putHdr "Requires" "%{hsc_name} = %{hsc_version}"
        putHdr_ "Requires" extraReq
        putHdr_ "Requires" runtimeReq
        putHdr "Provides" "%{pkg_name}-%{hsc_namever} = %{version}"
        putNewline
        putNewline

        put "%description -n %{hsc_name}-%{lc_name}"
        putDesc
        putNewline
        put "This package contains libraries for %{hsc_name} %{hsc_version}."
        putNewline
        putNewline

    when (rpmLibProf flags) $ do
        put "%package -n %{hsc_name}-%{lc_name}-prof"
        putHdr "Summary" "Profiling libraries for %{hsc_name}-%{lc_name}"
        putHdr "Group" "Development/Libraries"
        putHdr "Requires" "%{hsc_name}-%{lc_name} = %{version}"
        putHdr "Provides" "%{pkg_name}-%{hsc_namever}-prof = %{version}"
        putNewline
        putNewline

        put "%description -n %{hsc_name}-%{lc_name}-prof"
        putDesc
        putNewline
        put "This package contains profiling libraries for %{hsc_name} %{hsc_version}."
        putNewline
        putNewline

    put "%prep"
    put $ "%setup -q -n %{pkg_name}-%{version}"
    putNewline
    putNewline

    put "%build"
    put "if [ -f configure.ac -a ! -f configure ]; then autoreconf; fi"
    putSetup ("configure --prefix=%{_prefix} --libdir=%{_libdir} " ++
              "--docdir=%{_docdir}/%{hsc_name}-%{lc_name}-%{version} " ++
              "--libsubdir='$compiler/$pkgid' " ++
              (let cfg = rpmConfigurationsFlags flags
               in if null cfg
                  then ""
                  else "--flags='" ++ joinConfigurations cfg ++ "' ") ++
              (if (rpmLibProf flags) then "--enable" else "--disable") ++
              "-library-profiling --" ++ cmplr)
    withLib pkgDesc () $ \_ -> do
        hPutStr h "if "
        putSetup "makefile -f cabal-rpm.mk"
        put "then"
        put "    make -f cabal-rpm.mk %{_smp_mflags} || :"
        put "fi"
    putSetup "build"
    withLib pkgDesc () $ \_ -> do
        when doHaddock $
            putSetup "haddock || :"
        putSetup "register --gen-script"
        putSetup "unregister --gen-script"
    putNewline
    putNewline

    docs <- findDocs pkgDesc

    put "%install"
    put "rm -rf ${RPM_BUILD_ROOT}"
    putSetup "copy --destdir=${RPM_BUILD_ROOT}"
    withLib pkgDesc () $ \_ -> do
        put "install -m 755 register.sh unregister.sh ${RPM_BUILD_ROOT}%{pkg_libdir}"
        put "cd ${RPM_BUILD_ROOT}"
        put "echo '%defattr (-,root,root,-)' > %{tar_dir}/%{name}-files.prof"
        put "find .%{pkg_libdir} \\( -name '*_p.a' -o -name '*.p_hi' \\) | sed s/^.// >> %{tar_dir}/%{name}-files.prof"
        put "echo '%defattr (-,root,root,-)' > %{tar_dir}/%{name}-files.nonprof"
        put "find .%{pkg_libdir} -type d | sed 's/^./%dir /' >> %{tar_dir}/%{name}-files.nonprof"
        put "find .%{pkg_libdir} ! \\( -type d -o -name '*_p.a' -o -name '*.p_hi' \\) | sed s/^.// >> %{tar_dir}/%{name}-files.nonprof"
        put "sed 's,^/,%exclude /,' %{tar_dir}/%{name}-files.prof >> %{tar_dir}/%{name}-files.nonprof"
    putNewline
    put "cd ${RPM_BUILD_ROOT}/%{_datadir}/doc/%{hsc_name}-%{lc_name}-%{version}"
    put $ "rm -rf doc " ++ concat (intersperse " " docs)
    putNewline
    putNewline

    put "%clean"
    put "rm -rf ${RPM_BUILD_ROOT}"
    putNewline
    putNewline

    withLib pkgDesc () $ \_ -> do
        {- If we're upgrading to a library with the same Cabal
           name+version as the currently installed library (i.e. we've
           just bumped the release number), we need to unregister the
           old library first, so that the register script in %post may
           succeed.

           Note that this command runs *before* the new package's
           files are installed, and thus will execute the *previous*
           version's unregister script, if the script exists in the
           same location as the about-to-be-installed library's
           script. -}

        put $ "%pre " ++ subPackage
        put "[ \"$1\" = 2 ] && %{pkg_libdir}/unregister.sh >&/dev/null || :"
        putNewline
        putNewline

        put $ "%post " ++ subPackage
        put "%{pkg_libdir}/register.sh >&/dev/null"
        putNewline
        putNewline

        {- We must unregister an old version during an upgrade as
           well as during a normal removal, otherwise the Haskell
           runtime's package system will be left with a phantom record
           for a package it can no longer use. -}

        put $ "%preun " ++ subPackage
        put "%{pkg_libdir}/unregister.sh >&/dev/null"
        putNewline
        putNewline

        {- If we're upgrading, the %preun step may have unregistered
           the *new* version of the library (if it had an identical
           Cabal name+version, even though the RPM release differs);
           therefore, we must attempt to re-register it. -}

        put $ "%postun " ++ subPackage
        put "[ \"$1\" = 1 ] && %{pkg_libdir}/register.sh >& /dev/null || :"
        putNewline
        putNewline

        put $ "%files " ++ subPackage ++ " -f %{name}-files.nonprof"
        when doHaddock $
            put "%doc dist/doc/html"
        when ((not . null) docs) $
            put $ "%doc " ++ concat (intersperse " " docs)
        putNewline
        putNewline

        when (rpmLibProf flags) $ do
            put "%files -n %{hsc_name}-%{lc_name}-prof -f %{name}-files.prof"
            put $ "%doc " ++ licenseFile pkgDesc
            putNewline
            putNewline
    
    when isExec $ do
      put "%files"
      put "%defattr (-,root,root,-)"
    withExe pkgDesc $ \exe -> put $ "%{_bindir}/" ++ exeName exe
    when (((not . null . dataFiles) pkgDesc) && isExec) $
        put "%{_datadir}/%{lc_name}-%{version}"

    -- Add the license file to the main package only if it wouldn't
    -- otherwise be empty.
    when ((not . null . licenseFile) pkgDesc &&
          isExecutable pkgDesc ||
           (not . null . dataFiles) pkgDesc) $
        put $ "%doc " ++ licenseFile pkgDesc
    putNewline
    putNewline

    put "%changelog"
    put ("* " ++ date ++ " cabal-rpm <cabal-devel@haskell.org> - " ++
         version ++ "-" ++ release)
    put "- spec file autogenerated by cabal-rpm"
    hClose h
    return (specPath, filter (`notElem` (extraSrcFiles pkgDesc)) docs)

findDocs :: PackageDescription -> IO [FilePath]

findDocs pkgDesc = do
    contents <- getDirectoryContents "."
    let docs = filter likely contents
    return $ if (null . licenseFile) pkgDesc
             then docs
             else let lf = licenseFile pkgDesc
                  in lf : filter (/= lf) docs
  where names = ["author", "copying", "doc", "example", "licence", "license",
                 "readme", "todo"]
        likely name = let lowerName = map toLower name
                      in any (`isPrefixOf` lowerName) names

-- | Take a Haskell package name, and turn it into a "virtual package"
-- that encodes the compiler name and version used.

virtualPackage :: Compiler -> String -> String
virtualPackage compiler name = name ++ '-' : compilerNameVersion compiler

compilerNameVersion :: Compiler -> String
compilerNameVersion (Compiler flavour (PackageIdentifier _ version) _) =
    name ++ squishedVersion
  where name = case flavour of
               GHC -> "ghc"
               HBC -> "hbc"
               Helium -> "helium"
               Hugs -> "hugs"
               JHC -> "jhc"
               NHC -> "nhc"
               OtherCompiler c -> c
        squishedVersion = (concat . map show . versionBranch) version

-- | Convert from license to RPM-friendly description.  The strings are
-- taken from TagsCheck.py in the rpmlint distribution.

showLicense :: License -> String
showLicense GPL = "GPL"
showLicense LGPL = "LGPL"
showLicense BSD3 = "BSD"
showLicense BSD4 = "BSD-like"
showLicense PublicDomain = "Public Domain"
showLicense AllRightsReserved = "Proprietary"
showLicense OtherLicense = "Non-distributable"

-- | Generate a string expressing runtime dependencies, but only
-- on package/version pairs not already "built into" a compiler
-- distribution.

showRuntimeReq :: Verbosity -> Compiler -> PackageDescription -> IO String

showRuntimeReq verbose c pkgDesc = do
    let externalDeps = filter (not . isBundled c)
                       (buildDepends pkgDesc)
    clauses <- mapM (showRpmReq verbose (virtualPackage c)) externalDeps
    return $ (commaSep . concat) clauses

-- | Generate a string expressing package build dependencies, but only
-- on package/version pairs not already "built into" a compiler
-- distribution.

showBuildReq :: Verbosity -> Bool -> Compiler -> PackageDescription
             -> IO String

showBuildReq verbose haddock c pkgDesc = do
    cPkg <- case compilerFlavor c of
              GHC -> return "ghc"
              Hugs -> return "hugs98"
              _ -> die $ "cannot deal with compiler " ++ show c
    let cVersion = pkgVersion $ compilerId c
        myDeps = [Dependency cPkg (ThisVersion cVersion)] ++
                 if haddock then [Dependency "haddock" AnyVersion] else []
        externalDeps = filter (not . isBundled c)
                       (buildDepends pkgDesc)
    exReqs <- mapM (showRpmReq verbose (virtualPackage c)) externalDeps
    myReqs <- mapM (showRpmReq verbose id) myDeps
    return $ (commaSep . concat) (myReqs ++ exReqs)

-- | Represent a dependency in a form suitable for an RPM spec file.

showRpmReq :: Verbosity -> (String -> String) -> Dependency -> IO [String]

showRpmReq _ f (Dependency pkg AnyVersion) =
    return [f pkg]
showRpmReq _ f (Dependency pkg (ThisVersion v)) =
    return [f pkg ++ " = " ++ showVersion v]
showRpmReq _ f (Dependency pkg (EarlierVersion v)) =
    return [f pkg ++ " < " ++ showVersion v]
showRpmReq _ f (Dependency pkg (LaterVersion v)) =
    return [f pkg ++ " > " ++ showVersion v]
showRpmReq _ f (Dependency pkg (UnionVersionRanges
                         (ThisVersion v1)
                         (LaterVersion v2)))
    | v1 == v2 = return [f pkg ++ " >= " ++ showVersion v1]
showRpmReq _ f (Dependency pkg (UnionVersionRanges
                         (ThisVersion v1)
                         (EarlierVersion v2)))
    | v1 == v2 = return [f pkg ++ " <= " ++ showVersion v1]
showRpmReq verbose f (Dependency pkg (UnionVersionRanges _ _)) = do
    warn verbose ("Cannot accurately represent " ++
                  "dependency on package " ++ f pkg)
    warn verbose "  (uses version union, which RPM can't handle)"
    return [f pkg]
showRpmReq verbose f (Dependency pkg (IntersectVersionRanges r1 r2)) = do
    d1 <- showRpmReq verbose f (Dependency pkg r1)
    d2 <- showRpmReq verbose f (Dependency pkg r2)
    return (d1 ++ d2)

-- | Find the paths to all "extra" libraries specified in the package
-- config.  Prefer shared libraries, since that's what gcc prefers.
findLibPaths :: BuildInfo -> IO [FilePath]

findLibPaths buildInfo = mapM findLib (extraLibs buildInfo)
  where findLib :: String -> IO FilePath
        findLib lib = do
            so <- findLibPath ("lib" ++ lib ++ ".so")
            if isJust so
              then return (fromJust so)
              else findLibPath ("lib" ++ lib ++ ".a") >>=
                   maybe (die $ "could not find library: lib" ++ lib)
                         return
        findLibPath extraLib = do
            loc <- findInExtraLibs (extraLibDirs buildInfo)
            if isJust loc
              then return loc
              else findWithGcc extraLib
          where findInExtraLibs (d:ds) = do
                    let path = d </> extraLib
                    exists <- doesFileExist path
                    if exists
                      then return (Just path)
                      else findInExtraLibs ds
                findInExtraLibs [] = return Nothing

-- | Return the full path to a file (usually an object file) that gcc
-- knows about.

findWithGcc :: FilePath -> IO (Maybe FilePath)

findWithGcc lib = do
    (i,o,e,p) <- runInteractiveCommand $ "gcc -print-file-name=" ++ lib
    loc <- hGetLine o
    mapM_ hClose [i,o,e]
    waitForProcess p
    return $ if loc == lib then Nothing else Just loc

-- | Return the RPM that owns a particular file or directory.  Die if
-- not owned.

findRpmOwner :: FilePath -> IO String
findRpmOwner path = do
    (i,o,e,p) <- runInteractiveCommand (rpmQuery ++ path)
    pkg <- hGetLine o
    mapM_ hClose [i,o,e]
    ret <- waitForProcess p
    case ret of
      ExitSuccess -> return pkg
      _ -> die $ "not owned by any package: " ++ path
  where rpmQuery = "rpm --queryformat='%{NAME}' -qf "

-- | Find all RPMs on which the build of this package depends.  Die if
-- a dependency is not present, or not owned by an RPM.

findLibDeps :: BuildInfo -> IO [String]

findLibDeps buildInfo = findLibPaths buildInfo >>= mapM findRpmOwner

isExecutable :: PackageDescription -> Bool
isExecutable = not . null . executables
