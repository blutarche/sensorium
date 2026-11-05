import Foundation

/// What the viewer's update line reads.
public enum LinuxUpdateStatus: Equatable, Sendable {
    /// Up to date, or not checked yet.
    case current
    case checking
    case downloading(LinuxUpdateVersion)
    /// Staged and tested: **Restart Now** installs it.
    case ready(LinuxUpdateVersion)
    /// A release that failed in a way that could pass on another try, held
    /// until the next scheduled check.
    case waiting(LinuxUpdateVersion)
    /// Finishes "… could not update: `<reason>`."
    case failed(reason: String)
    /// The data root is one this viewer cannot install into.
    case notUpdatable
}

/// Runs checks at launch and every six hours while automatic updates are
/// on, and makes no request at all while they are off until
/// `checkForUpdates()` is called. Holds a staged update until **Restart
/// Now** installs it, then hears back through `installFinished`.
@MainActor
public final class LinuxUpdateScheduler {
    public nonisolated static let checkInterval: Duration = .seconds(Int64(LinuxUpdateState.checkInterval))

    public private(set) var status: LinuxUpdateStatus {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    public var onStatusChange: (@MainActor (LinuxUpdateStatus) -> Void)?

    /// The update downloaded and tested, not switched to yet.
    public private(set) var stagedUpdate: LinuxStagedUpdate?

    /// **Check for Updates Automatically**. Turning it on checks at once.
    public var automaticUpdates: Bool {
        didSet {
            guard automaticUpdates != oldValue else { return }
            if automaticUpdates {
                startSchedule()
            } else {
                stop()
            }
        }
    }

    private let installability: LinuxUpdateInstallability
    private let stateStore: LinuxUpdateStateStore
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let check: @MainActor () async -> LinuxUpdateCheckResult
    private let stage: @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>
    private var schedule: Task<Void, Never>?
    private var isChecking = false

    public init(
        installability: LinuxUpdateInstallability,
        stateStore: LinuxUpdateStateStore,
        automaticUpdates: Bool,
        interval: Duration = LinuxUpdateScheduler.checkInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> LinuxUpdateCheckResult,
        stage: @escaping @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>
    ) {
        self.installability = installability
        self.stateStore = stateStore
        self.automaticUpdates = automaticUpdates
        self.interval = interval
        self.sleep = sleep
        self.check = check
        self.stage = stage
        status = installability == .updatable ? .current : .notUpdatable
    }

    /// Call once at launch.
    public func start() {
        if automaticUpdates {
            startSchedule()
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
    }

    /// **Check for Updates…**: clears every recorded failure and checks at
    /// once, whether or not automatic updates are on.
    public func checkForUpdates() async {
        _ = try? stateStore.update { $0.clearFailures() }
        await runCheck()
    }

    /// How **Restart Now** of `staged` ended: nil once the new version took
    /// over.
    public func installFinished(_ staged: LinuxStagedUpdate, failure: LinuxUpdateFailure?) {
        if stagedUpdate == staged {
            stagedUpdate = nil
        }
        if let failure {
            status = record(failure, version: staged.version, sha256: staged.sha256)
        }
    }

    /// A launch found a switch the new version never confirmed and rolled it
    /// back: that version did not start in time.
    public func recordStartupRollback(_ pending: LinuxUpdatePendingSwitch) {
        _ = try? stateStore.update { $0.recordFailure(.readyLate, version: pending.version, sha256: pending.sha256) }
    }

    private func startSchedule() {
        guard schedule == nil else { return }
        let sleep = sleep
        let interval = interval
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runCheck()
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                if self == nil || Task.isCancelled { return }
            }
        }
    }

    private func runCheck() async {
        guard installability == .updatable else {
            status = .notUpdatable
            return
        }
        guard stagedUpdate == nil, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let before = status
        status = .checking
        switch await check() {
        case .upToDate:
            status = .current
        case .unreachable:
            status = before
        case let .failed(failure):
            status = .failed(reason: failure.reason)
        case let .givenUp(_, reason):
            status = .failed(reason: reason)
        case let .heldBack(manifest):
            status = .waiting(manifest.version)
        case let .available(manifest):
            status = .downloading(manifest.version)
            switch await stage(manifest) {
            case let .success(staged):
                stagedUpdate = staged
                status = .ready(staged.version)
            case let .failure(failure):
                status = record(failure, version: manifest.version, sha256: manifest.sha256)
            }
        }
    }

    /// The *Failed* line after a bad release or the last try; otherwise the
    /// update keeps waiting for the next check.
    private func record(_ failure: LinuxUpdateFailure, version: LinuxUpdateVersion, sha256: String) -> LinuxUpdateStatus {
        let state = (try? stateStore.update { $0.recordFailure(failure, version: version, sha256: sha256) }) ?? stateStore.load()
        if failure.kind == .badRelease || state.hasGivenUp(on: version, sha256: sha256) {
            return .failed(reason: failure.reason)
        }
        return .waiting(version)
    }
}
