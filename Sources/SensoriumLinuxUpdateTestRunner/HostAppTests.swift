import Foundation
import SensoriumLinuxUpdate

/// The host updates through the same engine as the viewer, with its own
/// release files, folder and names.
func testTheHostHasItsOwnReleaseFilesFolderAndNames() {
    let host = LinuxUpdateApp.host
    expect(host.binaryName == "sensorium-host", "the host's binary is sensorium-host")
    expect(
        LinuxUpdateManifest.archiveFileName(for: version("0.8.0"), app: .host) == "Sensorium-Host-0.8.0-linux-x86_64.tar.gz",
        "the host's archive is Sensorium-Host-<version>-linux-x86_64.tar.gz"
    )
    expect(
        LinuxUpdateReleaseLocation.manifestURL(for: .host).absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-host-update-linux-x86_64.json",
        "the host reads its own manifest"
    )
    expect(
        LinuxUpdateReleaseLocation.signatureURL(for: .host).absoluteString
            == "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-host-update-linux-x86_64.json.sig",
        "the host reads its own manifest's signature"
    )
    let home = URL(fileURLWithPath: "/home/ada", isDirectory: true)
    expect(
        LinuxUpdateInstallation.defaultDataRoot(app: .host, environment: [:], homeDirectory: home).path
            == "/home/ada/.local/share/sensorium-host",
        "the host installs into its own data folder"
    )
    let installation = LinuxUpdateInstallation(dataRoot: URL(fileURLWithPath: "/home/ada/.local/share/sensorium-host", isDirectory: true), app: .host)
    expect(
        installation.currentExecutable.path == "/home/ada/.local/share/sensorium-host/current/sensorium-host",
        "the host runs current/sensorium-host"
    )
    expect(
        LinuxUpdateStateStore(dataRoot: installation.dataRoot, app: .host).url.lastPathComponent == "host-update-state.json",
        "the host keeps its own update state"
    )
    expect(LinuxUpdateApp.viewer.binaryName == "Sensorium", "the viewer's binary stays Sensorium")
}

/// One key signs both manifests, so each app must refuse the other's.
func testEachAppRefusesTheOthersManifest() async {
    let directory = makeTemporaryDirectory("cross-manifest")
    defer { removeTemporaryDirectory(directory) }
    let signer = SigningKey()
    let viewerManifest = serialized(sampleManifestObject(version: "0.8.0"))
    var hostObject = sampleManifestObject(version: "0.8.0")
    hostObject["file"] = "Sensorium-Host-0.8.0-linux-x86_64.tar.gz"
    let hostManifest = serialized(hostObject)

    let wrongPage = FakeReleasePage()
    wrongPage.publish(viewerManifest, signedWith: signer.privateKey, app: .host)
    let hostChecker = LinuxUpdateChecker(
        runningVersion: version("0.7.0"),
        transport: wrongPage,
        stateStore: LinuxUpdateStateStore(dataRoot: directory, app: .host),
        app: .host,
        publicKey: signer.publicKey
    )
    let hostResult = await hostChecker.check()
    expect(hostResult == .failed(.manifestInvalid), "a host refuses a signed manifest that names the viewer's archive, got \(hostResult)")

    let swappedPage = FakeReleasePage()
    swappedPage.publish(hostManifest, signedWith: signer.privateKey, app: .viewer)
    let viewerChecker = LinuxUpdateChecker(
        runningVersion: version("0.7.0"),
        transport: swappedPage,
        stateStore: LinuxUpdateStateStore(dataRoot: directory),
        publicKey: signer.publicKey
    )
    let viewerResult = await viewerChecker.check()
    expect(viewerResult == .failed(.manifestInvalid), "a viewer refuses a signed manifest that names the host's archive, got \(viewerResult)")

    let rightPage = FakeReleasePage()
    rightPage.publish(hostManifest, signedWith: signer.privateKey, app: .host)
    let offered = await LinuxUpdateChecker(
        runningVersion: version("0.7.0"),
        transport: rightPage,
        stateStore: LinuxUpdateStateStore(dataRoot: directory, app: .host),
        app: .host,
        publicKey: signer.publicKey
    ).check()
    guard case let .available(manifest) = offered else {
        return expect(false, "a host offers its own signed manifest, got \(offered)")
    }
    expect(
        LinuxUpdateReleaseLocation.downloadURL(for: manifest).absoluteString
            == "https://github.com/blutarche/sensorium/releases/download/v0.8.0/Sensorium-Host-0.8.0-linux-x86_64.tar.gz",
        "the host downloads its own archive"
    )
}

func testTheHostArchiveHoldsSensoriumHostAlone() {
    let directory = makeTemporaryDirectory("host-archive")
    defer { removeTemporaryDirectory(directory) }
    let good = writeArchive([.binary("sensorium-host")], in: directory, name: "good.tar.gz")
    let out = directory.appendingPathComponent("good", isDirectory: true)
    try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
    switch LinuxUpdateArchive.extract(good, into: out, app: .host) {
    case let .success(binary):
        expect(binary.lastPathComponent == "sensorium-host", "the host archive extracts sensorium-host")
        expect(posixMode(of: binary) == 0o755, "the host binary is executable")
    case let .failure(failure):
        expect(false, "a host archive with sensorium-host alone extracts, got \(failure)")
    }

    let viewer = writeArchive([.binary("Sensorium")], in: directory, name: "viewer.tar.gz")
    let refused = directory.appendingPathComponent("refused", isDirectory: true)
    try! FileManager.default.createDirectory(at: refused, withIntermediateDirectories: false)
    guard case .failure(.wrongArchiveContents) = LinuxUpdateArchive.extract(viewer, into: refused, app: .host) else {
        return expect(false, "a host refuses the viewer's archive")
    }
}

func testTheHostSelfTestPrintsSensoriumHostAndItsVersion() async {
    let directory = makeTemporaryDirectory("host-self-test")
    defer { removeTemporaryDirectory(directory) }
    let binary = directory.appendingPathComponent("sensorium-host")
    writeFile("#!/bin/sh\n[ \"$1\" = --update-self-test ] || exit 9\necho \"$SELF_TEST_LINE\"\n", to: binary, mode: 0o755)

    func run(_ line: String) async -> LinuxUpdateFailure? {
        setenv("SELF_TEST_LINE", line, 1)
        defer { unsetenv("SELF_TEST_LINE") }
        return await LinuxUpdateStaging.runSelfTest(executable: binary, version: version("0.8.0"), app: .host)
    }
    let passed = await run("Sensorium Host 0.8.0")
    expect(passed == nil, "a host that prints Sensorium Host and its version passes, got \(String(describing: passed))")
    let viewerLine = await run("Sensorium 0.8.0")
    guard case .wrongArchiveContents = viewerLine else {
        return expect(false, "a host binary that reports itself as the viewer is the wrong file")
    }
}

func testTheHostLauncherEntryRunsCurrentWithNoFieldCode() {
    let directory = makeTemporaryDirectory("host-launcher")
    defer { removeTemporaryDirectory(directory) }
    let root = directory.appendingPathComponent("share/sensorium-host", isDirectory: true)
    let packaged = directory.appendingPathComponent("packaged/com.sensorium.host.desktop")
    writeFile("[Desktop Entry]\nType=Application\nName=Sensorium Host\nExec=sensorium-host\nIcon=com.sensorium.host\n", to: packaged)
    let packagedIcons = directory.appendingPathComponent("packaged-icons", isDirectory: true)
    writeFile("png", to: packagedIcons.appendingPathComponent("hicolor/48x48/apps/com.sensorium.host.png"))
    let applications = directory.appendingPathComponent("applications", isDirectory: true)
    let icons = directory.appendingPathComponent("icons", isDirectory: true)

    do {
        try LinuxUpdateLauncherEntry.install(
            app: .host,
            dataRoot: root,
            packagedDesktopFile: packaged,
            packagedIconsDirectory: packagedIcons,
            applicationsDirectory: applications,
            iconsDirectory: icons
        )
    } catch {
        return expect(false, "the host's launcher entry is written, got \(error)")
    }
    let written = try? String(contentsOf: applications.appendingPathComponent("com.sensorium.host.desktop"), encoding: .utf8)
    expect(
        written?.contains("\nExec=\(root.path)/current/sensorium-host\n") == true,
        "the host's entry runs current/sensorium-host with no field code, got \(String(describing: written))"
    )
    expect(
        FileManager.default.fileExists(atPath: icons.appendingPathComponent("hicolor/48x48/apps/com.sensorium.host.png").path),
        "the host's icons are copied"
    )
}
