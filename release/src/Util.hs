-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
module Util (
    isReleaseCommit,
    readVersionAt,
    releaseToBintray,
    runFastLoggingT,

    Artifact(..),
    ArtifactLocation(..),
    BazelLocations(..),
    BazelTarget(..),

    artifactFiles,
    mavenArtifactCoords,
    copyToReleaseDir,
    buildTargets,
    getBazelLocations,
    resolvePomData,
    loggedProcess_,
  ) where


import Control.Applicative
import qualified Control.Concurrent.Async.Lifted.Safe as Async
import qualified Control.Exception.Safe as E
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import Data.Aeson
import           Data.Char (isSpace)
import           Data.Conduit ((.|))
import qualified Data.Conduit as C
import qualified Data.Conduit.Process as Proc
import qualified Data.Conduit.Text as CT
import qualified System.Process
import Data.Foldable
import Data.Maybe
import           Data.Text (Text, unpack)
import qualified Data.Text as T
import           Path
import           Path.IO
import           System.Console.ANSI
                   (Color(..), SGR(SetColor, Reset), ConsoleLayer(Foreground),
                    ColorIntensity(..), setSGRCode)
import qualified System.Log.FastLogger as FastLogger
import System.Info.Extra
import qualified Text.XML as XML
import qualified Text.XML.Cursor as XML

import Types

newtype BazelTarget = BazelTarget { getBazelTarget :: Text }
    deriving (FromJSON, Show)

data ReleaseType
    = TarGz
    | Zip
    | Jar JarType
    deriving Show

data JarType
    = Plain
      -- ^ Plain java or scala library, without source jar.
    | Lib
      -- ^ A java library jar, with source and javadoc jars.
    | Deploy
      -- ^ Deploy jar, e.g. a fat jar containing transitive deps.
    | Proto
      -- ^ A java protobuf library (*-speed.jar).
    | Scala
      -- ^ A scala library jar, with source and scaladoc jars. Use when
      -- source or scaladoc is desired, otherwise use 'Plain'.
    deriving (Eq, Show)

instance FromJSON ReleaseType where
    parseJSON = withText "ReleaseType" $ \t ->
        case t of
            "targz" -> pure TarGz
            "zip" -> pure Zip
            "jar" -> pure $ Jar Plain
            "jar-lib" -> pure $ Jar Lib
            "jar-deploy" -> pure $ Jar Deploy
            "jar-proto" -> pure $ Jar Proto
            "jar-scala" -> pure $ Jar Scala
            _ -> fail ("Could not parse release type: " <> unpack t)

data Artifact c = Artifact
    { artTarget :: !BazelTarget
    , artReleaseType :: !ReleaseType
    , artPlatformDependent :: !PlatformDependent
    , artBintrayPackage :: !BintrayPackage
    -- ^ Defaults to sdk-components if not specified
    , artMavenUpload :: MavenUpload
    -- ^ Defaults to False if not specified
    , artJavadocJar :: !(Maybe (Path Rel File))
    , artSourceJar :: !(Maybe (Path Rel File))
    -- artJavadocJar and artSourceJar can be used to specify the path to
    -- custom Bazel targets javadoc and source jars. The corresponding Bazel target
    -- is assumed to be in the same package as artTarget and should have the same
    -- name as the output file. E.g., if artTarget points to //foobar:mycustomx,
    -- artSourceJar can be set to mycustomx-src.jar and we will build the bazel target
    -- //foobar:mycustomx-src.jar.
    , artMetadata :: !c
    } deriving Show

instance FromJSON (Artifact (Maybe ArtifactLocation)) where
    parseJSON = withObject "Artifact" $ \o -> Artifact
        <$> o .: "target"
        <*> o .: "type"
        <*> (fromMaybe (PlatformDependent False) <$> o .:? "platformDependent")
        <*> (fromMaybe PkgSdkComponents <$> o .:? "bintrayPackage")
        <*> (fromMaybe (MavenUpload False) <$> o .:? "mavenUpload")
        <*> o .:? "javadoc-jar"
        <*> o .:? "src-jar"
        <*> o .:? "location"

data ArtifactLocation = ArtifactLocation
    { coordGroupId :: GroupId
    , coordArtifactId :: ArtifactId
    } deriving Show

instance FromJSON ArtifactLocation where
    parseJSON = withObject "ArtifactLocation" $ \o -> do
        groupId <- o .: "groupId"
        artifactId <- o .: "artifactId"
        pure $ ArtifactLocation (T.split (== '.') groupId) artifactId

-- | This maps a target declared in artifacts.yaml to the individual Bazel targets
-- that need to be built for a release.
buildTargets :: Artifact (Maybe ArtifactLocation) -> [BazelTarget]
buildTargets art@Artifact{..} =
    case artReleaseType of
        Jar jarTy ->
            let pomTar = BazelTarget (getBazelTarget artTarget <> "_pom")
                jarTarget | jarTy == Deploy = BazelTarget (getBazelTarget artTarget <> "_deploy.jar")
                          | otherwise = artTarget
                (directory, _) = splitBazelTarget artTarget
            in [jarTarget, pomTar] <>
               map (\t -> BazelTarget ("//" <> directory <> ":" <> t))
               (catMaybes
                    [ sourceJarName art
                    , scalaSourceJarName art
                    , T.pack . toFilePath <$> artSourceJar
                    , javadocJarName art
                    , scaladocJarName art
                    , T.pack . toFilePath <$> artJavadocJar
                    ])
        Zip -> [artTarget]
        TarGz -> [artTarget]

data PomData = PomData
  { pomGroupId :: GroupId
  , pomArtifactId :: ArtifactId
  , pomVersion :: TextVersion
  } deriving (Eq, Show)

readPomData :: FilePath -> IO PomData
readPomData f = do
    doc <- XML.readFile XML.def f
    let c = XML.fromDocument doc
    let elName name = XML.Name name (Just "http://maven.apache.org/POM/4.0.0") Nothing
    [artifactId] <- pure $ c XML.$/ (XML.element (elName "artifactId") XML.&/ XML.content)
    [groupId] <- pure $ c XML.$/ (XML.element (elName "groupId") XML.&/ XML.content)
    [version] <- pure $ c XML.$/ (XML.element (elName "version") XML.&/ XML.content)
    pure $ PomData
        { pomGroupId = T.split (== '.') groupId
        , pomArtifactId = artifactId
        , pomVersion = version
        }

resolvePomData :: BazelLocations -> Version -> Version -> Artifact (Maybe ArtifactLocation) -> IO (Artifact PomData)
resolvePomData BazelLocations{..} sdkVersion sdkComponentVersion art =
    case artMetadata art of
        Just ArtifactLocation{..} -> pure art
            { artMetadata = PomData
                { pomGroupId = coordGroupId
                , pomArtifactId = coordArtifactId
                , pomVersion = renderVersion version
                }
            }
        Nothing -> do
            let (dir, name) = splitBazelTarget $ artTarget art
            dir <- parseRelDir (unpack dir)
            name <- parseRelFile (unpack name <> "_pom.xml")
            dat <- readPomData $ unpack $ pathToText $ bazelBin </> dir </> name
            pure art { artMetadata = dat }
    where version = case artBintrayPackage art of
              PkgSdk -> sdkVersion
              PkgSdkComponents -> sdkComponentVersion

data BazelLocations = BazelLocations
    { bazelBin :: !(Path Abs Dir)
    } deriving Show

getBazelLocations :: IO BazelLocations
getBazelLocations = do
    bazelBin <- parseAbsDir . T.unpack . T.strip . T.pack =<< System.Process.readProcess "bazel" ["info", "bazel-bin"] ""
    pure BazelLocations{..}

splitBazelTarget :: BazelTarget -> (Text, Text)
splitBazelTarget (BazelTarget t) =
    case T.split (== ':') <$> T.stripPrefix "//" t of
        Just [a, b] -> (a, b)
        _ -> error ("Malformed bazel target: " <> show t)

mainExt :: ReleaseType -> Text
mainExt Zip = "zip"
mainExt TarGz = "tar.gz"
mainExt Jar{} = "jar"

mainFileName :: ReleaseType -> Text -> Text
mainFileName releaseType name =
    case releaseType of
        TarGz -> name <> ".tar.gz"
        Zip -> name <> ".zip"
        Jar jarTy -> case jarTy of
            Plain -> name <> ".jar"
            Lib -> "lib" <> name <> ".jar"
            Deploy -> name <> "_deploy.jar"
            Proto -> "lib" <> T.replace "_java" "" name <> "-speed.jar"
            Scala -> name <> ".jar"

sourceJarName :: Artifact a -> Maybe Text
sourceJarName Artifact{..}
  | Jar Lib <- artReleaseType = Just $ "lib" <> snd (splitBazelTarget artTarget) <> "-src.jar"
  | otherwise = Nothing

scalaSourceJarName :: Artifact a -> Maybe Text
scalaSourceJarName Artifact{..}
  | Jar Scala <- artReleaseType = Just $ snd (splitBazelTarget artTarget) <> "_src.jar"
  | otherwise = Nothing

customSourceJarName :: Artifact a -> Maybe Text
customSourceJarName Artifact{..} = T.pack . toFilePath <$> artSourceJar

scaladocJarName :: Artifact a -> Maybe Text
scaladocJarName Artifact{..}
   | Jar Scala <- artReleaseType = Just $ snd (splitBazelTarget artTarget) <> "_scaladoc.jar"
   | otherwise = Nothing

javadocJarName :: Artifact a -> Maybe Text
javadocJarName Artifact{..}
  | Jar Lib <- artReleaseType = Just $ snd (splitBazelTarget artTarget) <> "_javadoc.jar"
  | otherwise = Nothing

customJavadocJarName :: Artifact a -> Maybe Text
customJavadocJarName Artifact{..} = T.pack . toFilePath <$> artJavadocJar

-- | Given an artifact, produce a list of pairs of an input file and the corresponding output file.
artifactFiles :: E.MonadThrow m => AllArtifacts -> Artifact PomData -> m [(Path Rel File, Path Rel File)]
artifactFiles allArtifacts art@Artifact{..} = do
    let PomData{..} = artMetadata
    outDir <- parseRelDir $ unpack $
        T.intercalate "/" pomGroupId #"/"# pomArtifactId #"/"# pomVersion #"/"
    let ostxt =  if getPlatformDependent artPlatformDependent then "-" <> osName else ""
    let (directory, name) = splitBazelTarget artTarget
    directory <- parseRelDir $ unpack directory

    mainArtifactIn <- parseRelFile $ unpack $ mainFileName artReleaseType name
    mainArtifactOut <- parseRelFile (unpack (pomArtifactId #"-"# pomVersion # ostxt # "." # mainExt artReleaseType))

    pomFileIn <- parseRelFile (unpack (name <> "_pom.xml"))
    pomFileOut <- releasePomPath artMetadata

    mbSourceJarIn <-
        traverse
            (parseRelFile . unpack)
            (customSourceJarName art <|> sourceJarName art <|> scalaSourceJarName art)
    sourceJarOut <- releaseSourceJarPath artMetadata

    mbJavadocJarIn <-
        traverse
            (parseRelFile . unpack)
            (customJavadocJarName art <|> javadocJarName art <|> scaladocJarName art)
    javadocJarOut <- releaseDocJarPath artMetadata

    let shouldReleasePlatInd = shouldRelease allArtifacts (PlatformDependent False)

    pure $
        [(directory </> mainArtifactIn, outDir </> mainArtifactOut) | shouldRelease allArtifacts artPlatformDependent] <>
        [(directory </> pomFileIn, outDir </> pomFileOut) | isJar artReleaseType, shouldReleasePlatInd] <>
        [(directory </> sourceJarIn, outDir </> sourceJarOut) | shouldReleasePlatInd, Just sourceJarIn <- pure mbSourceJarIn] <>
        [(directory </> javadocJarIn, outDir </> javadocJarOut) | shouldReleasePlatInd, Just javadocJarIn <- pure mbJavadocJarIn]
        -- ^ Note that the Scaladoc is specified with the "javadoc" classifier.

-- | The file path to the source jar for the given artifact in the release directory.
releaseSourceJarPath :: E.MonadThrow m => PomData -> m (Path Rel File)
releaseSourceJarPath PomData{..} =
    parseRelFile (unpack (pomArtifactId # "-" # pomVersion # "-sources.jar"))

-- | The file path to the javadoc jar for the given artifact in the release directory.
releaseDocJarPath :: E.MonadThrow m => PomData -> m (Path Rel File)
releaseDocJarPath PomData{..} =
    parseRelFile (unpack (pomArtifactId # "-" # pomVersion # "-javadoc.jar"))

-- | The file path to the pom file for the given artifact in the release directory.
releasePomPath :: E.MonadThrow m => PomData -> m (Path Rel File)
releasePomPath PomData{..} =
    parseRelFile (unpack (pomArtifactId # "-" # pomVersion # ".pom"))

-- | Given an artifact, produce a list of pairs of an input file and the Maven coordinates.
-- This corresponds to the files uploaded to Maven Central.
mavenArtifactCoords :: E.MonadThrow m => AllArtifacts -> Artifact PomData -> m [(MavenCoords, Path Rel File)]
mavenArtifactCoords allArtifacts Artifact{..} = do
    let PomData{..} = artMetadata
    let jarClassifier =  if getPlatformDependent artPlatformDependent then Just osName else Nothing
    outDir <- parseRelDir $ unpack $
        T.intercalate "/" pomGroupId #"/"# pomArtifactId #"/"# pomVersion #"/"
    let ostxt =  if getPlatformDependent artPlatformDependent then "-" <> osName else ""

    mainArtifactFile <- parseRelFile (unpack (pomArtifactId #"-"# pomVersion # ostxt # "." # mainExt artReleaseType))
    pomFile <- releasePomPath artMetadata
    sourcesFile <- releaseSourceJarPath artMetadata
    javadocFile <- releaseDocJarPath artMetadata

    let mavenCoords classifier artifactType =
           MavenCoords { groupId = pomGroupId, artifactId = pomArtifactId, version = pomVersion, classifier, artifactType }
    let shouldReleasePlatInd = shouldRelease allArtifacts (PlatformDependent False)

    pure $ [ (mavenCoords jarClassifier $ mainExt artReleaseType, outDir </> mainArtifactFile) | shouldReleasePlatInd] <>
           [ (mavenCoords Nothing "pom",  outDir </> pomFile) | isJar artReleaseType, shouldReleasePlatInd] <>
           [ (mavenCoords (Just "sources") "jar", outDir </> sourcesFile) | isJar artReleaseType, shouldReleasePlatInd] <>
           [ (mavenCoords (Just "javadoc") "jar", outDir </> javadocFile) | isJar artReleaseType, shouldReleasePlatInd]

shouldRelease :: AllArtifacts -> PlatformDependent -> Bool
shouldRelease (AllArtifacts allArtifacts) (PlatformDependent platformDependent) =
    allArtifacts || platformDependent || osName == "linux"

copyToReleaseDir :: (MonadLogger m, MonadIO m) => BazelLocations -> Path Abs Dir -> Path Rel File -> Path Rel File -> m ()
copyToReleaseDir BazelLocations{..} releaseDir inp out = do
    let absIn = bazelBin </> inp
    let absOut = releaseDir </> out
    $logInfo ("Copying " <> pathToText absIn <> " to " <> pathToText absOut)
    createDirIfMissing True (parent absOut)
    copyFile absIn absOut

-- | the function below takes a text representation since we can can pass
-- various stuff when releasing versions locally
-- --------------------------------------------------------------------

-- release files data for artifactory
type ReleaseDir = Path Abs Dir

isJar :: ReleaseType -> Bool
isJar t =
    case t of
        Jar{} -> True
        _ -> False

bintrayTargetLocation :: BintrayPackage -> TextVersion -> Text
bintrayTargetLocation pkg version =
    let pkgName = case pkg of
          PkgSdkComponents -> "sdk-components"
          PkgSdk -> "sdk"
    in "digitalassetsdk/DigitalAssetSDK/" # pkgName # "/" # version

releaseToBintray ::
     MonadCI m
  => PerformUpload
  -> ReleaseDir
  -> [(Artifact PomData, Path Rel File)]
  -> m ()
releaseToBintray upload releaseDir artifacts = do
  for_ artifacts $ \(Artifact{..}, location) -> do
    let sourcePath = pathToText (releaseDir </> location)
    let targetLocation = bintrayTargetLocation artBintrayPackage (pomVersion artMetadata)
    let targetPath = pathToText location
    let msg = "Uploading "# sourcePath #" to target location "# targetLocation #" and target path "# targetPath
    if getPerformUpload upload
        then do
            $logInfo msg
            let args = ["bt", "upload", "--flat=false", "--publish=true", sourcePath, targetLocation, targetPath]
            mbErr <- E.try (loggedProcess_ "jfrog" args)
            case mbErr of
              Left (err :: Proc.ProcessExitedUnsuccessfully) ->
                $logError ("jfrog failed, assuming it's because the artifact was already there: "# tshow err)
              Right () -> return ()
        else
            $logInfo ("(In dry run, skipping) "# msg)

osName ::  Text
osName
  | isWindows = "windows"
  | isMac = "osx"
  | otherwise = "linux"

readVersionAt :: MonadCI m => GitRev -> m Version
readVersionAt rev = do
    txt <- T.unlines <$> loggedProcess "git" ["show", rev #":"# pathToText versionFile] C.sourceToList
    case parseVersion (T.strip txt) of
        Nothing ->
            throwIO (CIException ("Could not decode VERSION file at revision "# rev #": "# tshow txt))
        Just version ->
            pure version

gitChangedFiles :: MonadCI m => GitRev -> m [T.Text]
gitChangedFiles rev =
    loggedProcess "git" ["diff-tree", "--no-commit-id", "--name-only", "-r", rev] C.sourceToList

versionFile :: Path Rel File
versionFile = $(mkRelFile "VERSION")

isReleaseCommit :: MonadCI m => m Bool
isReleaseCommit = do
    files <- gitChangedFiles "HEAD"
    let isRelease = "VERSION" `elem` files
                 && "unreleased.rst" `elem` files
                 && "docs/source/support/release-notes.rst" `elem` files
                 && length files == 3
    if "VERSION" `elem` files && not isRelease
    then throwIO $ CIException "Release commit should only change VERSION, release-notes.rst and unreleased.rst."
    else return isRelease

runFastLoggingT :: LoggingT IO c -> IO c
runFastLoggingT m = do
  E.bracket
    (FastLogger.newStdoutLoggerSet FastLogger.defaultBufSize)
    FastLogger.rmLoggerSet
    (\logSet -> do
      let lf _location _source level msg = do
            let mbColor = case level of
                  LevelDebug -> Nothing
                  LevelInfo -> Just Cyan
                  LevelWarn -> Just Yellow
                  LevelError -> Just Red
                  LevelOther{} -> Just Magenta
            FastLogger.pushLogStr logSet $ case mbColor of
              Nothing -> msg <> "\n"
              Just color -> mconcat
                [ FastLogger.toLogStr (setSGRCode [SetColor Foreground Dull color])
                , msg
                , FastLogger.toLogStr (setSGRCode [Reset])
                , "\n"
                ]
      runLoggingT m lf)

-- | @loggedProcessCwd mbCwd ex args cont@ run exectuable @ex@ with @args@
--   (optionally in working directory @mbCwd`) and processes the output
--   with the continuation @cont@.
--
loggedProcessCwd ::
     MonadCI m
  => Maybe (Path Rel Dir) -- ^ optional working directory to run executable in
  -> Text    -- ^ executable
  -> [Text]  -- ^ arguments to executable
  -> (C.ConduitT () Text m () -> m b) -- ^ continuation to process the output from exec
  -> m b
loggedProcessCwd mbCwd ex args cont = do
  $logDebug ("Running "# ex #" "# T.intercalate " " (map showArg args))
  let p = (Proc.proc (unpack ex) (map unpack args)){Proc.cwd = fmap toFilePath mbCwd}
  Proc.withCheckedProcessCleanup p $
    \Proc.ClosedStream out err ->
      fmap snd $ Async.concurrently
        (C.runConduit (err .| reLog "err" .| C.awaitForever (\_ -> return ())))
        (cont (out .| reLog "out"))
  where
    showArg arg = if T.any isSpace arg
      then tshow arg
      else arg
    reLog stream =
      CT.decode CT.utf8 .| CT.lines .|
      C.awaitForever (\l -> do
        $logDebug (ex #" "# stream #": "# l)
        C.yield l)

loggedProcess ::
     MonadCI m
  => Text   -- ^ program
  -> [Text] -- ^ args
  -> (C.ConduitT () Text m () -> m b) -> m b
loggedProcess = loggedProcessCwd Nothing

loggedProcess_ ::
     MonadCI m
  => Text -> [Text]
  -> m ()
loggedProcess_ ex args =
  loggedProcess ex args $ \out ->
    C.runConduit (out .| C.awaitForever (\_ -> return ()))
