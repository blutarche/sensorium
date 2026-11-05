#if os(Linux)
import Foundation
import Glibc
import SensoriumClient
import SensoriumCore
import SensoriumLinuxUpdate

private let linuxRunning = LinuxUpdateVersion("0.4.0")!
private let linuxNext = LinuxUpdateVersion("0.5.0")!
private let linuxDigest = String(repeating: "ab", count: 32)

private func linuxManifest(_ version: LinuxUpdateVersion) -> LinuxUpdateManifest {
    LinuxUpdateManifest(version: version, file: LinuxUpdateManifest.archiveFileName(for: version), size: 1024, sha256: linuxDigest)
}

private func linuxStaged(_ version: LinuxUpdateVersion) -> LinuxStagedUpdate {
    LinuxStagedUpdate(version: version, sha256: linuxDigest, executable: URL(fileURLWithPath: "/nonexistent/Sensorium"))
}

private func makeLinuxUpdaterDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-linux-updater-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    chmod(url.path, 0o700)
    return url
}

/// Puts `version` in place under `versions` and points `current` at it, as
/// an earlier install would have.
private func placeLinuxVersion(_ version: LinuxUpdateVersion, in installation: LinuxUpdateInstallation) {
    let folder = installation.versionDirectory(for: version)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    chmod(installation.versionsDirectory.path, 0o700)
    chmod(folder.path, 0o700)
    FileManager.default.createFile(atPath: folder.appendingPathComponent("Sensorium").path, contents: Data("#!/bin/sh\n".utf8))
    chmod(folder.appendingPathComponent("Sensorium").path, 0o755)
}

@MainActor
private final class LinuxUpdaterHarness {
    let directory: URL
    let installation: LinuxUpdateInstallation
    let stateStore: LinuxUpdateStateStore
    let preferences = InMemoryViewerUpdatePreferencesStore()
    var checkResult: LinuxUpdateCheckResult = .upToDate
    var restartOutcome: LinuxUpdateRestartOutcome = .tookOver
    private(set) var restarts: [LinuxStagedUpdate] = []
    private(set) var adoptions = 0
    private(set) var terminations = 0
    private(set) var lines: [ViewerUpdateLine?] = []
    private(set) var updater: LinuxViewerUpdater!

    init(
        label: String,
        installability: LinuxUpdateInstallability = .updatable,
        replacing: ViewerReplacement? = nil,
        runningVersion: LinuxUpdateVersion = linuxRunning,
        directory: URL? = nil
    ) {
        self.directory = directory ?? makeLinuxUpdaterDirectory(label)
        let dataRoot = self.directory.appendingPathComponent("sensorium", isDirectory: true)
        installation = LinuxUpdateInstallation(dataRoot: dataRoot)
        stateStore = LinuxUpdateStateStore(dataRoot: dataRoot)
        updater = LinuxViewerUpdater(
            runningVersion: runningVersion,
            installation: installation,
            installability: installability,
            stateStore: stateStore,
            preferences: preferences,
            replacing: replacing,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            check: { [unowned self] in self.checkResult },
            stage: { .success(linuxStaged($0.version)) },
            restart: { [unowned self] staged in
                self.restarts.append(staged)
                return self.restartOutcome
            },
            adoptLauncherEntry: { [unowned self] in self.adoptions += 1 },
            onTerminate: { [unowned self] in self.terminations += 1 },
            log: { _ in }
        )
        updater.onLineChange = { [unowned self] in self.lines.append($0) }
    }

    func cleanUp() {
        updater.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The Linux viewer's update line follows the scheduler through a chosen
/// check, and an answered check is cleared the next time the window shows.
@MainActor
func testLinuxViewerUpdaterManualCheckTests() async {
    let harness = LinuxUpdaterHarness(label: "manual")
    defer { harness.cleanUp() }
    expect(harness.updater.line == nil, "nothing to say at launch")
    expect(harness.updater.checksAutomatically, "automatic checks are on by default")
    await harness.updater.checkForUpdates()
    expect(harness.lines.contains { $0?.text == "Checking for updates\u{2026}" }, "a chosen check says it is checking, got \(harness.lines)")
    expect(harness.updater.line?.text == "Sensorium 0.4.0 is up to date.", "and is answered up to date, got \(String(describing: harness.updater.line))")
    harness.updater.windowDidShow()
    expect(harness.updater.line == nil, "an answered check is cleared the next time Your Machines shows")

    harness.checkResult = .unreachable
    await harness.updater.checkForUpdates()
    expect(harness.updater.line == nil, "a check that reached nothing does not claim up to date, got \(String(describing: harness.updater.line))")

    harness.updater.setChecksAutomatically(false)
    expect(!harness.preferences.checksAutomatically() && !harness.updater.checksAutomatically, "turning automatic checks off is remembered")
    harness.updater.setChecksAutomatically(true)
    expect(harness.preferences.checksAutomatically(), "and on again")

    let stuck = LinuxUpdaterHarness(label: "stuck", installability: .notUpdatable(.dataRootNotOwned))
    defer { stuck.cleanUp() }
    expect(
        stuck.updater.line?.text == "Sensorium cannot update itself because it cannot write to its own folder.",
        "a viewer that cannot install says so, got \(String(describing: stuck.updater.line))"
    )
    print("PASS: the Linux viewer's update line answers a chosen check and says when it cannot update")
}

/// **Restart Now** runs only with no session live, hands over to the new
/// version and quits, or stays with the reason it did not take.
@MainActor
func testLinuxViewerUpdaterRestartNowTests() async {
    let harness = LinuxUpdaterHarness(label: "restart")
    defer { harness.cleanUp() }
    harness.checkResult = .available(linuxManifest(linuxNext))
    await harness.updater.checkForUpdates()
    expect(
        harness.updater.line == ViewerUpdateLine(text: "Sensorium 0.5.0 is ready.", offersRestartNow: true),
        "a staged update offers Restart Now, got \(String(describing: harness.updater.line))"
    )

    harness.updater.sessionRunChanged(true)
    expect(
        harness.updater.line == ViewerUpdateLine(text: "Sensorium 0.5.0 is ready.", offersRestartNow: false),
        "while a session runs the line stays without Restart Now, got \(String(describing: harness.updater.line))"
    )
    await harness.updater.restartNow()
    expect(harness.restarts.isEmpty, "and a restart is refused")
    harness.updater.sessionRunChanged(false)
    expect(harness.updater.line?.offersRestartNow == true, "once the session ends, Restart Now is back")

    harness.restartOutcome = .failed(.readyLate)
    await harness.updater.restartNow()
    expect(harness.restarts == [linuxStaged(linuxNext)], "Restart Now hands the staged update over")
    expect(harness.terminations == 0, "a restart that did not take keeps this viewer running")
    expect(
        harness.updater.line == ViewerUpdateLine(
            text: "Sensorium could not update: \(LinuxUpdateFailure.readyLate.reason). It keeps running 0.4.0.",
            offersRestartNow: false,
            isFailure: true
        ),
        "and says why, got \(String(describing: harness.updater.line))"
    )
    expect(
        harness.stateStore.load().failure(version: linuxNext, sha256: linuxDigest)?.tries == 1,
        "the failed try is recorded against that release"
    )

    harness.checkResult = .available(linuxManifest(linuxNext))
    await harness.updater.checkForUpdates()
    harness.restartOutcome = .tookOver
    await harness.updater.restartNow()
    expect(harness.terminations == 1, "a new version that took over ends this one")
    expect(harness.updater.line?.offersRestartNow == false, "and no second Restart Now is offered meanwhile")
    print("PASS: Restart Now is refused during a session, hands over, and keeps running with the reason when it does not take")
}

/// A new version started with `--replacing` reports ready once its window
/// is up, then confirms the switch and adopts the launcher entry. One that
/// finds nothing to confirm quits, since the old viewer is still running.
@MainActor
func testLinuxViewerUpdaterConfirmsAReplacingLaunchTests() async {
    let directory = makeLinuxUpdaterDirectory("replacing")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    expect(installation.installability() == .updatable, "a fresh data root is updatable")
    placeLinuxVersion(linuxRunning, in: installation)
    placeLinuxVersion(linuxNext, in: installation)
    expect((try? installation.switchCurrent(to: linuxStaged(linuxNext)).get()) != nil, "the old viewer switched current")

    let handoff = try! LinuxUpdateHandoff.makeFolder(in: installation)
    let readyFile = handoff.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    let replacing = ViewerReplacement(pid: 4242, readyFile: readyFile)
    let harness = LinuxUpdaterHarness(label: "replacing", replacing: replacing, runningVersion: linuxNext, directory: directory)
    expect(harness.updater.rollBackUnconfirmedSwitch() == nil, "the awaited version does not roll its own switch back")
    expect(installation.currentVersion() == linuxNext, "so current still names it")

    harness.updater.windowDidShow()
    expect(installation.pendingSwitch() == nil, "the window being up confirms the switch")
    expect(
        LinuxUpdateHandoff.readReport(at: readyFile) == LinuxUpdateReadyReport(processIdentifier: getpid(), version: linuxNext),
        "and the ready file names this process and version"
    )
    expect(harness.adoptions == 1, "and the launcher entry is adopted, after the confirmation")
    expect(harness.terminations == 0, "the confirmed new version keeps running")
    harness.updater.windowDidShow()
    expect(harness.adoptions == 1, "a later show does nothing more")

    let late = LinuxUpdaterHarness(label: "late", replacing: replacing, runningVersion: linuxNext)
    defer { late.cleanUp() }
    late.updater.windowDidShow()
    expect(late.terminations == 1, "a replacing launch with nothing to confirm quits")
    expect(late.adoptions == 0, "and adopts nothing")
    print("PASS: a replacing launch reports ready, confirms, then adopts the launcher entry, or quits with nothing to confirm")
}

/// A new version that cannot write its ready file leaves the switch
/// unconfirmed, so the old viewer, which never sees the file, finds the
/// switch as it made it and puts the previous version back.
@MainActor
func testLinuxViewerUpdaterDoesNotConfirmWithoutAReadyFileTests() async {
    let directory = makeLinuxUpdaterDirectory("unreported")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    expect(installation.installability() == .updatable, "a fresh data root is updatable")
    placeLinuxVersion(linuxRunning, in: installation)
    expect((try? installation.switchCurrent(to: linuxStaged(linuxRunning)).get()) != nil, "an earlier switch to the running version")
    expect(installation.markConfirmed(version: linuxRunning) == .confirmed, "was confirmed")
    placeLinuxVersion(linuxNext, in: installation)
    let switched = try! installation.switchCurrent(to: linuxStaged(linuxNext)).get()

    let missingFolder = installation.dataRoot.appendingPathComponent(".handoff-missing", isDirectory: true)
    let replacing = ViewerReplacement(pid: 4242, readyFile: missingFolder.appendingPathComponent(LinuxUpdateHandoff.readyFileName))
    let harness = LinuxUpdaterHarness(label: "unreported", replacing: replacing, runningVersion: linuxNext, directory: directory)
    harness.updater.windowDidShow()
    expect(installation.pendingSwitch() == switched, "a new version that could not report ready leaves the switch unconfirmed")
    expect(harness.adoptions == 0, "and adopts no launcher entry")
    expect(installation.rollBack(switched) == .rolledBack(switched), "so the old viewer's switch back finds it")
    expect(installation.currentVersion() == linuxRunning, "and current names the previous version again")
    print("PASS: a replacing launch that cannot report ready does not confirm, and the old viewer goes back")
}

/// Launch removes the staging and handoff folders an interrupted update
/// left behind.
@MainActor
func testLinuxViewerUpdaterRemovesAbandonedWorkFoldersAtLaunchTests() async {
    let harness = LinuxUpdaterHarness(label: "abandoned")
    defer { harness.cleanUp() }
    expect(harness.installation.installability() == .updatable, "a fresh data root is updatable")
    let old = Date().addingTimeInterval(-2 * LinuxUpdateInstallation.abandonedFolderAge)
    let staging = harness.installation.versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    let handoff = harness.installation.dataRoot.appendingPathComponent(".handoff-\(UUID().uuidString)", isDirectory: true)
    for folder in [staging, handoff] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
    }
    harness.updater.start()
    expect(
        !FileManager.default.fileExists(atPath: staging.path) && !FileManager.default.fileExists(atPath: handoff.path),
        "launch removes the staging and handoff folders an interrupted update left behind"
    )
    print("PASS: launch removes the work folders an interrupted update left behind")
}

/// Before any window, a launch that is not the awaited version rolls an
/// unconfirmed switch back and records it against that release.
@MainActor
func testLinuxViewerUpdaterRollsBackAtLaunchTests() async {
    let directory = makeLinuxUpdaterDirectory("rollback")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    _ = installation.installability()
    placeLinuxVersion(linuxRunning, in: installation)
    expect((try? installation.switchCurrent(to: linuxStaged(linuxRunning)).get()) != nil, "a first switch to the running version")
    expect(installation.markConfirmed(version: linuxRunning) == .confirmed, "is confirmed")
    placeLinuxVersion(linuxNext, in: installation)
    expect((try? installation.switchCurrent(to: linuxStaged(linuxNext)).get()) != nil, "then a switch the new version never confirmed")

    let harness = LinuxUpdaterHarness(label: "rollback", runningVersion: linuxRunning, directory: directory)
    let rolledBack = harness.updater.rollBackUnconfirmedSwitch()
    expect(rolledBack?.version == linuxNext, "a plain launch rolls the unconfirmed switch back, got \(String(describing: rolledBack))")
    expect(installation.currentVersion() == linuxRunning, "current names the earlier version again")
    expect(
        harness.stateStore.load().failure(version: linuxNext, sha256: linuxDigest)?.reason == LinuxUpdateFailure.readyLate.reason,
        "and the release is recorded as not starting in time"
    )
    expect(harness.updater.rollBackUnconfirmedSwitch() == nil, "a second launch finds nothing pending")

    expect(
        LinuxViewerUpdater.runningVersion(ViewerRelease.version) == LinuxUpdateVersion(ViewerRelease.version),
        "a release build updates itself"
    )
    expect(LinuxViewerUpdater.runningVersion("development") == nil, "a development build has no updater")
    let route = ViewerLaunchRoute.route(["--replacing", "4242", "/home/someone/.local/share/sensorium/.handoff-1/update-ready.json"])
    expect(
        route == .viewer(arguments: [], replacing: ViewerReplacement(
            pid: 4242, readyFile: URL(fileURLWithPath: "/home/someone/.local/share/sensorium/.handoff-1/update-ready.json")
        )),
        "the Linux launch route takes the replacing launch before the viewer's own parsing"
    )
    expect(ViewerLaunchRoute.route(["--update-self-test"]) == .updateSelfTest, "and the self-test")
    print("PASS: a launch rolls back a switch the new version never confirmed, and records it")
}
#else
func testLinuxViewerUpdaterManualCheckTests() async {}
func testLinuxViewerUpdaterRestartNowTests() async {}
func testLinuxViewerUpdaterConfirmsAReplacingLaunchTests() async {}
func testLinuxViewerUpdaterDoesNotConfirmWithoutAReadyFileTests() async {}
func testLinuxViewerUpdaterRemovesAbandonedWorkFoldersAtLaunchTests() async {}
func testLinuxViewerUpdaterRollsBackAtLaunchTests() async {}
#endif
