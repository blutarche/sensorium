import Foundation
import SensoriumUpdate

/// What the running app's Info.plist says about it. A build without a
/// version that compares, such as one `swift run` makes, has no updater at
/// all: no scheduler, no request, no line.
public struct HostUpdateBundle: Equatable, Sendable {
    public let version: UpdateVersion
    public let bundleIdentifier: String

    public init(version: UpdateVersion, bundleIdentifier: String) {
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }

    /// Pass `Bundle.main.infoDictionary`, read at launch.
    public static func read(infoDictionary: [String: Any]?) -> HostUpdateBundle? {
        guard let text = infoDictionary?["CFBundleShortVersionString"] as? String,
              let version = UpdateVersion(text),
              let bundleIdentifier = infoDictionary?["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            return nil
        }
        return HostUpdateBundle(version: version, bundleIdentifier: bundleIdentifier)
    }

    /// Calls `make` only for a packaged app.
    public static func makeUpdater<Updater>(
        infoDictionary: [String: Any]?,
        _ make: (HostUpdateBundle) -> Updater
    ) -> Updater? {
        read(infoDictionary: infoDictionary).map(make)
    }
}

/// The host's side of the update scheduler: the window's checkbox and line,
/// **Check for Updates…**, and installing once a session or pairing ends.
@MainActor
public final class HostUpdater {
    public let version: UpdateVersion
    public private(set) var line: String
    public var onLineChange: ((String) -> Void)?

    private let scheduler: UpdateScheduler
    private let preferences: any HostUpdatePreferenceStoring
    private let log: (String) -> Void
    private var idleWatch = HostUpdateIdleWatch()
    private var installFailureReason: String?

    /// `makeScheduler` receives the saved checkbox state and the log, and is
    /// normally `HostUpdater.makeScheduler`.
    public init(
        version: UpdateVersion,
        preferences: any HostUpdatePreferenceStoring,
        log: @escaping (String) -> Void = HostUpdateLog.record,
        makeScheduler: (_ automaticUpdates: Bool, _ log: @escaping (String) -> Void) -> UpdateScheduler
    ) {
        self.version = version
        self.preferences = preferences
        self.log = log
        let scheduler = makeScheduler(preferences.installsAutomatically(), log)
        self.scheduler = scheduler
        line = HostUpdateStatusLine.line(for: scheduler.status, runningVersion: version)
            ?? HostUpdateStatusLine.line(for: .current, runningVersion: version)!
        scheduler.onStatusChange = { [weak self] status in
            self?.statusChanged(status)
        }
    }

    public var installsAutomatically: Bool {
        scheduler.automaticUpdates
    }

    /// Call once, when the host is ready to check: at launch, or for an
    /// update relaunch once the process it replaced has exited.
    public func start() {
        scheduler.start()
    }

    /// Saved first, so a choice that could not be saved changes nothing.
    /// Off stops every update request; on checks at once.
    public func setInstallsAutomatically(_ isOn: Bool) throws {
        try preferences.remember(installsAutomatically: isOn)
        scheduler.automaticUpdates = isOn
        log("Install updates automatically turned \(isOn ? "on" : "off")")
    }

    /// **Check for Updates…**: clears every recorded failure and checks now.
    public func checkForUpdates() {
        log("Check for Updates chosen")
        Task {
            await scheduler.checkForUpdates()
        }
    }

    /// Every change of the host's status. A waiting update installs the
    /// moment the host becomes idle, whether or not the checkbox is on: it
    /// is already downloaded, so installing it makes no request.
    public func hostStatusChanged(_ status: HostOperatorStatus, now: Date = Date()) {
        guard idleWatch.observe(status, now: now) else { return }
        Task {
            await scheduler.installIfIdle()
        }
    }

    /// For an install that left this process unable to serve: the failed
    /// line stays until the process quits, whatever the scheduler reports.
    public func showInstallFailure(reason: String) {
        installFailureReason = reason
        setLine(HostUpdateStatusLine.failed(reason: reason, runningVersion: version))
    }

    private func statusChanged(_ status: UpdateStatus) {
        guard installFailureReason == nil,
              let next = HostUpdateStatusLine.line(for: status, runningVersion: version) else {
            return
        }
        setLine(next)
    }

    private func setLine(_ next: String) {
        guard next != line else { return }
        line = next
        onLineChange?(next)
    }

    /// The scheduler the host runs, logging each check and download.
    public static func makeScheduler(
        automaticUpdates: Bool,
        installability: UpdateInstallability,
        stateStore: UpdateStateStore,
        check: @escaping @MainActor () async -> UpdateCheckResult,
        stage: @escaping @MainActor (UpdateOffer) async -> Result<StagedUpdate, UpdateFailure>,
        isIdle: @escaping @MainActor () -> Bool,
        install: @escaping @MainActor (StagedUpdate) async -> UpdateHandoffOutcome,
        log: @escaping (String) -> Void = HostUpdateLog.record,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> UpdateScheduler {
        UpdateScheduler(
            flavor: .host(isIdle: isIdle, install: install),
            installability: installability,
            stateStore: stateStore,
            automaticUpdates: automaticUpdates,
            sleep: sleep,
            check: {
                log("checking for updates")
                let result = await check()
                log(HostUpdateLog.describe(result))
                return result
            },
            stage: { offer in
                log("downloading Sensorium Host \(offer.version)")
                let result = await stage(offer)
                log(HostUpdateLog.describeStage(result, version: offer.version))
                return result
            }
        )
    }
}
