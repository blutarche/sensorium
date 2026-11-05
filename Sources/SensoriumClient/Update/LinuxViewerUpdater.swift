#if os(Linux)
import Foundation
import SensoriumLinuxUpdate

/// The Linux viewer's side of self-update, as section 11 of
/// `docs/self-update-design.md` describes: checks at launch and every six
/// hours while automatic updates are on, holds a staged update for
/// **Restart Now**, and keeps the *Your Machines* line. Nothing installs at
/// quit: a staged update that was not restarted into waits for the next
/// launch's check.
@MainActor
public final class LinuxViewerUpdater {
    public private(set) var line: ViewerUpdateLine?
    public var onLineChange: ((ViewerUpdateLine?) -> Void)?

    public var checksAutomatically: Bool { scheduler.automaticUpdates }

    private let scheduler: LinuxUpdateScheduler
    private let lastCheck: LinuxLastCheck
    private let runningVersion: LinuxUpdateVersion
    private let installation: LinuxUpdateInstallation
    private let preferences: any ViewerUpdatePreferencesStoring
    private let replacing: ViewerReplacement?
    private let restart: @MainActor (LinuxStagedUpdate) async -> LinuxUpdateRestartOutcome
    private let adoptLauncherEntry: @MainActor () -> Void
    private let onTerminate: @MainActor () -> Void
    private let log: @MainActor (String) -> Void
    private var manualCheck: ViewerManualCheck = .none
    private var sessionInProgress = false
    private var isRestarting = false
    private var restartFailureReason: String?
    private var hasConfirmed = false

    public init(
        runningVersion: LinuxUpdateVersion,
        installation: LinuxUpdateInstallation,
        installability: LinuxUpdateInstallability,
        stateStore: LinuxUpdateStateStore,
        preferences: any ViewerUpdatePreferencesStoring,
        replacing: ViewerReplacement?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> LinuxUpdateCheckResult,
        stage: @escaping @MainActor (LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure>,
        restart: @escaping @MainActor (LinuxStagedUpdate) async -> LinuxUpdateRestartOutcome,
        adoptLauncherEntry: @escaping @MainActor () -> Void,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void
    ) {
        let lastCheck = LinuxLastCheck()
        self.lastCheck = lastCheck
        self.runningVersion = runningVersion
        self.installation = installation
        self.preferences = preferences
        self.replacing = replacing
        self.restart = restart
        self.adoptLauncherEntry = adoptLauncherEntry
        self.onTerminate = onTerminate
        self.log = log
        scheduler = LinuxUpdateScheduler(
            installability: installability,
            stateStore: stateStore,
            automaticUpdates: preferences.checksAutomatically(),
            sleep: sleep,
            check: {
                // The scheduler answers a check that reached nothing by
                // keeping the status it had, which cannot tell a chosen
                // check whether it found the running version current.
                let result = await check()
                lastCheck.result = result
                if result == .unreachable {
                    lastCheck.restoresStatus = true
                    log("update: the release page could not be reached")
                }
                return result
            },
            stage: stage
        )
        line = makeLine()
        scheduler.onStatusChange = { [weak self] status in
            self?.statusChanged(status)
        }
    }

    /// The updater for this viewer, or nil in a build with no release
    /// version, such as one built from source without one. Without it there
    /// is no check, no line, no menu item and no rollback.
    public static func make(
        releaseVersion: String,
        dataRoot: URL,
        replacing: ViewerReplacement?,
        transport: any LinuxUpdateTransport,
        launcherFolders: LinuxViewerLauncherFolders,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void = { print("Sensorium: \($0)") }
    ) -> LinuxViewerUpdater? {
        guard let runningVersion = runningVersion(releaseVersion) else { return nil }
        let installation = LinuxUpdateInstallation(dataRoot: dataRoot)
        let installability = installation.installability()
        let stateStore = LinuxUpdateStateStore(dataRoot: dataRoot)
        let checker = LinuxUpdateChecker(runningVersion: runningVersion, transport: transport, stateStore: stateStore)
        let stager = LinuxUpdateStager(installation: installation, transport: transport)
        let restart = LinuxUpdateRestart(installation: installation)
        return LinuxViewerUpdater(
            runningVersion: runningVersion,
            installation: installation,
            installability: installability,
            stateStore: stateStore,
            preferences: FileViewerUpdatePreferencesStore(
                url: dataRoot.appendingPathComponent(FileViewerUpdatePreferencesStore.fileName)
            ),
            replacing: replacing,
            check: { await checker.check() },
            stage: { await stager.stage($0) },
            restart: { await restart.run($0) },
            adoptLauncherEntry: {
                do {
                    try LinuxUpdateLauncherEntry.install(
                        dataRoot: dataRoot,
                        packagedDesktopFile: LinuxViewerLocations.packagedDesktopFile,
                        packagedIconsDirectory: LinuxViewerLocations.packagedIconsFolder,
                        applicationsDirectory: launcherFolders.applications,
                        iconsDirectory: launcherFolders.icons
                    )
                } catch {
                    // A viewer not installed by the package has no entry to
                    // adopt, and keeps whatever launcher it was given.
                    log("update: the launcher entry was not written: \(error)")
                }
            },
            onTerminate: onTerminate,
            log: log
        )
    }

    /// `ViewerRelease.version`, when it is a release version.
    public nonisolated static func runningVersion(_ releaseVersion: String) -> LinuxUpdateVersion? {
        LinuxUpdateVersion(releaseVersion)
    }

    /// Before any window: a switch the new version never confirmed is rolled
    /// back, unless this process is that version started with `--replacing`.
    /// Returns the switch that was rolled back.
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

    /// Call once at launch.
    public func start() {
        if !installation.removeAbandonedWorkFolders().isEmpty {
            log("update: removed the folders an interrupted update left behind")
        }
        scheduler.start()
    }

    public func stop() {
        scheduler.stop()
    }

    /// **Check for Updates…**: clears recorded failures and checks now,
    /// whether or not automatic updates are on.
    public func checkForUpdates() async {
        manualCheck = .pending
        lastCheck.result = nil
        refresh()
        await scheduler.checkForUpdates()
        settleManualCheck()
        refresh()
    }

    /// **Check for Updates Automatically**. Off stops every update request
    /// until it is turned on again or **Check for Updates…** is chosen.
    public func setChecksAutomatically(_ on: Bool) {
        preferences.remember(checksAutomatically: on)
        scheduler.automaticUpdates = on
        log(on ? "update: automatic checks are on" : "update: automatic checks are off")
    }

    /// From when a session run starts until it has ended and its windows
    /// are closed. **Restart Now** is offered only outside that span.
    public func sessionRunChanged(_ inProgress: Bool) {
        sessionInProgress = inProgress
        refresh()
    }

    /// *Your Machines* came on screen. An answered check stops being shown,
    /// and a version started to replace another reports ready, then
    /// confirms the switch, then adopts the launcher entry. The ready file
    /// comes first: a version that could not write it never confirms, so
    /// the old viewer, which then gives up waiting, finds the switch as it
    /// made it and puts the previous version back. The old viewer's last
    /// look at the ready file is under the lock the confirmation takes, so
    /// it never switches back under a version that has confirmed.
    public func windowDidShow() {
        if case .answered = manualCheck {
            manualCheck = .none
            refresh()
        }
        guard let replacing, !hasConfirmed else { return }
        hasConfirmed = true
        do {
            try LinuxUpdateHandoff.reportReady(version: runningVersion, to: replacing.readyFile)
            log("update: \(runningVersion) is ready")
        } catch {
            log("update: could not report ready, so the switch to \(runningVersion) is left unconfirmed: \(error)")
            return
        }
        switch installation.markConfirmed(version: runningVersion) {
        case .confirmed:
            break
        case .nothingPending, .notPending:
            // The old viewer gave up waiting and switched back, and is still
            // running: this one is not the version `current` names.
            log("update: \(runningVersion) has no switch to confirm, so it quits and the running version stays")
            onTerminate()
            return
        }
        adoptLauncherEntry()
    }

    /// **Restart Now**: switch to the staged update and hand off to it. This
    /// process quits through `onTerminate` once the new version reports
    /// ready, and otherwise carries on with the line saying why.
    public func restartNow() async {
        guard let staged = scheduler.stagedUpdate, !sessionInProgress, !isRestarting else {
            return
        }
        isRestarting = true
        restartFailureReason = nil
        refresh()
        log("update: restarting into \(staged.version)")
        switch await restart(staged) {
        case .tookOver:
            scheduler.installFinished(staged, failure: nil)
            log("update: \(staged.version) took over")
            onTerminate()
        case let .failed(failure):
            scheduler.installFinished(staged, failure: failure)
            isRestarting = false
            restartFailureReason = failure.reason
            log("update: Sensorium could not update: \(failure.reason)")
            refresh()
        }
    }

    private func statusChanged(_ status: LinuxUpdateStatus) {
        restartFailureReason = nil
        if lastCheck.restoresStatus {
            lastCheck.restoresStatus = false
        } else {
            logStatus(status)
        }
        settleManualCheck()
        refresh()
    }

    private func logStatus(_ status: LinuxUpdateStatus) {
        switch status {
        case .current:
            log("update: \(runningVersion) is up to date")
        case .checking:
            log("update: checking for updates")
        case let .downloading(version):
            log("update: downloading \(version)")
        case let .ready(version):
            log("update: \(version) is ready")
        case let .waiting(version):
            log("update: \(version) will be tried again at the next check")
        case let .failed(reason):
            log("update: Sensorium could not update: \(reason)")
        case .notUpdatable:
            log("update: this viewer cannot write to its own folder, so it does not update itself")
        }
    }

    /// A chosen check is answered once the scheduler stops checking. Only
    /// *up to date* is the check's own answer; a ready update, a failure or
    /// a viewer that cannot update says so through its own line.
    private func settleManualCheck() {
        guard manualCheck == .pending else { return }
        switch scheduler.status {
        case .checking, .downloading:
            return
        case .current:
            manualCheck = .answered(upToDate: lastCheck.result == .upToDate)
        case .ready, .waiting, .failed, .notUpdatable:
            manualCheck = .none
        }
    }

    private func refresh() {
        let next = makeLine()
        guard next != line else { return }
        line = next
        onLineChange?(next)
    }

    private func makeLine() -> ViewerUpdateLine? {
        let status: ViewerUpdateLineStatus = switch scheduler.status {
        case .current: .current
        case .checking, .downloading, .waiting: .busy
        case let .ready(version): .ready(version: version.description)
        case let .failed(reason): .failed(reason: reason)
        case .notUpdatable: .notUpdatable
        }
        return ViewerUpdateLine.make(
            status: status,
            runningVersion: runningVersion.description,
            platform: .linux,
            manualCheck: manualCheck,
            sessionInProgress: sessionInProgress,
            isRestarting: isRestarting,
            restartFailureReason: restartFailureReason
        )
    }
}

/// What the most recent check answered, recorded by the check the
/// scheduler runs.
@MainActor
private final class LinuxLastCheck {
    var result: LinuxUpdateCheckResult?
    /// Set when a check reached nothing: the scheduler's next status change
    /// only puts back the status it had before checking.
    var restoresStatus = false
}
#endif
