import Foundation

/// What the app's update line reads.
public enum LinuxUpdateStatus: Equatable, Sendable {
    /// Up to date, or not checked yet.
    case current
    case checking
    case downloading(LinuxUpdateVersion)
    /// The viewer's update is staged and tested: **Restart Now** installs
    /// it.
    case ready(LinuxUpdateVersion)
    /// The host's update is staged and installs when no machine is
    /// connected; also a release that failed in a way that could pass on
    /// another try, held until the next scheduled check.
    case waiting(LinuxUpdateVersion)
    /// Finishes "… could not update: `<reason>`."
    case failed(reason: String)
    /// The data root is one this app cannot install into.
    case notUpdatable
}

/// How the host's own install of a staged update ended.
public enum LinuxUpdateInstallOutcome: Equatable, Sendable {
    /// The new host serves in this one's place: this process exits.
    case tookOver
    /// A session or pairing began while the listener was stopping. Nothing
    /// was switched, and the update stays staged for the next idle moment.
    case busy
    case failed(LinuxUpdateFailure)
}

/// Runs checks at launch and every six hours while automatic updates are
/// on, and makes no request at all while they are off until
/// `checkForUpdates()` is called.
@MainActor
public final class LinuxUpdateScheduler {
    public enum Flavor {
        /// Holds a staged update until **Restart Now** installs it, then
        /// hears back through `installFinished`.
        case viewer
        /// Installs a staged update whenever `isIdle` holds: no session
        /// live, no pairing in progress. `install` stops the listener,
        /// checks the host is still idle, and runs the handover.
        case host(
            isIdle: @MainActor () -> Bool,
            install: @MainActor (LinuxStagedUpdate) async -> LinuxUpdateInstallOutcome
        )
    }

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
    private let flavor: Flavor
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let check: @MainActor () async -> LinuxUpdateCheckResult
    private let stage: @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>
    private var schedule: Task<Void, Never>?
    private var isChecking = false
    private var isInstalling = false

    public init(
        installability: LinuxUpdateInstallability,
        stateStore: LinuxUpdateStateStore,
        automaticUpdates: Bool,
        flavor: Flavor = .viewer,
        interval: Duration = LinuxUpdateScheduler.checkInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> LinuxUpdateCheckResult,
        stage: @escaping @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>
    ) {
        self.installability = installability
        self.stateStore = stateStore
        self.automaticUpdates = automaticUpdates
        self.flavor = flavor
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

    /// The host calls this when a session ends or a pairing finishes, so a
    /// waiting update installs once the host is idle. The idle rule is
    /// checked here, right before installing, and once more by `install`
    /// after the listener stops.
    public func installIfIdle() async {
        guard case let .host(isIdle, install) = flavor, let staged = stagedUpdate, !isInstalling else {
            return
        }
        status = .waiting(staged.version)
        guard isIdle() else { return }
        isInstalling = true
        defer { isInstalling = false }
        switch await install(staged) {
        case .tookOver:
            installFinished(staged, failure: nil)
        case .busy:
            break
        case let .failed(failure):
            installFinished(staged, failure: failure)
        }
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
        if stagedUpdate == nil {
            await checkAndStage()
        }
        if case .host = flavor {
            await installIfIdle()
        }
    }

    private func checkAndStage() async {
        guard !isChecking, !isInstalling else { return }
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
                switch flavor {
                case .viewer: status = .ready(staged.version)
                case .host: status = .waiting(staged.version)
                }
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
