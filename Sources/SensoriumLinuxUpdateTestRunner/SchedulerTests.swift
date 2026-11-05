import Foundation
import SensoriumCore
import SensoriumLinuxUpdate

/// Holds a check or a scheduled sleep until the test lets it go on.
@MainActor
final class SchedulerGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var waiters: Int { waiting.count }

    func wait() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        let resumed = waiting
        waiting = []
        for continuation in resumed {
            continuation.resume()
        }
    }
}

private func manifest(_ text: String, sha256: String = sampleDigest) -> LinuxUpdateManifest {
    LinuxUpdateManifest(version: version(text), file: LinuxUpdateManifest.archiveFileName(for: version(text)), size: 1024, sha256: sha256)
}

private func stagedFor(_ manifest: LinuxUpdateManifest) -> LinuxStagedUpdate {
    LinuxStagedUpdate(version: manifest.version, sha256: manifest.sha256, executable: URL(fileURLWithPath: "/nonexistent/Sensorium"))
}

@MainActor
private final class SchedulerHarness {
    let directory = makeTemporaryDirectory("scheduler")
    let stateStore: LinuxUpdateStateStore
    var checkResult: LinuxUpdateCheckResult
    var stageResult: ((LinuxUpdateManifest) -> Result<LinuxStagedUpdate, LinuxUpdateFailure>) = { .success(stagedFor($0)) }
    let sleepGate = SchedulerGate()
    private(set) var checks = 0
    private(set) var stages: [LinuxUpdateManifest] = []
    private(set) var statuses: [LinuxUpdateStatus] = []
    private(set) var scheduler: LinuxUpdateScheduler!

    init(
        installability: LinuxUpdateInstallability = .updatable,
        automaticUpdates: Bool = true,
        checkResult: LinuxUpdateCheckResult = .upToDate
    ) {
        stateStore = LinuxUpdateStateStore(dataRoot: directory)
        self.checkResult = checkResult
        let sleepGate = sleepGate
        scheduler = LinuxUpdateScheduler(
            installability: installability,
            stateStore: stateStore,
            automaticUpdates: automaticUpdates,
            sleep: { _ in await sleepGate.wait() },
            check: { [unowned self] in
                self.checks += 1
                return self.checkResult
            },
            stage: { [unowned self] manifest in
                self.stages.append(manifest)
                return self.stageResult(manifest)
            }
        )
        scheduler.onStatusChange = { [unowned self] in self.statuses.append($0) }
    }

    func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func cleanUp() {
        scheduler.stop()
        sleepGate.open()
        removeTemporaryDirectory(directory)
    }
}

@MainActor
func testSchedulerChecksAtLaunchAndEverySixHoursWhileOn() async {
    expect(LinuxUpdateScheduler.checkInterval == .seconds(6 * 60 * 60), "the viewer checks every six hours")

    let harness = SchedulerHarness()
    defer { harness.cleanUp() }
    expect(harness.scheduler.status == .current, "an updatable viewer starts current")
    harness.scheduler.start()
    let settled1 = await harness.settle(until: { harness.checks == 1 })
    expect(settled1, "and checks once at launch")
    let settled2 = await harness.settle(until: { harness.sleepGate.waiters == 1 })
    expect(settled2, "then waits for the interval")
    harness.sleepGate.open()
    let settled3 = await harness.settle(until: { harness.checks == 2 })
    expect(settled3, "and checks again once it has passed")
    expect(harness.statuses.contains(.checking), "a check says it is checking")
    expect(harness.scheduler.status == .current, "and an up-to-date answer is current")

    let off = SchedulerHarness(automaticUpdates: false)
    defer { off.cleanUp() }
    off.scheduler.start()
    try? await Task.sleep(nanoseconds: 50_000_000)
    expect(off.checks == 0, "with automatic updates off, launch makes no request")
    await off.scheduler.checkForUpdates()
    expect(off.checks == 1, "Check for Updates\u{2026} checks anyway")
    off.scheduler.automaticUpdates = true
    let settled4 = await off.settle(until: { off.checks == 2 })
    expect(settled4, "turning automatic updates on checks at once")
    off.scheduler.automaticUpdates = false
    off.sleepGate.open()
    try? await Task.sleep(nanoseconds: 50_000_000)
    expect(off.checks == 2, "and turning them off stops the schedule")

    let stuck = SchedulerHarness(installability: .notUpdatable(.dataRootNotOwned))
    defer { stuck.cleanUp() }
    expect(stuck.scheduler.status == .notUpdatable, "a viewer that cannot install starts not updatable")
    stuck.scheduler.start()
    await stuck.scheduler.checkForUpdates()
    expect(stuck.checks == 0, "and asks the release page nothing")
}

@MainActor
func testSchedulerStagesAnUpdateAndReportsEachAnswer() async {
    let harness = SchedulerHarness(automaticUpdates: false, checkResult: .available(manifest("0.6.0")))
    defer { harness.cleanUp() }
    await harness.scheduler.checkForUpdates()
    expect(harness.statuses.contains(.downloading(version("0.6.0"))), "a found update downloads")
    expect(harness.scheduler.status == .ready(version("0.6.0")), "and is ready once staged, got \(harness.scheduler.status)")
    expect(harness.scheduler.stagedUpdate == stagedFor(manifest("0.6.0")), "the staged update is held for Restart Now")
    await harness.scheduler.checkForUpdates()
    expect(harness.checks == 1, "a staged update is not checked for again")

    harness.scheduler.installFinished(stagedFor(manifest("0.6.0")), failure: nil)
    expect(harness.scheduler.stagedUpdate == nil, "an install that took over leaves nothing staged")

    let answers: [(LinuxUpdateCheckResult, LinuxUpdateStatus, String)] = [
        (.upToDate, .current, "up to date"),
        (.failed(.signatureInvalid), .failed(reason: LinuxUpdateFailure.signatureInvalid.reason), "a failed check"),
        (.givenUp(manifest("0.6.0"), reason: "the new version did not start"), .failed(reason: "the new version did not start"), "a release given up on"),
        (.heldBack(manifest("0.6.0")), .waiting(version("0.6.0")), "a retry held back")
    ]
    for (result, status, name) in answers {
        let answer = SchedulerHarness(automaticUpdates: false, checkResult: result)
        await answer.scheduler.checkForUpdates()
        expect(answer.scheduler.status == status, "\(name) reads \(status), got \(answer.scheduler.status)")
        answer.cleanUp()
    }

    let unreachable = SchedulerHarness(automaticUpdates: false, checkResult: .heldBack(manifest("0.6.0")))
    defer { unreachable.cleanUp() }
    await unreachable.scheduler.checkForUpdates()
    unreachable.checkResult = .unreachable
    await unreachable.scheduler.checkForUpdates()
    expect(unreachable.scheduler.status == .waiting(version("0.6.0")), "a check that reached nothing keeps the status it had")
}

/// A release page every transfer of which runs out of time, the way a real
/// transport reports a request or a whole transfer passing its deadline.
private final class TimingOutReleasePage: LinuxUpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var fetchCount = 0
    private var downloadCount = 0
    private let page = FakeReleasePage()
    private var timesOutFetches = true

    var fetches: Int { lock.withLock { fetchCount } }
    var downloads: Int { lock.withLock { downloadCount } }

    /// From now on the manifest and its signature arrive; only the archive
    /// still times out.
    func publish(_ manifest: Data, signedWith privateKey: Data) {
        page.publish(manifest, signedWith: privateKey)
        lock.withLock { timesOutFetches = false }
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let timesOut = lock.withLock { () -> Bool in
            fetchCount += 1
            return timesOutFetches
        }
        if timesOut {
            throw LinuxUpdateTransportError.failed("The request timed out.")
        }
        return try await page.fetch(url, maximumBytes: maximumBytes)
    }

    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        lock.withLock { downloadCount += 1 }
        throw LinuxUpdateTransportError.failed("The request timed out.")
    }
}

@MainActor
func testSchedulerKeepsCheckingAfterATransferTimesOut() async {
    let directory = makeTemporaryDirectory("scheduler-timeout")
    defer { removeTemporaryDirectory(directory) }
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    expect(installation.installability() == .updatable, "the data root is updatable")
    let stateStore = LinuxUpdateStateStore(dataRoot: installation.dataRoot)
    let privateKey = SensoriumCrypto.ed25519GeneratePrivateKey()
    let page = TimingOutReleasePage()
    let checker = LinuxUpdateChecker(
        runningVersion: version("0.5.0"),
        transport: page,
        stateStore: stateStore,
        publicKey: try! SensoriumCrypto.ed25519PublicKey(privateKey: privateKey)
    )
    let stager = LinuxUpdateStager(installation: installation, transport: page)
    let scheduler = LinuxUpdateScheduler(
        installability: .updatable,
        stateStore: stateStore,
        automaticUpdates: false,
        check: { await checker.check() },
        stage: { await stager.stage($0) }
    )

    await scheduler.checkForUpdates()
    expect(page.fetches == 1, "a check asks for the manifest")
    expect(scheduler.status == .current, "a check that timed out keeps the status it had, got \(scheduler.status)")
    await scheduler.checkForUpdates()
    expect(page.fetches == 2, "and the next check still runs")

    page.publish(serialized(sampleManifestObject(version: "0.6.0")), signedWith: privateKey)
    await scheduler.checkForUpdates()
    expect(page.downloads == 1, "a signed newer release is downloaded")
    expect(scheduler.status == .waiting(version("0.6.0")), "a download that timed out waits for another try, got \(scheduler.status)")
    await scheduler.checkForUpdates()
    expect(page.downloads == 2, "and the next check downloads it again")
    expect(scheduler.stagedUpdate == nil, "nothing is staged from a download that never finished")
}

@MainActor
func testSchedulerRecordsFailuresAndClearsThemOnAChosenCheck() async {
    let harness = SchedulerHarness(automaticUpdates: false, checkResult: .available(manifest("0.6.0")))
    defer { harness.cleanUp() }
    harness.stageResult = { _ in .failure(.digestMismatch) }
    await harness.scheduler.checkForUpdates()
    expect(harness.scheduler.status == .waiting(version("0.6.0")), "a download that could pass on another try waits, got \(harness.scheduler.status)")
    expect(harness.stateStore.load().failure(version: version("0.6.0"), sha256: sampleDigest)?.tries == 1, "and is recorded once")

    harness.stageResult = { _ in .failure(.selfTestFailed(status: 1)) }
    await harness.scheduler.checkForUpdates()
    expect(
        harness.scheduler.status == .failed(reason: LinuxUpdateFailure.selfTestFailed(status: 1).reason),
        "a bad release fails at once, got \(harness.scheduler.status)"
    )
    expect(harness.stateStore.load().failure(version: version("0.6.0"), sha256: sampleDigest)?.tries == 1, "the chosen check forgot the earlier try")

    harness.stageResult = { .success(stagedFor($0)) }
    await harness.scheduler.checkForUpdates()
    let staged = stagedFor(manifest("0.6.0"))
    expect(harness.scheduler.stagedUpdate == staged, "a later good download is staged")
    for attempt in 1...LinuxUpdateState.maximumTries {
        harness.scheduler.installFinished(staged, failure: .readyLate)
        expect(harness.scheduler.stagedUpdate == nil, "a restart that did not take leaves nothing staged")
        if attempt < LinuxUpdateState.maximumTries {
            expect(harness.scheduler.status == .waiting(version("0.6.0")), "try \(attempt) waits for the next check, got \(harness.scheduler.status)")
        }
    }
    expect(
        harness.scheduler.status == .failed(reason: LinuxUpdateFailure.readyLate.reason),
        "the last try fails, got \(harness.scheduler.status)"
    )

    harness.scheduler.recordStartupRollback(LinuxUpdatePendingSwitch(version: version("0.7.0"), sha256: sampleDigest, previous: version("0.5.0")))
    expect(
        harness.stateStore.load().failure(version: version("0.7.0"), sha256: sampleDigest)?.reason == LinuxUpdateFailure.readyLate.reason,
        "a switch rolled back at launch is recorded as a late ready file"
    )
}
