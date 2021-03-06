-- |
-- Module      :  Setup
-- Copyright   :  Bryan O'Sullivan 2007, 2008
--                Jens Petersen 2012-2013
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Command line option processing for building RPM
-- packages.

-- This software may be used and distributed according to the terms of
-- the GNU General Public License, incorporated herein by reference.

module Setup (
      RpmFlags(..)
    , parseArgs
    ) where

import Control.Monad (unless, when)
import Data.Char     (toLower)
import Data.Version  (showVersion)

import Distribution.PackageDescription (FlagName (..))
import Distribution.ReadE              (readEOrFail)
import Distribution.Verbosity          (Verbosity, flagToVerbosity, normal)

import System.Console.GetOpt (ArgDescr (..), ArgOrder (..), OptDescr (..),
                              getOpt', usageInfo)
import System.Environment    (getProgName)
import System.Exit           (ExitCode (..), exitSuccess, exitWith)
import System.IO             (Handle, hPutStr, hPutStrLn, stderr, stdout)

import Paths_cabal_rpm       (version)

data RpmFlags = RpmFlags
    { rpmConfigurationsFlags :: [(FlagName, Bool)]
    , rpmForce               :: Bool
    , rpmHelp                :: Bool
    , rpmLibrary             :: Bool
    , rpmRelease             :: Maybe String
    , rpmVerbosity           :: Verbosity
    , rpmVersion             :: Bool
    }
    deriving (Eq, Show)

emptyRpmFlags :: RpmFlags
emptyRpmFlags = RpmFlags
    { rpmConfigurationsFlags = []
    , rpmForce = False
    , rpmHelp = False
    , rpmLibrary = False
    , rpmRelease = Nothing
    , rpmVerbosity = normal
    , rpmVersion = False
    }

options :: [OptDescr (RpmFlags -> RpmFlags)]

options =
    [
      Option "h?" ["help"] (NoArg (\x -> x { rpmHelp = True }))
             "Show this help text",
      Option "l" ["library"] (NoArg (\x -> x { rpmLibrary = True }))
             "Force package to be a Library ignoring executables",
      Option "f" ["flags"] (ReqArg (\flags x -> x { rpmConfigurationsFlags = rpmConfigurationsFlags x ++ flagList flags }) "FLAGS")
             "Set given flags in Cabal conditionals",
      Option "" ["force"] (NoArg (\x -> x { rpmForce = True }))
             "Overwrite existing spec file.",
      Option "" ["release"] (ReqArg (\rel x -> x { rpmRelease = Just rel }) "RELEASE")
             "Override the default package release",
      Option "v" ["verbose"] (ReqArg (\verb x -> x { rpmVerbosity = readEOrFail flagToVerbosity verb }) "n")
             "Change build verbosity",
      Option "V" ["version"] (NoArg (\x -> x { rpmVersion = True }))
             "Show version number"
    ]

-- Lifted from Distribution.Simple.Setup, since it's not exported.
flagList :: String -> [(FlagName, Bool)]
flagList = map tagWithValue . words
  where tagWithValue ('-':name) = (FlagName (map toLower name), False)
        tagWithValue name       = (FlagName (map toLower name), True)

printHelp :: Handle -> IO ()

printHelp h = do
    progName <- getProgName
    let info = "Usage: " ++ progName ++ " [OPTION]... [COMMAND] [PKGDIR|PKG|PKG-VERSION|CABALFILE|TARBALL]\n"
            ++ "\n"
            ++ "Commands:\n"
            ++ "  spec\t generate a spec file\n"
            ++ "  srpm\t generate a src rpm file\n"
            ++ "  local\t build rpm package\n"
            ++ "  install\t user install package\n"
--             ++ "  install\t install rpm package\n"
--             ++ "  mock\t mock build package\n"
            ++ "\n"
            ++ "Options:"
    hPutStrLn h (usageInfo info options)

parseArgs :: [String] -> IO (RpmFlags, [String])
parseArgs args = do
     let (os, args', unknown, errs) = getOpt' RequireOrder options args
         opts = foldl (flip ($)) emptyRpmFlags os
     when (rpmHelp opts) $ do
       printHelp stdout
       exitSuccess
     when (rpmVersion opts) $ do
       hPutStrLn stdout $ showVersion version
       exitSuccess
     unless (null errs) $ do
       hPutStrLn stderr "Error:"
       mapM_ (hPutStrLn stderr) errs
       exitWith (ExitFailure 1)
     unless (null unknown) $ do
       hPutStr stderr "Unrecognised options: "
       hPutStrLn stderr $ unwords unknown
       exitWith (ExitFailure 1)
     when ((null args') || (notElem (head args') ["spec", "srpm", "build", "install"])) $ do
       printHelp stderr
       exitWith (ExitFailure 1)
     when (length args' > 2) $ do
       hPutStr stderr "Too many arguments: "
       hPutStrLn stderr $ unwords args'
       exitWith (ExitFailure 1)
     return (opts, args')
