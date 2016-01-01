{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
module Stack.Solver
    ( solveExtraDeps
    , solveResolverSpec
    ) where

import           Control.Applicative
import           Control.Exception.Enclosed  (tryIO)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import           Data.Aeson.Extended         (object, (.=), toJSON, logJSONWarnings)
import qualified Data.ByteString             as S
import           Data.Either
import qualified Data.HashMap.Strict         as HashMap
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Monoid
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Text.Encoding          (decodeUtf8, encodeUtf8)
import qualified Data.Yaml                   as Yaml
import           Network.HTTP.Client.Conduit (HasHttpManager)
import           Path
import           Path.IO                     (parseRelAsAbsDir)
import           Prelude
import           Stack.BuildPlan
import           Stack.Setup
import           Stack.Setup.Installed
import           Stack.Types
import           Stack.Types.Internal        ( HasTerminal
                                             , HasReExec
                                             , HasLogLevel)
import           System.Directory            (copyFile,
                                              createDirectoryIfMissing,
                                              getTemporaryDirectory)
import qualified System.FilePath             as FP
import           System.IO.Temp              (withSystemTempDirectory)
import           System.Process.Read

cabalSolver :: (MonadIO m, MonadLogger m, MonadMask m, MonadBaseControl IO m, MonadReader env m, HasConfig env)
            => EnvOverride
            -> [Path Abs Dir] -- ^ cabal files
            -> Map PackageName Version -- ^ constraints
            -> Map PackageName (Map FlagName Bool) -- ^ user-specified flags
            -> [String] -- ^ additional arguments
            -> m (Map PackageName (Version, Map FlagName Bool))
cabalSolver menv cabalfps constraints userFlags cabalArgs = withSystemTempDirectory "cabal-solver" $ \dir -> do
    configLines <- getCabalConfig dir constraints
    let configFile = dir FP.</> "cabal.config"
    liftIO $ S.writeFile configFile $ encodeUtf8 $ T.unlines configLines

    -- Run from a temporary directory to avoid cabal getting confused by any
    -- sandbox files, see:
    -- https://github.com/commercialhaskell/stack/issues/356
    --
    -- In theory we could use --ignore-sandbox, but not all versions of cabal
    -- support it.
    tmpdir <- liftIO getTemporaryDirectory >>= parseRelAsAbsDir

    let args = ("--config-file=" ++ configFile)
             : "install"
             : "--enable-tests"
             : "--enable-benchmarks"
             : "-v"
             : "--dry-run"
             : "--only-dependencies"
             : "--reorder-goals"
             : "--max-backjumps=-1"
             : "--package-db=clear"
             : "--package-db=global"
             : cabalArgs ++
               toConstraintArgs userFlags ++
               fmap toFilePath cabalfps

    $logInfo "Asking cabal to calculate a build plan, please wait"

    bs <- readProcessStdout (Just tmpdir) menv "cabal" args
    let ls = drop 1
           $ dropWhile (not . T.isPrefixOf "In order, ")
           $ T.lines
           $ decodeUtf8 bs
        (errs, pairs) = partitionEithers $ map parseLine ls
    if null errs
        then return (Map.fromList pairs)
        else error $ "Could not parse cabal-install output: " ++ show errs
  where
    parseLine t0 = maybe (Left t0) Right $ do
        -- get rid of (new package) and (latest: ...) bits
        ident':flags' <- Just $ T.words $ T.takeWhile (/= '(') t0
        PackageIdentifier name version <-
            parsePackageIdentifierFromString $ T.unpack ident'
        flags <- mapM parseFlag flags'
        Just (name, (version, Map.fromList flags))
    parseFlag t0 = do
        flag <- parseFlagNameFromString $ T.unpack t1
        return (flag, enabled)
      where
        (t1, enabled) =
            case T.stripPrefix "-" t0 of
                Nothing ->
                    case T.stripPrefix "+" t0 of
                        Nothing -> (t0, True)
                        Just x -> (x, True)
                Just x -> (x, False)
    toConstraintArgs userFlagMap =
        [formatFlagConstraint package flag enabled | (package, fs) <- Map.toList userFlagMap
                                                   , (flag, enabled) <- Map.toList fs]
    formatFlagConstraint package flag enabled =
        let sign = if enabled then '+' else '-'
        in
        "--constraint=" ++ unwords [packageNameString package, sign : flagNameString flag]

getCabalConfig :: (MonadReader env m, HasConfig env, MonadIO m, MonadThrow m)
               => FilePath -- ^ temp dir
               -> Map PackageName Version -- ^ constraints
               -> m [Text]
getCabalConfig dir constraints = do
    indices <- asks $ configPackageIndices . getConfig
    remotes <- mapM goIndex indices
    let cache = T.pack $ "remote-repo-cache: " ++ dir
    return $ cache : remotes ++ map goConstraint (Map.toList constraints)
  where
    goIndex index = do
        src <- configPackageIndex $ indexName index
        let dstdir = dir FP.</> T.unpack (indexNameText $ indexName index)
            dst = dstdir FP.</> "00-index.tar"
        liftIO $ void $ tryIO $ do
            createDirectoryIfMissing True dstdir
            copyFile (toFilePath src) dst
        return $ T.concat
            [ "remote-repo: "
            , indexNameText $ indexName index
            , ":http://0.0.0.0/fake-url"
            ]

    goConstraint (name, version) = T.concat
        [ "constraint: "
        , T.pack $ packageNameString name
        , "=="
        , T.pack $ versionString version
        ]

setupCompiler
    :: ( MonadBaseControl IO m, MonadIO m, MonadLogger m, MonadMask m
       , MonadReader env m, HasConfig env , HasGHCVariant env
       , HasHttpManager env , HasLogLevel env , HasReExec env
       , HasTerminal env)
    => CompilerVersion
    -> m (Maybe ExtraDirs)
setupCompiler compiler = do
    let msg = Just $ T.concat
          [ "Compiler version (" <> compilerVersionText compiler <> ") "
          , "required by your resolver specification cannot be found.\n\n"
          , "Please use '--install-ghc' command line switch to automatically "
          , "install the compiler or '--system-ghc' to use a suitable "
          , "compiler available on your PATH." ]

    config <- asks getConfig
    mpaths <- ensureCompiler SetupOpts
        { soptsInstallIfMissing  = configInstallGHC config
        , soptsUseSystem         = configSystemGHC config
        , soptsWantedCompiler    = compiler
        , soptsCompilerCheck     = configCompilerCheck config

        , soptsStackYaml         = Nothing
        , soptsForceReinstall    = False
        , soptsSanityCheck       = False
        , soptsSkipGhcCheck      = False
        , soptsSkipMsys          = configSkipMsys config
        , soptsUpgradeCabal      = False
        , soptsResolveMissingGHC = msg
        , soptsStackSetupYaml    = defaultStackSetupYaml
        , soptsGHCBindistURL     = Nothing
        }

    return mpaths

setupCabalEnv
    :: ( MonadBaseControl IO m, MonadIO m, MonadLogger m, MonadMask m
       , MonadReader env m, HasConfig env , HasGHCVariant env
       , HasHttpManager env , HasLogLevel env , HasReExec env
       , HasTerminal env)
    => CompilerVersion
    -> m EnvOverride
setupCabalEnv compiler = do
    mpaths <- setupCompiler compiler
    menv0 <- getMinimalEnvOverride
    envMap <- removeHaskellEnvVars
              <$> augmentPathMap (maybe [] edBins mpaths)
                                 (unEnvOverride menv0)
    platform <- asks getPlatform
    menv <- mkEnvOverride platform envMap

    mcabal <- findExecutable menv "cabal"
    case mcabal of
        Nothing -> throwM SolverMissingCabalInstall
        Just _ -> return ()

    mver <- getSystemCompiler menv (whichCompiler compiler)
    case mver of
        Just (version, _) ->
            $logInfo $ "Solver: using compiler " <> compilerVersionText version
        Nothing -> error "Failed to determine compiler version. \
                         \This is most likely a bug."
    return menv

solveResolverSpec
    :: ( MonadBaseControl IO m, MonadIO m, MonadLogger m, MonadMask m
       , MonadReader env m, HasConfig env , HasGHCVariant env
       , HasHttpManager env , HasLogLevel env , HasReExec env
       , HasTerminal env)
    => Path Abs File  -- ^ stack.yaml file location
    -> [Path Abs Dir] -- ^ package dirs containing cabal files
    -> ( Resolver
       , Map PackageName (Map FlagName Bool)
       , Map PackageName Version)
    -> m ( Resolver
         , Map PackageName (Map FlagName Bool)
         , Map PackageName Version)
solveResolverSpec stackYaml cabalDirs (resolver, flags, extraPackages) = do
    compilerVer <- getResolverCompiler resolver
    menv <- setupCabalEnv compilerVer
    extraDeps <- cabalSolver menv cabalDirs extraPackages flags $
                  ["--ghcjs" | (whichCompiler compilerVer) == Ghcjs]
    return
        ( ResolverCompiler compilerVer
        , Map.filter (not . Map.null) $ fmap snd extraDeps
        , fmap fst extraDeps
        )

    where
      getResolverCompiler (ResolverSnapshot snapName) = do
          mbp <- loadMiniBuildPlan snapName
          return (mbpCompilerVersion mbp)

      getResolverCompiler (ResolverCompiler compiler) =
          return compiler

      -- FIXME instead of passing the stackYaml dir we should maintain
      -- the file URL in the custom resolver always relative to stackYaml.
      getResolverCompiler (ResolverCustom _ url) = do
          mbp <- parseCustomMiniBuildPlan stackYaml url
          return (mbpCompilerVersion mbp)

-- | Determine missing extra-deps
solveExtraDeps
    :: ( MonadBaseControl IO m, MonadIO m, MonadLogger m, MonadMask m
       , MonadReader env m, HasConfig env , HasEnvConfig env, HasGHCVariant env
       , HasHttpManager env , HasLogLevel env , HasReExec env
       , HasTerminal env)
    => Bool -- ^ modify stack.yaml?
    -> m ()
solveExtraDeps modStackYaml = do
    econfig <- asks getEnvConfig
    bconfig <- asks getBuildConfig
    let stackYaml = bcStackYaml bconfig
    snapshot <-
        case bcResolver bconfig of
            ResolverSnapshot snapName -> liftM mbpPackages $ loadMiniBuildPlan snapName
            ResolverCompiler _ -> return Map.empty
            ResolverCustom _ url -> liftM mbpPackages $ parseCustomMiniBuildPlan
                (bcStackYaml bconfig)
                url

    let packages = Map.union
            (bcExtraDeps bconfig)
            (mpiVersion <$> snapshot)

    (_, flags, extraDeps) <- solveResolverSpec stackYaml
                              (Map.keys $ envConfigPackages econfig)
                              (bcResolver bconfig,
                               (bcFlags bconfig),
                               packages)

    let newDeps = extraDeps `Map.difference` packages
        newFlags = Map.filter (not . Map.null) $ flags

    $logInfo "This command is not guaranteed to give you a perfect build plan"
    if Map.null newDeps
        then $logInfo "No needed changes found"
        else do
            $logInfo "It's possible that even with the changes generated below, you will still need to do some manual tweaking"
            let o = object
                    $ ("extra-deps" .= map fromTuple (Map.toList newDeps))
                    : (if Map.null newFlags
                        then []
                        else ["flags" .= newFlags])
            mapM_ $logInfo $ T.lines $ decodeUtf8 $ Yaml.encode o

    if modStackYaml
      then do
        let fp = toFilePath $ bcStackYaml bconfig
        obj <- liftIO (Yaml.decodeFileEither fp) >>= either throwM return
        (ProjectAndConfigMonoid project _, warnings) <-
            liftIO (Yaml.decodeFileEither fp) >>= either throwM return
        logJSONWarnings fp warnings
        let obj' =
                HashMap.insert "extra-deps"
                    (toJSON $ map fromTuple $ Map.toList
                            $ Map.union (projectExtraDeps project) newDeps)
              $ HashMap.insert ("flags" :: Text)
                    (toJSON $ Map.union (projectFlags project) newFlags)
                obj
        liftIO $ Yaml.encodeFile fp obj'
        $logInfo $ T.pack $ "Updated " ++ fp
      else do
        $logInfo ""
        $logInfo "To automatically modify your stack.yaml file, rerun with '--modify-stack-yaml'"
