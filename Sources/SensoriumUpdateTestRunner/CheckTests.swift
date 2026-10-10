#if os(macOS)
import CryptoKit
import Foundation
import SensoriumUpdate

func testReleaseAddressesAreBuiltFromConstantsAndManifestFields() {
    expect(
        UpdateReleaseLocation.manifestURL.absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update.json",
        "the manifest address is the release page's stable latest link"
    )
    expect(
        UpdateReleaseLocation.signatureURL.absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update.json.sig",
        "the signature sits beside the manifest"
    )
    let manifest = try! UpdateManifest.parse(serialized(sampleManifestObject()))
    expect(
        UpdateReleaseLocation.downloadURL(version: manifest.version, app: manifest.app(.host)).absoluteString
            == "https://github.com/blutarche/sensorium/releases/download/v0.4.0/Sensorium-Host-0.4.0.zip",
        "a zip's address is built from the manifest's version and file"
    )
}

func testRealTransportIsEphemeralCookielessUncachedAndNamed() {
    let configuration = URLSessionUpdateTransport.makeConfiguration()
    expect(configuration.httpCookieStorage == nil && configuration.httpCookieAcceptPolicy == .never, "no cookie is kept")
    expect(!configuration.httpShouldSetCookies, "no cookie is sent")
    expect(configuration.urlCache == nil, "nothing is cached")
    expect(configuration.urlCredentialStorage == nil, "no credential is stored")
    expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "every request goes to the server")
    expect(configuration.timeoutIntervalForRequest == 30, "a request times out after 30 seconds")
    expect(
        configuration.httpAdditionalHeaders?["User-Agent"] as? String == "Sensorium-Update/1",
        "every request carries the fixed user agent"
    )
    expect(UpdateReleaseLocation.maximumSmallFileBytes == 64 * 1024, "the manifest and signature are capped at 64 KB")
}

private func makeChecker(
    page: FakeReleasePage,
    key: Curve25519.Signing.PrivateKey,
    store: UpdateStateStore,
    running: String = "0.4.0",
    system: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
) -> UpdateChecker {
    UpdateChecker(
        role: .host,
        runningVersion: UpdateVersion(running)!,
        transport: page,
        stateStore: store,
        publicKey: key.publicKey.rawRepresentation,
        system: system,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
}

func testCheckFindsASignedNewerReleaseAndRemembersIt() async {
    let directory = makeTemporaryDirectory("check")
    defer { removeTemporaryDirectory(directory) }
    let store = UpdateStateStore(role: .host, directory: directory)
    let key = Curve25519.Signing.PrivateKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.5.0")), signedWith: key)

    let result = await makeChecker(page: page, key: key, store: store).check()
    guard case let .available(offer) = result else {
        return expect(false, "a signed newer release is offered, got \(result)")
    }
    expect(offer.version == UpdateVersion("0.5.0")!, "the offer names the new version")
    expect(offer.app.file == "Sensorium-Host-0.5.0.zip", "the host is offered the host's zip")
    expect(
        page.requests == [
            .init(url: UpdateReleaseLocation.manifestURL, maximumBytes: 64 * 1024),
            .init(url: UpdateReleaseLocation.signatureURL, maximumBytes: 64 * 1024)
        ],
        "a check fetches the manifest and its signature, each capped at 64 KB, and nothing else"
    )
    let state = store.load()
    expect(state.highestVersionSeen == UpdateVersion("0.5.0")!, "the version of a valid manifest is remembered")
    expect(state.lastCheck == Date(timeIntervalSince1970: 1_800_000_000), "the time of the check is remembered")
}

func testCheckStopsOnAnyFailureBeforeTrustingTheManifest() async {
    let directory = makeTemporaryDirectory("check-failures")
    defer { removeTemporaryDirectory(directory) }
    let store = UpdateStateStore(role: .host, directory: directory)
    let key = Curve25519.Signing.PrivateKey()

    let forged = FakeReleasePage()
    forged.publish(serialized(sampleManifestObject(version: "0.5.0")), signedWith: Curve25519.Signing.PrivateKey())
    let forgedResult = await makeChecker(page: forged, key: key, store: store).check()
    expect(forgedResult == .failed(.signatureInvalid), "a manifest signed with another key is a failed check")
    expect(store.load().highestVersionSeen == nil, "an unverified manifest's version is not remembered")

    let unreachable = FakeReleasePage()
    let before = store.load()
    let unreachableResult = await makeChecker(page: unreachable, key: key, store: store).check()
    expect(unreachableResult == .unreachable, "an unreachable release page is not a failure")
    expect(store.load() == before, "an unreachable release page records nothing")

    let malformed = FakeReleasePage()
    malformed.publish(serialized(manifestObject(sampleManifestObject(version: "0.5.0"), settingApp: "host", field: "size", to: 0)), signedWith: key)
    let malformedResult = await makeChecker(page: malformed, key: key, store: store).check()
    expect(malformedResult == .failed(.manifestInvalid), "a signed but malformed manifest is a failed check")

    let future = FakeReleasePage()
    future.publish(serialized(sampleManifestObject(version: "0.5.0").merging(["format": 2]) { $1 }), signedWith: key)
    let futureResult = await makeChecker(page: future, key: key, store: store).check()
    expect(futureResult == .upToDate, "a manifest format this app cannot read offers nothing")

    let newerMacOS = FakeReleasePage()
    newerMacOS.publish(serialized(sampleManifestObject(version: "0.5.0").merging(["minimumMacOS": "15.0"]) { $1 }), signedWith: key)
    let newerMacOSResult = await makeChecker(page: newerMacOS, key: key, store: store).check()
    expect(newerMacOSResult == .upToDate, "a release for a newer macOS offers nothing")
    expect(store.load().highestVersionSeen == nil, "a release this Mac cannot run is not remembered as seen")
}

func testCheckReportsTheReleasePageGoingBackwards() async {
    let directory = makeTemporaryDirectory("check-backwards")
    defer { removeTemporaryDirectory(directory) }
    let store = UpdateStateStore(role: .host, directory: directory)
    try! store.save(UpdateState(highestVersionSeen: UpdateVersion("0.6.0")!))
    let key = Curve25519.Signing.PrivateKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.5.0")), signedWith: key)

    let result = await makeChecker(page: page, key: key, store: store).check()
    expect(
        result == .failed(.wentBackwards(highestSeen: UpdateVersion("0.6.0")!, offered: UpdateVersion("0.5.0")!)),
        "an older signed manifest served again is a failed check"
    )
    expect(store.load().highestVersionSeen == UpdateVersion("0.6.0")!, "going backwards does not lower the highest version seen")
}

func testCheckDoesNotOfferAReleaseThatWasGivenUpOn() async {
    let directory = makeTemporaryDirectory("check-given-up")
    defer { removeTemporaryDirectory(directory) }
    let store = UpdateStateStore(role: .host, directory: directory)
    var state = UpdateState()
    state.recordFailure(.requirementFailed, version: UpdateVersion("0.5.0")!, sha256: sampleDigest)
    try! store.save(state)
    let key = Curve25519.Signing.PrivateKey()
    let page = FakeReleasePage()
    page.publish(serialized(sampleManifestObject(version: "0.5.0")), signedWith: key)

    let result = await makeChecker(page: page, key: key, store: store).check()
    guard case let .givenUp(offer, reason) = result else {
        return expect(false, "a bad release is not offered again, got \(result)")
    }
    expect(offer.version == UpdateVersion("0.5.0")!, "the given-up result names the version")
    expect(reason == "the new version is not signed like this one", "the given-up result carries the recorded reason")
}
#endif
