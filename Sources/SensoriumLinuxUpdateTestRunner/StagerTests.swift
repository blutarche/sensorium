import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct PublishedRelease {
    let manifest: LinuxUpdateManifest
    let archive: Data
}

/// A release whose binary is a shell script that answers the self-test the
/// way a real viewer does.
private func publishRelease(
    _ text: String,
    on page: FakeReleasePage,
    in directory: URL,
    body: String? = nil,
    entries: [TarEntry]? = nil,
    sha256: String? = nil,
    size: Int64? = nil
) -> PublishedRelease {
    let script = body ?? "#!/bin/sh\n[ \"$1\" = --update-self-test ] || exit 9\necho 'Sensorium \(text)'\n"
    let archiveURL = writeArchive(entries ?? [.binary("Sensorium", script)], in: directory, name: "release-\(UUID().uuidString).tar.gz")
    let archive = try! Data(contentsOf: archiveURL)
    try! FileManager.default.removeItem(at: archiveURL)
    let manifest = LinuxUpdateManifest(
        version: version(text),
        file: LinuxUpdateManifest.archiveFileName(for: version(text)),
        size: size ?? Int64(archive.count),
        sha256: sha256 ?? hexDigest(archive)
    )
    page.serve(archive, at: LinuxUpdateReleaseLocation.downloadURL(for: manifest))
    return PublishedRelease(manifest: manifest, archive: archive)
}

private func entries(of directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

func testStagingASignedReleaseEndToEnd() async {
    let directory = makeTemporaryDirectory("stage")
    defer { removeTemporaryDirectory(directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    expect(installation.installability() == .updatable, "the data root is updatable")
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)
    let page = FakeReleasePage()
    let release = publishRelease("0.6.0", on: page, in: directory)

    let result = await LinuxUpdateStager(installation: installation, transport: page).stage(release.manifest)
    guard case let .success(staged) = result else {
        return expect(false, "a release that matches its manifest and passes its self-test is staged, got \(result)")
    }
    expect(staged.version == version("0.6.0") && staged.sha256 == release.manifest.sha256, "the staged update names its version and archive")
    expect(
        staged.executable.standardizedFileURL == installation.versionDirectory(for: version("0.6.0")).appendingPathComponent("Sensorium").standardizedFileURL,
        "the staged binary is in place at versions/0.6.0/Sensorium"
    )
    expect(posixMode(of: staged.executable) == 0o755, "the staged binary is executable")
    expect(posixMode(of: staged.executable.deletingLastPathComponent()) == 0o700, "its version folder is owner-only")
    expect(entries(of: staged.executable.deletingLastPathComponent()) == ["Sensorium"], "the version folder holds the binary alone")
    expect(entries(of: installation.versionsDirectory) == ["0.5.0", "0.6.0"], "staging leaves no download or staging folder behind")
    expect(
        page.requests == [.init(url: LinuxUpdateReleaseLocation.downloadURL(for: release.manifest), maximumBytes: release.manifest.size)],
        "the archive is fetched once, from the address built from the manifest, capped at the manifest's size"
    )
    expect(installation.currentVersion() == version("0.5.0"), "staging does not switch current")

    expect(installation.switchCurrent(to: staged) == nil, "the staged update can be switched to")
    expect(installation.currentVersion() == version("0.6.0"), "current names the staged version after the switch")
}

func testStagingFailuresAreClassifiedAndLeaveNothingBehind() async {
    let directory = makeTemporaryDirectory("stage-failures")
    defer { removeTemporaryDirectory(directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)

    func stage(_ release: PublishedRelease, on page: FakeReleasePage) async -> LinuxUpdateFailure? {
        let result = await LinuxUpdateStager(installation: installation, transport: page, selfTestTimeout: 2).stage(release.manifest)
        expect(entries(of: installation.versionsDirectory) == ["0.5.0"], "a failed staging leaves only the versions that were there")
        if case let .failure(failure) = result { return failure }
        return nil
    }

    let page = FakeReleasePage()
    let wrongDigest = publishRelease("0.6.0", on: page, in: directory, sha256: String(repeating: "0", count: 64))
    let wrongDigestResult = await stage(wrongDigest, on: page)
    expect(wrongDigestResult == .digestMismatch, "an archive with another digest fails as a mismatch")

    let short = publishRelease("0.6.0", on: page, in: directory, size: 10)
    let shortResult = await stage(short, on: page)
    expect(shortResult == .sizeMismatch, "an archive past the manifest's size fails as a mismatch")

    let unreachable = FakeReleasePage()
    let lost = publishRelease("0.6.0", on: unreachable, in: directory)
    unreachable.fail(LinuxUpdateReleaseLocation.downloadURL(for: lost.manifest))
    let lostResult = await stage(lost, on: unreachable)
    expect(lostResult == .downloadFailed, "a download that fails is a download failure")

    let link = publishRelease("0.6.0", on: page, in: directory, entries: [TarEntry(name: "Sensorium", type: UInt8(ascii: "2"), linkName: "/bin/sh")])
    guard case .wrongArchiveContents = await stage(link, on: page) else {
        return expect(false, "a matching archive that holds a link is the wrong contents")
    }

    let crashing = publishRelease("0.6.0", on: page, in: directory, body: "#!/bin/sh\nexit 1\n")
    let crashingResult = await stage(crashing, on: page)
    expect(crashingResult == .selfTestFailed(status: 1), "a binary whose self-test fails is refused")

    let mislabelled = publishRelease("0.6.0", on: page, in: directory, body: "#!/bin/sh\necho 'Sensorium 0.5.0'\n")
    guard case .wrongArchiveContents = await stage(mislabelled, on: page) else {
        return expect(false, "a binary that reports another version is the wrong contents")
    }

    let hanging = publishRelease("0.6.0", on: page, in: directory, body: "#!/bin/sh\nexec sleep 30\n")
    let hangingResult = await stage(hanging, on: page)
    expect(hangingResult == .selfTestTimedOut, "a binary whose self-test hangs times out")

    // A folder an earlier try left for 0.6.0 is replaced.
    let leftover = placeVersion("0.6.0", in: installation)
    writeFile("stale", to: leftover)
    let good = publishRelease("0.6.0", on: page, in: directory)
    guard case let .success(staged) = await LinuxUpdateStager(installation: installation, transport: page).stage(good.manifest) else {
        return expect(false, "a version folder left by an earlier try is replaced")
    }
    expect((try? String(contentsOf: staged.executable, encoding: .utf8))?.contains("Sensorium 0.6.0") == true, "the replaced folder holds the new binary")

    pointCurrent(at: "0.6.0", in: installation)
    let running = publishRelease("0.6.0", on: page, in: directory)
    let refused = await LinuxUpdateStager(installation: installation, transport: page).stage(running.manifest)
    expect(refused == .failure(.stagingFailed), "the version current names is never replaced")
    expect(entries(of: installation.versionsDirectory) == ["0.5.0", "0.6.0"], "a refused replacement leaves no staging folder")
}
