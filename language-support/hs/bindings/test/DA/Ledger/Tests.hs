-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE DuplicateRecordFields #-}

module DA.Ledger.Tests (main) where

import Prelude hiding(Enum)
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class(liftIO)
import DA.Bazel.Runfiles
import DA.Daml.LF.Proto3.Archive (DecodingMode(DecodeAsMain), decodeArchive)
import DA.Daml.LF.Reader(Dalfs(..),readDalfs)
import DA.Ledger.Sandbox (Sandbox,SandboxSpec(..),startSandbox,shutdownSandbox,withSandbox)
import Data.List (elem,isPrefixOf,isInfixOf,(\\))
import Data.Text.Lazy (Text)
import System.Environment.Blank (setEnv)
import System.FilePath
import System.Random (randomIO)
import System.Time.Extra (timeout)
import Test.Tasty as Tasty (TestName,TestTree,testGroup,withResource,defaultMain)
import Test.Tasty.HUnit as Tasty(assertFailure,assertBool,assertEqual,testCase)
import qualified Codec.Archive.Zip as Zip
import qualified DA.Daml.LF.Ast as LF
import qualified Data.ByteString as BS (readFile)
import qualified Data.ByteString.Lazy as BSL (readFile,toStrict)
import qualified Data.ByteString.UTF8 as BS (ByteString,fromString)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text.Lazy as Text(pack,unpack,fromStrict)
import qualified Data.UUID as UUID (toString)

import DA.Ledger.Sandbox as Sandbox
import DA.Ledger as Ledger

main :: IO ()
main = do
    setEnv "TASTY_NUM_THREADS" "1" True
    Tasty.defaultMain $ testGroup "Ledger bindings"
        [ sharedSandboxTests
        ]

type SandboxTest = WithSandbox -> TestTree

sharedSandboxTests :: TestTree
sharedSandboxTests = testGroupWithSandbox (ShareSandbox True) "shared sandbox"
    [ tGetLedgerIdentity
    -- The reset service causes a bunch of issues so for now
    -- we disable these tests.
    -- , tReset
    -- , tMultipleResets
    , tListPackages
    , tGetPackage
    , tGetPackageBad
    , tGetPackageStatusRegistered
    , tGetPackageStatusUnknown
    , tSubmit
    , tSubmitBad
    , tSubmitComplete
    , tCreateWithKey
    , tCreateWithoutKey
    , tStakeholders
    , tPastFuture
    , tGetFlatTransactionByEventId
    , tGetFlatTransactionById
    , tGetTransactions
    , tGetTransactionTrees
    , tGetTransactionByEventId
    , tGetTransactionById
    , tGetActiveContracts
    , tGetLedgerConfiguration
    , tGetTime
    , tSetTime
    , tSubmitAndWait
    , tSubmitAndWaitForTransactionId
    , tSubmitAndWaitForTransaction
    , tSubmitAndWaitForTransactionTree
    , tGetParticipantId
    , tValueConversion

    , tUploadDarFileBad
    , tUploadDarFile
    , tAllocateParty
    ]

run :: WithSandbox -> (PackageId -> TestId -> LedgerService ()) -> IO ()
run withSandbox f = withSandbox $ \sandbox pid testId -> runWithSandbox sandbox (f pid testId)

tGetLedgerIdentity :: SandboxTest
tGetLedgerIdentity withSandbox = testCase "getLedgerIdentity" $ run withSandbox $ \_pid _testId -> do
    lid <- getLedgerIdentity
    liftIO $ assertBool "looksLikeSandBoxLedgerId" (looksLikeSandBoxLedgerId lid)

{-
tReset :: SandboxTest
tReset withSandbox = testCase "reset" $ run withSandbox $ \_ _ -> do
    lid1 <- getLedgerIdentity
    Ledger.reset lid1
    lid2 <- getLedgerIdentity
    liftIO $ assertBool "lid1 /= lid2" (lid1 /= lid2)

tMultipleResets :: SandboxTest
tMultipleResets withSandbox = testCase "multipleResets" $ run withSandbox $ \_pid _testId -> do
    let resetsCount = 20
    lids <- forM [1 .. resetsCount] $ \_ -> do
        lid <- getLedgerIdentity
        Ledger.reset lid
        pure lid
    liftIO $ assertEqual "Ledger IDs are unique" resetsCount (Set.size $ Set.fromList lids)
-}

tListPackages :: SandboxTest
tListPackages withSandbox = testCase "listPackages" $ run withSandbox $ \pid _testId -> do
    lid <- getLedgerIdentity
    pids <- listPackages lid
    liftIO $ do
        assertEqual "#packages" 3 (length pids)
        assertBool "The pid is listed" (pid `elem` pids)

tGetPackage :: SandboxTest
tGetPackage withSandbox = testCase "getPackage" $ run withSandbox $ \pid _testId -> do
    lid <-  getLedgerIdentity
    Just (Package bs) <- getPackage lid pid
    liftIO $ assertBool "contents" ("currency" `isInfixOf` show bs)

tGetPackageBad :: SandboxTest
tGetPackageBad withSandbox = testCase "getPackage/bad" $ run withSandbox $ \_pid _testId -> do
    lid <- getLedgerIdentity
    let pid = PackageId "xxxxxxxxxxxxxxxxxxxxxx"
    Nothing <- getPackage lid pid
    return ()

tGetPackageStatusRegistered :: SandboxTest
tGetPackageStatusRegistered withSandbox = testCase "getPackageStatus/Registered" $ run withSandbox $ \pid _testId -> do
    lid <- getLedgerIdentity
    status <- getPackageStatus lid pid
    liftIO $ assertBool "status" (status == PackageStatusREGISTERED)

tGetPackageStatusUnknown :: SandboxTest
tGetPackageStatusUnknown withSandbox = testCase "getPackageStatus/Unknown" $ run withSandbox $ \_pid _testId -> do
    lid <- getLedgerIdentity
    let pid = PackageId "xxxxxxxxxxxxxxxxxxxxxx"
    status <- getPackageStatus lid pid
    liftIO $ assertBool "status" (status == PackageStatusUNKNOWN)

tSubmit :: SandboxTest
tSubmit withSandbox = testCase "submit" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    let command =  createIOU pid (alice testId) "A-coin" 100
    Right _ <- submitCommand lid (alice testId) command
    return ()

tSubmitBad :: SandboxTest
tSubmitBad withSandbox = testCase "submit/bad" $ run withSandbox $ \_pid testId -> do
    lid <- getLedgerIdentity
    let pid = PackageId "xxxxxxxxxxxxxxxxxxxxxx"
    let command =  createIOU pid (alice testId) "A-coin" 100
    Left err <- submitCommand lid (alice testId) command
    liftIO $ assertTextContains err "Couldn't find package"

tSubmitComplete :: SandboxTest
tSubmitComplete withSandbox = testCase "tSubmitComplete" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    let command = createIOU pid (alice testId) "A-coin" 100
    completions <- completionStream (lid,myAid,[alice testId],Nothing)
    off0 <- completionEnd lid
    Right cidA1 <- submitCommand lid (alice testId) command
    Right (Just Checkpoint{offset=cp1},[Completion{cid=cidB1}]) <- liftIO $ takeStream completions
    off1 <- completionEnd lid
    Right cidA2 <- submitCommand lid (alice testId) command
    Right (Just Checkpoint{offset=cp2},[Completion{cid=cidB2}]) <- liftIO $ takeStream completions
    off2 <- completionEnd lid

    liftIO $ do
        assertEqual "cidB1" cidA1 cidB1
        assertEqual "cidB2" cidA2 cidB2
        assertBool "off0 /= off1" (off0 /= off1)
        assertBool "off1 /= off2" (off1 /= off2)

        assertEqual "cp1" off1 cp1
        assertEqual "cp2" off2 cp2

    completionsX <- completionStream (lid,myAid,[alice testId],Just (LedgerAbsOffset off0))
    completionsY <- completionStream (lid,myAid,[alice testId],Just (LedgerAbsOffset off1))

    Right (Just Checkpoint{offset=cpX},[Completion{cid=cidX}]) <- liftIO $ takeStream completionsX
    Right (Just Checkpoint{offset=cpY},[Completion{cid=cidY}]) <- liftIO $ takeStream completionsY

    liftIO $ do
        assertEqual "cidX" cidA1 cidX
        assertEqual "cidY" cidA2 cidY
        assertEqual "cpX" cp1 cpX
        assertEqual "cpY" cp2 cpY

tCreateWithKey :: SandboxTest
tCreateWithKey withSandbox = testCase "createWithKey" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity False) $ \txs -> do
    let command = createWithKey pid (alice testId) 100
    Right _ <- submitCommand lid (alice testId) command
    liftIO $ do
        Just (Right [Transaction{events=[CreatedEvent{key}]}]) <- timeout 1 (takeStream txs)
        assertEqual "contract has right key" key (Just (VRecord (Record Nothing [ RecordField "" (VParty (alice testId)), RecordField "" (VInt 100) ])))

tCreateWithoutKey :: SandboxTest
tCreateWithoutKey withSandbox = testCase "createWithoutKey" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity False) $ \txs -> do
    let command = createWithoutKey pid (alice testId) 100
    Right _ <- submitCommand lid (alice testId) command
    liftIO $ do
        Just (Right [Transaction{events=[CreatedEvent{key}]}]) <- timeout 1 (takeStream txs)
        assertEqual "contract has no key" key Nothing

tStakeholders :: WithSandbox -> Tasty.TestTree
tStakeholders withSandbox = testCase "stakeholders are exposed correctly" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetTransactionsPF lid (alice testId) $ \PastAndFuture {future=txs} -> do
    let command = createIOU pid (alice testId) "(alice testId)-in-chains" 100
    _ <- submitCommand lid (alice testId) command
    liftIO $ do
        Just (Right [Transaction{events=[CreatedEvent{signatories,observers}]}]) <- timeout 1 (takeStream txs)
        assertEqual "the only signatory" signatories [alice testId]
        assertEqual "observers are empty" observers []

tPastFuture :: SandboxTest
tPastFuture withSandbox = testCase "past/future" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    let command =  createIOU pid (alice testId) "A-coin" 100
    withGetTransactionsPF lid (alice testId) $ \PastAndFuture {past=past1,future=future1} -> do
    Right _ <- submitCommand lid (alice testId) command
    withGetTransactionsPF lid (alice testId) $ \PastAndFuture {past=past2,future=future2} -> do
    Right _ <- submitCommand lid (alice testId) command
    liftIO $ do
        Just (Right x1) <- timeout 1 (takeStream future1)
        Just (Right y1) <- timeout 1 (takeStream future1)
        Just (Right y2) <- timeout 1 (takeStream future2)
        assertEqual "past is initially empty" [] past1
        assertEqual "future becomes the past" [x1] past2
        assertEqual "continuing future matches" y1 y2

tGetFlatTransactionByEventId :: SandboxTest
tGetFlatTransactionByEventId withSandbox = testCase "tGetFlatTransactionByEventId" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Right _ <- submitCommand lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Just (Right [txOnStream]) <- liftIO $ timeout 1 (takeStream txs)
    Transaction{events=[CreatedEvent{eid}]} <- return txOnStream
    Just txByEventId <- getFlatTransactionByEventId lid eid [alice testId]
    liftIO $ assertEqual "tx" txOnStream txByEventId
    Nothing <- getFlatTransactionByEventId lid (EventId "eeeeee") [alice testId]
    return ()

tGetFlatTransactionById :: SandboxTest
tGetFlatTransactionById withSandbox = testCase "tGetFlatTransactionById" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Right _ <- submitCommand lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Just (Right [txOnStream]) <- liftIO $ timeout 1 (takeStream txs)
    Transaction{trid} <- return txOnStream
    Just txById <- getFlatTransactionById lid trid [alice testId]
    liftIO $ assertEqual "tx" txOnStream txById
    Nothing <- getFlatTransactionById lid (TransactionId "xxxxx") [alice testId]
    return ()

tGetTransactions :: SandboxTest
tGetTransactions withSandbox = testCase "tGetTransactions" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Right cidA <- submitCommand lid (alice testId) (createIOU pid (alice testId) "A-coin" 100)
    Just (Right [Transaction{cid=Just cidB}]) <- liftIO $ timeout 1 (takeStream txs)
    liftIO $ do assertEqual "cid" cidA cidB

tGetTransactionTrees :: SandboxTest
tGetTransactionTrees withSandbox = testCase "tGetTransactionTrees" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactionTrees lid (alice testId) (Verbosity True) $ \txs -> do
    Right cidA <- submitCommand lid (alice testId) (createIOU pid (alice testId) "A-coin" 100)
    Just (Right [TransactionTree{cid=Just cidB}]) <- liftIO $ timeout 1 (takeStream txs)
    liftIO $ do assertEqual "cid" cidA cidB

tGetTransactionByEventId :: SandboxTest
tGetTransactionByEventId withSandbox = testCase "tGetTransactionByEventId" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactionTrees lid (alice testId) (Verbosity True) $ \txs -> do
    Right _ <- submitCommand lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Just (Right [txOnStream]) <- liftIO $ timeout 1 (takeStream txs)
    TransactionTree{roots=[eid]} <- return txOnStream
    Just txByEventId <- getTransactionByEventId lid eid [alice testId]
    liftIO $ assertEqual "tx" txOnStream txByEventId
    Nothing <- getTransactionByEventId lid (EventId "eeeeee") [alice testId]
    return ()

tGetTransactionById :: SandboxTest
tGetTransactionById withSandbox = testCase "tGetTransactionById" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactionTrees lid (alice testId) (Verbosity True) $ \txs -> do
    Right _ <- submitCommand lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Just (Right [txOnStream]) <- liftIO $ timeout 1 (takeStream txs)
    TransactionTree{trid} <- return txOnStream
    Just txById <- getTransactionById lid trid [alice testId]
    liftIO $ assertEqual "tx" txOnStream txById
    Nothing <- getTransactionById lid (TransactionId "xxxxx") [alice testId]
    return ()

tGetActiveContracts :: SandboxTest
tGetActiveContracts withSandbox = testCase "tGetActiveContracts" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    -- no active contracts here
    [(off1,_,[])] <- getActiveContracts lid (filterEverythingForParty (alice testId)) (Verbosity True)
    -- so let's create one
    Right _ <- submitCommand lid (alice testId) (createIOU pid (alice testId) "A-coin" 100)
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Just (Right [Transaction{events=[ev]}]) <- liftIO $ timeout 1 (takeStream txs)
    -- and then we get it
    [(off2,_,[active]),(off3,_,[])] <- getActiveContracts lid (filterEverythingForParty (alice testId)) (Verbosity True)
    let diffOffset :: AbsOffset -> AbsOffset -> Int
        (AbsOffset a) `diffOffset` (AbsOffset b) = read (Text.unpack a) - read (Text.unpack b)
    liftIO $ do
        assertEqual "off2" (AbsOffset "" ) off2 -- strange
        assertEqual "off3 - off1" 1 (off3 `diffOffset` off1)
        assertEqual "active" ev active

tGetLedgerConfiguration :: SandboxTest
tGetLedgerConfiguration withSandbox = testCase "tGetLedgerConfiguration" $ run withSandbox $ \_pid _testId -> do
    lid <- getLedgerIdentity
    xs <- getLedgerConfiguration lid
    Just (Right config) <- liftIO $ timeout 1 (takeStream xs)
    let expected = LedgerConfiguration {
            minTtl = Duration {durationSeconds = 2, durationNanos = 0},
            maxTtl = Duration {durationSeconds = 30, durationNanos = 0}}
    liftIO $ assertEqual "config" expected config

tUploadDarFileBad :: SandboxTest
tUploadDarFileBad withSandbox = testCase "tUploadDarFileBad" $ run withSandbox $ \_pid _testId -> do
    lid <- getLedgerIdentity
    let bytes = BS.fromString "not-the-bytes-for-a-darfile"
    Left err <- uploadDarFileGetPid lid bytes
    liftIO $ assertTextContains err "Invalid DAR: package-upload"

tUploadDarFile :: SandboxTest
tUploadDarFile withSandbox = testCase "tUploadDarFileGood" $ run withSandbox $ \_pid testId -> do
    lid <- getLedgerIdentity
    bytes <- liftIO getBytesForUpload
    before <- listKnownPackages
    pid <- uploadDarFileGetPid lid bytes >>= either (liftIO . assertFailure) return
    after <- listKnownPackages
    let getPid PackageDetails{pid} = pid
    liftIO $ assertEqual "new pids"
        (Set.fromList (map getPid after) Set.\\ Set.fromList (map getPid before))
        (Set.singleton pid)
    cidA <- submitCommand lid (alice testId) (createExtra pid (alice testId)) >>= either (liftIO . assertFailure) return
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Just (Right [Transaction{cid=Just cidB}]) <- liftIO $ timeout 10 (takeStream txs)
    liftIO $ do assertEqual "cid" cidA cidB
    where
        createExtra :: PackageId -> Party -> Command
        createExtra pid party = CreateCommand {tid,args}
            where
                tid = TemplateId (Identifier pid mod ent)
                mod = ModuleName "ExtraModule"
                ent = EntityName "ExtraTemplate"
                args = Record Nothing [
                    RecordField "owner" (VParty party),
                    RecordField "message" (VText "Hello extra module")
                    ]

getBytesForUpload :: IO BS.ByteString
getBytesForUpload = do
        let extraDarFilename = "language-support/hs/bindings/for-upload.dar"
        file <- locateRunfiles (mainWorkspace </> extraDarFilename)
        BS.readFile file

-- Would be nice if the underlying service returned the pid on successful upload.
uploadDarFileGetPid :: LedgerId -> BS.ByteString -> LedgerService (Either String PackageId)
uploadDarFileGetPid lid bytes = do
    before <- listPackages lid
    uploadDarFile bytes >>= \case -- call the actual service
        Left m -> return $ Left m
        Right () -> do
            after <- listPackages lid
            [newPid] <- return (after \\ before) -- see what new pid appears
            return $ Right newPid


tGetTime :: SandboxTest
tGetTime withSandbox = testCase "tGetTime" $ run withSandbox $ \_ _testId -> do
    lid <- getLedgerIdentity
    xs <- Ledger.getTime lid
    Just (Right time1) <- liftIO $ timeout 1 (takeStream xs)
    let expect1 = Timestamp {seconds = 0, nanos = 0}
    liftIO $  assertEqual "time1" expect1 time1


tSetTime :: SandboxTest
tSetTime withSandbox = testCase "tSetTime" $ run withSandbox $ \_ _testId -> do
    lid <- getLedgerIdentity
    xs <- Ledger.getTime lid

    let t00 = Timestamp {seconds = 0, nanos = 0}
    let t11 = Timestamp {seconds = 1, nanos = 1}
    let t22 = Timestamp {seconds = 2, nanos = 2}
    let t33 = Timestamp {seconds = 3, nanos = 3}

    Just (Right time) <- liftIO $ timeout 1 (takeStream xs)
    liftIO $ assertEqual "time1" t00 time -- initially the time is 0,0

    Right () <- Ledger.setTime lid t00 t11
    Just (Right time) <- liftIO $ timeout 1 (takeStream xs)
    liftIO $ assertEqual "time2" t11 time -- time is 1,1 as we set it

    _bad <- Ledger.setTime lid t00 t22 -- the wrong current_time was passed, so the time was not set
    -- Left _ <- return _bad -- Bug in the sandbox cause this to fail

    Right () <- Ledger.setTime lid t11 t33
    Just (Right time) <- liftIO $ timeout 1 (takeStream xs)
    liftIO $ assertEqual "time3" t33 time  -- time is 3,3 as we set it

requiresAuthorizerButGot :: Party -> Party -> String -> IO ()
requiresAuthorizerButGot (Party required) (Party given) err =
    assertTextContains err $ "requires authorizers " <> Text.unpack required <> ", but only " <> Text.unpack given <> " were given"

tSubmitAndWait :: SandboxTest
tSubmitAndWait withSandbox =
    testCase "tSubmitAndWait" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity False) $ \txs -> do
    -- bad
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (bob testId) "B-coin" 100
    Left err <- submitAndWait commands
    liftIO $ requiresAuthorizerButGot (bob testId) (alice testId) err
    -- good
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Right () <- submitAndWait commands
    Just (Right [_]) <- liftIO $ timeout 1 $ takeStream txs
    return ()

tSubmitAndWaitForTransactionId :: SandboxTest
tSubmitAndWaitForTransactionId withSandbox =
    testCase "tSubmitAndWaitForTransactionId" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity False) $ \txs -> do
    -- bad
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (bob testId) "B-coin" 100
    Left err <- submitAndWaitForTransactionId commands
    liftIO $ requiresAuthorizerButGot (bob testId) (alice testId) err
    -- good
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Right trid <- submitAndWaitForTransactionId commands
    Just (Right [Transaction{trid=tridExpected}]) <- liftIO $ timeout 1 $ takeStream txs
    liftIO $ assertEqual "trid" tridExpected trid

tSubmitAndWaitForTransaction :: SandboxTest
tSubmitAndWaitForTransaction withSandbox =
    testCase "tSubmitAndWaitForTransaction" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    -- bad
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (bob testId) "B-coin" 100
    Left err <- submitAndWaitForTransaction commands
    liftIO $ requiresAuthorizerButGot (bob testId) (alice testId) err
    -- good
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Right trans <- submitAndWaitForTransaction commands
    Just (Right [transExpected]) <- liftIO $ timeout 1 $ takeStream txs
    liftIO $ assertEqual "trans" transExpected trans

tSubmitAndWaitForTransactionTree :: SandboxTest
tSubmitAndWaitForTransactionTree withSandbox =
    testCase "tSubmitAndWaitForTransactionTree" $ run withSandbox $ \pid testId -> do
    lid <- getLedgerIdentity
    withGetAllTransactionTrees lid (alice testId) (Verbosity True) $ \txs -> do
    -- bad
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (bob testId) "B-coin" 100
    Left err <- submitAndWaitForTransactionTree commands
    liftIO $ requiresAuthorizerButGot (bob testId) (alice testId) err
    -- good
    (_cid,commands) <- liftIO $ makeCommands lid (alice testId) $ createIOU pid (alice testId) "A-coin" 100
    Right tree <- submitAndWaitForTransactionTree commands
    Just (Right [treeExpected]) <- liftIO $ timeout 1 $ takeStream txs
    liftIO $ assertEqual "tree" treeExpected tree


tGetParticipantId :: SandboxTest
tGetParticipantId withSandbox = testCase "tGetParticipantId" $ run withSandbox $ \_pid _testId -> do
    id <- getParticipantId
    liftIO $ assertEqual "participant" (ParticipantId "sandbox-participant") id

tAllocateParty :: SandboxTest
tAllocateParty withSandbox = testCase "tAllocateParty" $ run withSandbox $ \_pid (TestId testId) -> do
    let party = Party (Text.pack $ "me" <> show testId)
    before <- listKnownParties
    let displayName = "Only Me"
    let request = AllocatePartyRequest { partyIdHint = unParty party, displayName }
    deats <- allocateParty request
    let expected = PartyDetails { party, displayName, isLocal = True }
    liftIO $ assertEqual "deats" expected deats
    after <- listKnownParties
    liftIO $ assertEqual "new parties"
        (Set.fromList after Set.\\ Set.fromList before)
        (Set.singleton expected)

bucket :: Value
bucket = VRecord $ Record Nothing
    [ RecordField "record" $ VRecord $ Record Nothing
        [ RecordField "foo" $ VBool False
        , RecordField "bar" $ VText "sheep"
        ]
    , RecordField "variants" $ VList
        [ VVariant $ Variant Nothing (ConstructorId "B") (VBool True)
        , VVariant $ Variant Nothing (ConstructorId "I") (VInt 99)
        ]
    , RecordField "contract"$ VContract (ContractId "xxxxx")
    , RecordField "list"    $ VList []
    , RecordField "int"     $ VInt 42
    , RecordField "decimal" $ VDecimal 123.456
    , RecordField "text"    $ VText "OMG lol"
    , RecordField "time"    $ VTime (MicroSecondsSinceEpoch $ 1000 * 1000 * 60 * 60 * 24 * 365 * 50)
    , RecordField "party"   $ VParty $ Party "good time"
    , RecordField "bool"    $ VBool False
    , RecordField "unit"      VUnit
    , RecordField "date"    $ VDate $ DaysSinceEpoch 123
    , RecordField "opts"    $ VList
        [ VOpt Nothing
        , VOpt $ Just $ VText "something"
        ]
    , RecordField "map"     $ VMap $ Map.fromList [("one",VInt 1),("two",VInt 2),("three",VInt 3)]
    , RecordField "enum"    $ VEnum $ Enum Nothing (ConstructorId "Green")

    ]

tValueConversion :: SandboxTest
tValueConversion withSandbox = testCase "tValueConversion" $ run withSandbox $ \pid testId -> do
    let owner = alice testId
    let mod = ModuleName "Valuepedia"
    let tid = TemplateId (Identifier pid mod $ EntityName "HasBucket")
    let args = Record Nothing [ RecordField "owner" (VParty owner), RecordField "bucket" bucket ]
    let command = CreateCommand {tid,args}
    lid <- getLedgerIdentity
    _::CommandId <- submitCommand lid (alice testId) command >>= either (liftIO . assertFailure) return
    withGetAllTransactions lid (alice testId) (Verbosity True) $ \txs -> do
    Just elem <- liftIO $ timeout 1 (takeStream txs)
    trList <- either (liftIO . assertFailure . show) return elem
    [Transaction{events=[CreatedEvent{createArgs=Record{fields}}]}] <- return trList
    [RecordField{label="owner"},RecordField{label="bucket",fieldValue=bucketReturned}] <- return fields
    liftIO $ assertEqual "bucket" bucket (detag bucketReturned)

-- Strip the rid,vid,eid tags recusively from record, variant and enum values
detag :: Value -> Value
detag = \case
    VRecord r -> VRecord $ detagRecord r
    VVariant v -> VVariant $ detagVariant v
    VEnum e -> VEnum $ detagEnum e
    VList xs -> VList $ fmap detag xs
    VOpt opt -> VOpt $ fmap detag opt
    VMap m -> VMap $ fmap detag m
    v -> v
    where
        detagRecord :: Record -> Record
        detagRecord r = r { rid = Nothing, fields = map detagField $ fields r }

        detagField :: RecordField -> RecordField
        detagField f = f { fieldValue = detag $ fieldValue f }

        detagVariant :: Variant -> Variant
        detagVariant v = v { vid = Nothing, value = detag $ value v }

        detagEnum :: Enum -> Enum
        detagEnum e = e { eid = Nothing }

----------------------------------------------------------------------
-- misc ledger ops/commands

newtype TestId = TestId Int

nextTestId :: TestId -> TestId
nextTestId (TestId i) = TestId (i + 1)

alice,bob :: TestId -> Party
alice (TestId i) = Party $ Text.pack $ "Alice" <> show i
bob (TestId i) = Party $ Text.pack $ "Bob" <> show i

createIOU :: PackageId -> Party -> Text -> Int -> Command
createIOU pid party currency quantity = CreateCommand {tid,args}
    where
        tid = TemplateId (Identifier pid mod ent)
        mod = ModuleName "Iou"
        ent = EntityName "Iou"
        args = Record Nothing [
            RecordField "issuer" (VParty party),
            RecordField "owner" (VParty party),
            RecordField "currency" (VText currency),
            RecordField "amount" (VInt quantity)
            ]

createWithKey :: PackageId -> Party -> Int -> Command
createWithKey pid owner n = CreateCommand {tid,args}
    where
        tid = TemplateId (Identifier pid mod ent)
        mod = ModuleName "ContractKeys"
        ent = EntityName "WithKey"
        args = Record Nothing [
            RecordField "owner" (VParty owner),
            RecordField "n" (VInt n)
            ]

createWithoutKey :: PackageId -> Party -> Int -> Command
createWithoutKey pid owner n = CreateCommand {tid,args}
    where
        tid = TemplateId (Identifier pid mod ent)
        mod = ModuleName "ContractKeys"
        ent = EntityName "WithoutKey"
        args = Record Nothing [
            RecordField "owner" (VParty owner),
            RecordField "n" (VInt n)
            ]

submitCommand :: LedgerId -> Party -> Command -> LedgerService (Either String CommandId)
submitCommand lid party com = do
    (cid,commands) <- liftIO $ makeCommands lid party com
    Ledger.submit commands >>= \case
        Left s -> return $ Left s
        Right () -> return $ Right cid

makeCommands :: LedgerId -> Party -> Command -> IO (CommandId,Commands)
makeCommands lid party com = do
    cid <- liftIO randomCid
    let wid = Nothing
    let leTime = Timestamp 0 0
    let mrTime = Timestamp 5 0
    return $ (cid,) $ Commands {lid,wid,aid=myAid,cid,party,leTime,mrTime,coms=[com]}


myAid :: ApplicationId
myAid = ApplicationId ":my-application:"

randomCid :: IO CommandId
randomCid = do fmap (CommandId . Text.pack . UUID.toString) randomIO

looksLikeSandBoxLedgerId :: LedgerId -> Bool
looksLikeSandBoxLedgerId (LedgerId text) =
    "sandbox-" `isPrefixOf` s && length s == 44 where s = Text.unpack text

----------------------------------------------------------------------
-- runWithSandbox

runWithSandbox :: Sandbox -> LedgerService a -> IO a
runWithSandbox Sandbox{port} ls = runLedgerService ls timeout (configOfPort port)
    where timeout = 30 :: TimeoutSeconds

-- resetSandbox :: Sandbox-> IO ()
-- resetSandbox sandbox = runWithSandbox sandbox $ do
--     lid <- getLedgerIdentity
--     Ledger.reset lid
--     lid2 <- getLedgerIdentity
--     unless (lid /= lid2) $ fail "resetSandbox: reset did not change the ledger-id"

----------------------------------------------------------------------
-- misc expectation combinators

assertTextContains :: String -> String -> IO ()
assertTextContains text frag =
    unless (frag `isInfixOf` text) (assertFailure msg)
    where msg = "expected frag: " ++ frag ++ "\n contained in: " ++ text

----------------------------------------------------------------------
-- test with/out shared sandboxes...

createSpec :: IO SandboxSpec
createSpec = do
    dar <- locateRunfiles (mainWorkspace </> "language-support/hs/bindings/for-tests.dar")
    return SandboxSpec {dar}

newtype ShareSandbox = ShareSandbox Bool

testGroupWithSandbox :: ShareSandbox -> TestName -> [WithSandbox -> TestTree] -> TestTree
testGroupWithSandbox (ShareSandbox enableSharing) name tests =
    if enableSharing
    then
        -- waits to run in the one shared sandbox
        withResource acquireShared releaseShared $ \resource -> do
        testGroup name $ map (\f -> f (withShared resource)) tests
    else do
        -- runs in it's own freshly (and very slowly!) spun-up sandbox
        let withSandbox' f = do
                spec <- createSpec
                pid <- mainPackageId spec
                withSandbox spec $ \sandbox -> f sandbox pid (TestId 0)
        testGroup name $ map (\f -> f withSandbox') tests

mainPackageId :: SandboxSpec -> IO PackageId
mainPackageId (SandboxSpec dar) = do
    archive <- Zip.toArchive <$> BSL.readFile dar
    Dalfs { mainDalf } <- either fail pure $ readDalfs archive
    case decodeArchive DecodeAsMain (BSL.toStrict mainDalf) of
        Left err -> fail $ show err
        Right (LF.PackageId pId, _) -> pure (PackageId $ Text.fromStrict pId)

----------------------------------------------------------------------
-- SharedSandbox

type WithSandbox = (Sandbox -> PackageId -> TestId -> IO ()) -> IO ()

data SharedSandbox = SharedSandbox (MVar (Sandbox, PackageId, TestId))

acquireShared :: IO SharedSandbox
acquireShared = do
    spec <- createSpec
    sandbox <- startSandbox spec
    pid <- mainPackageId spec
    mv <- newMVar (sandbox, pid, TestId 0)
    return $ SharedSandbox mv

releaseShared :: SharedSandbox -> IO ()
releaseShared (SharedSandbox mv) = do
    (sandbox, _, _) <- takeMVar mv
    shutdownSandbox sandbox

withShared :: IO SharedSandbox -> WithSandbox
withShared resource f = do
    SharedSandbox mv <- resource
    modifyMVar_ mv $ \(sandbox, pid, testId) -> do
        -- resetSandbox sandbox
        f sandbox pid testId
        pure (sandbox, pid, nextTestId testId)
