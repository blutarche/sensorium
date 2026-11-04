import Foundation
import SensoriumLinuxUpdate

func version(_ text: String) -> LinuxUpdateVersion {
    LinuxUpdateVersion(text)!
}

func testFailureKindsAndReasonsMatchTheDesignTable() {
    let didNotMatch = "the download did not match the release"
    let didNotStart = "the new version did not start"
    let notInTime = "the new version did not start in time"
    let bad: [(LinuxUpdateFailure, String)] = [
        (.signatureInvalid, didNotMatch),
        (.manifestInvalid, didNotMatch),
        (.wrongArchiveContents("two entries"), didNotMatch),
        (.selfTestFailed(status: 3), didNotStart)
    ]
    for (failure, reason) in bad {
        expect(failure.kind == .badRelease, "\(failure) is a bad release")
        expect(failure.reason == reason, "\(failure) reads '\(reason)'")
    }
    let retryable: [(LinuxUpdateFailure, String)] = [
        (.sizeMismatch, didNotMatch), (.digestMismatch, didNotMatch),
        (.downloadFailed, notInTime), (.stagingFailed, notInTime), (.selfTestTimedOut, notInTime),
        (.switchFailed, notInTime), (.launchFailed, notInTime), (.readyLate, notInTime)
    ]
    for (failure, reason) in retryable {
        expect(failure.kind == .couldPassOnAnotherTry, "\(failure) could pass on another try")
        expect(failure.reason == reason, "\(failure) reads '\(reason)'")
    }
    let backwards = LinuxUpdateFailure.wentBackwards(highestSeen: version("0.5.0"), offered: version("0.4.0"))
    expect(backwards.kind == .badRelease, "the release page going backwards is a failed check")
    expect(
        backwards.reason == "the release page offered an older version than one it offered before",
        "the release page going backwards keeps its reason"
    )
}

func testStateRecordsFailuresWithAThreeTryCapAndClears() {
    var state = LinuxUpdateState()
    let release = (version: version("0.6.0"), sha256: sampleDigest)
    let otherArchive = String(repeating: "cd", count: 32)

    expect(LinuxUpdateState.maximumTries == 3, "a release that could pass on another try gets three tries")
    expect(state.mayTry(version: release.version, sha256: release.sha256), "a release that never failed may be tried")

    state.recordFailure(.readyLate, version: release.version, sha256: release.sha256)
    expect(state.mayTry(version: release.version, sha256: release.sha256), "one retryable failure leaves another try")
    expect(state.failure(version: release.version, sha256: release.sha256)?.tries == 1, "the first try is counted")
    expect(!state.hasGivenUp(on: release.version, sha256: release.sha256), "the Waiting line stays between tries")

    state.recordFailure(.digestMismatch, version: release.version, sha256: release.sha256)
    expect(state.mayTry(version: release.version, sha256: release.sha256), "two retryable failures leave a third try")
    state.recordFailure(.selfTestTimedOut, version: release.version, sha256: release.sha256)
    expect(!state.mayTry(version: release.version, sha256: release.sha256), "after the third try the release is not tried again")
    expect(state.failure(version: release.version, sha256: release.sha256)?.kind == .badRelease, "after the third try it counts as a bad release")
    expect(
        state.failure(version: release.version, sha256: release.sha256)?.reason == "the new version did not start in time",
        "the given-up release keeps the reason of its last failure, so the Failed line can name it after a relaunch"
    )
    expect(state.hasGivenUp(on: release.version, sha256: release.sha256), "the Failed line shows after the third try")
    expect(state.failures.count == 1, "one release keeps one record however often it failed")

    var bad = LinuxUpdateState()
    bad.recordFailure(.selfTestFailed(status: 1), version: release.version, sha256: release.sha256)
    expect(!bad.mayTry(version: release.version, sha256: release.sha256), "a bad release is never tried again")
    expect(bad.hasGivenUp(on: release.version, sha256: release.sha256), "the Failed line shows after a bad release")
    expect(bad.failure(version: release.version, sha256: release.sha256)?.reason == "the new version did not start", "a bad release keeps its reason")
    expect(bad.mayTry(version: release.version, sha256: otherArchive), "the same version with a different archive is tried")
    expect(bad.mayTry(version: version("0.6.1"), sha256: release.sha256), "a different version is tried")

    bad.clearFailures()
    expect(bad.mayTry(version: release.version, sha256: release.sha256), "Check for Updates clears every recorded failure")
    expect(bad.failures.isEmpty, "no failure is left after clearing")
}

func testARetryIsHeldBackUntilACheckIntervalAfterItsLastFailure() {
    let release = (version: version("0.6.0"), sha256: sampleDigest)
    let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let sixHours: TimeInterval = 6 * 60 * 60
    var state = LinuxUpdateState()

    expect(LinuxUpdateState.checkInterval == sixHours, "the viewer checks every six hours")
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
        "the same version with a different archive is not held back"
    )

    var bad = LinuxUpdateState()
    bad.recordFailure(.wrongArchiveContents("a link"), version: release.version, sha256: release.sha256, now: failedAt)
    expect(!bad.isHeldBack(version: release.version, sha256: release.sha256, now: failedAt), "a bad release is given up on, not held back")
}

func testStateStoreRoundTripsOwnerOnly() {
    let directory = makeTemporaryDirectory("state")
    defer { removeTemporaryDirectory(directory) }
    let root = directory.appendingPathComponent("sensorium", isDirectory: true)
    let store = LinuxUpdateStateStore(dataRoot: root)

    expect(store.url.lastPathComponent == "viewer-update-state.json", "the state file is viewer-update-state.json")
    expect(store.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL, "the state file lives in the data root")
    expect(store.load() == LinuxUpdateState(), "a missing file reads as an empty state")

    var state = LinuxUpdateState()
    state.highestVersionSeen = version("0.6.0")
    state.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
    state.recordFailure(.selfTestTimedOut, version: version("0.6.0"), sha256: sampleDigest, now: Date(timeIntervalSince1970: 1_800_000_060))
    try! store.save(state)

    expect(store.load() == state, "the state reads back as it was saved")
    expect(posixMode(of: store.url) == 0o600, "the state file is owner read-write only")
    expect(posixMode(of: root) == 0o700, "its folder is owner-only")

    let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
    let record = (saved["failures"] as! [[String: Any]])[0]
    expect(saved["highestVersionSeen"] as? String == "0.6.0", "the highest version seen is written as its text")
    expect(record["sha256"] as? String == sampleDigest && record["tries"] as? Int == 1, "a failure names its archive's digest and its try count")
    expect(record["kind"] as? String == "couldPassOnAnotherTry", "a failure names its kind")

    let updated = try! store.update { $0.clearFailures() }
    expect(updated.failures.isEmpty && store.load().failures.isEmpty, "an update reads, changes and writes the file")
    expect(store.load().highestVersionSeen == version("0.6.0"), "an update keeps the fields it did not change")

    let names = try! FileManager.default.contentsOfDirectory(atPath: root.path)
    expect(names == ["viewer-update-state.json"], "an atomic write leaves no temporary file")

    try! Data("{ not json".utf8).write(to: store.url)
    expect(store.load() == LinuxUpdateState(), "a corrupt file reads as an empty state rather than failing every check")
}
