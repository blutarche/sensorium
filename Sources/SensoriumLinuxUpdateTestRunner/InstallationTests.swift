import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Writes `versions/<version>/Sensorium` as an installed version would be.
@discardableResult
func placeVersion(_ text: String, in installation: LinuxUpdateInstallation) -> URL {
    let folder = installation.versionDirectory(for: version(text))
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    chmod(installation.versionsDirectory.path, 0o700)
    chmod(folder.path, 0o700)
    let binary = folder.appendingPathComponent("Sensorium")
    writeFile("#!/bin/sh\necho 'Sensorium \(text)'\n", to: binary, mode: 0o755)
    return binary
}

func pointCurrent(at text: String, in installation: LinuxUpdateInstallation) {
    unlink(installation.currentLink.path)
    expect(symlink("versions/\(text)", installation.currentLink.path) == 0, "a test can point current at \(text)")
}

func staged(_ text: String, in installation: LinuxUpdateInstallation, sha256: String = sampleDigest) -> LinuxStagedUpdate {
    LinuxStagedUpdate(version: version(text), sha256: sha256, executable: placeVersion(text, in: installation))
}

private func names(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private func versionNames(_ installation: LinuxUpdateInstallation) -> [String] {
    names(in: installation.versionsDirectory).filter { !$0.hasPrefix(".") }
}

private func makeInstallation(_ directory: URL) -> LinuxUpdateInstallation {
    let root = directory.appendingPathComponent("sensorium", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    chmod(root.path, 0o700)
    return LinuxUpdateInstallation(dataRoot: root)
}

func testDataRootFollowsTheXDGRuleAndNamesTheLayout() {
    let home = URL(fileURLWithPath: "/home/ada", isDirectory: true)
    expect(
        LinuxUpdateInstallation.defaultDataRoot(environment: ["XDG_DATA_HOME": "/home/ada/data"], homeDirectory: home).path
            == "/home/ada/data/sensorium",
        "XDG_DATA_HOME names the data root's parent"
    )
    expect(
        LinuxUpdateInstallation.defaultDataRoot(environment: [:], homeDirectory: home).path == "/home/ada/.local/share/sensorium",
        "without XDG_DATA_HOME the data root is ~/.local/share/sensorium"
    )
    expect(
        LinuxUpdateInstallation.defaultDataRoot(environment: ["XDG_DATA_HOME": ""], homeDirectory: home).path == "/home/ada/.local/share/sensorium",
        "an empty XDG_DATA_HOME falls back to the default"
    )

    let installation = LinuxUpdateInstallation(dataRoot: URL(fileURLWithPath: "/home/ada/.local/share/sensorium", isDirectory: true))
    expect(installation.versionsDirectory.path == "/home/ada/.local/share/sensorium/versions", "versions live in versions/")
    expect(installation.versionDirectory(for: version("0.6.0")).path == "/home/ada/.local/share/sensorium/versions/0.6.0", "one folder per version")
    expect(installation.currentLink.path == "/home/ada/.local/share/sensorium/current", "the running version is current")
    expect(installation.currentExecutable.path == "/home/ada/.local/share/sensorium/current/Sensorium", "the launcher runs current/Sensorium")
    expect(installation.pendingMarker.path == "/home/ada/.local/share/sensorium/update-pending.json", "the pending marker sits in the data root")
}

func testInstallabilityRefusesAnUnsafeDataRoot() {
    let directory = makeTemporaryDirectory("installability")
    defer { removeTemporaryDirectory(directory) }

    let fresh = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("share/sensorium", isDirectory: true))
    expect(fresh.installability() == .updatable, "a data root that does not exist yet is made and is updatable")
    expect(posixMode(of: fresh.dataRoot) == 0o700, "a data root the engine makes is owner-only")

    let installation = makeInstallation(directory)
    expect(installation.installability() == .updatable, "an owner-only data root is updatable")
    expect(
        installation.installability(userID: getuid() + 1) == .notUpdatable(.dataRootNotOwned),
        "a data root another account owns is not updatable"
    )
    for mode: mode_t in [0o770, 0o707, 0o777] {
        chmod(installation.dataRoot.path, mode)
        expect(
            installation.installability() == .notUpdatable(.dataRootWritableByOthers),
            "a data root of mode \(String(mode, radix: 8)) is not updatable"
        )
    }
    chmod(installation.dataRoot.path, 0o755)
    expect(installation.installability() == .updatable, "a data root others may only read is updatable")
    if geteuid() != 0 {
        chmod(installation.dataRoot.path, 0o500)
        expect(installation.installability() == .notUpdatable(.dataRootNotWritable), "a data root this user cannot write is not updatable")
    } else {
        print("SKIP: running as root, every folder is writable")
    }
    chmod(installation.dataRoot.path, 0o700)

    try! FileManager.default.createDirectory(at: installation.versionsDirectory, withIntermediateDirectories: false)
    chmod(installation.versionsDirectory.path, 0o777)
    expect(installation.installability() == .notUpdatable(.versionsFolderUnsafe), "a versions folder others may write is not updatable")
    try! FileManager.default.removeItem(at: installation.versionsDirectory)
    let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
    try! FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    expect(symlink(elsewhere.path, installation.versionsDirectory.path) == 0, "a test can link the versions folder away")
    expect(installation.installability() == .notUpdatable(.versionsFolderUnsafe), "a versions folder that is a link is not updatable")
    unlink(installation.versionsDirectory.path)

    try! FileManager.default.createDirectory(at: installation.currentLink, withIntermediateDirectories: false)
    expect(installation.installability() == .notUpdatable(.currentNotALink), "a current that is a real folder is not updatable")
    try! FileManager.default.removeItem(at: installation.currentLink)

    let file = directory.appendingPathComponent("a-file")
    writeFile("x", to: file)
    expect(
        LinuxUpdateInstallation(dataRoot: file).installability() == .notUpdatable(.dataRootNotADirectory),
        "a data root that is a file is not updatable"
    )
}

func testStagingFoldersAreFreshAndOwnerOnly() {
    let directory = makeTemporaryDirectory("staging-folder")
    defer { removeTemporaryDirectory(directory) }
    let installation = makeInstallation(directory)

    let first = try! installation.makeStagingDirectory()
    let second = try! installation.makeStagingDirectory()
    expect(first != second, "each staging folder is new")
    expect(first.deletingLastPathComponent().standardizedFileURL == installation.versionsDirectory.standardizedFileURL, "staging happens under the versions folder")
    expect(posixMode(of: first) == 0o700 && posixMode(of: installation.versionsDirectory) == 0o700, "the staging and versions folders are owner-only")
    expect(names(in: first).isEmpty, "a staging folder starts empty")
    expect(LinuxUpdateVersion(first.lastPathComponent) == nil, "a staging folder is never mistaken for a version")
}

func testSwitchWritesThePendingMarkerThenMovesCurrentInOneStep() {
    let directory = makeTemporaryDirectory("switch")
    defer { removeTemporaryDirectory(directory) }
    let installation = makeInstallation(directory)
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)
    expect(installation.currentVersion() == version("0.5.0"), "current names the running version")

    let update = staged("0.6.0", in: installation)
    expect(
        installation.switchCurrent(to: update) == .success(LinuxUpdatePendingSwitch(version: version("0.6.0"), sha256: sampleDigest, previous: version("0.5.0"))),
        "the switch succeeds and names the version it switched from"
    )
    expect(symlinkTarget(of: installation.currentLink) == "versions/0.6.0", "current is a relative link to the new version")
    expect(installation.currentVersion() == version("0.6.0"), "current names the new version")
    expect(
        installation.pendingSwitch() == LinuxUpdatePendingSwitch(version: version("0.6.0"), sha256: sampleDigest, previous: version("0.5.0")),
        "the pending marker names the new version, its archive and the version to go back to"
    )
    expect(posixMode(of: installation.pendingMarker) == 0o600, "the pending marker is owner-only")
    expect(
        names(in: installation.dataRoot).filter { $0.hasPrefix(".current") }.isEmpty,
        "the switch leaves no temporary link behind"
    )

    let missing = LinuxStagedUpdate(version: version("0.7.0"), sha256: sampleDigest, executable: installation.versionDirectory(for: version("0.7.0")).appendingPathComponent("Sensorium"))
    expect(installation.switchCurrent(to: missing) == .failure(.switchFailed), "a version that is not in place is never switched to")
    expect(installation.currentVersion() == version("0.6.0"), "a refused switch leaves current alone")

    let fromPackage = makeInstallation(directory.appendingPathComponent("package", isDirectory: true))
    expect(fromPackage.currentVersion() == nil, "a viewer from the package has no current yet")
    expect((try? fromPackage.switchCurrent(to: staged("0.6.0", in: fromPackage)).get()) != nil, "the first switch succeeds")
    expect(fromPackage.pendingSwitch()?.previous == nil, "the first switch has no version to go back to")
}

func testAnUnconfirmedSwitchIsRolledBack() {
    let directory = makeTemporaryDirectory("rollback")
    defer { removeTemporaryDirectory(directory) }
    let installation = makeInstallation(directory)
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)

    expect(installation.rollbackIfUnconfirmed(startup: .normal) == .nothingPending, "with no pending marker nothing rolls back")

    _ = installation.switchCurrent(to: staged("0.6.0", in: installation))
    let pending = installation.pendingSwitch()!
    expect(
        installation.rollbackIfUnconfirmed(startup: .replacing(version("0.6.0"))) == .awaitingConfirmation(pending),
        "the new version started with --replacing is the one the switch waits on"
    )
    expect(installation.currentVersion() == version("0.6.0"), "waiting on the new version keeps it current")

    expect(installation.rollbackIfUnconfirmed(startup: .normal) == .rolledBack(pending), "a launch that finds a pending switch rolls it back")
    expect(installation.currentVersion() == version("0.5.0"), "current is the previous version again")
    expect(installation.pendingSwitch() == nil, "the pending marker is removed")
    expect(versionNames(installation) == ["0.5.0", "0.6.0"], "rolling back removes no version")
    expect(installation.markConfirmed(version: version("0.6.0")) == .nothingPending, "a version confirmed after its rollback stays rolled back")
    expect(installation.currentVersion() == version("0.5.0"), "a late confirmation does not switch current again")

    _ = installation.switchCurrent(to: staged("0.6.0", in: installation))
    let again = installation.pendingSwitch()!
    expect(
        installation.rollbackIfUnconfirmed(startup: .replacing(version("0.7.0"))) == .rolledBack(again),
        "a --replacing start of another version than the pending one rolls back"
    )

    let late = try! installation.switchCurrent(to: staged("0.6.0", in: installation)).get()
    expect(installation.rollBack(late) == .rolledBack(late), "the old viewer rolls back when the ready file is late")
    expect(installation.currentVersion() == version("0.5.0"), "after a late ready file current is the previous version")

    // The marker is gone, as a confirmation leaves it, and the old viewer's
    // wait ran out all the same.
    let confirmedLate = try! installation.switchCurrent(to: staged("0.6.0", in: installation)).get()
    expect(installation.markConfirmed(version: version("0.6.0")) == .confirmed, "the new version confirms")
    expect(installation.rollBack(confirmedLate) == .rolledBack(confirmedLate), "the old viewer still rolls back the switch it made")
    expect(
        installation.currentVersion() == version("0.5.0") && installation.pendingSwitch() == nil,
        "current is the previous version again, with no marker"
    )

    let reported = try! installation.switchCurrent(to: staged("0.6.0", in: installation)).get()
    expect(
        installation.rollBack(reported, unlessReported: { true }) == .awaitingConfirmation(reported),
        "a ready report found under the lock keeps the switch"
    )
    expect(
        installation.currentVersion() == version("0.6.0") && installation.pendingSwitch() == reported,
        "current stays on the new version, which confirms the switch itself"
    )
    expect(installation.rollBack(reported) == .rolledBack(reported), "without a report the same switch rolls back")

    let undone = try! installation.switchCurrent(to: staged("0.6.0", in: installation)).get()
    _ = installation.rollbackIfUnconfirmed(startup: .normal)
    pointCurrent(at: "0.4.0", in: installation)
    expect(installation.rollBack(undone) == .nothingPending, "a switch already undone elsewhere is left as it is")
    expect(installation.currentVersion() == version("0.4.0"), "and current is not moved")
    pointCurrent(at: "0.5.0", in: installation)

    // An interrupted rollback: current already back, the marker still there.
    _ = installation.switchCurrent(to: staged("0.6.0", in: installation))
    let interrupted = installation.pendingSwitch()!
    pointCurrent(at: "0.5.0", in: installation)
    expect(installation.rollbackIfUnconfirmed(startup: .normal) == .rolledBack(interrupted), "an interrupted rollback finishes at the next launch")
    expect(installation.currentVersion() == version("0.5.0") && installation.pendingSwitch() == nil, "the finished rollback leaves the previous version and no marker")

    let fromPackage = makeInstallation(directory.appendingPathComponent("package", isDirectory: true))
    _ = fromPackage.switchCurrent(to: staged("0.6.0", in: fromPackage))
    guard case .rolledBack = fromPackage.rollbackIfUnconfirmed(startup: .normal) else {
        return expect(false, "an unconfirmed first update rolls back")
    }
    expect(fileType(of: fromPackage.currentLink) == nil, "rolling back a first update removes current, leaving the package's viewer")

    writeFile("{ not json", to: installation.pendingMarker, mode: 0o600)
    expect(installation.rollbackIfUnconfirmed(startup: .normal) == .nothingPending, "an unreadable pending marker is discarded")
    expect(fileType(of: installation.pendingMarker) == nil, "the unreadable marker is removed")
    expect(installation.currentVersion() == version("0.5.0"), "an unreadable marker leaves current alone")
}

func testConfirmationRemovesTheMarkerAndKeepsTwoPreviousVersions() {
    let directory = makeTemporaryDirectory("confirm")
    defer { removeTemporaryDirectory(directory) }
    let installation = makeInstallation(directory)
    for text in ["0.3.0", "0.4.0", "0.5.0", "0.9.0"] {
        placeVersion(text, in: installation)
    }
    pointCurrent(at: "0.5.0", in: installation)
    let staging = try! installation.makeStagingDirectory()
    let unrelated = installation.versionsDirectory.appendingPathComponent("notes")
    writeFile("kept", to: unrelated)

    _ = installation.switchCurrent(to: staged("0.6.0", in: installation))
    expect(installation.markConfirmed(version: version("0.7.0")) == .notPending, "confirming another version than the pending one changes nothing")
    expect(installation.pendingSwitch() != nil, "the marker stays for the version it names")
    expect(versionNames(installation) == ["0.3.0", "0.4.0", "0.5.0", "0.6.0", "0.9.0", "notes"], "nothing is pruned before the switch is confirmed")

    expect(installation.markConfirmed(version: version("0.6.0")) == .confirmed, "the new version confirms its switch")
    expect(installation.pendingSwitch() == nil, "confirmation removes the pending marker")
    expect(installation.currentVersion() == version("0.6.0"), "confirmation keeps the new version current")
    expect(
        versionNames(installation) == ["0.4.0", "0.5.0", "0.6.0", "notes"],
        "after a confirmed switch the two previous versions are kept and every other version is removed"
    )
    expect(fileType(of: staging) == S_IFDIR, "a staging folder is not a version and is left alone")
    expect(installation.markConfirmed(version: version("0.6.0")) == .nothingPending, "confirming twice does nothing more")

    pointCurrent(at: "0.4.0", in: installation)
    _ = installation.switchCurrent(to: staged("0.5.0", in: installation))
    expect(installation.markConfirmed(version: version("0.5.0")) == .confirmed, "a switch to an older version confirms too")
    expect(versionNames(installation) == ["0.4.0", "0.5.0", "notes"], "versions newer than current are not previous versions and are removed")
}

private func makeFolder(_ url: URL, modified: Date) {
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    chmod(url.path, 0o700)
    try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

func testAbandonedWorkFoldersAreRemovedOnlyWhenOldAndExactlyNamed() {
    let directory = makeTemporaryDirectory("abandoned")
    defer { removeTemporaryDirectory(directory) }
    let installation = makeInstallation(directory)
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)
    let now = Date()
    let old = now.addingTimeInterval(-2 * 60 * 60)
    let recent = now.addingTimeInterval(-30 * 60)
    expect(LinuxUpdateInstallation.abandonedFolderAge == 60 * 60, "a work folder is abandoned an hour after it last changed")

    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    writeFile("kept", to: outside.appendingPathComponent("file"))
    makeFolder(outside, modified: old)

    let staleStaging = installation.versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    writeFile("partial", to: staleStaging.appendingPathComponent("Sensorium-0.6.0-linux-x86_64.tar.gz"))
    expect(symlink(outside.path, staleStaging.appendingPathComponent("link").path) == 0, "a test can put a link in a stale folder")
    makeFolder(staleStaging, modified: old)
    let staleHandoff = installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)", isDirectory: true)
    makeFolder(staleHandoff, modified: old)

    let freshStaging = installation.versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    makeFolder(freshStaging, modified: recent)
    let freshHandoff = installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)", isDirectory: true)
    makeFolder(freshHandoff, modified: recent)
    let linkedStaging = installation.versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
    expect(symlink(outside.path, linkedStaging.path) == 0, "a test can link a staging name to another folder")
    let linkedHandoff = installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)")
    expect(symlink(outside.path, linkedHandoff.path) == 0, "a test can link a handoff name to another folder")
    let lowercase = installation.versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString.lowercased())", isDirectory: true)
    makeFolder(lowercase, modified: old)
    let notAUUID = installation.dataRoot.appendingPathComponent(".handoff-notes", isDirectory: true)
    makeFolder(notAUUID, modified: old)
    let suffixed = installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)-copy", isDirectory: true)
    makeFolder(suffixed, modified: old)
    let wrongPlace = installation.dataRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    makeFolder(wrongPlace, modified: old)
    let plainFile = installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)")
    writeFile("x", to: plainFile)
    try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: plainFile.path)

    let asSomeoneElse = installation.removeAbandonedWorkFolders(now: now, userID: getuid() + 1)
    expect(asSomeoneElse.isEmpty, "folders another account owns are left alone")
    expect(fileType(of: staleStaging) == S_IFDIR && fileType(of: staleHandoff) == S_IFDIR, "and are still there")

    let removed = installation.removeAbandonedWorkFolders(now: now)
    expect(
        Set(removed.map(\.lastPathComponent)) == [staleStaging.lastPathComponent, staleHandoff.lastPathComponent],
        "an old staging folder and an old handoff folder are removed, got \(removed.map(\.lastPathComponent))"
    )
    expect(fileType(of: staleStaging) == nil && fileType(of: staleHandoff) == nil, "and are gone")
    expect(fileType(of: outside.appendingPathComponent("file")) == S_IFREG, "a link inside a removed folder is not followed")
    for kept in [freshStaging, freshHandoff, lowercase, notAUUID, suffixed, wrongPlace] {
        expect(fileType(of: kept) == S_IFDIR, "\(kept.lastPathComponent) is kept")
    }
    expect(fileType(of: linkedStaging) == S_IFLNK && fileType(of: linkedHandoff) == S_IFLNK, "a link with a work folder's name is kept")
    expect(fileType(of: plainFile) == S_IFREG, "a file with a work folder's name is kept")
    expect(installation.currentVersion() == version("0.5.0") && fileType(of: installation.versionDirectory(for: version("0.5.0"))) == S_IFDIR, "versions are never touched")

    let linkedVersions = makeInstallation(directory.appendingPathComponent("linked", isDirectory: true))
    let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
    let elsewhereStaging = elsewhere.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    makeFolder(elsewhereStaging, modified: old)
    expect(symlink(elsewhere.path, linkedVersions.versionsDirectory.path) == 0, "a test can link the versions folder away")
    expect(linkedVersions.removeAbandonedWorkFolders(now: now).isEmpty, "a versions folder that is a link is not looked into")
    expect(fileType(of: elsewhereStaging) == S_IFDIR, "and what it links to is left alone")
}
