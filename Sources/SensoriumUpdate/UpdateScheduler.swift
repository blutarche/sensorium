#if os(macOS)
import Foundation

/// What the app's update line shows.
public enum UpdateStatus: Equatable, Sendable {
    /// Up to date, or not checked yet.
    case current
    case checking
    case downloading(UpdateVersion)
    /// The viewer's update is staged: **Restart Now**, or it installs at
    /// quit.
    case ready(UpdateVersion)
    /// The host's update is staged and installs when no machine is
    /// connected; also an update between tries after a failure that could
    /// pass on another try.
    case waiting(UpdateVersion)
    /// Finishes "… could not update: `<reason>`."
    case failed(reason: String)
    /// The app runs from a place it cannot replace itself in.
    case notUpdatable
}

/// Runs checks at launch and every six hours while automatic updates are
/// on, and makes no request at all while they are off until
/// `checkForUpdates()` is called.
@MainActor
public final class UpdateScheduler {
    public enum Flavor {
        /// Holds a staged update until the app installs it at quit or on
        /// **Restart Now**, then reports back through `installFinished`.
        case viewer
        /// Installs a staged update whenever `isIdle` holds: no session
        /// live, no pairing in progress. `install` stops the listener, runs
        /// `UpdateInstaller.installAndHandOff(_:baseline:rollback:)` with
        /// `.relaunchPrevious`, and quits when the outcome says to.
        case host(
            isIdle: @MainActor () -> Bool,
            install: @MainActor (StagedUpdate) async -> UpdateHandoffOutcome
        )
    }

    public nonisolated static let checkInterval: Duration = .seconds(6 * 60 * 60)

    public private(set) var status: UpdateStatus {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    public var onStatusChange: (@MainActor (UpdateStatus) -> Void)?

    /// The update downloaded and checked, not yet installed.
    public private(set) var stagedUpdate: StagedUpdate?

    /// **Install updates automatically** (host) or **Check for Updates
    /// Automatically** (viewer). Turning it on checks at once.
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

    private let flavor: Flavor
    private let installability: UpdateInstallability
    private let stateStore: UpdateStateStore
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let check: @MainActor () async -> UpdateCheckResult
    private let stage: @MainActor (UpdateOffer) async -> Result<StagedUpdate, UpdateFailure>
    private var schedule: Task<Void, Never>?
    private var isChecking = false
    private var isInstalling = false

    /// `installability` is `UpdateInstaller.installability(of:
    /// Bundle.main.bundleURL)`.
    public convenience init(
        flavor: Flavor,
        installability: UpdateInstallability,
        checker: UpdateChecker,
        stager: UpdateStager,
        stateStore: UpdateStateStore,
        automaticUpdates: Bool
    ) {
        self.init(
            flavor: flavor,
            installability: installability,
            stateStore: stateStore,
            automaticUpdates: automaticUpdates,
            check: { await checker.check() },
            stage: { await stager.stage($0) }
        )
    }

    public init(
        flavor: Flavor,
        installability: UpdateInstallability,
        stateStore: UpdateStateStore,
        automaticUpdates: Bool,
        interval: Duration = UpdateScheduler.checkInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> UpdateCheckResult,
        stage: @escaping @MainActor (UpdateOffer) async -> Result<StagedUpdate, UpdateFailure>
    ) {
        self.flavor = flavor
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

    /// The host calls this when a session ends or a pairing finishes, so a
    /// waiting update installs once the host is idle. The idle rule is
    /// checked here, right before installing.
    public func installIfIdle() async {
        guard case let .host(isIdle, install) = flavor, let staged = stagedUpdate, !isInstalling else {
            return
        }
        guard isIdle() else {
            status = .waiting(staged.version)
            return
        }
        isInstalling = true
        stagedUpdate = nil
        let outcome = await install(staged)
        isInstalling = false
        installFinished(staged, outcome: outcome)
    }

    /// Records how an install of `staged` ended: the viewer's **Restart
    /// Now**, and the host's own installs.
    public func installFinished(_ staged: StagedUpdate, outcome: UpdateHandoffOutcome) {
        if case .notUpdatable = outcome {
            finish(staged, failure: nil, notUpdatable: true)
        } else {
            finish(staged, failure: outcome.failure, notUpdatable: false)
        }
    }

    /// Records how the viewer's install at quit ended, for its next launch.
    public func installFinished(_ staged: StagedUpdate, atQuit outcome: UpdateQuitInstallOutcome) {
        switch outcome {
        case .installed:
            finish(staged, failure: nil, notUpdatable: false)
        case .notUpdatable:
            finish(staged, failure: nil, notUpdatable: true)
        case let .failed(failure), let .swapBackFailed(failure):
            finish(staged, failure: failure, notUpdatable: false)
        }
    }

    private func finish(_ staged: StagedUpdate, failure: UpdateFailure?, notUpdatable: Bool) {
        if stagedUpdate == staged {
            stagedUpdate = nil
        }
        if notUpdatable {
            status = .notUpdatable
        } else if let failure {
            status = record(failure, version: staged.version, sha256: staged.sha256)
        }
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
                if self == nil { return }
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
        case let .heldBack(offer):
            status = .waiting(offer.version)
        case let .available(offer):
            status = .downloading(offer.version)
            switch await stage(offer) {
            case let .success(staged):
                stagedUpdate = staged
                switch flavor {
                case .viewer: status = .ready(staged.version)
                case .host: status = .waiting(staged.version)
                }
            case let .failure(failure):
                status = record(failure, version: offer.version, sha256: offer.app.sha256)
            }
        }
    }

    /// The *Failed* line after a bad release or the last try; otherwise the
    /// update keeps waiting for the next check.
    private func record(_ failure: UpdateFailure, version: UpdateVersion, sha256: String) -> UpdateStatus {
        let state = (try? stateStore.update { $0.recordFailure(failure, version: version, sha256: sha256) }) ?? stateStore.load()
        if failure.kind == .badRelease || state.hasGivenUp(on: version, sha256: sha256) {
            return .failed(reason: failure.reason)
        }
        return .waiting(version)
    }
}
#endif
