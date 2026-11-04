/// Runs on macOS and on Linux alike: nothing the engine does is specific to
/// either.
@main
struct SensoriumLinuxUpdateTestRunner {
    static func main() async {
        let tests: [(String, () async -> Void)] = [
            ("versions parse strictly and compare numerically", testVersionsParseStrictlyAndCompareNumerically),
            ("the decision table's first matching row decides", testDecisionTableFirstMatchingRowDecides),
            ("the compiled public key matches the macOS updater's", testCompiledPublicKeyMatchesTheMacOSUpdater),
            ("the compiled public key is a key and rejects a fresh signer", testCompiledPublicKeyIsAKeyAndRejectsAFreshSigner),
            ("the manifest parses the design's shape", testManifestParsesTheDesignShape),
            ("the manifest refuses every malformed field", testManifestRefusesEveryMalformedField),
            ("the signature verifies only the exact bytes with the right key", testSignatureVerifiesOnlyTheExactBytesWithTheRightKey),
            ("failure kinds and reasons match the design table", testFailureKindsAndReasonsMatchTheDesignTable),
            ("the state records failures with a three-try cap and clears", testStateRecordsFailuresWithAThreeTryCapAndClears),
            ("a retry is held back until a check interval after its last failure", testARetryIsHeldBackUntilACheckIntervalAfterItsLastFailure),
            ("the state store round-trips, owner-only", testStateStoreRoundTripsOwnerOnly),
            ("release addresses are built from constants and manifest fields", testReleaseAddressesAreBuiltFromConstantsAndManifestFields),
            ("a check finds a signed newer release and remembers it", testCheckFindsASignedNewerReleaseAndRemembersIt),
            ("a check stops on any failure before trusting the manifest", testCheckStopsOnAnyFailureBeforeTrustingTheManifest),
            ("a release with no Linux manifest yet is up to date", testAReleaseWithNoLinuxManifestYetIsUpToDate),
            ("a check reports the release page going backwards", testCheckReportsTheReleasePageGoingBackwards),
            ("a check does not offer a release that was given up on", testCheckDoesNotOfferAReleaseThatWasGivenUpOn),
            ("a check holds back a retry until a check interval after its last failure", testCheckHoldsBackARetryUntilACheckIntervalAfterItsLastFailure),
            ("an archive with one binary extracts it executable", testArchiveWithOneBinaryExtractsItExecutable),
            ("an archive is refused unless it holds one regular binary", testArchiveRefusesAnythingButOneRegularBinary),
            ("an archive is refused unless it is a clean tar stream", testArchiveRefusesWhatIsNotACleanTarStream),
            ("an archive the system tar made extracts", testArchiveFromTheSystemTarExtracts),
            ("a download is checked for size and digest", testDownloadIsCheckedForSizeAndDigest),
            ("the self-test passes, fails, checks the version and times out", testSelfTestPassesFailsAndTimesOut),
            ("the data root follows the XDG rule and names the layout", testDataRootFollowsTheXDGRuleAndNamesTheLayout),
            ("installability refuses an unsafe data root", testInstallabilityRefusesAnUnsafeDataRoot),
            ("staging folders are fresh and owner-only", testStagingFoldersAreFreshAndOwnerOnly),
            ("the switch writes the pending marker, then moves current in one step", testSwitchWritesThePendingMarkerThenMovesCurrentInOneStep),
            ("an unconfirmed switch is rolled back", testAnUnconfirmedSwitchIsRolledBack),
            ("confirmation removes the marker and keeps two previous versions", testConfirmationRemovesTheMarkerAndKeepsTwoPreviousVersions),
            ("staging a signed release end to end", testStagingASignedReleaseEndToEnd),
            ("staging failures are classified and leave nothing behind", testStagingFailuresAreClassifiedAndLeaveNothingBehind),
            ("the launcher entry runs current and the icons are copied", testLauncherEntryRunsCurrentAndTheIconsAreCopied),
            ("the Exec argument is quoted as the desktop entry specification requires", testExecArgumentIsQuotedAsTheDesktopEntrySpecificationRequires)
        ]

        for (name, test) in tests {
            await test()
            print("PASS: \(name)")
        }

        print("PASS: \(tests.count) tests")
    }
}
