#if os(macOS)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumUpdate

// MARK: - Helpers

private func makeUpdateTestDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-viewer-update-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeUpdateTestDirectory(_ url: URL) {
    if let walker = FileManager.default.enumerator(atPath: url.path) {
        for case let relative as String in walker {
            chmod(url.appendingPathComponent(relative).path, 0o700)
        }
    }
    chmod(url.path, 0o700)
    try? FileManager.default.removeItem(at: url)
}

private func permissions(of url: URL) -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return -1 }
    return Int(info.st_mode & 0o7777)
}

/// Every entry's name, size, mode and modification time, so a check that
/// nothing was written, created, removed or touched compares one value.
private func snapshot(of directory: URL) -> [String] {
    var lines: [String] = []
    var info = stat()
    if lstat(directory.path, &info) == 0 {
        lines.append(". \(info.st_mode) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names.sorted() {
        var entry = stat()
        guard lstat(directory.appendingPathComponent(name).path, &entry) == 0 else { continue }
        lines.append("\(name) \(entry.st_size) \(entry.st_mode) \(entry.st_mtimespec.tv_sec).\(entry.st_mtimespec.tv_nsec)")
    }
    return lines
}

private let viewerTestVersion = UpdateVersion("0.4.0")!

private func viewerTestOffer(_ version: String) -> UpdateOffer {
    let viewerDigest = String(repeating: "ab", count: 32)
    let hostDigest = String(repeating: "cd", count: 32)
    let json = """
    {"format":1,"version":"\(version)","minimumMacOS":"13.0","apps":{\
    "viewer":{"bundleIdentifier":"com.sensorium.viewer","file":"Sensorium-\(version).zip","size":1024,"sha256":"\(viewerDigest)"},\
    "host":{"bundleIdentifier":"com.sensorium.host","file":"Sensorium-Host-\(version).zip","size":1024,"sha256":"\(hostDigest)"}}}
    """
    let manifest = try! UpdateManifest.parse(Data(json.utf8))
    return UpdateOffer(version: manifest.version, app: manifest.app(.viewer))
}

/// A staged update whose folder is never created: nothing here installs it.
private func viewerTestStaged(_ offer: UpdateOffer) -> StagedUpdate {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-never-created-\(UUID().uuidString)", isDirectory: true)
    return StagedUpdate(
        version: offer.version,
        sha256: offer.app.sha256,
        directory: directory,
        appURL: directory.appendingPathComponent("Sensorium.app")
    )
}

// MARK: - Launch routing

/// `--update-self-test` and `--replacing` are taken before the viewer's own
/// parsing, which ends any argument it does not know with a usage message
/// and exit status 2.
func testViewerLaunchRouteTests() {
    expect(
        ViewerLaunchRoute.route(["--update-self-test"]) == .updateSelfTest,
        "--update-self-test alone is the self-test, answered before ViewerApplication.run parses anything"
    )
    let readyFile = "/tmp/sensorium-staging/update-ready.json"
    expect(
        ViewerLaunchRoute.route(["--replacing", "4242", readyFile])
            == .viewer(arguments: [], replacing: ViewerReplacement(pid: 4242, readyFile: URL(fileURLWithPath: readyFile))),
        "--replacing <pid> <ready file> launches the viewer with no arguments of its own and a report to write"
    )
    expect(ViewerLaunchRoute.route([]) == .viewer(arguments: [], replacing: nil), "no arguments is a plain launch")
    let ordinary = ["enter", "sensorium://enter/mini.local", "--transport", "quic"]
    expect(
        ViewerLaunchRoute.route(ordinary) == .viewer(arguments: ordinary, replacing: nil),
        "every other argument reaches the viewer untouched"
    )
    expect(
        ViewerLaunchRoute.route(["--update-self-test", "enter"])
            == .viewer(arguments: ["--update-self-test", "enter"], replacing: nil),
        "only the exact self-test form is the self-test"
    )
    print("PASS: the self-test and the replacing launch are routed before the viewer's own argument parsing")
}

// MARK: - Self-test

func testViewerUpdateSelfTestTests() throws {
    let directory = makeUpdateTestDirectory("self-test")
    defer { removeUpdateTestDirectory(directory) }

    let absent = directory.appendingPathComponent("absent", isDirectory: true)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: absent) == 0, "no folder at all passes")
    expect(!FileManager.default.fileExists(atPath: absent.path), "and the self-test does not create it")
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) == 0, "an empty folder passes")

    let savedHosts = directory.appendingPathComponent("saved-host.json")
    let identityFile = directory.appendingPathComponent("device-identity.json")
    let host = SavedHost(
        displayName: "Studio",
        host: "studio.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([1, 2, 3]),
        tlsCertificateHash: Data([4, 5, 6])
    )
    try SavedHostFileCoding.encode([host])!.write(to: savedHosts)
    try FileDeviceIdentityStore(url: identityFile).store(DeviceIdentity.generate())
    // What the app's own stores would tidy away on reading. The self-test
    // leaves them, since tidying is a write.
    try Data("partial".utf8).write(to: directory.appendingPathComponent(".saved-host.json.partial-test"))
    try Data("partial".utf8).write(to: directory.appendingPathComponent(".device-identity.json.partial-test"))

    var before = snapshot(of: directory)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) == 0, "readable machines and a readable key pass")
    expect(snapshot(of: directory) == before, "and the self-test changes nothing in the folder")

    let single = try JSONEncoder().encode(host)
    try single.write(to: savedHosts)
    before = snapshot(of: directory)
    expect(
        ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) == 0,
        "a single saved machine, the shape an older viewer wrote, passes"
    )
    expect(snapshot(of: directory) == before, "and is not rewritten into a list")

    try Data("{ not json".utf8).write(to: savedHosts)
    before = snapshot(of: directory)
    expect(
        ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) != 0,
        "a saved-machines file that does not parse fails, where the app would read it as no machines"
    )
    expect(snapshot(of: directory) == before, "and the failing self-test changes nothing either")
    try SavedHostFileCoding.encode([host])!.write(to: savedHosts)

    let goodIdentity = try Data(contentsOf: identityFile)
    try Data(#"{"privateKey":"not base64!"}"#.utf8).write(to: identityFile)
    before = snapshot(of: directory)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) != 0, "a key file holding no key fails")
    expect(snapshot(of: directory) == before, "and nothing replaces it")
    try Data(#"{"privateKey":"AAAA"}"#.utf8).write(to: identityFile)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) != 0, "a key of the wrong length fails")
    try goodIdentity.write(to: identityFile)

    chmod(savedHosts.path, 0)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) != 0, "a file that exists but cannot be read fails")
    chmod(savedHosts.path, 0o600)
    expect(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) == 0, "and passes again once it can be")
    print("PASS: the update self-test reads the saved machines and this machine's key, fails only on a file it cannot read, and writes nothing")
}

// MARK: - Preference

func testViewerUpdatePreferencesTests() {
    expect(
        FileViewerUpdatePreferencesStore.fileName == "viewer-update-preferences.json",
        "the file is named for the viewer, since the host shares the folder"
    )
    expect(ViewerUpdatePreferencesFileCoding.decode(Data("{ not json".utf8)), "a file that does not parse reads as on")
    expect(
        ViewerUpdatePreferencesFileCoding.encode(false).map(ViewerUpdatePreferencesFileCoding.decode) == false,
        "off survives a round trip through the file's own coding"
    )

    let root = makeUpdateTestDirectory("preferences")
    defer { removeUpdateTestDirectory(root) }
    let folder = root.appendingPathComponent("Sensorium", isDirectory: true)
    let file = folder.appendingPathComponent(FileViewerUpdatePreferencesStore.fileName)
    let store = FileViewerUpdatePreferencesStore(url: file)
    expect(store.checksAutomatically(), "automatic updates are on with nothing saved")
    expect(!FileManager.default.fileExists(atPath: folder.path), "and reading creates nothing")
    store.remember(checksAutomatically: false)
    expect(!FileViewerUpdatePreferencesStore(url: file).checksAutomatically(), "off is remembered for the next launch")
    expect(permissions(of: file) == 0o600, "the file is the owner's alone, got \(String(permissions(of: file), radix: 8))")
    expect(permissions(of: folder) == 0o700, "and so is its folder, got \(String(permissions(of: folder), radix: 8))")
    store.remember(checksAutomatically: true)
    expect(FileViewerUpdatePreferencesStore(url: file).checksAutomatically(), "and on again")

    let memory = InMemoryViewerUpdatePreferencesStore(checksAutomatically: false)
    memory.remember(checksAutomatically: true)
    expect(memory.checksAutomatically(), "the in-memory store remembers too")
    print("PASS: Check for Updates Automatically is on by default and remembered in an owner-only file named for the viewer")
}

// MARK: - The line

func testViewerUpdateLineTests() {
    let next = UpdateVersion("0.5.0")!
    func line(
        _ status: UpdateStatus,
        manualCheck: ViewerManualCheck = .none,
        sessionInProgress: Bool = false,
        isRestarting: Bool = false,
        restartFailureReason: String? = nil
    ) -> ViewerUpdateLine? {
        ViewerUpdateLine.make(
            status: status,
            runningVersion: viewerTestVersion,
            manualCheck: manualCheck,
            sessionInProgress: sessionInProgress,
            isRestarting: isRestarting,
            restartFailureReason: restartFailureReason
        )
    }

    expect(
        line(.ready(next)) == ViewerUpdateLine(text: "Sensorium 0.5.0 is ready.", offersRestartNow: true),
        "a staged update says so, with Restart Now, got \(String(describing: line(.ready(next))))"
    )
    expect(
        line(.ready(next), sessionInProgress: true) == ViewerUpdateLine(text: "Sensorium 0.5.0 is ready.", offersRestartNow: false),
        "while a session runs or a session window is open, the line stays and Restart Now does not"
    )
    expect(
        line(.ready(next), isRestarting: true)?.offersRestartNow == false,
        "nor while a restart is already under way"
    )
    expect(ViewerUpdateLine.restartNowTitle == "Restart Now", "the button says Restart Now")

    expect(line(.checking, manualCheck: .pending)?.text == "Checking for updates\u{2026}", "a chosen check says it is checking")
    expect(line(.downloading(next), manualCheck: .pending)?.text == "Checking for updates\u{2026}", "until it has an answer")
    expect(line(.checking) == nil, "an automatic check says nothing")
    expect(line(.downloading(next)) == nil, "nor does an automatic download")
    expect(
        line(.current, manualCheck: .answered(upToDate: true))
            == ViewerUpdateLine(text: "Sensorium 0.4.0 is up to date.", offersRestartNow: false),
        "a chosen check that found nothing newer names the running version"
    )
    expect(
        line(.current, manualCheck: .answered(upToDate: false)) == nil,
        "a chosen check that could not reach the release page does not claim up to date"
    )
    expect(line(.current) == nil, "up to date with no check chosen says nothing")
    expect(line(.waiting(next)) == nil, "an update waiting for its next try says nothing")

    expect(
        line(.failed(reason: "the download did not match the release"))?.text
            == "Sensorium could not update: the download did not match the release.",
        "a failure names its reason"
    )
    expect(
        line(.ready(next), restartFailureReason: "the new version did not start in time")
            == ViewerUpdateLine(text: "Sensorium could not update: the new version did not start in time.", offersRestartNow: false),
        "a Restart Now that did not take says why, whatever the status"
    )
    expect(
        line(.notUpdatable)?.text == "Move Sensorium to Applications and open it again to receive updates.",
        "an app that cannot replace itself says where to move it"
    )
    print("PASS: the Your Machines update line says ready, checking, up to date, failed or not updatable, and offers Restart Now only with no session")
}

// MARK: - The updater

@MainActor
private final class FakeViewerUpdateInstaller: ViewerUpdateInstalling {
    var quitOutcome: UpdateQuitInstallOutcome = .installed
    var handOffOutcome: UpdateHandoffOutcome = .handedOff
    /// Holds a handoff in progress until the test opens it.
    var handOffGate: CheckGate?
    private(set) var quitInstalls: [StagedUpdate] = []
    private(set) var handOffs: [(staged: StagedUpdate, baseline: UpdateReadyReport, rollback: UpdateInstaller.Rollback)] = []

    func installWithoutRelaunch(_ staged: StagedUpdate) -> UpdateQuitInstallOutcome {
        quitInstalls.append(staged)
        return quitOutcome
    }

    func installAndHandOff(
        _ staged: StagedUpdate,
        baseline: UpdateReadyReport,
        rollback: UpdateInstaller.Rollback
    ) async -> UpdateHandoffOutcome {
        handOffs.append((staged, baseline, rollback))
        if let handOffGate { await handOffGate.wait() }
        return handOffOutcome
    }
}

/// Holds a check until the test lets it answer.
@MainActor
private final class CheckGate {
    private var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }

    func wait() async {
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }
}

private final class FinishedReplacements: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(pid: pid_t, readyFile: URL, appName: String)] = []

    var all: [(pid: pid_t, readyFile: URL, appName: String)] { lock.withLock { calls } }

    func record(_ pid: pid_t, _ readyFile: URL, _ appName: String) {
        lock.withLock { calls.append((pid, readyFile, appName)) }
    }
}

@MainActor
private final class ViewerUpdaterHarness {
    let directory = makeUpdateTestDirectory("updater")
    let installer = FakeViewerUpdateInstaller()
    let preferences: InMemoryViewerUpdatePreferencesStore
    let finished = FinishedReplacements()
    var checkResult: UpdateCheckResult
    var gate: CheckGate?
    private(set) var checks = 0
    private(set) var terminations = 0
    private(set) var logs: [String] = []
    private(set) var updater: ViewerUpdater!

    init(
        checksAutomatically: Bool = true,
        installability: UpdateInstallability = .updatable,
        checkResult: UpdateCheckResult = .upToDate,
        replacing: ViewerReplacement? = nil
    ) {
        preferences = InMemoryViewerUpdatePreferencesStore(checksAutomatically: checksAutomatically)
        self.checkResult = checkResult
        let finished = finished
        updater = ViewerUpdater(
            runningVersion: viewerTestVersion,
            appName: "Sensorium.app",
            installability: installability,
            stateStore: UpdateStateStore(role: .viewer, directory: directory),
            preferences: preferences,
            installer: installer,
            replacing: replacing,
            loginItemStatus: { UpdateReadyReport.LoginItemStatus.notRegistered },
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
            check: { [unowned self] in
                checks += 1
                if let gate { await gate.wait() }
                return self.checkResult
            },
            stage: { offer in .success(viewerTestStaged(offer)) },
            finishReplacing: { pid, readyFile, appName in
                finished.record(pid, readyFile, appName)
                return true
            },
            onTerminate: { [unowned self] in terminations += 1 },
            log: { [unowned self] in logs.append($0) }
        )
    }

    func cleanUp() {
        updater.stop()
        removeUpdateTestDirectory(directory)
    }

    func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func pause() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// With automatic updates off nothing is asked of the release page until the
/// person asks; turning them on checks at once and is remembered.
@MainActor
func testViewerUpdaterAutomaticPreferenceTests() async {
    let harness = ViewerUpdaterHarness(checksAutomatically: false, checkResult: .available(viewerTestOffer("0.5.0")))
    defer { harness.cleanUp() }
    harness.updater.start()
    await harness.pause()
    expect(harness.checks == 0, "with automatic updates off, launch makes no update request")
    expect(harness.updater.line == nil, "and the line says nothing")
    expect(!harness.updater.checksAutomatically, "the menu's checkmark reads off")

    harness.updater.setChecksAutomatically(true)
    expect(harness.preferences.checksAutomatically(), "turning them on is remembered")
    expect(await harness.settle(until: { harness.checks == 1 }), "and checks at once")
    expect(
        await harness.settle(until: { harness.updater.line?.text == "Sensorium 0.5.0 is ready." }),
        "a found update is downloaded and said to be ready, got \(String(describing: harness.updater.line))"
    )

    harness.updater.setChecksAutomatically(false)
    expect(!harness.preferences.checksAutomatically(), "turning them off is remembered")
    expect(!harness.updater.checksAutomatically, "and the checkmark follows")
    print("PASS: Check for Updates Automatically starts and stops update requests and is remembered")
}

/// Restart Now waits for no session, hands off through the installer with
/// this process's own report, and quits only when the new version took over.
@MainActor
func testViewerUpdaterRestartNowTests() async {
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        var lines: [ViewerUpdateLine?] = []
        harness.updater.onLineChange = { lines.append($0) }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        expect(lines.last == harness.updater.line, "and the window is told")

        harness.updater.sessionRunChanged(true)
        expect(harness.updater.line?.offersRestartNow == false, "a session in progress takes Restart Now away")
        expect(harness.updater.line?.text == "Sensorium 0.5.0 is ready.", "and leaves the line")
        await harness.updater.restartNow()
        expect(harness.installer.handOffs.isEmpty, "Restart Now does nothing while a session runs")
        harness.updater.sessionRunChanged(false)
        expect(harness.updater.line?.offersRestartNow == true, "and comes back once it has ended")

        harness.installer.handOffOutcome = .failed(.readyLate)
        await harness.updater.restartNow()
        expect(harness.installer.handOffs.count == 1, "Restart Now hands off once")
        let handOff = harness.installer.handOffs[0]
        expect(handOff.rollback == .keepRunning, "and keeps this process running if the new version is refused")
        expect(
            handOff.baseline == UpdateReadyReport(
                version: viewerTestVersion,
                screenRecordingGranted: nil,
                accessibilityGranted: nil,
                loginItemStatus: UpdateReadyReport.LoginItemStatus.notRegistered,
                host: nil
            ),
            "with this process's own version and login item status as the baseline, got \(handOff.baseline)"
        )
        expect(harness.terminations == 0, "a refused handoff does not quit")
        expect(
            harness.updater.line == ViewerUpdateLine(text: "Sensorium could not update: the new version did not start in time.", offersRestartNow: false),
            "and the line says why, got \(String(describing: harness.updater.line))"
        )
        harness.updater.installAtQuit()
        expect(harness.installer.quitInstalls.isEmpty, "the refused update is no longer staged, so quitting installs nothing")
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        await harness.updater.restartNow()
        expect(harness.terminations == 1, "a new version that took over ends this one through the quit path")
        harness.updater.installAtQuit()
        expect(harness.installer.quitInstalls.isEmpty, "and quitting does not install it a second time")
        expect(
            !harness.logs.contains { $0.contains("/") },
            "no update log line names a path, got \(harness.logs)"
        )
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        harness.installer.handOffOutcome = .swapBackFailed(.requirementFailed)
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        await harness.updater.restartNow()
        expect(harness.terminations == 0, "a refused version that could not be swapped back out does not quit this one")
        expect(
            harness.updater.line?.text == "Sensorium could not update: the new version is not signed like this one.",
            "and the line says why, got \(String(describing: harness.updater.line))"
        )
    }
    print("PASS: Restart Now waits for no session, hands off with this process's report, and quits only once the new version took over")
}

@MainActor
func testViewerUpdaterInstallAtQuitTests() async {
    do {
        let harness = ViewerUpdaterHarness(checkResult: .upToDate)
        defer { harness.cleanUp() }
        harness.updater.start()
        expect(await harness.settle(until: { harness.checks == 1 }), "launch checks once")
        harness.updater.installAtQuit()
        expect(harness.installer.quitInstalls.isEmpty, "with nothing staged, quitting installs nothing")
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.stagedUpdate != nil }), "a found update is staged")
        let staged = harness.updater.stagedUpdate
        harness.updater.installAtQuit()
        expect(harness.installer.quitInstalls == [staged].compactMap { $0 }, "quitting installs the staged update, once")
        expect(harness.updater.stagedUpdate == nil, "and it is no longer staged")
        harness.updater.installAtQuit()
        expect(harness.installer.quitInstalls.count == 1, "a second quit installs nothing more")
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        harness.installer.quitOutcome = .failed(.requirementFailed)
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.stagedUpdate != nil }), "a found update is staged")
        harness.updater.installAtQuit()
        let failures = UpdateStateStore(role: .viewer, directory: harness.directory).load().failures
        expect(
            failures.count == 1 && failures.first?.kind == .badRelease,
            "an install at quit that failed is recorded for the next launch, got \(failures)"
        )
    }
    print("PASS: quitting installs a staged update, and only a staged one, and records how it went")
}

/// The app delegate wired to the updater the way the viewer wires it, with
/// AppKit's answer recorded instead of sent.
@MainActor
private func terminatingDelegate(
    _ updater: ViewerUpdater,
    replies: @escaping @MainActor (Bool) -> Void
) -> ViewerApplicationDelegate {
    let delegate = ViewerApplicationDelegate(onReopenWithNoWindows: {}, replyToTerminate: replies)
    delegate.beforeTerminate = { updater.prepareToTerminate(then: $0) }
    return delegate
}

/// A quit from the Dock, a logout or shutdown, or an Apple Event installs a
/// staged update just as the viewer's own quit does, and a quit that comes
/// both ways installs at most once.
@MainActor
func testViewerUpdaterQuitThroughAppKitTests() async {
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        var replies: [Bool] = []
        let delegate = terminatingDelegate(harness.updater) { replies.append($0) }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.stagedUpdate != nil }), "a found update is staged")
        let staged = harness.updater.stagedUpdate
        expect(
            delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
            "with no Restart Now under way, AppKit terminates at once"
        )
        expect(harness.installer.quitInstalls == [staged].compactMap { $0 }, "after the staged update is installed")
        expect(replies.isEmpty, "and AppKit needs no later answer, got \(replies)")
        await harness.updater.finishBeforeQuit()
        expect(harness.installer.quitInstalls.count == 1, "the viewer's own quit after it installs nothing more")
    }
    do {
        let harness = ViewerUpdaterHarness(checksAutomatically: false, checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        let gate = CheckGate()
        harness.gate = gate
        let delegate = terminatingDelegate(harness.updater) { _ in }
        harness.updater.start()
        let check = Task { await harness.updater.checkForUpdates() }
        expect(await harness.settle(until: { gate.isWaiting }), "a chosen check is under way")
        expect(
            delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
            "a check under way does not hold AppKit back"
        )
        expect(harness.installer.quitInstalls.isEmpty, "with nothing staged yet, quitting installs nothing")
        gate.open()
        await check.value
        expect(harness.updater.stagedUpdate != nil, "the check goes on to stage an update")
        await harness.updater.finishBeforeQuit()
        expect(
            harness.installer.quitInstalls.isEmpty,
            "a quit installs at most once, so one that comes both ways does not install an update staged in between"
        )
    }
    print("PASS: a quit from outside the app installs a staged update, and a quit that comes both ways installs once")
}

/// Quitting while Restart Now is handing off lets the handoff finish first,
/// so the old app is never left half replaced: a refused version is swapped
/// back out before this one ends, and one that took over is left running.
@MainActor
func testViewerUpdaterQuitDuringRestartNowTests() async {
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        let handOff = CheckGate()
        harness.installer.handOffGate = handOff
        harness.installer.handOffOutcome = .failed(.readyLate)
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        let restart = Task { await harness.updater.restartNow() }
        expect(await harness.settle(until: { handOff.isWaiting }), "Restart Now is handing off")
        var quitFinished = false
        let quit = Task {
            await harness.updater.finishBeforeQuit()
            quitFinished = true
        }
        await harness.pause()
        expect(!quitFinished, "the viewer's own quit waits for the handoff")
        expect(harness.installer.quitInstalls.isEmpty, "and installs nothing while it waits")
        handOff.open()
        await restart.value
        await quit.value
        expect(harness.installer.handOffs.first?.rollback == .keepRunning, "a refused version is swapped back out")
        expect(harness.installer.quitInstalls.isEmpty, "and is not installed again at quit")
        expect(harness.terminations == 0, "the quit already under way is the only one, got \(harness.terminations)")
        expect(
            harness.updater.line?.text == "Sensorium could not update: the new version did not start in time.",
            "the line says why, got \(String(describing: harness.updater.line))"
        )
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        let handOff = CheckGate()
        harness.installer.handOffGate = handOff
        var replies: [Bool] = []
        let delegate = terminatingDelegate(harness.updater) { replies.append($0) }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        let restart = Task { await harness.updater.restartNow() }
        expect(await harness.settle(until: { handOff.isWaiting }), "Restart Now is handing off")
        expect(
            delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
            "a quit from outside the app during a handoff holds AppKit back"
        )
        await harness.pause()
        expect(replies.isEmpty, "until the handoff has finished, got \(replies)")
        handOff.open()
        await restart.value
        expect(replies == [true], "then AppKit is told to go ahead, once, got \(replies)")
        expect(
            harness.terminations == 0,
            "and the new version taking over does not start the viewer's own quit as well, got \(harness.terminations)"
        )
        expect(harness.installer.quitInstalls.isEmpty, "the update it took over with is not installed again")
    }
    do {
        let harness = ViewerUpdaterHarness(checkResult: .available(viewerTestOffer("0.5.0")))
        defer { harness.cleanUp() }
        let handOff = CheckGate()
        harness.installer.handOffGate = handOff
        harness.installer.handOffOutcome = .failed(.launchFailed)
        var replies: [Bool] = []
        let delegate = terminatingDelegate(harness.updater) { replies.append($0) }
        harness.updater.start()
        expect(await harness.settle(until: { harness.updater.line?.offersRestartNow == true }), "a ready update offers Restart Now")
        let restart = Task { await harness.updater.restartNow() }
        expect(await harness.settle(until: { handOff.isWaiting }), "Restart Now is handing off")
        var quitFinished = false
        let quit = Task {
            await harness.updater.finishBeforeQuit()
            quitFinished = true
        }
        expect(
            delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
            "both quits wait for the handoff"
        )
        handOff.open()
        expect(
            await harness.settle(until: { quitFinished && replies == [true] }),
            "and both go on once it has finished, got \(quitFinished) and \(replies)"
        )
        await restart.value
        await quit.value
        expect(harness.installer.quitInstalls.isEmpty, "with nothing left to install")
        expect(harness.terminations == 0, "and no third quit, got \(harness.terminations)")
    }
    print("PASS: quitting during Restart Now lets the handoff finish first, then quits once")
}

@MainActor
func testViewerUpdaterManualCheckTests() async {
    let harness = ViewerUpdaterHarness(checksAutomatically: false, checkResult: .upToDate)
    defer { harness.cleanUp() }
    harness.updater.start()
    let gate = CheckGate()
    harness.gate = gate
    let check = Task { await harness.updater.checkForUpdates() }
    expect(await harness.settle(until: { gate.isWaiting }), "Check for Updates asks even with automatic updates off")
    expect(harness.updater.line?.text == "Checking for updates\u{2026}", "the line says it is checking, got \(String(describing: harness.updater.line))")
    gate.open()
    await check.value
    harness.gate = nil
    expect(
        harness.updater.line?.text == "Sensorium 0.4.0 is up to date.",
        "then that this version is current, got \(String(describing: harness.updater.line))"
    )
    harness.updater.windowDidShow()
    expect(harness.updater.line == nil, "and stops saying so the next time the window shows")

    harness.checkResult = .unreachable
    let logsBefore = harness.logs.count
    await harness.updater.checkForUpdates()
    expect(harness.updater.line == nil, "a check that reached nothing does not claim up to date, got \(String(describing: harness.updater.line))")
    expect(
        !harness.logs.dropFirst(logsBefore).contains { $0.contains("up to date") },
        "nor does its log, got \(Array(harness.logs.dropFirst(logsBefore)))"
    )

    harness.checkResult = .failed(.signatureInvalid)
    await harness.updater.checkForUpdates()
    expect(
        harness.updater.line?.text == "Sensorium could not update: the download did not match the release.",
        "a failed check says why, got \(String(describing: harness.updater.line))"
    )
    expect(!harness.updater.checksAutomatically, "and a chosen check leaves automatic updates off")
    print("PASS: Check for Updates says it is checking, then up to date until the window next shows, or why it failed")
}

@MainActor
func testViewerUpdaterNotUpdatableTests() async {
    let harness = ViewerUpdaterHarness(installability: .notUpdatable(.translocated))
    defer { harness.cleanUp() }
    expect(
        harness.updater.line?.text == "Move Sensorium to Applications and open it again to receive updates.",
        "an app run from a temporary copy says so from launch, got \(String(describing: harness.updater.line))"
    )
    harness.updater.start()
    await harness.pause()
    expect(harness.checks == 0, "and asks the release page nothing")
    print("PASS: a viewer that cannot replace itself says where to move it and checks nothing")
}

@MainActor
func testViewerUpdaterReportsReadyOnceTests() async {
    let folder = makeUpdateTestDirectory("staging")
    defer { removeUpdateTestDirectory(folder) }
    // The staging folder the installer makes is the owner's alone, and the
    // report is written only into such a folder.
    chmod(folder.path, 0o700)
    let readyFile = folder.appendingPathComponent(UpdateHandoff.readyFileName)
    let harness = ViewerUpdaterHarness(replacing: ViewerReplacement(pid: 4242, readyFile: readyFile))
    defer { harness.cleanUp() }
    expect(UpdateReadyReport.read(from: readyFile) == nil, "nothing is reported before the window is up")
    harness.updater.windowDidShow()
    expect(
        UpdateReadyReport.read(from: readyFile) == UpdateReadyReport(
            version: viewerTestVersion,
            screenRecordingGranted: nil,
            accessibilityGranted: nil,
            loginItemStatus: UpdateReadyReport.LoginItemStatus.notRegistered,
            host: nil,
            processIdentifier: getpid()
        ),
        "once the window is up, the ready file holds this version, its login item status and this process"
    )
    expect(
        await harness.settle(until: { harness.finished.all.count == 1 }),
        "and the replaced version is waited out in the background"
    )
    let call = harness.finished.all.first
    expect(
        call?.pid == 4242 && call?.readyFile == readyFile && call?.appName == "Sensorium.app",
        "for the process and staging folder it was launched with"
    )
    try? FileManager.default.removeItem(at: readyFile)
    harness.updater.windowDidShow()
    await harness.pause()
    expect(UpdateReadyReport.read(from: readyFile) == nil, "the report is written once, not every time the window shows")
    expect(harness.finished.all.count == 1, "and the wait starts once")
    print("PASS: a replacing launch reports ready once its window is up, then waits out the version it replaced")
}

@MainActor
func testViewerUpdaterInertWithoutVersionTests() {
    expect(ViewerUpdater.runningVersion(infoDictionary: nil) == nil, "no Info.plist, no version")
    expect(ViewerUpdater.runningVersion(infoDictionary: [:]) == nil, "no CFBundleShortVersionString, no version")
    expect(
        ViewerUpdater.runningVersion(infoDictionary: ["CFBundleShortVersionString": "0.4.0"]) == viewerTestVersion,
        "a release's version is read"
    )
    expect(
        ViewerUpdater.runningVersion(infoDictionary: ["CFBundleShortVersionString": "0.4.0-dev"]) == nil,
        "a version a release could never carry is not"
    )
    expect(
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] == nil,
        "this runner, like a swift run build, has no bundle version"
    )
    let directory = makeUpdateTestDirectory("inert")
    defer { removeUpdateTestDirectory(directory) }
    let before = snapshot(of: directory)
    let updater = ViewerUpdater.make(bundle: .main, applicationSupportDirectory: directory, replacing: nil, onTerminate: {})
    expect(updater == nil, "so there is no updater: no scheduler, no request, no line and no menu items")
    expect(snapshot(of: directory) == before, "and nothing is written")
    print("PASS: a build with no bundle version has no updater at all")
}
#endif
