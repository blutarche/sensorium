#if os(macOS)
import Foundation
import SensoriumUpdate

/// Stands in for the release certificate's designated requirement: any
/// bundle signed, ad hoc or not, under the fixture identifier.
let fixtureRequirement = CodeRequirementCheck(requirementText: "identifier \"\(fixtureIdentifier)\"")!

struct FixedRequirement: UpdateRequirementChecking {
    let satisfied: Bool
    func isSatisfied(byBundleAt url: URL) -> Bool { satisfied }
}

func testDownloadIsCheckedForSizeAndDigest() {
    let directory = makeTemporaryDirectory("digest")
    defer { removeTemporaryDirectory(directory) }
    let file = directory.appendingPathComponent("download.zip")
    try! Data(repeating: 7, count: 300_000).write(to: file)
    let digest = sha256Hex(of: file)

    expect(UpdateStaging.verifyDownload(at: file, size: 300_000, sha256: digest) == nil, "a file of the right size and digest passes")
    expect(UpdateStaging.verifyDownload(at: file, size: 299_999, sha256: digest) == .sizeMismatch, "a file of another size fails")
    expect(
        UpdateStaging.verifyDownload(at: file, size: 300_000, sha256: String(repeating: "0", count: 64)) == .digestMismatch,
        "a file with another digest fails"
    )
}

func testStagingFolderIsOwnerOnlyBesideTheInstalledApp() {
    let directory = makeTemporaryDirectory("staging-folder")
    defer { removeTemporaryDirectory(directory) }
    let installed = makeAppBundle(in: directory, signingIdentifier: nil)

    let staging = try! UpdateStaging.makeStagingDirectory(appropriateFor: installed)
    defer { try? FileManager.default.removeItem(at: staging) }
    expect(posixMode(of: staging) == 0o700, "the staging folder is owner-only")
    let volume = { (url: URL) in try! url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as! NSObject }
    expect(volume(staging).isEqual(volume(installed)), "the staging folder is on the installed app's volume")
    expect(try! FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, "the staging folder starts empty")
}

func testBundleValidationRefusesAnythingButOneMatchingApp() {
    let version = UpdateVersion("0.5.0")!
    func validate(_ folder: URL, identifier: String = fixtureIdentifier) -> Result<URL, UpdateFailure> {
        UpdateStaging.validateBundle(in: folder, appName: fixtureAppName, bundleIdentifier: identifier, version: version)
    }
    func refused(_ result: Result<URL, UpdateFailure>, _ why: String) {
        guard case let .failure(failure) = result, case .wrongBundleContents = failure else {
            return expect(false, "a staged folder is refused when \(why)")
        }
    }
    func fresh(_ label: String, _ build: (URL) -> Void) -> Result<URL, UpdateFailure> {
        let folder = makeTemporaryDirectory(label)
        defer { removeTemporaryDirectory(folder) }
        build(folder)
        return validate(folder)
    }

    let good = makeTemporaryDirectory("validate-good")
    defer { removeTemporaryDirectory(good) }
    let app = makeAppBundle(in: good, signingIdentifier: nil)
    try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/inside").path, withDestinationPath: "MacOS/Fixture")
    guard case let .success(found) = validate(good) else {
        return expect(false, "one app with the right name, identifier and version, with a link that stays inside, is accepted")
    }
    expect(found.lastPathComponent == fixtureAppName, "validation returns the staged app")
    refused(validate(good, identifier: "com.example.other"), "the bundle identifier is not the expected one")

    refused(fresh("validate-two") { folder in
        makeAppBundle(in: folder, signingIdentifier: nil)
        try! Data("extra".utf8).write(to: folder.appendingPathComponent("README"))
    }, "it holds two items")
    refused(fresh("validate-empty") { _ in }, "it is empty")
    refused(fresh("validate-name") { folder in
        makeAppBundle(in: folder, name: "Other.app", signingIdentifier: nil)
    }, "the app is not named like the installed app")
    refused(fresh("validate-version") { folder in
        makeAppBundle(in: folder, version: "0.4.9", signingIdentifier: nil)
    }, "its version is not the manifest's")
    let elsewhere = makeTemporaryDirectory("validate-top-link-target")
    defer { removeTemporaryDirectory(elsewhere) }
    makeAppBundle(in: elsewhere, signingIdentifier: nil)
    refused(fresh("validate-top-link") { folder in
        try! FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(fixtureAppName), withDestinationURL: elsewhere.appendingPathComponent(fixtureAppName))
    }, "the app is a symbolic link rather than a folder")
    refused(fresh("validate-absolute-link") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/escape").path, withDestinationPath: "/etc")
    }, "a symbolic link inside points to an absolute path outside")
    refused(fresh("validate-relative-link") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/MacOS/escape").path, withDestinationPath: "../../..")
    }, "a symbolic link inside climbs out of the bundle")
    refused(fresh("validate-root-dotdot-link") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("root").path, withDestinationPath: ".")
        try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("escape").path, withDestinationPath: "root/../outside")
    }, "a symbolic link climbs out through another link that names the bundle itself")
    refused(fresh("validate-dangling-link") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        try! FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/dangling").path, withDestinationPath: "nothing-here")
    }, "a symbolic link points at nothing, so where it leads cannot be checked")
    refused(fresh("validate-fifo") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        expect(mkfifo(app.appendingPathComponent("Contents/pipe").path, 0o600) == 0, "a named pipe can be made")
    }, "it holds a special file (a named pipe stands in for a device, which only root can make)")
    refused(fresh("validate-hard-link") { folder in
        let app = makeAppBundle(in: folder, signingIdentifier: nil)
        expect(link(app.appendingPathComponent("Contents/Info.plist").path, app.appendingPathComponent("Contents/Second.plist").path) == 0, "a hard link can be made")
    }, "a file inside has a second hard link")
}

func testRequirementCheckPassesOnlyForAMatchingSignature() {
    let directory = makeTemporaryDirectory("requirement")
    defer { removeTemporaryDirectory(directory) }
    func app(_ label: String, signingIdentifier: String?) -> URL {
        let folder = directory.appendingPathComponent(label, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return makeAppBundle(in: folder, signingIdentifier: signingIdentifier)
    }

    expect(fixtureRequirement.isSatisfied(byBundleAt: app("match", signingIdentifier: fixtureIdentifier)), "a bundle signed under the required identifier passes")
    expect(!fixtureRequirement.isSatisfied(byBundleAt: app("other", signingIdentifier: "com.example.other")), "a bundle signed under another identifier fails")
    expect(!fixtureRequirement.isSatisfied(byBundleAt: app("unsigned", signingIdentifier: nil)), "an unsigned bundle fails")

    let tampered = app("tampered", signingIdentifier: fixtureIdentifier)
    try! Data("changed after signing".utf8).write(to: tampered.appendingPathComponent("Contents/Resources-added"))
    expect(!fixtureRequirement.isSatisfied(byBundleAt: tampered), "a file added after signing fails strict validation")

    expect(CodeRequirementCheck(requirementText: "this is not a requirement") == nil, "a requirement that does not compile is refused")
    expect(CodeRequirementCheck.runningApp() != nil, "the running program's own designated requirement can be read")
}

/// The argument that makes this runner act as the child of
/// `testRunningAppRequirementIsReadOnceAndCached` instead of running tests.
let cachedRequirementProbeArgument = "--probe-cached-requirement"

/// In the child: reads the running program's requirement, puts
/// `replacement` where the program's own file was, and reads it again.
/// Exits 0 only if the second read still holds the requirement from launch.
func runCachedRequirementProbe(ownPath: String, replacement: String) -> Never {
    let own = URL(fileURLWithPath: ownPath)
    guard let first = CodeRequirementCheck.runningApp(), first.isSatisfied(byBundleAt: own) else {
        print("FAIL: the probe's own requirement is satisfied by its own file")
        exit(2)
    }
    guard rename(replacement, ownPath) == 0 else {
        print("FAIL: the probe's file can be replaced")
        exit(3)
    }
    guard let second = CodeRequirementCheck.runningApp() else {
        print("FAIL: the second read returns a requirement")
        exit(4)
    }
    guard !second.isSatisfied(byBundleAt: own) else {
        print("FAIL: the second read returns the requirement read at launch, not the one now on disk")
        exit(5)
    }
    exit(0)
}

func testRunningAppRequirementIsReadOnceAndCached() {
    let directory = makeTemporaryDirectory("cached-requirement")
    defer { removeTemporaryDirectory(directory) }
    let runner = Bundle.main.executableURL!
    let probe = directory.appendingPathComponent("probe")
    let replacement = directory.appendingPathComponent("replacement")
    try! FileManager.default.copyItem(at: runner, to: probe)
    try! FileManager.default.copyItem(at: runner, to: replacement)
    // Ad hoc signatures under different identifiers have different code
    // directory hashes, so each copy has a designated requirement of its own.
    expect(runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.example.probe-launched", probe.path]) == 0, "codesign signs the probe")
    expect(runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.example.probe-replacement", replacement.path]) == 0, "codesign signs the replacement")

    let process = Process()
    process.executableURL = probe
    process.arguments = [cachedRequirementProbeArgument, probe.path, replacement.path]
    try! process.run()
    process.waitUntilExit()
    expect(
        process.terminationReason == .exit && process.terminationStatus == 0,
        "a second read of the running app's requirement returns the one read at launch, even after the file on disk changed (probe exit \(process.terminationStatus))"
    )
}

func testSelfTestPassesFailsAndTimesOut() async {
    let directory = makeTemporaryDirectory("self-test")
    defer { removeTemporaryDirectory(directory) }
    func app(_ label: String, _ body: String) -> URL {
        let folder = directory.appendingPathComponent(label, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return makeAppBundle(in: folder, executable: .script(body), signingIdentifier: nil)
    }

    let passing = await UpdateStaging.runSelfTest(appURL: app("pass", "[ \"$1\" = --update-self-test ] && [ $# = 1 ] || exit 9"), timeout: .seconds(10))
    expect(passing == nil, "a self-test that exits 0 passes, and it is run with --update-self-test alone")

    let failing = await UpdateStaging.runSelfTest(appURL: app("fail", "exit 3"), timeout: .seconds(10))
    expect(failing == .selfTestFailed(status: 3), "a self-test that exits 3 is a failure")
    expect(failing?.kind == .badRelease, "a self-test that exits with an error is a bad release")
    expect(failing?.reason == "the new version did not start", "a self-test that exits with an error reads as the new version not starting")

    let start = Date()
    let hanging = await UpdateStaging.runSelfTest(appURL: app("hang", "exec sleep 30"), timeout: .milliseconds(500))
    expect(hanging == .selfTestTimedOut, "a self-test that outlives its timeout fails")
    expect(hanging?.kind == .couldPassOnAnotherTry, "a self-test timeout could pass on another try")
    expect(Date().timeIntervalSince(start) < 5, "a hanging self-test is stopped at its timeout, not waited out")

    expect(UpdateStaging.selfTestTimeout == .seconds(10), "the real self-test gets 10 seconds")
}

private func stager(installed: URL, page: FakeReleasePage, requirement: any UpdateRequirementChecking = fixtureRequirement) -> UpdateStager {
    UpdateStager(installedAppURL: installed, bundleIdentifier: fixtureIdentifier, transport: page, requirement: requirement)
}

private func offer(for zip: URL, size: Int64? = nil, sha256: String? = nil) -> UpdateOffer {
    var object = sampleManifestObject(version: "0.5.0")
    object = manifestObject(object, settingApp: "host", field: "bundleIdentifier", to: fixtureIdentifier)
    object = manifestObject(object, settingApp: "host", field: "size", to: size ?? fileSize(of: zip))
    object = manifestObject(object, settingApp: "host", field: "sha256", to: sha256 ?? sha256Hex(of: zip))
    let manifest = try! UpdateManifest.parse(serialized(object))
    return UpdateOffer(version: manifest.version, app: manifest.app(.host))
}

func testStagingASignedReleaseEndToEnd() async {
    let directory = makeTemporaryDirectory("stage")
    defer { removeTemporaryDirectory(directory) }
    let installedFolder = directory.appendingPathComponent("Applications", isDirectory: true)
    try! FileManager.default.createDirectory(at: installedFolder, withIntermediateDirectories: true)
    let installed = makeAppBundle(in: installedFolder, version: "0.4.0")
    let built = directory.appendingPathComponent("built", isDirectory: true)
    try! FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
    let zip = directory.appendingPathComponent("Sensorium-Host-0.5.0.zip")
    zipItem(makeAppBundle(in: built, version: "0.5.0", marker: "new"), to: zip)
    let release = offer(for: zip)
    let address = UpdateReleaseLocation.downloadURL(version: release.version, app: release.app)

    let page = FakeReleasePage()
    page.serve(try! Data(contentsOf: zip), at: address)
    let result = await stager(installed: installed, page: page).stage(release)
    guard case let .success(staged) = result else {
        return expect(false, "a signed release that matches the manifest is staged, got \(result)")
    }
    defer { try? FileManager.default.removeItem(at: staged.directory) }
    expect(page.requests == [.init(url: address, maximumBytes: release.app.size)], "the zip is fetched once, capped at the manifest's size")
    expect(staged.version == release.version && staged.sha256 == release.app.sha256, "the staged update names its release")
    expect(staged.appURL == staged.directory.appendingPathComponent(fixtureAppName), "the staged app sits in the staging folder under the installed app's name")
    expect(marker(of: staged.appURL) == "new", "the staged app is the one from the zip")
    expect(posixMode(of: staged.directory) == 0o700, "the staging folder is owner-only")
    expect(try! FileManager.default.contentsOfDirectory(atPath: staged.directory.path) == [fixtureAppName], "the staging folder holds the app alone")
    expect(staged.readyFileURL.deletingLastPathComponent() == staged.directory, "the ready file lives in the staging folder")
    expect(marker(of: installed) == nil, "staging does not touch the installed app")

    let refusing = await stager(installed: installed, page: page, requirement: FixedRequirement(satisfied: false)).stage(release)
    expect(refusing == .failure(.requirementFailed), "a staged app that fails the requirement check is refused")

    let tooBig = FakeReleasePage()
    tooBig.serve(try! Data(contentsOf: zip) + Data([0]), at: address)
    let oversized = await stager(installed: installed, page: tooBig).stage(release)
    expect(oversized == .failure(.sizeMismatch), "a download that runs past the manifest's size stops as a size mismatch")

    var altered = try! Data(contentsOf: zip)
    altered[altered.count / 2] ^= 0x01
    let alteredPage = FakeReleasePage()
    alteredPage.serve(altered, at: address)
    let mismatched = await stager(installed: installed, page: alteredPage).stage(release)
    expect(mismatched == .failure(.digestMismatch), "a download with one changed byte fails its SHA-256")
    expect(UpdateFailure.digestMismatch.kind == .couldPassOnAnotherTry, "a download that fails its SHA-256 could pass on another try")

    let missing = await stager(installed: installed, page: FakeReleasePage()).stage(release)
    expect(missing == .failure(.downloadFailed), "a download that fails could pass on another try")

    let wrongIdentifier = UpdateStager(installedAppURL: installed, bundleIdentifier: "com.example.other", transport: page, requirement: fixtureRequirement)
    guard case .failure(.wrongBundleContents) = await wrongIdentifier.stage(release) else {
        return expect(false, "a manifest entry for another bundle identifier is refused")
    }
}

func testStagingRefusesAZipWithTwoItems() async {
    let directory = makeTemporaryDirectory("stage-two")
    defer { removeTemporaryDirectory(directory) }
    let installed = makeAppBundle(in: directory, version: "0.4.0")
    let contents = directory.appendingPathComponent("contents", isDirectory: true)
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    makeAppBundle(in: contents, version: "0.5.0")
    try! Data("extra".utf8).write(to: contents.appendingPathComponent("extra.txt"))
    let zip = directory.appendingPathComponent("two.zip")
    zipContents(of: contents, to: zip)
    let release = offer(for: zip)
    let page = FakeReleasePage()
    page.serve(try! Data(contentsOf: zip), at: UpdateReleaseLocation.downloadURL(version: release.version, app: release.app))

    guard case .failure(.wrongBundleContents) = await stager(installed: installed, page: page).stage(release) else {
        return expect(false, "a zip with two top-level items is refused")
    }
}
#endif
