#if os(macOS)
@main
struct SensoriumUpdateTestRunner {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == cachedRequirementProbeArgument {
            runCachedRequirementProbe(ownPath: arguments[2], replacement: arguments[3])
        }
        let tests: [(String, @MainActor () async -> Void)] = [
            ("versions parse strictly and compare numerically", testVersionsParseStrictlyAndCompareNumerically),
            ("the manifest parses the design's shape", testManifestParsesTheDesignShape),
            ("the manifest refuses every malformed field", testManifestRejectsEveryMalformedField),
            ("the signature verifies only the exact bytes with the right key", testSignatureVerifiesOnlyTheExactBytesWithTheRightKey),
            ("the compiled public key is a key and rejects a fresh signer", testCompiledPublicKeyIsAKeyAndRejectsAFreshSigner),
            ("the decision table's first matching row decides", testDecisionTableFirstMatchingRowDecides),
            ("failure kinds and reasons match the design table", testFailureKindsAndReasonsMatchTheDesignTable),
            ("the state records failures with a three-try cap and clears", testStateRecordsFailuresWithAThreeTryCapAndClears),
            ("a retry is held back until a check interval after its last failure", testARetryIsHeldBackUntilACheckIntervalAfterItsLastFailure),
            ("a failure saved without its time still reads", testAFailureSavedWithoutItsTimeStillReads),
            ("the state store round-trips, owner-only", testStateStoreRoundTripsOwnerOnly),
            ("release addresses are built from constants and manifest fields", testReleaseAddressesAreBuiltFromConstantsAndManifestFields),
            ("the real transport is ephemeral, cookieless, uncached and named", testRealTransportIsEphemeralCookielessUncachedAndNamed),
            ("a check finds a signed newer release and remembers it", testCheckFindsASignedNewerReleaseAndRemembersIt),
            ("a check stops on any failure before trusting the manifest", testCheckStopsOnAnyFailureBeforeTrustingTheManifest),
            ("a check reports the release page going backwards", testCheckReportsTheReleasePageGoingBackwards),
            ("a check does not offer a release that was given up on", testCheckDoesNotOfferAReleaseThatWasGivenUpOn),
            ("a check holds back a retry until a check interval after its last failure", testCheckHoldsBackARetryUntilACheckIntervalAfterItsLastFailure),
            ("a download is checked for size and digest", testDownloadIsCheckedForSizeAndDigest),
            ("the staging folder is owner-only, beside the installed app", testStagingFolderIsOwnerOnlyBesideTheInstalledApp),
            ("bundle validation refuses anything but one matching app", testBundleValidationRefusesAnythingButOneMatchingApp),
            ("the requirement check passes only for a matching signature", testRequirementCheckPassesOnlyForAMatchingSignature),
            ("the running app's requirement is read once and cached", testRunningAppRequirementIsReadOnceAndCached),
            ("the self-test passes, fails and times out", testSelfTestPassesFailsAndTimesOut),
            ("staging a signed release end to end", testStagingASignedReleaseEndToEnd),
            ("staging refuses a zip with two items", testStagingRefusesAZipWithTwoItems),
            ("a ready report round-trips, owner-only", testReadyReportRoundTripsOwnerOnly),
            ("a ready report is accepted only when nothing got worse", testReadyReportIsAcceptedOnlyWhenNothingGotWorse),
            ("installability refuses translocated and unwritable locations", testInstallabilityRefusesTranslocatedAndUnwritableLocations),
            ("install at quit swaps in place and swaps back on a requirement failure", testInstallAtQuitSwapsInPlaceAndSwapsBackOnARequirementFailure),
            ("a swap failure leaves the installed app alone", testSwapFailureLeavesTheInstalledAppAlone),
            ("a failed swap back is reported as such", testAFailedSwapBackIsReportedAsSuch),
            ("the handoff is accepted when the new version reports the same values", testHandoffIsAcceptedWhenTheNewVersionReportsTheSameValues),
            ("the handoff swaps back on every rejection", testHandoffSwapsBackOnEveryRejection),
            ("the handoff accepts only a report from the launched process", testHandoffAcceptsOnlyAReportFromTheLaunchedProcess),
            ("a host rollback relaunches the previous version through the same handoff", testHostRollbackRelaunchesThePreviousVersionThroughTheSameHandoff),
            ("the command line parses the two update modes before anything else", testCommandLineParsesTheTwoUpdateModesBeforeAnythingElse),
            ("waiting for the old process returns once it exits", testWaitingForTheOldProcessReturnsOnceItExits),
            ("finishing the handoff removes only a staging folder", testFinishingTheHandoffRemovesOnlyAStagingFolder),
            ("the ready file is written only into an owner-only folder", testTheReadyFileIsWrittenOnlyIntoAnOwnerOnlyFolder),
            ("the staging folder is removed only when it is one", testTheStagingFolderIsRemovedOnlyWhenItIsOne),
            ("the scheduler makes no request when automatic updates are off", testSchedulerMakesNoRequestWhenAutomaticUpdatesAreOff),
            ("the scheduler checks at launch and every six hours while on", testSchedulerChecksAtLaunchAndEverySixHoursWhileOn),
            ("the scheduler shows failures and unreachable checks plainly", testSchedulerShowsFailuresAndUnreachableChecksPlainly),
            ("a download that does not match is tried three times", testADownloadThatDoesNotMatchIsTriedThreeTimes),
            ("the scheduler makes no request when not updatable", testSchedulerMakesNoRequestWhenNotUpdatable),
            ("the host installs only when idle and rechecks right before installing", testHostInstallsOnlyWhenIdleAndRechecksRightBeforeInstalling),
            ("a rolled-back host waits for the next scheduled check before trying again", testARolledBackHostWaitsForTheNextScheduledCheckBeforeTryingAgain),
            ("the viewer holds a ready update until asked to install", testViewerHoldsAReadyUpdateUntilAskedToInstall)
        ]

        for (name, test) in tests {
            await test()
            print("PASS: \(name)")
        }

        print("PASS: \(tests.count) tests")
    }
}
#else
/// The updater is macOS-only; the Linux viewer updates through its package.
@main
struct SensoriumUpdateTestRunner {
    static func main() {
        print("SKIP: the update core is macOS-only")
    }
}
#endif
