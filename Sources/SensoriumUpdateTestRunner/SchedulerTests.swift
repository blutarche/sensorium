#if os(macOS)
import CryptoKit
import Foundation
import SensoriumUpdate

/// A clock that never moves on its own: every sleep waits until the test
/// calls `advance()`.
final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    var sleepCalls: Int { lock.withLock { calls } }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                calls += 1
                waiting.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func advance() {
        let sleepers = lock.withLock {
            defer { waiting = [] }
            return waiting
        }
        sleepers.forEach { $0.resume() }
    }
}

/// Lets the scheduler's tasks run until `condition` holds, or fails after two
/// seconds.
@MainActor
func eventually(_ what: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        guard Date() < deadline else {
            return expect(false, what)
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Gives the scheduler's tasks a moment, for checks that something did not
/// happen.
@MainActor
func settle() async {
    try? await Task.sleep(for: .milliseconds(100))
}

private func stagedStub(_ offer: UpdateOffer) -> StagedUpdate {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("never-created-\(UUID().uuidString)")
    return StagedUpdate(version: offer.version, sha256: offer.app.sha256, directory: directory, appURL: directory.appendingPathComponent(fixtureAppName))
}

@MainActor
private final class SchedulerHarness {
    let directory = makeTemporaryDirectory("scheduler")
    let key = Curve25519.Signing.PrivateKey()
    let page = FakeReleasePage()
    let sleeper = FakeSleeper()
    lazy var store = UpdateStateStore(role: .host, directory: directory)
    var stageResult: (UpdateOffer) -> Result<StagedUpdate, UpdateFailure> = { .success(stagedStub($0)) }
    var stageCalls = 0
    var onStage: () -> Void = {}

    func publish(_ version: String) {
        page.publish(serialized(sampleManifestObject(version: version)), signedWith: key)
    }

    func scheduler(
        flavor: UpdateScheduler.Flavor,
        automaticUpdates: Bool,
        installability: UpdateInstallability = .updatable
    ) -> UpdateScheduler {
        let checker = UpdateChecker(
            role: .host,
            runningVersion: UpdateVersion("0.4.0")!,
            transport: page,
            stateStore: store,
            publicKey: key.publicKey.rawRepresentation
        )
        let sleeper = sleeper
        return UpdateScheduler(
            flavor: flavor,
            installability: installability,
            stateStore: store,
            automaticUpdates: automaticUpdates,
            sleep: { try await sleeper.sleep($0) },
            check: { await checker.check() },
            stage: { [unowned self] offer in
                stageCalls += 1
                onStage()
                return stageResult(offer)
            }
        )
    }

    deinit {
        removeTemporaryDirectory(directory)
    }
}

@MainActor
func testSchedulerMakesNoRequestWhenAutomaticUpdatesAreOff() async {
    let harness = SchedulerHarness()
    harness.publish("0.5.0")
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: false)
    scheduler.start()
    await settle()
    harness.sleeper.advance()
    await settle()
    expect(harness.page.requests.isEmpty, "with automatic updates off, launch makes no request")
    expect(scheduler.status == .current, "with automatic updates off, the status stays current")

    await scheduler.checkForUpdates()
    expect(harness.page.requests.count == 2, "Check for Updates fetches the manifest and signature once, even with automatic updates off")
    expect(scheduler.status == .ready(UpdateVersion("0.5.0")!), "a manual check stages the update")
    harness.sleeper.advance()
    await settle()
    expect(harness.page.requests.count == 2, "a manual check does not start the six-hour schedule")
}

@MainActor
func testSchedulerChecksAtLaunchAndEverySixHoursWhileOn() async {
    let harness = SchedulerHarness()
    harness.publish("0.4.0")
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: true)
    expect(UpdateScheduler.checkInterval == .seconds(6 * 60 * 60), "the schedule is every six hours")
    var statuses: [UpdateStatus] = []
    scheduler.onStatusChange = { statuses.append($0) }

    scheduler.start()
    await eventually("a check runs at launch") { harness.page.requests.count == 2 }
    expect(scheduler.status == .current, "the running version is up to date")
    expect(statuses == [.checking, .current], "the status shows the check, then up to date")

    await eventually("the scheduler sleeps after the launch check") { harness.sleeper.sleepCalls == 1 }
    harness.sleeper.advance()
    await eventually("a check runs after six hours") { harness.page.requests.count == 4 }

    await eventually("the scheduler sleeps again") { harness.sleeper.sleepCalls == 2 }
    scheduler.automaticUpdates = false
    harness.sleeper.advance()
    await settle()
    expect(harness.page.requests.count == 4, "turning automatic updates off stops the schedule")

    scheduler.automaticUpdates = true
    await eventually("turning automatic updates back on checks at once") { harness.page.requests.count == 6 }
    scheduler.stop()
    harness.sleeper.advance()
}

@MainActor
func testSchedulerShowsFailuresAndUnreachableChecksPlainly() async {
    let harness = SchedulerHarness()
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: false)

    await scheduler.checkForUpdates()
    expect(scheduler.status == .current, "an unreachable release page leaves the status as it was")

    harness.page.publish(serialized(sampleManifestObject(version: "0.5.0")), signedWith: Curve25519.Signing.PrivateKey())
    await scheduler.checkForUpdates()
    expect(scheduler.status == .failed(reason: "the download did not match the release"), "a forged manifest shows as failed")

    harness.publish("0.5.0")
    harness.stageResult = { _ in .failure(.downloadFailed) }
    await scheduler.checkForUpdates()
    expect(scheduler.status == .waiting(UpdateVersion("0.5.0")!), "between tries the update stays waiting")
    expect(harness.store.load().failures.first?.tries == 1, "the failed try is recorded")

    harness.stageResult = { _ in .failure(.requirementFailed) }
    await scheduler.checkForUpdates()
    expect(harness.store.load().failures.isEmpty == false, "a bad release is recorded")
    expect(scheduler.status == .failed(reason: "the new version is not signed like this one"), "a bad release shows as failed with its reason")

    let stagesBefore = harness.stageCalls
    let requestsBefore = harness.page.requests.count
    let automatic = harness.scheduler(flavor: .viewer, automaticUpdates: true)
    automatic.start()
    await eventually("an automatic check runs at launch") { harness.page.requests.count == requestsBefore + 2 }
    await settle()
    expect(harness.stageCalls == stagesBefore, "an automatic check never retries a bad release")
    expect(automatic.status == .failed(reason: "the new version is not signed like this one"), "the recorded reason shows after a relaunch")

    harness.stageResult = { .success(stagedStub($0)) }
    await automatic.checkForUpdates()
    expect(harness.store.load().failures.isEmpty, "Check for Updates clears every recorded failure")
    expect(automatic.status == .ready(UpdateVersion("0.5.0")!), "and tries again at once")
    automatic.stop()
    harness.sleeper.advance()
}

@MainActor
func testADownloadThatDoesNotMatchIsTriedThreeTimes() async {
    let harness = SchedulerHarness()
    harness.publish("0.5.0")
    let version = UpdateVersion("0.5.0")!
    let didNotMatch = "the download did not match the release"
    harness.stageResult = { _ in .failure(.digestMismatch) }
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: true)

    scheduler.start()
    await eventually("the first try runs at launch") { harness.stageCalls == 1 }
    await eventually("a download whose SHA-256 does not match waits for another try") { scheduler.status == .waiting(version) }
    expect(harness.store.load().failures.first?.tries == 1, "the mismatched download counts as one try")

    harness.stageResult = { _ in .failure(.sizeMismatch) }
    await eventually("the scheduler sleeps after the first try") { harness.sleeper.sleepCalls == 1 }
    harness.sleeper.advance()
    await eventually("the second try runs at the next check") { harness.stageCalls == 2 }
    await eventually("a download of the wrong size waits for another try") { scheduler.status == .waiting(version) }
    expect(harness.store.load().failures.first?.tries == 2, "the second mismatch counts as the second try")

    await eventually("the scheduler sleeps after the second try") { harness.sleeper.sleepCalls == 2 }
    harness.sleeper.advance()
    await eventually("the third try runs at the next check") { harness.stageCalls == 3 }
    await eventually("after the third mismatch the update has failed") { scheduler.status == .failed(reason: didNotMatch) }
    expect(harness.store.load().failures.first?.kind == .badRelease, "after the third try it counts as a bad release")

    await eventually("the scheduler sleeps after the third try") { harness.sleeper.sleepCalls == 3 }
    harness.sleeper.advance()
    await eventually("a fourth check runs") { harness.page.requests.count == 8 }
    await settle()
    expect(harness.stageCalls == 3, "a release given up on after three mismatches is not downloaded again")
    expect(scheduler.status == .failed(reason: didNotMatch), "the given-up release keeps its reason")
    scheduler.stop()
    harness.sleeper.advance()
}

@MainActor
func testSchedulerMakesNoRequestWhenNotUpdatable() async {
    let harness = SchedulerHarness()
    harness.publish("0.5.0")
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: true, installability: .notUpdatable(.translocated))
    scheduler.start()
    await settle()
    await scheduler.checkForUpdates()
    expect(harness.page.requests.isEmpty, "an app that cannot be updated makes no request")
    expect(scheduler.status == .notUpdatable, "it shows the not-updatable line")
    scheduler.stop()
    harness.sleeper.advance()
}

@MainActor
private final class HostProbe {
    var idle = true
    var idleChecks = 0
    var installs: [StagedUpdate] = []
    var outcome = UpdateHandoffOutcome.failed(.readyLate)
}

@MainActor
func testHostInstallsOnlyWhenIdleAndRechecksRightBeforeInstalling() async {
    let harness = SchedulerHarness()
    harness.publish("0.5.0")
    let host = HostProbe()
    let flavor = UpdateScheduler.Flavor.host(
        isIdle: {
            host.idleChecks += 1
            return host.idle
        },
        install: { staged in
            host.installs.append(staged)
            return host.outcome
        }
    )
    let scheduler = harness.scheduler(flavor: flavor, automaticUpdates: false)

    harness.onStage = { host.idle = false }
    await scheduler.checkForUpdates()
    expect(host.installs.isEmpty, "a host that became busy during the download does not install")
    expect(host.idleChecks >= 1, "the idle rule is checked again right before installing")
    expect(scheduler.status == .waiting(UpdateVersion("0.5.0")!), "a busy host shows the update as waiting")

    await scheduler.installIfIdle()
    expect(host.installs.isEmpty, "a host that is still busy does not install")

    host.idle = true
    await scheduler.installIfIdle()
    expect(host.installs.count == 1, "once idle, the host installs the staged update")
    expect(scheduler.status == .waiting(UpdateVersion("0.5.0")!), "a failure that could pass on another try keeps the waiting line")
    expect(harness.store.load().failures.first?.tries == 1, "the failed install is recorded")
    expect(scheduler.stagedUpdate == nil, "a failed install leaves nothing staged; the next check downloads again")

    harness.onStage = {}
    host.outcome = .handedOff
    await scheduler.checkForUpdates()
    expect(host.installs.count == 2, "a manual check on an idle host stages and installs at once")
}

@MainActor
func testViewerHoldsAReadyUpdateUntilAskedToInstall() async {
    let harness = SchedulerHarness()
    harness.publish("0.5.0")
    let scheduler = harness.scheduler(flavor: .viewer, automaticUpdates: false)
    await scheduler.checkForUpdates()
    guard let staged = scheduler.stagedUpdate else {
        return expect(false, "the viewer holds the staged update")
    }
    expect(scheduler.status == .ready(UpdateVersion("0.5.0")!), "the viewer shows the update as ready")

    await scheduler.checkForUpdates()
    expect(harness.stageCalls == 1, "a ready update is not downloaded again")

    scheduler.installFinished(staged, outcome: .failed(.readyLate))
    expect(scheduler.stagedUpdate == nil, "a failed Restart Now leaves nothing staged")
    expect(scheduler.status == .waiting(UpdateVersion("0.5.0")!), "a Restart Now that could pass on another try waits for the next check")
    expect(harness.store.load().failures.first?.tries == 1, "the failed Restart Now is recorded")
}
#endif
