import Control.Applicative ((<$>))
import Control.Monad (forM, mplus, when, unless, forM_, foldM)
import Data.List (isSuffixOf, isPrefixOf, intercalate)
import qualified Data.Map as Map
import Data.Maybe (listToMaybe, catMaybes, isNothing)
import Data.Either (lefts, rights)
import Data.Monoid
import qualified Data.Set as Set
import qualified Distribution.InstalledPackageInfo as I
import Distribution.Package
import Distribution.Simple.Compiler
import Distribution.Simple.GHC
import Distribution.Simple.PackageIndex
import Distribution.Simple.Program
import Distribution.Text
import Distribution.Verbosity
import System.FilePath
import System.Directory
import System.Environment
import System.Exit
import System.IO

_VERBOSITY :: Verbosity
_VERBOSITY = normal

printUsage :: IO ()
printUsage = do
  prog <- getProgName
  hPutStrLn stderr $ "Usage: " ++ prog ++ " SANDBOX_PATH or " ++ prog ++ " SANDBOX_PATH PKGDIR_NAME"
  hPutStrLn stderr "Optional package stack: --package-db=global --package-db=user --package-db=/path/"

getReadPackageDB = do
  progConfig <- configureAllKnownPrograms _VERBOSITY $ addKnownProgram ghcProgram defaultProgramConfiguration
  return $ \pkgdb -> getPackageDBContents _VERBOSITY pkgdb progConfig

packageIdFromInstalledPackageId (InstalledPackageId str) = case simpleParse $ take (length str - 33) str of
  Nothing -> Left $ "Failed to parse installed package id " ++ str
  Just pid -> return pid

fixPackageIndex globalPkgIndices sandboxRPT brokenPackageIndex
  = fromPackageIdsPackageInfoPairs . unzip <$> mapM fixInstalledPackage (allPackages brokenPackageIndex)
  where
    fromPackageIdsPackageInfoPairs = \(brokenPkgIds, infos) -> (concat brokenPkgIds, fromList infos)

    fixInstalledPackage info
      = do
      -- 1. Fix dependencies
      dependencies <- forM (I.depends info) $ \ipkgid -> do
        pkgid <- packageIdFromInstalledPackageId ipkgid
        case lookupInstalledPackageId brokenPackageIndex ipkgid `mplus`
             (listToMaybe $ concatMap ((flip lookupSourcePackageId) pkgid) globalPkgIndices)
          of
          Just fInfo -> return . Right $ I.installedPackageId fInfo
          Nothing -> return . Left $ pkgid

      let fixedDependencies = rights dependencies
          brokenDependencies = lefts dependencies

      -- 2. Fix the global paths
      let 
        findOneOrFail path = case findPartialPathMatches path sandboxRPT of
          [] -> Left $ "Could not find sandbox path of " ++ path
          [a] -> return a
          ps -> Left $ "Multiple possible sandbox paths of " ++ path ++ ": " ++ show ps
        findFirstOrRoot path = case findPartialPathMatches path sandboxRPT of
          [] -> "/"
          (a : _) -> a
      fixedImportDirs <- mapM findOneOrFail $ I.importDirs info
      fixedLibDirs <- mapM findOneOrFail $ I.libraryDirs info
      fixedIncludeDirs <- mapM findOneOrFail $ I.includeDirs info
      let fixedFrameworkDirs = findFirstOrRoot <$> I.frameworkDirs info
          fixedHaddockIfaces = findFirstOrRoot <$> I.haddockInterfaces info
          fixedHaddockHTMLs =  findFirstOrRoot <$> I.haddockHTMLs info
      return
        (brokenDependencies,
         info
           { I.depends = fixedDependencies
           , I.importDirs = fixedImportDirs
           , I.libraryDirs = fixedLibDirs
           , I.includeDirs = fixedIncludeDirs
           , I.frameworkDirs = fixedFrameworkDirs
           , I.haddockInterfaces = fixedHaddockIfaces
           , I.haddockHTMLs = fixedHaddockHTMLs
           })

findDBs :: FilePath -> Maybe String -> IO [FilePath]
findDBs sandboxPath pkgDir =
  case pkgDir of
   Nothing -> map (\p -> sandboxPath <> "/" <> p) . filter (isSuffixOf ".conf.d") <$> getDirectoryContents sandboxPath
   Just pkgDir' -> return [sandboxPath <> "/" <> pkgDir']

data SandFixArgs
  = SandFixArgs
    { isVerbose :: Bool
    , packageDbStack :: PackageDBStack
    , sandboxPathMaybe :: Maybe FilePath
    , pkgDirMaybe :: Maybe FilePath
    }

parseSandFixArgs :: [String] -> Maybe SandFixArgs
parseSandFixArgs =
  foldM parseArg'
    SandFixArgs
      { isVerbose = False
      , packageDbStack = []
      , sandboxPathMaybe = Nothing
      , pkgDirMaybe = Nothing
      }
  where
    packageDbPrefix = "--package-db="
    parseArg' sandFixArgs arg
      | arg `elem` ["-v", "--verbose"] =
          Just sandFixArgs
            { isVerbose = True
            }
      | packageDbPrefix `isPrefixOf` arg =
          Just sandFixArgs
            { packageDbStack = packageDbStack sandFixArgs ++ [parseDb $ drop (length packageDbPrefix) arg]
            }
      | isNothing (sandboxPathMaybe sandFixArgs) =
          Just sandFixArgs
            { sandboxPathMaybe = Just arg
            }
      | isNothing (pkgDirMaybe sandFixArgs) =
          Just sandFixArgs
            { pkgDirMaybe = Just arg
            }
      | otherwise = Nothing
    parseDb "global" = GlobalPackageDB
    parseDb "user" = UserPackageDB
    parseDb p = SpecificPackageDB p

pkgDbStackWithDefault :: PackageDBStack -> PackageDBStack
pkgDbStackWithDefault [] = [GlobalPackageDB]
pkgDbStackWithDefault pkgs = pkgs

data LogLevel = Normal | Verbose | Error

logMsg :: Bool -> LogLevel -> String -> IO ()
logMsg v level msg =
  case (v, level) of
   (_, Normal) -> putStr msg
   (True, Verbose) -> putStr msg
   (_, Error) -> hPutStr stderr msg
   _ -> return ()

justOrExit :: Maybe a -> IO a
justOrExit Nothing = printUsage >> exitFailure
justOrExit (Just a) = return a

main :: IO ()
main = do
  sandFixArgs <- justOrExit . parseSandFixArgs =<< getArgs
  sandboxPath <- justOrExit $ sandboxPathMaybe sandFixArgs
  let verboseEnabled = isVerbose sandFixArgs
      logNormal = logMsg verboseEnabled Normal
      logVerbose = logMsg verboseEnabled Verbose
      logError = logMsg verboseEnabled Error

  brokenDBPaths <- findDBs sandboxPath (pkgDirMaybe sandFixArgs)
  when (null brokenDBPaths) $ do
    logError $ "Unable to find sandbox package database in " ++ sandboxPath ++ "\n"
    exitFailure

  -- print comp
  readPkgDB <- getReadPackageDB
  logVerbose "Reading sandbox Package DB... "
  brokenPackageDBs <- mapM (readPkgDB . SpecificPackageDB) brokenDBPaths
  logVerbose "done\n"
  logVerbose "Reading global Package DB... "
  globalPackageDBs <- mapM readPkgDB (pkgDbStackWithDefault $ packageDbStack sandFixArgs)
  logVerbose "done\n"
  logVerbose "Constructing path tree of sandbox... "
  sandboxRPT <- fromDirRecursively sandboxPath
  logVerbose "done\n"
  logNormal "Fixing sandbox package DB... "
  case mapM (fixPackageIndex globalPackageDBs sandboxRPT) brokenPackageDBs of
    Left err -> logError err >> exitFailure
    Right brokenPkgIdsFixedPackageDBPairs -> do
      let (brokenPkgIdss, fixedPackageDBs) = unzip brokenPkgIdsFixedPackageDBPairs
          brokenPkgIds = Set.toList . Set.fromList $ concat brokenPkgIdss
      unless (null brokenPkgIds) $ do
        let errorMsg =
              "Could not find package(s) " ++ intercalate ", " (display <$> brokenPkgIds) ++ " in either the sandbox or global DB. As a last resort try cabal installing them explicitly(these specific versions) into the global DB with --global"
        logError errorMsg >> exitFailure
      logNormal "done\n"
      logVerbose "Overwriting broken package DB(s)... "
      forM_ (zip brokenDBPaths fixedPackageDBs) $ \(path, db) -> forM_ (allPackages db) $ \info -> do
        let filename = path <> "/" <> display (I.installedPackageId info) <> ".conf"
        writeFile filename $ I.showInstalledPackageInfo info
      logVerbose "done\n"
      logVerbose "Please run 'cabal sandbox hc-pkg recache' in the sandbox to update the package cache\n"

newtype Pt
  = Pt
    { ptChildren :: Map.Map String Pt
    }
  deriving (Show)
newtype TopPt
  = TopPt (Map.Map String [(FilePath, Pt)])
  deriving (Show)

findPartialPathMatches :: FilePath -> TopPt -> [FilePath]
findPartialPathMatches path (TopPt m) = go (splitDirectories path)
  where
    go [] = []
    go (a : as)
      | Just pts <- Map.lookup a m
        = let
            match (p, pt)
              | doesMatch as pt = Just $ joinPath (p : a : as)
              | otherwise = Nothing
          in case catMaybes (match <$> pts) of
            [] -> go as
            r -> r
      | otherwise = go as

doesMatch :: [FilePath] -> Pt -> Bool
doesMatch [] _ = True
doesMatch (a : as) pt
  | Just ch <- Map.lookup a (ptChildren pt) = doesMatch as ch
  | otherwise = False

fromDirRecursively :: FilePath -> IO TopPt
fromDirRecursively p = topPtFromPt <$> fromDirRecursively' p
  where
    fromDirRecursively' somePath = fromDirRecursively'' =<< canonicalizePath somePath
    fromDirRecursively'' path = do
      let isSub "." = False
          isSub ".." = False
          isSub _ = True
      allSubs <- filter isSub <$> getDirectoryContents path
      pts <- forM allSubs $ \sub -> do
        let fullSub = path </> sub
        doesDirectoryExist fullSub >>= \b ->
          if b
          then ((,) (sub)) <$> fromDirRecursively'' fullSub
          else return (sub, Pt Map.empty)
      return $ Pt (Map.fromList pts)

    topPtFromPt = TopPt . topPtFromPt' Map.empty p
    topPtFromPt' m p' (Pt children) = foldr descend (foldr ins m (Map.toList children)) (Map.toList children)
      where
        ins (sub, pt) = Map.alter (Just . maybe [(p', pt)] ((p', pt) :)) sub
        descend (sub, pt) m' = topPtFromPt' m' (p' </> sub) pt
