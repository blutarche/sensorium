#if os(macOS)
import Foundation
import SensoriumUpdate

/// The two installs the viewer runs. Behind a protocol so tests never swap
/// or launch an app.
@MainActor
public protocol ViewerUpdateInstalling: AnyObject {
    func installWithoutRelaunch(_ staged: StagedUpdate) -> UpdateQuitInstallOutcome
    func installAndHandOff(
        _ staged: StagedUpdate,
        baseline: UpdateReadyReport,
        rollback: UpdateInstaller.Rollback
    ) async -> UpdateHandoffOutcome
}

extension UpdateInstaller: ViewerUpdateInstalling {}

/// The viewer's side of self-update, as sections 1.2 and 3.4 of
/// `docs/self-update-design.md` describe: checks at launch and every six
/// hours while automatic updates are on, holds a staged update for
/// **Restart Now** or the next quit, and keeps the *Your Machines* line.
@MainActor
public final class ViewerUpdater {
    /// Waits for the replaced process to exit, then removes its staging
    /// folder: `UpdateHandoff.finishReplacing` outside tests.
    public typealias FinishReplacing = @Sendable (_ pid: pid_t, _ readyFile: URL, _ appName: String) async -> Bool

    public private(set) var line: ViewerUpdateLine?
    public var onLineChange: ((ViewerUpdateLine?) -> Void)?

    public var checksAutomatically: Bool { scheduler.automaticUpdates }
    public var stagedUpdate: StagedUpdate? { scheduler.stagedUpdate }

    private let scheduler: UpdateScheduler
    private let lastCheck: LastCheck
    private let runningVersion: UpdateVersion
    private let appName: String
    private let preferences: any ViewerUpdatePreferencesStoring
    private let installer: any ViewerUpdateInstalling
    private let replacing: ViewerReplacement?
    private let loginItemStatus: @MainActor () -> String
    private let finishReplacing: FinishReplacing
    private let onTerminate: @MainActor () -> Void
    private let log: @MainActor (String) -> Void
    private var manualCheck: ViewerManualCheck = .none
    private var sessionInProgress = false
    private var isRestarting = false
    private var isHandingOff = false
    /// Quits that began while **Restart Now** was handing off, run once the
    /// handoff has ended.
    private var afterHandOff: [@MainActor () -> Void] = []
    private var restartFailureReason: String?
    private var hasReportedReady = false
    private var hasRunQuitInstall = false

    public init(
        runningVersion: UpdateVersion,
        appName: String,
        installability: UpdateInstallability,
        stateStore: UpdateStateStore,
        preferences: any ViewerUpdatePreferencesStoring,
        installer: any ViewerUpdateInstalling,
        replacing: ViewerReplacement?,
        loginItemStatus: @escaping @MainActor () -> String = { UpdateReadyReport.LoginItemStatus.current() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        check: @escaping @MainActor () async -> UpdateCheckResult,
        stage: @escaping @MainActor (UpdateOffer) async -> Result<StagedUpdate, UpdateFailure>,
        finishReplacing: @escaping FinishReplacing,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void
    ) {
        let lastCheck = LastCheck()
        self.lastCheck = lastCheck
        self.runningVersion = runningVersion
        self.appName = appName
        self.preferences = preferences
        self.installer = installer
        self.replacing = replacing
        self.loginItemStatus = loginItemStatus
        self.finishReplacing = finishReplacing
        self.onTerminate = onTerminate
        self.log = log
        scheduler = UpdateScheduler(
            flavor: .viewer,
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

    /// The updater for this app, or nil when it has nothing to update: a
    /// build with no release version, such as `swift run`, or one whose
    /// signature cannot be read. Without one there is no check, no line and
    /// no menu item.
    public static func make(
        bundle: Bundle,
        applicationSupportDirectory: URL,
        replacing: ViewerReplacement?,
        onTerminate: @escaping @MainActor () -> Void,
        log: @escaping @MainActor (String) -> Void = { print("Sensorium: \($0)") }
    ) -> ViewerUpdater? {
        guard let runningVersion = runningVersion(infoDictionary: bundle.infoDictionary),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        guard let requirement = CodeRequirementCheck.runningApp() else {
            log("update: this app's signature could not be read, so it does not update itself")
            return nil
        }
        let appURL = bundle.bundleURL
        let stateStore = UpdateStateStore(role: .viewer, directory: applicationSupportDirectory)
        let checker = UpdateChecker(role: .viewer, runningVersion: runningVersion, stateStore: stateStore)
        let stager = UpdateStager(installedAppURL: appURL, bundleIdentifier: bundleIdentifier, requirement: requirement)
        return ViewerUpdater(
            runningVersion: runningVersion,
            appName: appURL.lastPathComponent,
            installability: UpdateInstaller.installability(of: appURL),
            stateStore: stateStore,
            preferences: FileViewerUpdatePreferencesStore(
                url: applicationSupportDirectory.appendingPathComponent(FileViewerUpdatePreferencesStore.fileName)
            ),
            installer: UpdateInstaller(
                installedAppURL: appURL,
                requirement: requirement,
                launcher: WorkspaceUpdateAppLauncher()
            ),
            replacing: replacing,
            check: { await checker.check() },
            stage: { await stager.stage($0) },
            finishReplacing: { pid, readyFile, appName in
                let folder = readyFile.deletingLastPathComponent().path
                return await UpdateHandoff.finishReplacing(oldProcess: pid, readyFile: readyFile, appName: appName) {
                    print("Sensorium: update: \($0.replacingOccurrences(of: folder, with: "the staging folder"))")
                }
            },
            onTerminate: onTerminate,
            log: log
        )
    }

    /// `CFBundleShortVersionString`, when it is a release version.
    public nonisolated static func runningVersion(infoDictionary: [String: Any]?) -> UpdateVersion? {
        (infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(UpdateVersion.init)
    }

    /// Call once at launch.
    public func start() {
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
    /// and a version launched to replace another reports that it is ready.
    public func windowDidShow() {
        if case .answered = manualCheck {
            manualCheck = .none
            refresh()
        }
        reportReadyOnce()
    }

    /// **Restart Now**: install the staged update and hand off to it. This
    /// process quits through `onTerminate` once the new version reports
    /// ready, unless a quit already waiting on the handoff ends it, and
    /// otherwise carries on with the line saying why.
    public func restartNow() async {
        guard let staged = scheduler.stagedUpdate, !sessionInProgress, !isRestarting else {
            return
        }
        isRestarting = true
        isHandingOff = true
        defer { endHandOff() }
        restartFailureReason = nil
        refresh()
        log("update: restarting into \(staged.version)")
        let outcome = await installer.installAndHandOff(staged, baseline: ownReport(), rollback: .keepRunning)
        scheduler.installFinished(staged, outcome: outcome)
        if outcome.shouldTerminate {
            log("update: \(staged.version) took over")
            // A quit already waiting on the handoff ends this process itself.
            if afterHandOff.isEmpty {
                onTerminate()
            }
            return
        }
        isRestarting = false
        if let failure = outcome.failure {
            restartFailureReason = failure.reason
            log("update: Sensorium could not update: \(failure.reason)")
        }
        refresh()
    }

    /// At quit: installs a staged update in place and opens nothing. Runs at
    /// most once per process, since the viewer's own quit and AppKit's can
    /// both reach it. Synchronous: the swap is a rename and a signature
    /// check, bounded by the size of the app.
    public func installAtQuit() {
        scheduler.stop()
        guard !isRestarting, !hasRunQuitInstall else {
            return
        }
        hasRunQuitInstall = true
        guard let staged = scheduler.stagedUpdate else {
            return
        }
        log("update: installing \(staged.version) at quit")
        let outcome = installer.installWithoutRelaunch(staged)
        scheduler.installFinished(staged, atQuit: outcome)
        switch outcome {
        case .installed:
            log("update: \(staged.version) installed")
        case .notUpdatable:
            log("update: this copy of Sensorium cannot replace itself")
        case let .failed(failure), let .swapBackFailed(failure):
            log("update: Sensorium could not update: \(failure.reason)")
        }
    }

    /// The viewer's own quit, once its event loop has ended. A **Restart
    /// Now** still handing off is let finish first, bounded by the
    /// installer's own timeouts, so a quit never leaves the old app half
    /// replaced; then a staged update is installed.
    public func finishBeforeQuit() async {
        scheduler.stop()
        if isHandingOff {
            await withCheckedContinuation { continuation in
                afterHandOff.append { continuation.resume() }
            }
        }
        installAtQuit()
    }

    /// AppKit is about to terminate the app: a quit from the Dock, a logout
    /// or shutdown, or an Apple Event, none of which ends the viewer's event
    /// loop first. Installs a staged update and returns true, or, while
    /// **Restart Now** is handing off, returns false and runs `proceed` once
    /// the handoff has ended and the install has run.
    public func prepareToTerminate(then proceed: @escaping @MainActor () -> Void) -> Bool {
        scheduler.stop()
        guard isHandingOff else {
            installAtQuit()
            return true
        }
        afterHandOff.append {
            self.installAtQuit()
            proceed()
        }
        return false
    }

    private func endHandOff() {
        isHandingOff = false
        let waiting = afterHandOff
        afterHandOff = []
        for quit in waiting {
            quit()
        }
    }

    /// This process's own ready report, read from its running state.
    private func ownReport() -> UpdateReadyReport {
        UpdateReadyReport(
            version: runningVersion,
            screenRecordingGranted: nil,
            accessibilityGranted: nil,
            loginItemStatus: loginItemStatus(),
            host: nil
        )
    }

    private func reportReadyOnce() {
        guard let replacing, !hasReportedReady else {
            return
        }
        hasReportedReady = true
        do {
            try UpdateHandoff.reportReady(ownReport(), to: replacing.readyFile)
            log("update: \(runningVersion) is ready")
        } catch {
            log("update: could not report ready: \(error)")
            return
        }
        let finishReplacing = finishReplacing
        let appName = appName
        Task.detached {
            _ = await finishReplacing(replacing.pid, replacing.readyFile, appName)
        }
    }

    private func statusChanged(_ status: UpdateStatus) {
        restartFailureReason = nil
        if lastCheck.restoresStatus {
            lastCheck.restoresStatus = false
        } else {
            logStatus(status)
        }
        settleManualCheck()
        refresh()
    }

    private func logStatus(_ status: UpdateStatus) {
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
            log("update: this copy of Sensorium cannot replace itself")
        }
    }

    /// A chosen check is answered once the scheduler stops checking. Only
    /// *up to date* is the check's own answer; a ready update, a failure or
    /// a copy that cannot update says so through its own line.
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
        ViewerUpdateLine.make(
            status: scheduler.status,
            runningVersion: runningVersion,
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
private final class LastCheck {
    var result: UpdateCheckResult?
    /// Set when a check reached nothing: the scheduler's next status change
    /// only puts back the status it had before checking.
    var restoresStatus = false
}
#endif
