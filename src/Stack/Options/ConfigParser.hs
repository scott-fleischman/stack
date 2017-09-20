{-# LANGUAGE NoImplicitPrelude #-}
module Stack.Options.ConfigParser where

import           Data.Char
import qualified Data.Set                          as Set
import           Options.Applicative
import           Options.Applicative.Builder.Extra
import           Path
import           Stack.Constants
import           Stack.Options.BuildMonoidParser
import           Stack.Options.DockerParser
import           Stack.Options.GhcBuildParser
import           Stack.Options.GhcVariantParser
import           Stack.Options.NixParser
import           Stack.Options.Utils
import           Stack.Prelude
import           Stack.Types.Config
import qualified System.FilePath as FilePath

-- | Command-line arguments parser for configuration.
configOptsParser :: FilePath -> GlobalOptsContext -> Parser ConfigMonoid
configOptsParser currentDir hide0 =
    (\stackRoot workDir buildOpts dockerOpts nixOpts systemGHC installGHC arch ghcVariant ghcBuild jobs includes libs overrideGccPath overrideHpack skipGHCCheck skipMsys localBin modifyCodePage allowDifferentUser dumpLogs -> mempty
        { configMonoidStackRoot = stackRoot
        , configMonoidWorkDir = workDir
        , configMonoidBuildOpts = buildOpts
        , configMonoidDockerOpts = dockerOpts
        , configMonoidNixOpts = nixOpts
        , configMonoidSystemGHC = systemGHC
        , configMonoidInstallGHC = installGHC
        , configMonoidSkipGHCCheck = skipGHCCheck
        , configMonoidArch = arch
        , configMonoidGHCVariant = ghcVariant
        , configMonoidGHCBuild = ghcBuild
        , configMonoidJobs = jobs
        , configMonoidExtraIncludeDirs = includes
        , configMonoidExtraLibDirs = libs
        , configMonoidOverrideGccPath = overrideGccPath
        , configMonoidOverrideHpack = overrideHpack
        , configMonoidSkipMsys = skipMsys
        , configMonoidLocalBinPath = localBin
        , configMonoidModifyCodePage = modifyCodePage
        , configMonoidAllowDifferentUser = allowDifferentUser
        , configMonoidDumpLogs = dumpLogs
        })
    <$> optionalFirst (absDirOption
            ( long stackRootOptionName
            <> metavar (map toUpper stackRootOptionName)
            <> help ("Absolute path to the global stack root directory " ++
                     "(Overrides any STACK_ROOT environment variable)")
            <> hide
            ))
    <*> optionalFirst (option (eitherReader (mapLeft showWorkDirError . parseRelDir))
            ( long "work-dir"
            <> metavar "WORK-DIR"
            <> completer (pathCompleterWith (defaultPathCompleterOpts { pcoAbsolute = False, pcoFileFilter = const False }))
            <> help ("Relative path of work directory " ++
                     "(Overrides any STACK_WORK environment variable, default is '.stack-work')")
            <> hide
            ))
    <*> buildOptsMonoidParser hide0
    <*> dockerOptsParser True
    <*> nixOptsParser True
    <*> firstBoolFlags
            "system-ghc"
            "using the system installed GHC (on the PATH) if available and a matching version. Disabled by default."
            hide
    <*> firstBoolFlags
            "install-ghc"
            "downloading and installing GHC if necessary (can be done manually with stack setup)"
            hide
    <*> optionalFirst (strOption
            ( long "arch"
           <> metavar "ARCH"
           <> help "System architecture, e.g. i386, x86_64"
           <> hide
            ))
    <*> optionalFirst (ghcVariantParser (hide0 /= OuterGlobalOpts))
    <*> optionalFirst (ghcBuildParser (hide0 /= OuterGlobalOpts))
    <*> optionalFirst (option auto
            ( long "jobs"
           <> short 'j'
           <> metavar "JOBS"
           <> help "Number of concurrent jobs to run"
           <> hide
            ))
    <*> fmap Set.fromList (many ((currentDir FilePath.</>) <$> strOption
            ( long "extra-include-dirs"
           <> metavar "DIR"
           <> completer dirCompleter
           <> help "Extra directories to check for C header files"
           <> hide
            )))
    <*> fmap Set.fromList (many ((currentDir FilePath.</>) <$> strOption
            ( long "extra-lib-dirs"
           <> metavar "DIR"
           <> completer dirCompleter
           <> help "Extra directories to check for libraries"
           <> hide
            )))
    <*> optionalFirst (absFileOption
             ( long "with-gcc"
            <> metavar "PATH-TO-GCC"
            <> help "Use gcc found at PATH-TO-GCC"
            <> hide
             ))
    <*> optionalFirst (strOption
             ( long "with-hpack"
            <> metavar "HPACK"
            <> help "Use Hpack executable (overrides bundled Hpack)"
            <> hide
             ))
    <*> firstBoolFlags
            "skip-ghc-check"
            "skipping the GHC version and architecture check"
            hide
    <*> firstBoolFlags
            "skip-msys"
            "skipping the local MSYS installation (Windows only)"
            hide
    <*> optionalFirst (strOption
             ( long "local-bin-path"
            <> metavar "DIR"
            <> completer dirCompleter
            <> help "Install binaries to DIR"
            <> hide
             ))
    <*> firstBoolFlags
            "modify-code-page"
            "setting the codepage to support UTF-8 (Windows only)"
            hide
    <*> firstBoolFlags
            "allow-different-user"
            ("permission for users other than the owner of the stack root " ++
                "directory to use a stack installation (POSIX only)")
            hide
    <*> fmap toDumpLogs
            (firstBoolFlags
             "dump-logs"
             "dump the build output logs for local packages to the console"
             hide)
  where
    hide = hideMods (hide0 /= OuterGlobalOpts)
    toDumpLogs (First (Just True)) = First (Just DumpAllLogs)
    toDumpLogs (First (Just False)) = First (Just DumpNoLogs)
    toDumpLogs (First Nothing) = First Nothing
    showWorkDirError err = show err ++
        "\nNote that --work-dir must be a relative child directory, because work-dirs outside of the package are not supported by Cabal." ++
        "\nSee https://github.com/commercialhaskell/stack/issues/2954"
