{-# LANGUAGE CPP, ForeignFunctionInterface #-}
{-# OPTIONS_GHC -cpp -fffi #-}
{-# OPTIONS_NHC98 -cpp #-}
{-# OPTIONS_JHC -fcpp -fffi #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Utils
-- Copyright   :  Isaac Jones, Simon Marlow 2003-2004
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Misc. Utilities, especially file-related utilities.
-- Stuff used by multiple modules that doesn't fit elsewhere.

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.Utils (
        die,
        dieWithLocation,
        warn, notice, info, debug,
        chattyTry,
        breaks,
	wrapText,
        rawSystemExit,
        rawSystemStdout,
	rawSystemStdout',
        maybeExit,
        xargs,
        smartCopySources,
        createDirectoryIfMissingVerbose,
        copyFileVerbose,
        copyDirectoryRecursiveVerbose,
        copyFiles,
        moduleToFilePath,
        moduleToFilePath2,
        mkLibName,
        mkProfLibName,
        mkSharedLibName,
        currentDir,
        dotToSep,
	findFile,
        findFileWithExtension,
        findFileWithExtension',
        withTempFile,
        defaultPackageDesc,
        findPackageDesc,
	defaultHookedPackageDesc,
	findHookedPackageDesc,
        exeExtension,
        objExtension,
        dllExtension,
  ) where

import Control.Monad
    ( when, filterM, unless )
import Data.List
    ( nub, unfoldr )

import System.Directory
    ( getDirectoryContents, getCurrentDirectory, doesDirectoryExist
    , doesFileExist, removeFile )
import System.Environment
    ( getProgName )
import System.Cmd
    ( rawSystem )
import System.Exit
    ( exitWith, ExitCode(..) )
import System.FilePath
    ( takeDirectory, takeExtension, (</>), (<.>), pathSeparator )
import System.Directory
    ( copyFile, createDirectoryIfMissing )
import System.IO
    ( hPutStrLn, stderr, hFlush, stdout )
import System.IO.Error
    ( try )
import Control.Exception
    ( bracket )

import Distribution.System
    ( OS(..), os )
import Distribution.Version
    (showVersion)
import Distribution.Package
    (PackageIdentifier(..))

#ifdef __GLASGOW_HASKELL__
import Control.Concurrent (forkIO)
import Control.Exception (evaluate)
import System.Process (runInteractiveProcess, waitForProcess)
import System.IO (hGetContents)
#else
import System.Cmd (system)
import System.Directory (getTemporaryDirectory)
#endif
import System.IO (Handle, hClose)

import Distribution.Compat.TempFile (openTempFile)
import Distribution.Verbosity

-- ------------------------------------------------------------------------------- Utils for setup

dieWithLocation :: FilePath -> (Maybe Int) -> String -> IO a
dieWithLocation fname Nothing msg = die (fname ++ ": " ++ msg)
dieWithLocation fname (Just n) msg = die (fname ++ ":" ++ show n ++ ": " ++ msg)

die :: String -> IO a
die msg = do
  hFlush stdout
  pname <- getProgName
  hPutStrLn stderr (pname ++ ": " ++ msg)
  exitWith (ExitFailure 1)

-- | Non fatal conditions that may be indicative of an error or problem.
--
-- We display these at the 'normal' verbosity level.
--
warn :: Verbosity -> String -> IO ()
warn verbosity msg = 
  when (verbosity >= normal) $ do
    hFlush stdout
    hPutStrLn stderr ("Warning: " ++ msg)

-- | Useful status messages.
--
-- We display these at the 'normal' verbosity level.
--
-- This is for the ordinary helpful status messages that users see. Just
-- enough information to know that things are working but not floods of detail.
--
notice :: Verbosity -> String -> IO ()
notice verbosity msg =
  when (verbosity >= normal) $
    putStrLn msg

-- | More detail on the operation of some action.
-- 
-- We display these messages when the verbosity level is 'verbose'
--
info :: Verbosity -> String -> IO ()
info verbosity msg =
  when (verbosity >= verbose) $
    putStrLn msg

-- | Detailed internal debugging information
--
-- We display these messages when the verbosity level is 'deafening'
--
debug :: Verbosity -> String -> IO ()
debug verbosity msg =
  when (verbosity >= deafening) $
    putStrLn msg

-- | Perform an IO action, catching any IO exceptions and printing an error
--   if one occurs.
chattyTry :: String  -- ^ a description of the action we were attempting
          -> IO ()   -- ^ the action itself
          -> IO ()
chattyTry desc action =
  catch action $ \exception ->
    putStrLn $ "Error while " ++ desc ++ ": " ++ show exception

-- -----------------------------------------------------------------------------
-- Helper functions

breaks :: (a -> Bool) -> [a] -> [[a]]
breaks _ [] = []
breaks f xs = case span f xs of
                  (_, xs') ->
                      case break f xs' of
                          (v, xs'') ->
                              v : breaks f xs''

-- Wraps a list of words text to a list of lines of a particular width.
wrapText :: Int -> [String] -> [String]
wrapText width = map unwords . wrap 0 []
  where wrap :: Int -> [String] -> [String] -> [[String]]
        wrap 0   []   (w:ws)
          | length w + 1 > width
          = wrap (length w) [w] ws
        wrap col line (w:ws)
          | col + length w + 1 > width
          = reverse line : wrap 0 [] (w:ws)
        wrap col line (w:ws)
          = let col' = col + length w + 1
             in wrap col' (w:line) ws
        wrap _ []   [] = []
        wrap _ line [] = [reverse line]

-- -----------------------------------------------------------------------------
-- rawSystem variants
maybeExit :: IO ExitCode -> IO ()
maybeExit cmd = do
  res <- cmd
  unless (res == ExitSuccess) $ exitWith res

printRawCommandAndArgs :: Verbosity -> FilePath -> [String] -> IO ()
printRawCommandAndArgs verbosity path args
 | verbosity >= deafening = print (path, args)
 | verbosity >= verbose   = putStrLn $ unwords (path : args)
 | otherwise              = return ()

-- Exit with the same exitcode if the subcommand fails
rawSystemExit :: Verbosity -> FilePath -> [String] -> IO ()
rawSystemExit verbosity path args = do
  printRawCommandAndArgs verbosity path args
  hFlush stdout
  maybeExit $ rawSystem path args

-- Run a command and return its output
rawSystemStdout :: Verbosity -> FilePath -> [String] -> IO String
rawSystemStdout verbosity path args = do
  (output, exitCode) <- rawSystemStdout' verbosity path args
  unless (exitCode == ExitSuccess) $ exitWith exitCode
  return output

rawSystemStdout' :: Verbosity -> FilePath -> [String] -> IO (String, ExitCode)
rawSystemStdout' verbosity path args = do
  printRawCommandAndArgs verbosity path args

#ifdef __GLASGOW_HASKELL__
  bracket (runInteractiveProcess path args Nothing Nothing)
          (\(inh,outh,errh,_) -> hClose inh >> hClose outh >> hClose errh)
    $ \(_,outh,errh,pid) -> do

      -- fork off a thread to pull on (and discard) the stderr
      -- so if the process writes to stderr we do not block.
      -- NB. do the hGetContents synchronously, otherwise the outer
      -- bracket can exit before this thread has run, and hGetContents
      -- will fail.
      err <- hGetContents errh 
      forkIO $ do evaluate (length err); return ()

      -- wait for all the output
      output <- hGetContents outh
      evaluate (length output)

      -- wait for the program to terminate
      exitcode <- waitForProcess pid

      return (output, exitcode)
#else
  tmpDir <- getTemporaryDirectory
  withTempFile tmpDir ".cmd.stdout" $ \tmpName tmpHandle -> do
    hClose tmpHandle
    let quote name = "'" ++ name ++ "'"
    exitCode <- system $ unwords (map quote (path:args)) ++ " >" ++ quote tmpName
    output <- readFile tmpName
    length output `seq` return (output, exitCode)
#endif

-- | Like the unix xargs program. Useful for when we've got very long command
-- lines that might overflow an OS limit on command line length and so you
-- need to invoke a command multiple times to get all the args in.
--
-- Use it with either of the rawSystem variants above. For example:
-- 
-- > xargs (32*1024) (rawSystemExit verbosity) prog fixedArgs bigArgs
--
xargs :: Int -> ([String] -> IO ())
      -> [String] -> [String] -> IO ()
xargs maxSize rawSystemFun fixedArgs bigArgs =
  let fixedArgSize = sum (map length fixedArgs) + length fixedArgs
      chunkSize = maxSize - fixedArgSize
   in mapM_ (rawSystemFun . (fixedArgs ++)) (chunks chunkSize bigArgs)

  where chunks len = unfoldr $ \s ->
          if null s then Nothing
                    else Just (chunk [] len s)

        chunk acc _   []     = (reverse acc,[])
        chunk acc len (s:ss)
          | len' < len = chunk (s:acc) (len-len'-1) ss
          | otherwise  = (reverse acc, s:ss)
          where len' = length s

-- ------------------------------------------------------------
-- * File Utilities
-- ------------------------------------------------------------

-- |Get the file path for this particular module.  In the IO monad
-- because it looks for the actual file.  Might eventually interface
-- with preprocessor libraries in order to correctly locate more
-- filenames.
-- Returns empty list if no such files exist.

moduleToFilePath :: [FilePath] -- ^search locations
                 -> String   -- ^Module Name
                 -> [String] -- ^possible suffixes
                 -> IO [FilePath]

moduleToFilePath pref s possibleSuffixes
    = filterM doesFileExist $
          concatMap (searchModuleToPossiblePaths s possibleSuffixes) pref
    where searchModuleToPossiblePaths :: String -> [String] -> FilePath -> [FilePath]
          searchModuleToPossiblePaths s' suffs searchP
              = moduleToPossiblePaths searchP s' suffs

-- |Like 'moduleToFilePath', but return the location and the rest of
-- the path as separate results.
moduleToFilePath2
    :: [FilePath] -- ^search locations
    -> String   -- ^Module Name
    -> [String] -- ^possible suffixes
    -> IO [(FilePath, FilePath)] -- ^locations and relative names
moduleToFilePath2 locs mname possibleSuffixes
    = filterM exists $
        [(loc, fname <.> ext) | loc <- locs, ext <- possibleSuffixes]
  where
    fname = dotToSep mname
    exists (loc, relname) = doesFileExist (loc </> relname)

-- |Get the possible file paths based on this module name.
moduleToPossiblePaths :: FilePath -- ^search prefix
                      -> String -- ^module name
                      -> [String] -- ^possible suffixes
                      -> [FilePath]
moduleToPossiblePaths searchPref s possibleSuffixes =
  let fname = searchPref </> (dotToSep s)
  in [fname <.> ext | ext <- possibleSuffixes]

findFile :: [FilePath]    -- ^search locations
         -> FilePath      -- ^File Name
         -> IO FilePath
findFile searchPath fileName =
  findFirstFile id
    [ path </> fileName
    | path <- nub searchPath]
  >>= maybe (die $ fileName ++ " doesn't exist") return

findFileWithExtension :: [String]
                      -> [FilePath]
                      -> FilePath
                      -> IO (Maybe FilePath)
findFileWithExtension extensions searchPath baseName =
  findFirstFile id
    [ path </> baseName <.> ext
    | path <- nub searchPath
    , ext <- nub extensions ]

findFileWithExtension' :: [String]
                       -> [FilePath]
                       -> FilePath
                       -> IO (Maybe (FilePath, FilePath))
findFileWithExtension' extensions searchPath baseName =
  findFirstFile (uncurry (</>))
    [ (path, baseName <.> ext)
    | path <- nub searchPath
    , ext <- nub extensions ]

findFirstFile :: (a -> FilePath) -> [a] -> IO (Maybe a)
findFirstFile file = findFirst
  where findFirst []     = return Nothing
        findFirst (x:xs) = do exists <- doesFileExist (file x)
                              if exists
                                then return (Just x)
                                else findFirst xs

dotToSep :: String -> String
dotToSep = map dts
  where
    dts '.' = pathSeparator
    dts c   = c

-- |Copy the source files into the right directory.  Looks in the
-- build prefix for files that look like the input modules, based on
-- the input search suffixes.  It copies the files into the target
-- directory.

smartCopySources :: Verbosity -- ^verbosity
            -> [FilePath] -- ^build prefix (location of objects)
            -> FilePath -- ^Target directory
            -> [String] -- ^Modules
            -> [String] -- ^search suffixes
            -> Bool     -- ^Exit if no such modules
            -> Bool     -- ^Preserve directory structure
            -> IO ()
smartCopySources verbosity srcDirs targetDir sources searchSuffixes exitIfNone preserveDirs
    = do allLocations <- mapM moduleToFPErr sources
         let copies = [(srcDir,
                        if preserveDirs 
                          then srcDir </> name
                          else name)
                      | Just (srcDir, name) <- allLocations]
	 copyFiles verbosity targetDir copies

    where moduleToFPErr m
              = do p <- findFileWithExtension' searchSuffixes srcDirs (dotToSep m)
                   case p of
                     Nothing | exitIfNone ->
                       die $ "Error: Could not find module: " ++ m
                          ++ " with any suffix: " ++ show searchSuffixes
                     _ -> return p

createDirectoryIfMissingVerbose :: Verbosity -> Bool -> FilePath -> IO ()
createDirectoryIfMissingVerbose verbosity parentsToo dir = do
  let msgParents = if parentsToo then " (and its parents)" else ""
  info verbosity ("Creating " ++ dir ++ msgParents)
  createDirectoryIfMissing parentsToo dir

copyFileVerbose :: Verbosity -> FilePath -> FilePath -> IO ()
copyFileVerbose verbosity src dest = do
  info verbosity ("copy " ++ src ++ " to " ++ dest)
  copyFile src dest

-- | Copies a bunch of files to a target directory, preserving the directory
-- structure in the target location. The target directories are created if they
-- do not exist.
--
-- The files are identified by a pair of base directory and a path relative to
-- that base. It is only the relative part that is preserved in the
-- destination.
--
-- For example:
--
-- > copyFiles normal "dist/src"
-- >    [("", "src/Foo.hs"), ("dist/build/", "src/Bar.hs")]
--
-- This would copy \"src\/Foo.hs\" to \"dist\/src\/src\/Foo.hs\" and
-- copy \"dist\/build\/src\/Bar.hs\" to \"dist\/src\/src\/Bar.hs\".
--
-- This operation is not atomic. Any IO failure during the copy (including any
-- missing source files) leaves the target in an unknown state so it is best to
-- use it with a freshly created directory so that it can be simply deleted if
-- anything goes wrong.
--
copyFiles :: Verbosity -> FilePath -> [(FilePath, FilePath)] -> IO ()
copyFiles verbosity targetDir srcFiles = do

  -- Create parent directories for everything
  let dirs = map (targetDir </>) . nub . map (takeDirectory . snd) $ srcFiles
  mapM_ (createDirectoryIfMissingVerbose verbosity True) dirs

  -- Copy all the files
  sequence_ [ let src  = srcBase   </> srcFile
                  dest = targetDir </> srcFile
               in copyFileVerbose verbosity src dest
            | (srcBase, srcFile) <- srcFiles ]

-- adaptation of removeDirectoryRecursive
copyDirectoryRecursiveVerbose :: Verbosity -> FilePath -> FilePath -> IO ()
copyDirectoryRecursiveVerbose verbosity srcDir destDir = do
  info verbosity ("copy directory '" ++ srcDir ++ "' to '" ++ destDir ++ "'.")
  let aux src dest =
         let cp :: FilePath -> IO ()
             cp f = let srcFile  = src  </> f
                        destFile = dest </> f
                    in  do success <- try (copyFileVerbose verbosity srcFile destFile)
                           case success of
                              Left e  -> do isDir <- doesDirectoryExist srcFile
                                            -- If f is not a directory, re-throw the error
                                            unless isDir $ ioError e
                                            aux srcFile destFile
                              Right _ -> return ()
         in  do createDirectoryIfMissingVerbose verbosity False dest
                getDirectoryContentsWithoutSpecial src >>= mapM_ cp
   in aux srcDir destDir

  where getDirectoryContentsWithoutSpecial =
            fmap (filter (not . flip elem [".", ".."]))
          . getDirectoryContents

-- | Use a temporary filename that doesn't already exist.
--
withTempFile :: FilePath -- ^ Temp dir to create the file in
             -> String   -- ^ File name template. See 'openTempFile'.
             -> (FilePath -> Handle -> IO a) -> IO a
withTempFile tmpDir template action =
  bracket (openTempFile tmpDir template)
          (\(name, handle) -> hClose handle >> removeFile name)
          (uncurry action)

-- | The path name that represents the current directory.
-- In Unix, it's @\".\"@, but this is system-specific.
-- (E.g. AmigaOS uses the empty string @\"\"@ for the current directory.)
currentDir :: FilePath
currentDir = "."

mkLibName :: FilePath -- ^file Prefix
          -> String   -- ^library name.
          -> String
mkLibName pref lib = pref </> ("libHS" ++ lib ++ ".a")

mkProfLibName :: FilePath -- ^file Prefix
              -> String   -- ^library name.
              -> String
mkProfLibName pref lib = mkLibName pref (lib++"_p")

-- Implement proper name mangling for dynamical shared objects
-- libHS<packagename>-<compilerFlavour><compilerVersion>
-- e.g. libHSbase-2.1-ghc6.6.1.so
mkSharedLibName :: FilePath        -- ^file Prefix
              -> String            -- ^library name.
              -> PackageIdentifier -- ^package identifier of the compiler
              -> String
mkSharedLibName pref lib (PackageIdentifier compilerName compilerVersion)
  = pref </> ("libHS" ++ lib ++ "-" ++ compiler) <.> dllExtension
  where compiler = compilerName ++ showVersion compilerVersion

-- ------------------------------------------------------------
-- * Finding the description file
-- ------------------------------------------------------------

buildInfoExt  :: String
buildInfoExt = "buildinfo"

-- |Package description file (/pkgname/@.cabal@)
defaultPackageDesc :: Verbosity -> IO FilePath
defaultPackageDesc verbosity
    = getCurrentDirectory >>= findPackageDesc verbosity

-- |Find a package description file in the given directory.  Looks for
-- @.cabal@ files.
findPackageDesc :: Verbosity   -- ^Verbosity
                -> FilePath    -- ^Where to look
                -> IO FilePath -- ^<pkgname>.cabal
findPackageDesc _verbosity dir
 = do files <- getDirectoryContents dir
      case filter ((==".cabal") . takeExtension) files of
        []          -> noDesc
        [cabalFile] -> return (dir </> cabalFile)
        multiple    -> multiDesc multiple

  where
    noDesc :: IO a
    noDesc = die $ "No cabal file found.\n"
                ++ "Please create a package description file <pkgname>.cabal"

    multiDesc :: [String] -> IO a
    multiDesc l = die $ "Multiple cabal files found.\n"
                    ++ "Please use only one of: "
                    ++ show l

-- |Optional auxiliary package information file (/pkgname/@.buildinfo@)
defaultHookedPackageDesc :: IO (Maybe FilePath)
defaultHookedPackageDesc = getCurrentDirectory >>= findHookedPackageDesc

-- |Find auxiliary package information in the given directory.
-- Looks for @.buildinfo@ files.
findHookedPackageDesc
    :: FilePath			-- ^Directory to search
    -> IO (Maybe FilePath)	-- ^/dir/@\/@/pkgname/@.buildinfo@, if present
findHookedPackageDesc dir = do
    ns <- getDirectoryContents dir
    case [dir </>  n |
		n <- ns, takeExtension n == '.':buildInfoExt] of
	[] -> return Nothing
	[f] -> return (Just f)
	_ -> die ("Multiple files with extension " ++ buildInfoExt)

-- ------------------------------------------------------------
-- * Platform file extensions
-- ------------------------------------------------------------ 

-- ToDo: This should be determined via autoconf (AC_EXEEXT)
-- | Extension for executable files
-- (typically @\"\"@ on Unix and @\"exe\"@ on Windows or OS\/2)
exeExtension :: String
exeExtension = case os of
                   Windows _ -> "exe"
                   _         -> ""

-- ToDo: This should be determined via autoconf (AC_OBJEXT)
-- | Extension for object files. For GHC and NHC the extension is @\"o\"@.
-- Hugs uses either @\"o\"@ or @\"obj\"@ depending on the used C compiler.
objExtension :: String
objExtension = "o"

-- | Extension for dynamically linked (or shared) libraries
-- (typically @\"so\"@ on Unix and @\"dll\"@ on Windows)
dllExtension :: String
dllExtension = case os of
                   Windows _ -> "dll"
                   OSX       -> "dylib"
                   _         -> "so"
