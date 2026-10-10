#if os(macOS)
import Foundation

public enum UpdateNotUpdatableReason: Equatable, Sendable {
    /// macOS is running a temporary copy of an app opened from Downloads.
    case translocated
    /// This user cannot write to the folder holding the app.
    case folderNotWritable
}

public enum UpdateInstallability: Equatable, Sendable {
    case updatable
    case notUpdatable(UpdateNotUpdatableReason)
}

/// How an install at quit ended.
public enum UpdateQuitInstallOutcome: Equatable, Sendable {
    case installed
    case notUpdatable(UpdateNotUpdatableReason)
    /// The installed app is the old one again.
    case failed(UpdateFailure)
    /// The new version failed after the swap, and swapping the old app back
    /// failed twice. The installed app is the refused new version, and the
    /// old app is left in the staging folder.
    case swapBackFailed(UpdateFailure)
}

/// How a handoff ended, and whether the calling process should now quit.
public enum UpdateHandoffOutcome: Equatable, Sendable {
    case notUpdatable(UpdateNotUpdatableReason)
    /// The new version is running and reported ready. Quit now.
    case handedOff
    /// The old app is installed again and this process carries on.
    case failed(UpdateFailure)
    /// The old app is installed again and a fresh instance of it reported
    /// ready. Quit now.
    case rolledBack(UpdateFailure)
    /// The old app is installed again, but no fresh instance of it came up.
    /// Nothing else is serving; this process stays.
    case rollbackRelaunchFailed(UpdateFailure)
    /// The new version failed after the swap, and swapping the old app back
    /// failed twice. The installed app is the refused new version, and the
    /// old app is left in the staging folder. Nothing is launched; this
    /// process stays.
    case swapBackFailed(UpdateFailure)

    public var shouldTerminate: Bool {
        switch self {
        case .handedOff, .rolledBack: true
        case .notUpdatable, .failed, .rollbackRelaunchFailed, .swapBackFailed: false
        }
    }

    public var failure: UpdateFailure? {
        switch self {
        case .notUpdatable, .handedOff: nil
        case let .failed(failure), let .rolledBack(failure), let .rollbackRelaunchFailed(failure),
             let .swapBackFailed(failure):
            failure
        }
    }
}

/// Swaps a staged update into place, as section 3.4 of
/// `docs/self-update-design.md` describes.
///
/// From the swap until this process quits, its bundle path holds another
/// version of the app. Anything this process loaded lazily from its bundle
/// in that window would come from that other version, so between the swap
/// and quitting it must load nothing from its bundle: no nib, image,
/// localized string, plug-in or resource of any kind.
@MainActor
public final class UpdateInstaller {
    public struct Timing: Sendable {
        /// How long the new instance has to write its ready file.
        public var readyTimeout: Duration
        /// How long an instance asked to quit has before it is forced.
        public var quitTimeout: Duration
        public var pollInterval: Duration

        public init(readyTimeout: Duration = .seconds(60), quitTimeout: Duration = .seconds(10), pollInterval: Duration = .milliseconds(100)) {
            self.readyTimeout = readyTimeout
            self.quitTimeout = quitTimeout
            self.pollInterval = pollInterval
        }
    }

    /// What a rejected handoff does once the old app is back in place.
    public enum Rollback: Sendable {
        /// This process carries on as it was: the viewer's **Restart Now**.
        case keepRunning
        /// The host, whose listener cannot be restarted once stopped:
        /// launch the old app again through the same handoff, and quit once
        /// it reports ready.
        case relaunchPrevious
    }

    let installedAppURL: URL
    let requirement: any UpdateRequirementChecking
    let launcher: any UpdateAppLaunching
    let processIdentifier: pid_t
    let timing: Timing

    /// `installedAppURL` is `Bundle.main.bundleURL`; `requirement` is
    /// `CodeRequirementCheck.runningApp()`, read at launch.
    public init(
        installedAppURL: URL,
        requirement: any UpdateRequirementChecking,
        launcher: any UpdateAppLaunching,
        processIdentifier: pid_t = getpid(),
        timing: Timing = Timing()
    ) {
        self.installedAppURL = installedAppURL
        self.requirement = requirement
        self.launcher = launcher
        self.processIdentifier = processIdentifier
        self.timing = timing
    }

    public nonisolated static func installability(of appURL: URL) -> UpdateInstallability {
        if appURL.path.contains("/AppTranslocation/") {
            return .notUpdatable(.translocated)
        }
        guard access(appURL.deletingLastPathComponent().path, W_OK) == 0 else {
            return .notUpdatable(.folderNotWritable)
        }
        return .updatable
    }

    /// The viewer at quit: swap, check the installed copy, swap back on
    /// failure. Launches nothing.
    public func installWithoutRelaunch(_ staged: StagedUpdate) -> UpdateQuitInstallOutcome {
        if case let .notUpdatable(reason) = Self.installability(of: installedAppURL) {
            removeStagingFolder(staged)
            return .notUpdatable(reason)
        }
        guard swap(staged) else {
            removeStagingFolder(staged)
            return .failed(.swapFailed)
        }
        guard requirement.isSatisfied(byBundleAt: installedAppURL) else {
            // A failed swap back leaves the only copy of the old app in the
            // staging folder, so that folder is kept.
            guard swapBack(staged) else {
                return .swapBackFailed(.requirementFailed)
            }
            removeStagingFolder(staged)
            return .failed(.requirementFailed)
        }
        removeStagingFolder(staged)
        return .installed
    }

    /// The host, and the viewer's **Restart Now**: swap, check the installed
    /// copy, launch it with `--replacing`, and wait for its ready report.
    ///
    /// `baseline` is this process's own report, with its running version:
    /// the new version's report must match it. The host stops its listener
    /// before calling this, and checks `installability(of:)` before that,
    /// since `.notUpdatable` relaunches nothing.
    public func installAndHandOff(_ staged: StagedUpdate, baseline: UpdateReadyReport, rollback: Rollback) async -> UpdateHandoffOutcome {
        if case let .notUpdatable(reason) = Self.installability(of: installedAppURL) {
            removeStagingFolder(staged)
            return .notUpdatable(reason)
        }
        try? FileManager.default.removeItem(at: staged.readyFileURL)
        guard swap(staged) else {
            return await roll(back: .swapFailed, staged, baseline: baseline, rollback: rollback, swapped: false)
        }
        guard requirement.isSatisfied(byBundleAt: installedAppURL) else {
            return await roll(back: .requirementFailed, staged, baseline: baseline, rollback: rollback, swapped: true)
        }
        let failure: UpdateFailure
        switch await launchAndAwaitReady(staged, baseline: baseline, expectedVersion: staged.version) {
        case .ready:
            return .handedOff
        case let .refused(refusal):
            failure = refusal
        }
        return await roll(back: failure, staged, baseline: baseline, rollback: rollback, swapped: true)
    }

    private enum LaunchResult {
        case ready
        case refused(UpdateFailure)
    }

    /// Launches the installed app with `--replacing` and waits for a report
    /// written by the launched process, from `expectedVersion`, that matches
    /// `baseline`. An instance that is refused is asked to quit, then forced.
    private func launchAndAwaitReady(_ staged: StagedUpdate, baseline: UpdateReadyReport, expectedVersion: UpdateVersion) async -> LaunchResult {
        let arguments = UpdateLaunchCommand.replacingArguments(pid: processIdentifier, readyFile: staged.readyFileURL)
        let app: any UpdateLaunchedApp
        do {
            app = try await launcher.launch(appAt: installedAppURL, arguments: arguments)
        } catch {
            return .refused(.launchFailed)
        }
        let failure: UpdateFailure
        if let report = await waitForReport(at: staged.readyFileURL, from: app) {
            if report.processIdentifier != app.processIdentifier {
                failure = .readyMismatch("process")
            } else if let difference = report.mismatch(comparedWith: baseline, expectedVersion: expectedVersion) {
                failure = .readyMismatch(difference)
            } else {
                return .ready
            }
        } else {
            failure = .readyLate
        }
        await stop(app)
        return .refused(failure)
    }

    private func roll(
        back failure: UpdateFailure,
        _ staged: StagedUpdate,
        baseline: UpdateReadyReport,
        rollback: Rollback,
        swapped: Bool
    ) async -> UpdateHandoffOutcome {
        // A failed swap back leaves the only copy of the old app in the
        // staging folder, so that folder is kept.
        if swapped, !swapBack(staged) {
            return .swapBackFailed(failure)
        }
        switch rollback {
        case .keepRunning:
            removeStagingFolder(staged)
            return .failed(failure)
        case .relaunchPrevious:
            try? FileManager.default.removeItem(at: staged.readyFileURL)
            // The relaunched instance removes the staging folder, which now
            // holds the refused new app, once this process has exited.
            switch await launchAndAwaitReady(staged, baseline: baseline, expectedVersion: baseline.version) {
            case .ready:
                return .rolledBack(failure)
            case .refused:
                removeStagingFolder(staged)
                return .rollbackRelaunchFailed(failure)
            }
        }
    }

    private func swap(_ staged: StagedUpdate) -> Bool {
        renamex_np(staged.appURL.path, installedAppURL.path, UInt32(RENAME_SWAP)) == 0
    }

    /// Puts the old app back after a swap, trying a second time if the first
    /// try fails.
    private func swapBack(_ staged: StagedUpdate) -> Bool {
        swap(staged) || swap(staged)
    }

    private func removeStagingFolder(_ staged: StagedUpdate) {
        try? FileManager.default.removeItem(at: staged.directory)
    }

    /// Stops early if the instance exits without reporting.
    private func waitForReport(at url: URL, from app: any UpdateLaunchedApp) async -> UpdateReadyReport? {
        let deadline = ContinuousClock.now + timing.readyTimeout
        while ContinuousClock.now < deadline {
            if let report = UpdateReadyReport.read(from: url) {
                return report
            }
            if app.hasExited {
                return nil
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return UpdateReadyReport.read(from: url)
    }

    private func stop(_ app: any UpdateLaunchedApp) async {
        app.requestQuit()
        if await waitForExit(app) {
            return
        }
        app.forceQuit()
        _ = await waitForExit(app)
    }

    private func waitForExit(_ app: any UpdateLaunchedApp) async -> Bool {
        let deadline = ContinuousClock.now + timing.quitTimeout
        while !app.hasExited {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return true
    }
}
#endif
