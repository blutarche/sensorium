#if os(macOS)
import Foundation
import SensoriumUpdate

/// Stands in for a launched app: it never runs anything, and quits when
/// asked unless told to ignore the request.
@MainActor
final class FakeLaunchedApp: UpdateLaunchedApp {
    let processIdentifier: pid_t
    let ignoresQuit: Bool
    private(set) var hasExited = false
    private(set) var quitRequests = 0
    private(set) var forceQuits = 0

    init(processIdentifier: pid_t, ignoresQuit: Bool) {
        self.processIdentifier = processIdentifier
        self.ignoresQuit = ignoresQuit
    }

    func requestQuit() {
        quitRequests += 1
        if !ignoresQuit { hasExited = true }
    }

    func forceQuit() {
        forceQuits += 1
        hasExited = true
    }
}

/// Stands in for LaunchServices. Each launch runs the next scripted
/// behaviour, which may write a ready report the way a new instance would.
@MainActor
final class FakeLauncher: UpdateAppLaunching {
    struct Launch {
        let url: URL
        let arguments: [String]
        let markerAtLaunch: String?
    }

    enum Behaviour {
        /// Writes the report as the launched instance.
        case reportReady(UpdateReadyReport)
        /// Writes the report naming process `processIdentifier`, or no
        /// process when it is nil, instead of the launched instance.
        case reportReadyAs(UpdateReadyReport, processIdentifier: pid_t?)
        case staySilent
        case ignoreQuitAndStaySilent
        case failToLaunch
    }

    var behaviours: [Behaviour]
    private(set) var launches: [Launch] = []
    private(set) var apps: [FakeLaunchedApp] = []

    init(_ behaviours: [Behaviour]) {
        self.behaviours = behaviours
    }

    func launch(appAt url: URL, arguments: [String]) async throws -> any UpdateLaunchedApp {
        launches.append(Launch(url: url, arguments: arguments, markerAtLaunch: marker(of: url)))
        let behaviour = behaviours.isEmpty ? .staySilent : behaviours.removeFirst()
        if case .failToLaunch = behaviour {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let ignoresQuit: Bool
        if case .ignoreQuitAndStaySilent = behaviour { ignoresQuit = true } else { ignoresQuit = false }
        let app = FakeLaunchedApp(processIdentifier: pid_t(90_000 + launches.count), ignoresQuit: ignoresQuit)
        apps.append(app)
        if arguments.count == 3 {
            let readyFile = URL(fileURLWithPath: arguments[2])
            switch behaviour {
            case let .reportReady(report):
                try UpdateHandoff.reportReady(report, to: readyFile, processIdentifier: app.processIdentifier)
            case let .reportReadyAs(report, processIdentifier?):
                try UpdateHandoff.reportReady(report, to: readyFile, processIdentifier: processIdentifier)
            case let .reportReadyAs(report, nil):
                writeReportWithoutProcess(report, to: readyFile)
            case .staySilent, .ignoreQuitAndStaySilent, .failToLaunch:
                break
            }
        }
        return app
    }
}

let fastTiming = UpdateInstaller.Timing(
    readyTimeout: .milliseconds(300),
    quitTimeout: .milliseconds(200),
    pollInterval: .milliseconds(20)
)

/// An installed app marked "old" in its own folder, and a staged app marked
/// "new" in a real staging folder on the same volume.
struct InstallFixture {
    let root: URL
    let installed: URL
    let staged: StagedUpdate

    init(_ label: String) {
        root = makeTemporaryDirectory(label)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try! FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        installed = makeAppBundle(in: applications, version: "0.4.0", signingIdentifier: nil, marker: "old")
        let directory = try! UpdateStaging.makeStagingDirectory(appropriateFor: installed)
        let app = makeAppBundle(in: directory, version: "0.5.0", signingIdentifier: nil, marker: "new")
        staged = StagedUpdate(version: UpdateVersion("0.5.0")!, sha256: sampleDigest, directory: directory, appURL: app)
    }

    var stagingExists: Bool {
        FileManager.default.fileExists(atPath: staged.directory.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: staged.directory)
        removeTemporaryDirectory(root)
    }
}

@MainActor
func testInstallabilityRefusesTranslocatedAndUnwritableLocations() {
    let directory = makeTemporaryDirectory("installability")
    defer { removeTemporaryDirectory(directory) }
    let app = makeAppBundle(in: directory, signingIdentifier: nil)
    expect(UpdateInstaller.installability(of: app) == .updatable, "an app in a folder this user can write to is updatable")

    let translocated = URL(fileURLWithPath: "/private/var/folders/xy/abc/T/AppTranslocation/0A1B2C3D/d/Sensorium Host.app")
    expect(UpdateInstaller.installability(of: translocated) == .notUpdatable(.translocated), "a translocated copy is not updatable")

    let locked = directory.appendingPathComponent("locked", isDirectory: true)
    try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let lockedApp = makeAppBundle(in: locked, signingIdentifier: nil)
    chmod(locked.path, 0o500)
    defer { chmod(locked.path, 0o700) }
    if getuid() != 0 {
        expect(UpdateInstaller.installability(of: lockedApp) == .notUpdatable(.folderNotWritable), "an app whose folder this user cannot write to is not updatable")
    } else {
        print("SKIP: running as root, every folder is writable")
    }
}

@MainActor
func testInstallAtQuitSwapsInPlaceAndSwapsBackOnARequirementFailure() async {
    let passing = InstallFixture("quit-install")
    defer { passing.remove() }
    let installer = UpdateInstaller(installedAppURL: passing.installed, requirement: FixedRequirement(satisfied: true), launcher: FakeLauncher([]), timing: fastTiming)
    expect(installer.installWithoutRelaunch(passing.staged) == .installed, "a staged update installs at quit")
    expect(marker(of: passing.installed) == "new", "the new app now sits at the installed path")
    expect(!passing.stagingExists, "the staging folder, holding the old app, is removed")

    let failing = InstallFixture("quit-install-refused")
    defer { failing.remove() }
    let launcher = FakeLauncher([])
    let refusing = UpdateInstaller(installedAppURL: failing.installed, requirement: FixedRequirement(satisfied: false), launcher: launcher, timing: fastTiming)
    expect(refusing.installWithoutRelaunch(failing.staged) == .failed(.requirementFailed), "an installed copy that fails the requirement check is a failure")
    expect(marker(of: failing.installed) == "old", "the old app is swapped back")
    expect(!failing.stagingExists, "the refused new app is removed with its staging folder")
    expect(launcher.launches.isEmpty, "installing at quit launches nothing")
}

/// Fails the requirement check after moving the checked bundle aside, so the
/// old app can no longer be swapped back.
struct SwapBackBreakingRequirement: UpdateRequirementChecking {
    let aside: URL
    func isSatisfied(byBundleAt url: URL) -> Bool {
        try? FileManager.default.moveItem(at: url, to: aside)
        return false
    }
}

@MainActor
func testAFailedSwapBackIsReportedAsSuch() async {
    let atQuit = InstallFixture("swap-back-at-quit")
    defer { atQuit.remove() }
    let quitLauncher = FakeLauncher([])
    let quitInstaller = UpdateInstaller(
        installedAppURL: atQuit.installed,
        requirement: SwapBackBreakingRequirement(aside: atQuit.root.appendingPathComponent("aside.app")),
        launcher: quitLauncher,
        timing: fastTiming
    )
    let quitOutcome = quitInstaller.installWithoutRelaunch(atQuit.staged)
    expect(quitOutcome == .swapBackFailed(.requirementFailed), "a requirement failure whose swap back fails is reported as a failed swap back, got \(quitOutcome)")
    expect(atQuit.stagingExists, "the staging folder, holding the only copy of the old app, is kept")
    expect(marker(of: atQuit.staged.appURL) == "old", "the old app is still in the staging folder")
    expect(quitLauncher.launches.isEmpty, "installing at quit launches nothing")

    for rollback in [UpdateInstaller.Rollback.keepRunning, .relaunchPrevious] {
        let fixture = InstallFixture("swap-back-handoff")
        defer { fixture.remove() }
        let launcher = FakeLauncher([.reportReady(sampleReport(version: "0.4.0"))])
        let installer = UpdateInstaller(
            installedAppURL: fixture.installed,
            requirement: SwapBackBreakingRequirement(aside: fixture.root.appendingPathComponent("aside.app")),
            launcher: launcher,
            timing: fastTiming
        )
        let outcome = await installer.installAndHandOff(fixture.staged, baseline: sampleReport(version: "0.4.0"), rollback: rollback)
        expect(outcome == .swapBackFailed(.requirementFailed), "a handoff whose swap back fails is reported as a failed swap back (\(rollback)), got \(outcome)")
        expect(!outcome.shouldTerminate, "with the old app not back in place, this process stays (\(rollback))")
        expect(outcome.failure == .requirementFailed, "the failure that started the rollback is kept (\(rollback))")
        expect(launcher.launches.isEmpty, "nothing is launched when the old app could not be swapped back (\(rollback))")
        expect(fixture.stagingExists && marker(of: fixture.staged.appURL) == "old", "the old app is kept in the staging folder (\(rollback))")
    }
}

@MainActor
func testSwapFailureLeavesTheInstalledAppAlone() {
    let fixture = InstallFixture("swap-failure")
    defer { fixture.remove() }
    try! FileManager.default.removeItem(at: fixture.staged.appURL)
    let installer = UpdateInstaller(installedAppURL: fixture.installed, requirement: FixedRequirement(satisfied: true), launcher: FakeLauncher([]), timing: fastTiming)
    expect(installer.installWithoutRelaunch(fixture.staged) == .failed(.swapFailed), "a swap that cannot happen is a failure")
    expect(marker(of: fixture.installed) == "old", "the installed app is untouched")
    expect(UpdateFailure.swapFailed.kind == .couldPassOnAnotherTry, "a failed swap could pass on another try")
}

@MainActor
func testHandoffIsAcceptedWhenTheNewVersionReportsTheSameValues() async {
    let fixture = InstallFixture("handoff")
    defer { fixture.remove() }
    let launcher = FakeLauncher([.reportReady(sampleReport(version: "0.5.0"))])
    let installer = UpdateInstaller(installedAppURL: fixture.installed, requirement: FixedRequirement(satisfied: true), launcher: launcher, processIdentifier: 4242, timing: fastTiming)

    let outcome = await installer.installAndHandOff(fixture.staged, baseline: sampleReport(version: "0.4.0"), rollback: .relaunchPrevious)
    expect(outcome == .handedOff, "a new version that reports every value unchanged is accepted, got \(outcome)")
    expect(outcome.shouldTerminate, "after a handoff the old instance quits")
    expect(launcher.launches.count == 1, "the new version is launched once")
    expect(launcher.launches[0].url == fixture.installed, "the new version is launched from the installed path")
    expect(launcher.launches[0].markerAtLaunch == "new", "the swap happens before the launch")
    expect(
        launcher.launches[0].arguments == ["--replacing", "4242", fixture.staged.readyFileURL.path],
        "the new version is told which process it replaces and where to report"
    )
    expect(marker(of: fixture.staged.appURL) == "old", "the old app now sits in the staging folder, for the new instance to remove")
    expect(launcher.apps[0].quitRequests == 0, "an accepted new instance is left running")
}

@MainActor
func testHandoffSwapsBackOnEveryRejection() async {
    func run(_ label: String, _ behaviours: [FakeLauncher.Behaviour], requirement: Bool = true) async -> (UpdateHandoffOutcome, FakeLauncher, InstallFixture) {
        let fixture = InstallFixture(label)
        let launcher = FakeLauncher(behaviours)
        let installer = UpdateInstaller(installedAppURL: fixture.installed, requirement: FixedRequirement(satisfied: requirement), launcher: launcher, timing: fastTiming)
        let outcome = await installer.installAndHandOff(fixture.staged, baseline: sampleReport(version: "0.4.0"), rollback: .keepRunning)
        return (outcome, launcher, fixture)
    }
    func expectRestored(_ fixture: InstallFixture, _ what: String) {
        expect(marker(of: fixture.installed) == "old", "\(what): the old app is swapped back")
        expect(!fixture.stagingExists, "\(what): the staging folder is removed")
        fixture.remove()
    }

    let (late, lateLauncher, lateFixture) = await run("handoff-late", [.staySilent])
    expect(late == .failed(.readyLate), "no ready file within the timeout is a failure, got \(late)")
    expect(!late.shouldTerminate, "a viewer whose Restart Now failed keeps running")
    expect(lateLauncher.apps[0].quitRequests == 1 && lateLauncher.apps[0].forceQuits == 0, "a late new instance is asked to quit")
    expectRestored(lateFixture, "late")

    let (stuck, stuckLauncher, stuckFixture) = await run("handoff-stuck", [.ignoreQuitAndStaySilent])
    expect(stuck == .failed(.readyLate), "a late instance that ignores the request to quit is still a late failure, got \(stuck)")
    expect(stuckLauncher.apps[0].forceQuits == 1, "a new instance that does not quit when asked is forced")
    expectRestored(stuckFixture, "stuck")

    var changed = sampleReport(version: "0.5.0")
    changed.host?.port = 7301
    let (mismatch, mismatchLauncher, mismatchFixture) = await run("handoff-mismatch", [.reportReady(changed)])
    guard case .failed(.readyMismatch) = mismatch else {
        return expect(false, "a ready report whose values differ is a failure, got \(mismatch)")
    }
    expect(mismatchLauncher.apps[0].quitRequests == 1, "a new instance serving with other values is asked to quit")
    expectRestored(mismatchFixture, "mismatch")

    let (unlaunched, _, unlaunchedFixture) = await run("handoff-launch", [.failToLaunch])
    expect(unlaunched == .failed(.launchFailed), "a new version that cannot be opened is a failure, got \(unlaunched)")
    expectRestored(unlaunchedFixture, "launch failure")

    let (unsigned, unsignedLauncher, unsignedFixture) = await run("handoff-requirement", [], requirement: false)
    expect(unsigned == .failed(.requirementFailed), "an installed copy that fails the requirement check is a failure, got \(unsigned)")
    expect(unsignedLauncher.launches.isEmpty, "a copy that fails the requirement check is never launched")
    expectRestored(unsignedFixture, "requirement")
}

@MainActor
func testHandoffAcceptsOnlyAReportFromTheLaunchedProcess() async {
    let cases: [(label: String, processIdentifier: pid_t?, what: String)] = [
        ("handoff-other-process", 4243, "another process"),
        ("handoff-no-process", nil, "no process")
    ]
    for (label, processIdentifier, what) in cases {
        let fixture = InstallFixture(label)
        defer { fixture.remove() }
        let launcher = FakeLauncher([.reportReadyAs(sampleReport(version: "0.5.0"), processIdentifier: processIdentifier)])
        let installer = UpdateInstaller(installedAppURL: fixture.installed, requirement: FixedRequirement(satisfied: true), launcher: launcher, processIdentifier: 4242, timing: fastTiming)
        let outcome = await installer.installAndHandOff(fixture.staged, baseline: sampleReport(version: "0.4.0"), rollback: .keepRunning)
        expect(outcome == .failed(.readyMismatch("process")), "a ready report naming \(what) is refused, got \(outcome)")
        expect(launcher.apps[0].quitRequests == 1, "the launched instance is asked to quit when the report naming \(what) is refused")
        expect(marker(of: fixture.installed) == "old", "the old app is swapped back when the report names \(what)")
    }
}

@MainActor
func testHostRollbackRelaunchesThePreviousVersionThroughTheSameHandoff() async {
    let fixture = InstallFixture("rollback")
    defer { fixture.remove() }
    var changed = sampleReport(version: "0.5.0")
    changed.host?.tailnetAddress = "100.64.1.99"
    let launcher = FakeLauncher([.reportReady(changed), .reportReady(sampleReport(version: "0.4.0"))])
    let installer = UpdateInstaller(installedAppURL: fixture.installed, requirement: FixedRequirement(satisfied: true), launcher: launcher, processIdentifier: 4242, timing: fastTiming)

    let outcome = await installer.installAndHandOff(fixture.staged, baseline: sampleReport(version: "0.4.0"), rollback: .relaunchPrevious)
    guard case .rolledBack(.readyMismatch) = outcome else {
        return expect(false, "a host whose new version reported other values relaunches the previous one, got \(outcome)")
    }
    expect(outcome.shouldTerminate, "once the previous version serves again, the old process quits")
    expect(launcher.launches.count == 2, "the new version, then the previous one, is launched")
    expect(launcher.launches[1].markerAtLaunch == "old", "the previous version is swapped back before it is relaunched")
    expect(launcher.launches[1].url == fixture.installed, "the previous version is relaunched from the installed path")
    expect(launcher.launches[1].arguments == ["--replacing", "4242", fixture.staged.readyFileURL.path], "the previous version is relaunched with the same handoff")
    expect(marker(of: fixture.staged.appURL) == "new", "the rejected new app waits in the staging folder for the relaunched instance to remove")

    let silent = InstallFixture("rollback-silent")
    defer { silent.remove() }
    let silentLauncher = FakeLauncher([.staySilent, .staySilent])
    let silentInstaller = UpdateInstaller(installedAppURL: silent.installed, requirement: FixedRequirement(satisfied: true), launcher: silentLauncher, timing: fastTiming)
    let silentOutcome = await silentInstaller.installAndHandOff(silent.staged, baseline: sampleReport(version: "0.4.0"), rollback: .relaunchPrevious)
    expect(silentOutcome == .rollbackRelaunchFailed(.readyLate), "a previous version that does not come back either is reported, got \(silentOutcome)")
    expect(!silentOutcome.shouldTerminate, "with nothing serving, the old process stays")
    expect(silentLauncher.apps.allSatisfy { $0.quitRequests == 1 }, "both silent instances are asked to quit")
    expect(marker(of: silent.installed) == "old", "the previous version stays installed")
    expect(!silent.stagingExists, "the staging folder is removed")

    let swapFails = InstallFixture("rollback-swap")
    defer { swapFails.remove() }
    try! FileManager.default.removeItem(at: swapFails.staged.appURL)
    let swapLauncher = FakeLauncher([.reportReady(sampleReport(version: "0.4.0"))])
    let swapInstaller = UpdateInstaller(installedAppURL: swapFails.installed, requirement: FixedRequirement(satisfied: true), launcher: swapLauncher, timing: fastTiming)
    let swapOutcome = await swapInstaller.installAndHandOff(swapFails.staged, baseline: sampleReport(version: "0.4.0"), rollback: .relaunchPrevious)
    expect(swapOutcome == .rolledBack(.swapFailed), "a host whose swap failed still hands over to a relaunched copy of itself, got \(swapOutcome)")
    expect(swapLauncher.launches.map(\.markerAtLaunch) == ["old"], "only the previous version is launched")
}
#endif
