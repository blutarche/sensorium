#if os(Linux)
import Foundation
import Glibc
import SensoriumLinuxUpdate

/// What the updater needs from the running host.
@MainActor
public protocol LinuxHostUpdateServing: AnyObject {
    func isIdleForUpdate(now: Date) -> Bool
    func updateIdleRecheckDate(now: Date) -> Date?
    func suspendForUpdate() async -> LinuxUpdateReadyReport.Host?
    func resumeAfterUpdate() async
    func servingValues() -> LinuxUpdateReadyReport.Host?
}

extension LinuxHostRuntime: LinuxHostUpdateServing {}

/// The Linux host's side of self-update, as `docs/self-update-design.md`
/// describes: checks at launch and every six hours, and installs a staged
/// update on its own once no machine is connected and no pairing is in
/// progress. The host has no **Restart Now**.
@MainActor
public final class LinuxHostUpdater {
    /// Nil until there is something to say; see `LinuxHostUpdateStatusLine`.
    public private(set) var line: HostWindowUpdateLine?
    public var onLineChange: ((HostWindowUpdateLine?) -> Void)?

    private let scheduler: LinuxUpdateScheduler
    private let answers: LinuxHostCheckAnswers
    private let runningVersion: LinuxUpdateVersion
    private let installation: LinuxUpdateInstallation
    private weak var host: (any LinuxHostUpdateServing)?
    private let replacing: LinuxHostReplacement?
    private let parentProcess: @MainActor () -> pid_t
    private let parentPollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let afterConfirm: @MainActor () -> Void
    private let onTerminate: @MainActor () -> Void
    private let log: @MainActor (String) -> Void
    private var hostHasStarted = false
    private var hasReported = false
    private var recheck: Task<Void, Never>?
    private var parentWatch: Task<Void, Never>?

    /// `handOver` switches to the staged version and waits for it to report
    /// ready, and `afterFailedHandover` takes back what the host gave up for
    /// it beyond its listener and grant. `afterConfirm` runs once a version
    /// started with `--replacing` has confirmed the switch.
    public init(
        runningVersion: LinuxUpdateVersion,
        installation: LinuxUpdateInstallation,
        installability: LinuxUpdateInstallability,
        stateStore: LinuxUpdateStateStore,
        host: any LinuxHostUpdateServing,
        replacing: LinuxHostReplacement?,
        parentProcess: @escaping @MainActor () -> pid_t = { getppid() },
        parentPollInterval: Duration = .milliseconds(500),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> LinuxUpdateCheckResult,
        stage: @escaping @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>,
        handOver: @escaping @MainActor (LinuxStagedUpdate, LinuxUpdateReadyReport.Host) async -> LinuxUpdateRestartOutcome,
        afterFailedHandover: @escaping @MainActor () -> Void,
        afterConfirm: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void
    ) {
        let answers = LinuxHostCheckAnswers()
        self.answers = answers
        self.runningVersion = runningVersion
        self.installation = installation
        self.host = host
        self.replacing = replacing
        self.parentProcess = parentProcess
        self.parentPollInterval = parentPollInterval
        self.sleep = sleep
        self.afterConfirm = afterConfirm
        self.onTerminate = onTerminate
        self.log = log
        weak let weakHost = host
        scheduler = LinuxUpdateScheduler(
            installability: installability,
            stateStore: stateStore,
            automaticUpdates: true,
            flavor: .host(
                isIdle: { weakHost?.isIdleForUpdate(now: Date()) ?? false },
                install: { staged in
                    guard let host = weakHost, let baseline = await host.suspendForUpdate() else {
                        log("update: a machine connected as \(staged.version) was about to install, so it waits")
                        return .busy
                    }
                    log("update: handing over to \(staged.version)")
                    switch await handOver(staged, baseline) {
                    case .tookOver:
                        log("update: \(staged.version) took over")
                        onTerminate()
                        return .tookOver
                    case let .failed(failure):
                        log("update: Sensorium Host could not update: \(failure.reason)")
                        await host.resumeAfterUpdate()
                        afterFailedHandover()
                        return .failed(failure)
                    }
                }
            ),
            sleep: sleep,
            check: {
                let result = await check()
                switch result {
                case .upToDate:
                    answers.upToDateThisLaunch = true
                case .unreachable:
                    log("update: the release page could not be reached")
                default:
                    break
                }
                return result
            },
            stage: stage
        )
        line = LinuxHostUpdateStatusLine.line(for: scheduler.status, runningVersion: runningVersion, upToDateAnswered: false)
        scheduler.onStatusChange = { [weak self] status in
            self?.statusChanged(status)
        }
    }

    /// The updater for this host, or nil in a build with no release version,
    /// such as one built from source without one. Without it there is no
    /// check, no line and no rollback.
    public static func make(
        releaseVersion: String,
        dataRoot: URL,
        host: LinuxHostRuntime,
        replacing: LinuxHostReplacement?,
        transport: any LinuxUpdateTransport = URLSessionLinuxUpdateTransport(),
        autostart: HostAutostart,
        launcherFolders: (applications: URL, icons: URL),
        afterFailedHandover: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void = { print("Sensorium host: \($0)") }
    ) -> LinuxHostUpdater? {
        guard let runningVersion = LinuxUpdateVersion(releaseVersion) else { return nil }
        let installation = LinuxUpdateInstallation(dataRoot: dataRoot, app: .host)
        let stateStore = LinuxUpdateStateStore(dataRoot: dataRoot, app: .host)
        let checker = LinuxUpdateChecker(runningVersion: runningVersion, transport: transport, stateStore: stateStore, app: .host)
        let stager = LinuxUpdateStager(installation: installation, transport: transport)
        let restart = LinuxUpdateRestart(installation: installation)
        return LinuxHostUpdater(
            runningVersion: runningVersion,
            installation: installation,
            installability: installation.installability(),
            stateStore: stateStore,
            host: host,
            replacing: replacing,
            check: { await checker.check() },
            stage: { await stager.stage($0) },
            handOver: { await restart.run($0, hostBaseline: $1) },
            afterFailedHandover: afterFailedHandover,
            afterConfirm: {
                do {
                    try LinuxUpdateLauncherEntry.install(
                        app: .host,
                        dataRoot: dataRoot,
                        packagedDesktopFile: LinuxHostLocations.packagedDesktopFile,
                        packagedIconsDirectory: LinuxHostLocations.packagedIconsFolder,
                        applicationsDirectory: launcherFolders.applications,
                        iconsDirectory: launcherFolders.icons
                    )
                } catch {
                    // A host not installed by the package has no entry to
                    // adopt, and keeps whatever launcher it was given.
                    log("update: the launcher entry was not written: \(error)")
                }
                do {
                    try autostart.repointIfEnabled()
                } catch {
                    log("update: Open at login could not be pointed at the installed version: \(error)")
                }
            },
            onTerminate: onTerminate,
            log: log
        )
    }

    /// Before the host starts: a switch the new version never confirmed is
    /// rolled back, unless this process is that version started with
    /// `--replacing`. Returns the switch that was rolled back.
    @discardableResult
    public func rollBackUnconfirmedSwitch() -> LinuxUpdatePendingSwitch? {
        let startup: LinuxUpdateStartup = replacing == nil ? .normal : .replacing(runningVersion)
        switch installation.rollbackIfUnconfirmed(startup: startup) {
        case .nothingPending, .awaitingConfirmation:
            return nil
        case let .rolledBack(pending):
            scheduler.recordStartupRollback(pending)
            log("update: \(pending.version) never confirmed it started, so this launch went back to \(pending.previous.map(\.description) ?? "the installed version")")
            return pending
        case let .failed(pending):
            log("update: could not switch back from \(pending.version), which never confirmed it started")
            return nil
        }
    }

    /// Call once the host has started: it has tried to listen and to restore
    /// the screen-sharing grant. A version started to replace another
    /// reports ready as soon as it listens, and checks for updates only once
    /// the host it replaced has exited.
    public func hostDidStart() {
        hostHasStarted = true
        if !installation.removeAbandonedWorkFolders().isEmpty {
            log("update: removed the folders an interrupted update left behind")
        }
        if replacing == nil {
            scheduler.start()
        } else {
            reportReadyIfServing()
        }
    }

    public func stop() {
        scheduler.stop()
        recheck?.cancel()
        recheck = nil
        parentWatch?.cancel()
        parentWatch = nil
    }

    /// Call on every change that can make the host idle. A waiting update
    /// installs the moment the host is idle.
    public func hostActivityChanged() {
        guard hostHasStarted else { return }
        if replacing != nil, !hasReported {
            reportReadyIfServing()
        }
        recheck?.cancel()
        recheck = nil
        // Nothing reports a pairing code running out, so look again then.
        if let date = host?.updateIdleRecheckDate(now: Date()) {
            let delay = max(0, date.timeIntervalSinceNow) + 1
            let sleep = sleep
            recheck = Task { [weak self] in
                guard (try? await sleep(.milliseconds(Int64(delay * 1000)))) != nil else { return }
                await self?.scheduler.installIfIdle()
            }
        }
        Task { [weak self] in
            await self?.scheduler.installIfIdle()
        }
    }

    /// The ready file comes first: a version that could not write it never
    /// confirms, so the old host, which then gives up waiting, finds the
    /// switch as it made it and puts the previous version back. The old
    /// host's last look at the ready file is under the lock the confirmation
    /// takes, so it never switches back under a version that has confirmed.
    private func reportReadyIfServing() {
        guard let replacing, !hasReported, let serving = host?.servingValues() else { return }
        hasReported = true
        do {
            try LinuxUpdateHandoff.reportReady(version: runningVersion, to: replacing.readyFile, host: serving)
            log("update: \(runningVersion) is ready")
        } catch {
            log("update: could not report ready, so the switch to \(runningVersion) is left unconfirmed: \(error)")
            return
        }
        switch installation.markConfirmed(version: runningVersion) {
        case .confirmed:
            break
        case .nothingPending, .notPending:
            // The old host gave up waiting and switched back, and serves
            // again: this one is not the version `current` names.
            log("update: \(runningVersion) has no switch to confirm, so it quits and the running version stays")
            onTerminate()
            return
        }
        afterConfirm()
        startOnceReplacedHostExits(replacing.pid)
    }

    /// The replaced host is this one's parent until it exits, and a check
    /// before then could start a second handover under it.
    private func startOnceReplacedHostExits(_ pid: pid_t) {
        let sleep = sleep
        let interval = parentPollInterval
        parentWatch = Task { [weak self] in
            while let self, self.parentProcess() == pid {
                guard (try? await sleep(interval)) != nil else { return }
            }
            self?.scheduler.start()
        }
    }

    private func statusChanged(_ status: LinuxUpdateStatus) {
        logStatus(status)
        switch status {
        case .checking, .downloading:
            // A check that finds nothing should not flicker the line.
            return
        case .current, .ready, .waiting, .failed, .notUpdatable:
            let next = LinuxHostUpdateStatusLine.line(
                for: status, runningVersion: runningVersion, upToDateAnswered: answers.upToDateThisLaunch
            )
            guard next != line else { return }
            line = next
            onLineChange?(next)
        }
    }

    private func logStatus(_ status: LinuxUpdateStatus) {
        switch status {
        case .current:
            if answers.upToDateThisLaunch { log("update: \(runningVersion) is up to date") }
        case .checking:
            log("update: checking for updates")
        case let .downloading(version):
            log("update: downloading \(version)")
        case let .ready(version), let .waiting(version):
            log("update: \(version) will install when no machine is connected")
        case let .failed(reason):
            log("update: Sensorium Host could not update: \(reason)")
        case .notUpdatable:
            log("update: this host cannot write to its own folder, so it does not update itself")
        }
    }
}

/// Whether a check this launch has answered up to date. The scheduler
/// answers a check that reached nothing by keeping the status it had, which
/// reads the same as up to date.
@MainActor
private final class LinuxHostCheckAnswers {
    var upToDateThisLaunch = false
}
#endif
