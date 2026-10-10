#if os(macOS)
import Foundation
import SensoriumUpdate

private func version(_ text: String) -> UpdateVersion { UpdateVersion(text)! }

private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

func testDecisionTableFirstMatchingRowDecides() {
    func decide(offered: String, running: String, highestSeen: String?, minimum: UpdateSystemVersion = UpdateSystemVersion(major: 13, minor: 0)) -> UpdateDecision {
        UpdateDecision.decide(
            offered: version(offered),
            minimumMacOS: minimum,
            running: version(running),
            highestSeen: highestSeen.map(version),
            system: sonoma
        )
    }
    expect(
        decide(offered: "0.4.0", running: "0.4.0", highestSeen: "0.5.0") == .wentBackwards(highestSeen: version("0.5.0")),
        "an offer below the highest seen is a failed check even when it equals the running version"
    )
    expect(
        decide(offered: "0.4.0", running: "0.3.0", highestSeen: "0.5.0") == .wentBackwards(highestSeen: version("0.5.0")),
        "an offer below the highest seen is a failed check even when it is newer than the running version"
    )
    expect(decide(offered: "0.4.0", running: "0.4.0", highestSeen: "0.4.0") == .upToDate, "an offer equal to the running version is up to date")
    expect(decide(offered: "0.4.0", running: "0.4.0", highestSeen: nil) == .upToDate, "with nothing seen yet an equal offer is up to date")
    expect(decide(offered: "0.5.0", running: "0.4.0", highestSeen: "0.4.0") == .update, "a newer offer is an update")
    expect(decide(offered: "0.5.0", running: "0.4.0", highestSeen: nil) == .update, "a newer offer is an update when nothing was seen before")
    expect(
        decide(offered: "0.4.0", running: "0.5.0", highestSeen: nil) == .upToDate,
        "an offer older than the running version but not below the highest seen matches no row and installs nothing"
    )
    expect(
        decide(offered: "0.5.0", running: "0.4.0", highestSeen: nil, minimum: UpdateSystemVersion(major: 15, minor: 0)) == .requiresNewerMacOS,
        "a release for a newer macOS is not offered"
    )
    expect(
        decide(offered: "0.5.0", running: "0.4.0", highestSeen: nil, minimum: UpdateSystemVersion(major: 14, minor: 5)) == .update,
        "a minimum equal to the running macOS is met"
    )
    expect(
        decide(offered: "0.5.0", running: "0.4.0", highestSeen: nil, minimum: UpdateSystemVersion(major: 14, minor: 5, patch: 1)) == .requiresNewerMacOS,
        "the minimum's third part counts"
    )
}

func testFailureKindsAndReasonsMatchTheDesignTable() {
    let didNotMatch = "the download did not match the release"
    let notSigned = "the new version is not signed like this one"
    let didNotStart = "the new version did not start"
    let notInTime = "the new version did not start in time"
    let bad: [(UpdateFailure, String)] = [
        (.signatureInvalid, didNotMatch),
        (.wrongBundleContents("two items"), didNotMatch),
        (.requirementFailed, notSigned),
        (.selfTestFailed(status: 3), didNotStart)
    ]
    for (failure, reason) in bad {
        expect(failure.kind == .badRelease, "\(failure) is a bad release")
        expect(failure.reason == reason, "\(failure) reads '\(reason)'")
    }
    let retryable: [(UpdateFailure, String)] = [
        (.sizeMismatch, didNotMatch), (.digestMismatch, didNotMatch),
        (.downloadFailed, notInTime), (.selfTestTimedOut, notInTime), (.stagingFailed, notInTime),
        (.swapFailed, notInTime), (.launchFailed, notInTime), (.readyLate, notInTime),
        (.readyMismatch("version"), notInTime), (.newInstanceDidNotQuit, notInTime)
    ]
    for (failure, reason) in retryable {
        expect(failure.kind == .couldPassOnAnotherTry, "\(failure) could pass on another try")
        expect(failure.reason == reason, "\(failure) reads '\(reason)'")
    }
    let backwards = UpdateFailure.wentBackwards(highestSeen: version("0.5.0"), offered: version("0.4.0"))
    expect(backwards.reason == "the release page offered an older version than one it offered before", "the release page going backwards keeps its reason")
}

func testStateRecordsFailuresWithAThreeTryCapAndClears() {
    var state = UpdateState()
    let release = (version: version("0.5.0"), sha256: sampleDigest)
    let otherZip = String(repeating: "cd", count: 32)

    expect(state.mayTry(version: release.version, sha256: release.sha256), "a release that never failed may be tried")

    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256)
    expect(state.mayTry(version: release.version, sha256: release.sha256), "one retryable failure leaves another try")
    expect(state.failure(version: release.version, sha256: release.sha256)?.tries == 1, "the first try is counted")
    expect(!state.hasGivenUp(on: release.version, sha256: release.sha256), "the Waiting line stays between tries")

    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256)
    expect(state.mayTry(version: release.version, sha256: release.sha256), "two retryable failures leave a third try")
    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256)
    expect(!state.mayTry(version: release.version, sha256: release.sha256), "after the third try the release is not tried again")
    expect(state.failure(version: release.version, sha256: release.sha256)?.kind == .badRelease, "after the third try it counts as a bad release")
    expect(
        state.failure(version: release.version, sha256: release.sha256)?.reason == "the new version did not start in time",
        "the given-up release keeps the reason of its last failure, so the Failed line can name it after a relaunch"
    )
    expect(state.hasGivenUp(on: release.version, sha256: release.sha256), "the Failed line shows after the third try")

    var bad = UpdateState()
    bad.recordFailure(.requirementFailed, version: release.version, sha256: release.sha256)
    expect(!bad.mayTry(version: release.version, sha256: release.sha256), "a bad release is never tried again")
    expect(bad.hasGivenUp(on: release.version, sha256: release.sha256), "the Failed line shows after a bad release")
    expect(bad.failure(version: release.version, sha256: release.sha256)?.reason == "the new version is not signed like this one", "a bad release keeps its reason")
    expect(bad.mayTry(version: release.version, sha256: otherZip), "the same version with a different zip is tried")
    expect(bad.mayTry(version: version("0.5.1"), sha256: release.sha256), "a different version is tried")

    bad.clearFailures()
    expect(bad.mayTry(version: release.version, sha256: release.sha256), "Check for Updates clears every recorded failure")
    expect(bad.failures.isEmpty, "no failure is left after clearing")
}

func testARetryIsHeldBackUntilACheckIntervalAfterItsLastFailure() {
    let release = (version: version("0.5.0"), sha256: sampleDigest)
    let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let sixHours: TimeInterval = 6 * 60 * 60
    var state = UpdateState()

    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256, now: failedAt)
    expect(state.failure(version: release.version, sha256: release.sha256)?.lastFailed == failedAt, "the time of the failure is recorded")
    expect(
        state.isHeldBack(version: release.version, sha256: release.sha256, now: failedAt.addingTimeInterval(60)),
        "a relaunch minutes after a failure does not try the release again"
    )
    expect(
        state.isHeldBack(version: release.version, sha256: release.sha256, now: failedAt.addingTimeInterval(sixHours - 1)),
        "the next try waits a whole check interval"
    )
    expect(
        !state.isHeldBack(version: release.version, sha256: release.sha256, now: failedAt.addingTimeInterval(sixHours)),
        "the next scheduled check tries again"
    )
    expect(
        !state.isHeldBack(version: release.version, sha256: String(repeating: "cd", count: 32), now: failedAt),
        "the same version with a different zip is not held back"
    )

    let secondTry = failedAt.addingTimeInterval(sixHours)
    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256, now: secondTry)
    expect(state.failure(version: release.version, sha256: release.sha256)?.lastFailed == secondTry, "each failure records its own time")
    expect(
        state.isHeldBack(version: release.version, sha256: release.sha256, now: secondTry.addingTimeInterval(60)),
        "the wait starts again from the latest failure"
    )

    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256, now: secondTry.addingTimeInterval(sixHours))
    expect(
        !state.isHeldBack(version: release.version, sha256: release.sha256, now: secondTry.addingTimeInterval(sixHours + 60)),
        "after the third try the release is given up on, not held back"
    )

    var bad = UpdateState()
    bad.recordFailure(.requirementFailed, version: release.version, sha256: release.sha256, now: failedAt)
    expect(!bad.isHeldBack(version: release.version, sha256: release.sha256, now: failedAt), "a bad release is given up on, not held back")
}

func testAFailureSavedWithoutItsTimeStillReads() {
    let directory = makeTemporaryDirectory("state-without-time")
    defer { removeTemporaryDirectory(directory) }
    let store = UpdateStateStore(role: .host, directory: directory)
    let saved = """
    {
      "failures" : [
        {
          "kind" : "couldPassOnAnotherTry",
          "reason" : "the new version did not start in time",
          "sha256" : "\(sampleDigest)",
          "tries" : 1,
          "version" : "0.5.0"
        }
      ],
      "highestVersionSeen" : "0.5.0"
    }
    """
    try! Data(saved.utf8).write(to: store.url)

    let state = store.load()
    let record = state.failure(version: version("0.5.0"), sha256: sampleDigest)
    expect(record?.tries == 1, "a failure saved without its time still reads")
    expect(record != nil && record?.lastFailed == nil, "with no time")
    expect(
        !state.isHeldBack(version: version("0.5.0"), sha256: sampleDigest, now: Date(timeIntervalSince1970: 1_800_000_000)),
        "a failure with no recorded time may be tried"
    )
}

func testStateStoreRoundTripsOwnerOnly() {
    let directory = makeTemporaryDirectory("state")
    defer { removeTemporaryDirectory(directory) }
    let folder = directory.appendingPathComponent("Sensorium", isDirectory: true)
    let store = UpdateStateStore(role: .host, directory: folder)
    let viewerStore = UpdateStateStore(role: .viewer, directory: folder)

    expect(store.load() == UpdateState(), "a missing file reads as an empty state")

    var state = UpdateState()
    state.highestVersionSeen = version("0.5.0")
    state.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
    state.recordFailure(.selfTestTimedOut, version: version("0.5.0"), sha256: sampleDigest, now: Date(timeIntervalSince1970: 1_800_000_060))
    try! store.save(state)

    expect(store.url.lastPathComponent == "host-update-state.json", "the host's file is host-update-state.json")
    expect(viewerStore.url.lastPathComponent == "viewer-update-state.json", "the viewer's file is viewer-update-state.json")
    expect(viewerStore.load() == UpdateState(), "the host's state is not the viewer's: both apps share the folder on a machine with both")
    expect(store.load() == state, "the state reads back as it was saved")
    expect(posixMode(of: store.url) == 0o600, "the state file is owner read-write only")
    expect(posixMode(of: store.url.deletingLastPathComponent()) == 0o700, "its folder is owner-only")

    let updated = try! store.update { $0.clearFailures() }
    expect(updated.failures.isEmpty && store.load().failures.isEmpty, "an update reads, changes and writes the file")
    expect(store.load().highestVersionSeen == version("0.5.0"), "an update keeps the fields it did not change")

    let names = try! FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
    expect(names == ["host-update-state.json"], "an atomic write leaves no temporary file")

    try! Data("{ not json".utf8).write(to: store.url)
    expect(store.load() == UpdateState(), "a corrupt file reads as an empty state rather than failing every check")

    expect(
        UpdateStateStore.defaultDirectory.path.hasSuffix("/Library/Application Support/Sensorium"),
        "the default folder is Application Support/Sensorium"
    )
}
#endif
