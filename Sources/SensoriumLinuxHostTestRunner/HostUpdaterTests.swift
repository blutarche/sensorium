#if os(Linux)
import Foundation
import Glibc
import SensoriumLinuxHost
import SensoriumLinuxUpdate

private let serving = LinuxUpdateReadyReport.Host(
    tlsCertificateFingerprint: "aa11",
    deviceIdentityFingerprint: "bb22",
    pairedMachinesDigest: "cc33",
    listenAddress: "100.64.1.5",
    port: 7777,
    screenSharingAllowed: true
)

@MainActor
private final class FakeHost: LinuxHostUpdateServing {
    var idle = false
    var serves: LinuxUpdateReadyReport.Host? = serving
    /// What `suspendForUpdate` finds, which can differ from `idle` when a
    /// machine connects between the two looks.
    var idleAtSuspend: Bool?
    var suspendCount = 0
    var resumeCount = 0

    func isIdleForUpdate(now: Date) -> Bool { idle }
    func updateIdleRecheckDate(now: Date) -> Date? { nil }
    func suspendForUpdate() async -> LinuxUpdateReadyReport.Host? {
        guard idleAtSuspend ?? idle else { return nil }
        suspendCount += 1
        return serves
    }
    func resumeAfterUpdate() async { resumeCount += 1 }
    func servingValues() -> LinuxUpdateReadyReport.Host? { serves }
}

@MainActor
private final class UpdaterRig {
    let folder: URL
    let installation: LinuxUpdateInstallation
    let host = FakeHost()
    var updater: LinuxHostUpdater!
    var checks = 0
    var handOvers: [(LinuxStagedUpdate, LinuxUpdateReadyReport.Host)] = []
    var handOverResult: LinuxUpdateRestartOutcome = .tookOver
    var failedHandovers = 0
    var confirms = 0
    var terminations = 0
    var parent: pid_t = 4242
    var checkResult: LinuxUpdateCheckResult

    static let next = LinuxUpdateManifest(
        version: LinuxUpdateVersion("0.8.0")!,
        file: "Sensorium-Host-0.8.0-linux-x86_64.tar.gz",
        size: 1,
        sha256: String(repeating: "a", count: 64)
    )

    init(running: String = "0.7.0", replacing: LinuxHostReplacement? = nil, checkResult: LinuxUpdateCheckResult = .available(UpdaterRig.next)) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorium-host-updater-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sensorium-host", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        installation = LinuxUpdateInstallation(dataRoot: folder, app: .host)
        self.checkResult = checkResult
        updater = LinuxHostUpdater(
            runningVersion: LinuxUpdateVersion(running)!,
            installation: installation,
            installability: installation.installability(),
            stateStore: LinuxUpdateStateStore(dataRoot: folder, app: .host),
            host: host,
            replacing: replacing,
            parentProcess: { [unowned self] in self.parent },
            parentPollInterval: .milliseconds(20),
            check: { [unowned self] in
                self.checks += 1
                return self.checkResult
            },
            stage: { [unowned self] manifest in
                .success(LinuxStagedUpdate(
                    version: manifest.version, sha256: manifest.sha256,
                    executable: self.installation.versionDirectory(for: manifest.version).appendingPathComponent("sensorium-host")
                ))
            },
            handOver: { [unowned self] staged, baseline in
                self.handOvers.append((staged, baseline))
                return self.handOverResult
            },
            afterFailedHandover: { [unowned self] in self.failedHandovers += 1 },
            afterConfirm: { [unowned self] in self.confirms += 1 },
            onTerminate: { [unowned self] in self.terminations += 1 },
            log: { _ in }
        )
    }

    func finish() {
        updater.stop()
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }
}

private let waiting = HostWindowUpdateLine(text: "Sensorium Host 0.8.0 will install when no machine is connected.", isFailure: false)

@MainActor
private func testAStagedUpdateWaitsUntilTheHostIsIdleThenHandsOver() async {
    let rig = UpdaterRig()
    expect(rig.updater.line == nil, "a host that has not checked says nothing")
    rig.updater.hostDidStart()
    await expectEventually("the update is staged and waits") { rig.updater.line == waiting }
    expect(rig.checks == 1, "a launch checks once")
    expect(rig.handOvers.isEmpty, "a busy host does not hand over")

    rig.updater.hostActivityChanged()
    try? await Task.sleep(for: .milliseconds(100))
    expect(rig.handOvers.isEmpty, "nor does a change that leaves it busy")

    rig.host.idle = true
    rig.updater.hostActivityChanged()
    await expectEventually("an idle host hands over") { rig.terminations == 1 }
    expect(rig.handOvers.count == 1, "once")
    expect(rig.handOvers.first?.0.version == UpdaterRig.next.version, "to the staged version")
    expect(rig.handOvers.first?.1 == serving, "with how the host served for the new one to match")
    expect(rig.host.resumeCount == 0, "and a host handed over does not serve again")
    rig.finish()
}

@MainActor
private func testAFailedHandoverServesAgainAndAMachineThatConnectsHoldsItBack() async {
    let rig = UpdaterRig()
    rig.host.idle = true
    rig.host.idleAtSuspend = false
    rig.updater.hostDidStart()
    await expectEventually("the update is staged") { rig.updater.line == waiting }
    try? await Task.sleep(for: .milliseconds(100))
    expect(rig.handOvers.isEmpty && rig.host.suspendCount == 0, "a machine that connects before the listener stops holds the update back")

    rig.host.idleAtSuspend = nil
    rig.handOverResult = .failed(.readyLate)
    rig.updater.hostActivityChanged()
    await expectEventually("a handover that fails serves again") { rig.host.resumeCount == 1 }
    expect(rig.failedHandovers == 1, "and takes back the rest of what it gave up")
    expect(rig.terminations == 0, "and keeps running")
    rig.finish()
}

@MainActor
private func testAnAnsweredCheckSaysUpToDate() async {
    let rig = UpdaterRig(checkResult: .upToDate)
    rig.updater.hostDidStart()
    await expectEventually("an answered check says so") {
        rig.updater.line == HostWindowUpdateLine(text: "Sensorium Host 0.7.0 is up to date.", isFailure: false)
    }
    rig.finish()
}

@MainActor
private func testAReplacingHostReportsReadyOnceItServesAndChecksAfterTheOldHostExits() async {
    let readyFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-host-ready-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: readyFolder, withIntermediateDirectories: true)
    // The old host makes the folder owner-only, and nothing else is written to.
    chmod(readyFolder.path, 0o700)
    defer { try? FileManager.default.removeItem(at: readyFolder) }
    let readyFile = readyFolder.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    let rig = UpdaterRig(running: "0.8.0", replacing: LinuxHostReplacement(pid: 4242, readyFile: readyFile), checkResult: .upToDate)

    let version = LinuxUpdateVersion("0.8.0")!
    let executable = rig.installation.versionDirectory(for: version).appendingPathComponent("sensorium-host")
    try! FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    guard case .success = rig.installation.switchCurrent(to: LinuxStagedUpdate(version: version, sha256: String(repeating: "b", count: 64), executable: executable)) else {
        return expect(false, "the old host's switch was made")
    }
    expect(rig.updater.rollBackUnconfirmedSwitch() == nil, "the version the old host started keeps its pending switch")

    rig.host.serves = nil
    rig.updater.hostDidStart()
    expect(LinuxUpdateHandoff.readReport(at: readyFile) == nil, "a new host that does not listen yet reports nothing")
    rig.host.serves = serving
    rig.updater.hostActivityChanged()
    expect(
        LinuxUpdateHandoff.readReport(at: readyFile) == LinuxUpdateReadyReport(processIdentifier: getpid(), version: version, host: serving),
        "once it listens it reports ready with how it serves"
    )
    expect(rig.installation.pendingSwitch() == nil, "and confirms the switch")
    rig.updater.hostActivityChanged()

    // The old host can still refuse the report and switch back, so the
    // launcher and Open at login wait until it has exited.
    try? await Task.sleep(for: .milliseconds(150))
    expect(rig.confirms == 0, "it adopts nothing while the host it replaced runs")
    expect(rig.checks == 0, "and checks for nothing")
    rig.parent = 1
    await expectEventually("once that host has exited it adopts the launcher entry and Open at login") { rig.confirms == 1 }
    await expectEventually("and checks for updates") { rig.checks == 1 }
    expect(rig.confirms == 1, "once")
    expect(rig.terminations == 0, "a confirmed host keeps running")
    rig.finish()
}

@MainActor
private func testAReplacingHostWithNothingToConfirmQuits() async {
    let readyFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-host-ready-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: readyFolder, withIntermediateDirectories: true)
    // The old host makes the folder owner-only, and nothing else is written to.
    chmod(readyFolder.path, 0o700)
    defer { try? FileManager.default.removeItem(at: readyFolder) }
    let readyFile = readyFolder.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    let rig = UpdaterRig(running: "0.8.0", replacing: LinuxHostReplacement(pid: 4242, readyFile: readyFile), checkResult: .upToDate)
    rig.updater.hostDidStart()
    expect(rig.terminations == 1, "a new host the old one already gave up on quits")
    expect(rig.confirms == 0, "and adopts nothing")
    rig.finish()
}

func hostUpdaterTests() -> [NamedTest] { [
    ("a staged update waits until the host is idle, then hands over", testAStagedUpdateWaitsUntilTheHostIsIdleThenHandsOver),
    ("a failed handover serves again, and a machine that connects holds it back", testAFailedHandoverServesAgainAndAMachineThatConnectsHoldsItBack),
    ("an answered check says the host is up to date", testAnAnsweredCheckSaysUpToDate),
    ("a replacing host reports ready once it serves, and checks after the old host exits", testAReplacingHostReportsReadyOnceItServesAndChecksAfterTheOldHostExits),
    ("a replacing host with nothing to confirm quits", testAReplacingHostWithNothingToConfirmQuits)
] }
#endif
