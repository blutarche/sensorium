import Foundation
import SensoriumCore
import SensoriumLinuxUpdate

func testReleaseAddressesAreBuiltFromConstantsAndManifestFields() {
    expect(
        LinuxUpdateReleaseLocation.manifestURL.absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update-linux-x86_64.json",
        "the manifest address is the release page's stable latest link"
    )
    expect(
        LinuxUpdateReleaseLocation.signatureURL.absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update-linux-x86_64.json.sig",
        "the signature sits beside the manifest"
    )
    let manifest = try! LinuxUpdateManifest.parse(serialized(sampleManifestObject(version: "0.6.0")))
    expect(
        LinuxUpdateReleaseLocation.downloadURL(for: manifest).absoluteString
            == "https://github.com/blutarche/sensorium/releases/download/v0.6.0/Sensorium-0.6.0-linux-x86_64.tar.gz",
        "the archive's address is built from the manifest's version and file"
    )
    expect(LinuxUpdateReleaseLocation.maximumSmallFileBytes == 64 * 1024, "the manifest and signature are capped at 64 KB")
    expect(LinuxUpdateReleaseLocation.userAgent == "Sensorium-Update/1", "every request carries the fixed user agent")
    expect(LinuxUpdateReleaseLocation.timeout == 30, "a request times out after 30 seconds")
}

private struct SigningKey {
    let privateKey = SensoriumCrypto.ed25519GeneratePrivateKey()
    var publicKey: Data { try! SensoriumCrypto.ed25519PublicKey(privateKey: privateKey) }
}

private func makeChecker(page: FakeReleasePage, key: SigningKey, store: LinuxUpdateStateStore, running: String = "0.5.0") -> LinuxUpdateChecker {
    LinuxUpdateChecker(
        runningVersion: LinuxUpdateVersion(running)!,
        transport: page,
        stateStore: store,
        publicKey: key.publicKey,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
}

func testCheckFindsASignedNewerReleaseAndRemembersIt() async {
    let directory = makeTemporaryDirectory("check")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    let key = SigningKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: key.privateKey)

    let result = await makeChecker(page: page, key: key, store: store).check()
    guard case let .available(offer) = result else {
        return expect(false, "a signed newer release is offered, got \(result)")
    }
    expect(offer.version == version("0.6.0"), "the offer names the new version")
    expect(offer.file == "Sensorium-0.6.0-linux-x86_64.tar.gz", "the offer names the Linux archive")
    expect(
        page.requests == [
            .init(url: LinuxUpdateReleaseLocation.manifestURL, maximumBytes: 64 * 1024),
            .init(url: LinuxUpdateReleaseLocation.signatureURL, maximumBytes: 64 * 1024)
        ],
        "a check fetches the manifest and its signature, each capped at 64 KB, and nothing else"
    )
    let state = store.load()
    expect(state.highestVersionSeen == version("0.6.0"), "the version of a valid manifest is remembered")
    expect(state.lastCheck == Date(timeIntervalSince1970: 1_800_000_000), "the time of the check is remembered")

    let current = await makeChecker(page: page, key: key, store: store, running: "0.6.0").check()
    expect(current == .upToDate, "the running version is up to date")
}

func testCheckStopsOnAnyFailureBeforeTrustingTheManifest() async {
    let directory = makeTemporaryDirectory("check-failures")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    let key = SigningKey()

    let forged = FakeReleasePage()
    forged.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: SigningKey().privateKey)
    let forgedResult = await makeChecker(page: forged, key: key, store: store).check()
    expect(forgedResult == .failed(.signatureInvalid), "a manifest signed with another key is a failed check")
    expect(store.load().highestVersionSeen == nil, "an unverified manifest's version is not remembered")

    let unreachable = FakeReleasePage()
    unreachable.fail(LinuxUpdateReleaseLocation.manifestURL)
    let before = store.load()
    let unreachableResult = await makeChecker(page: unreachable, key: key, store: store).check()
    expect(unreachableResult == .unreachable, "an unreachable release page is not a failure")
    expect(store.load() == before, "an unreachable release page records nothing")

    let serverError = FakeReleasePage()
    serverError.fail(LinuxUpdateReleaseLocation.manifestURL, with: .badStatus(503))
    let serverErrorResult = await makeChecker(page: serverError, key: key, store: store).check()
    expect(serverErrorResult == .unreachable, "a server error is an unreachable release page")

    var malformedObject = sampleManifestObject(version: "0.6.0")
    malformedObject["size"] = 0
    let malformed = FakeReleasePage()
    malformed.publish(serialized(malformedObject), signedWith: key.privateKey)
    let malformedResult = await makeChecker(page: malformed, key: key, store: store).check()
    expect(malformedResult == .failed(.manifestInvalid), "a signed but malformed manifest is a failed check")

    let future = FakeReleasePage()
    future.publish(serialized(sampleManifestObject(version: "0.6.0").merging(["format": 2]) { $1 }), signedWith: key.privateKey)
    let futureResult = await makeChecker(page: future, key: key, store: store).check()
    expect(futureResult == .upToDate, "a manifest format this viewer cannot read offers nothing")
    expect(store.load().highestVersionSeen == nil, "a manifest this viewer cannot read is not remembered as seen")
}

/// Section 11.2: a release whose Linux manifest is not signed and uploaded
/// yet reads as up to date.
func testAReleaseWithNoLinuxManifestYetIsUpToDate() async {
    let directory = makeTemporaryDirectory("check-no-manifest")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    let key = SigningKey()

    let empty = FakeReleasePage()
    let emptyResult = await makeChecker(page: empty, key: key, store: store).check()
    expect(emptyResult == .upToDate, "a release page with no Linux manifest is up to date")
    expect(empty.requests.count == 1, "no signature is fetched for a manifest that is not there")
    expect(store.load().lastCheck == Date(timeIntervalSince1970: 1_800_000_000), "the check still counts as made")

    let manifestOnly = FakeReleasePage()
    manifestOnly.serve(serialized(sampleManifestObject(version: "0.6.0")), at: LinuxUpdateReleaseLocation.manifestURL)
    let manifestOnlyResult = await makeChecker(page: manifestOnly, key: key, store: store).check()
    expect(manifestOnlyResult == .upToDate, "a manifest whose signature is not uploaded yet offers nothing")
    expect(store.load().highestVersionSeen == nil, "an unsigned manifest's version is not remembered")
}

func testCheckReportsTheReleasePageGoingBackwards() async {
    let directory = makeTemporaryDirectory("check-backwards")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    try! store.save(LinuxUpdateState(highestVersionSeen: version("0.7.0")))
    let key = SigningKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: key.privateKey)

    let result = await makeChecker(page: page, key: key, store: store).check()
    expect(
        result == .failed(.wentBackwards(highestSeen: version("0.7.0"), offered: version("0.6.0"))),
        "an older signed manifest served again is a failed check, even when it is newer than the running version"
    )
    expect(store.load().highestVersionSeen == version("0.7.0"), "going backwards does not lower the highest version seen")
}

func testCheckDoesNotOfferAReleaseThatWasGivenUpOn() async {
    let directory = makeTemporaryDirectory("check-given-up")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    var state = LinuxUpdateState()
    state.recordFailure(.selfTestFailed(status: 1), version: version("0.6.0"), sha256: sampleDigest)
    try! store.save(state)
    let key = SigningKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: key.privateKey)

    let result = await makeChecker(page: page, key: key, store: store).check()
    guard case let .givenUp(offer, reason) = result else {
        return expect(false, "a bad release is not offered again, got \(result)")
    }
    expect(offer.version == version("0.6.0"), "the given-up result names the version")
    expect(reason == "the new version did not start", "the given-up result carries the recorded reason")

    var otherArchive = sampleManifestObject(version: "0.6.0")
    otherArchive["sha256"] = String(repeating: "cd", count: 32)
    page.publish(serialized(otherArchive), signedWith: key.privateKey)
    let rebuilt = await makeChecker(page: page, key: key, store: store).check()
    guard case .available = rebuilt else {
        return expect(false, "the same version with a different archive is offered, got \(rebuilt)")
    }
}

func testCheckHoldsBackARetryUntilACheckIntervalAfterItsLastFailure() async {
    let directory = makeTemporaryDirectory("check-held-back")
    defer { removeTemporaryDirectory(directory) }
    let store = LinuxUpdateStateStore(dataRoot: directory)
    let key = SigningKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: key.privateKey)
    let checkTime = Date(timeIntervalSince1970: 1_800_000_000)

    func check(afterFailingAt failedAt: Date) async -> LinuxUpdateCheckResult {
        var state = LinuxUpdateState()
        state.recordFailure(.readyLate, version: version("0.6.0"), sha256: sampleDigest, now: failedAt)
        try! store.save(state)
        return await makeChecker(page: page, key: key, store: store).check()
    }

    let soon = await check(afterFailingAt: checkTime.addingTimeInterval(-60 * 60))
    guard case let .heldBack(offer) = soon else {
        return expect(false, "a release that failed an hour ago is held back, got \(soon)")
    }
    expect(offer.version == version("0.6.0"), "the held-back result names the version")

    let due = await check(afterFailingAt: checkTime.addingTimeInterval(-6 * 60 * 60))
    guard case .available = due else {
        return expect(false, "a release that failed six hours ago is offered again, got \(due)")
    }
}
