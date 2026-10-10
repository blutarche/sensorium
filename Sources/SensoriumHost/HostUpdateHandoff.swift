import Foundation
import SensoriumUpdate

public enum HostUpdateProblemCopy {
    /// An install stopped the listener, which never starts again in the same
    /// process, and then could not hand over to another copy.
    public static let stoppedListening =
        "Sensorium Host stopped listening to install an update and could not finish. Quit it and open it again."
}

/// The replacing instance's report: written once, from the first listener
/// ready, with values read from this instance's own running state. A report
/// that cannot be written is logged and the host keeps serving; the old
/// instance then gives up waiting and asks this one to quit.
@MainActor
public final class HostUpdateRelaunchReporter {
    private let relaunch: HostUpdateRelaunch
    private let makeReport: (HostListenerReady) -> UpdateReadyReport
    private let write: (UpdateReadyReport, URL) throws -> Void
    private let log: (String) -> Void
    private var hasReported = false

    public init(
        relaunch: HostUpdateRelaunch,
        makeReport: @escaping (HostListenerReady) -> UpdateReadyReport,
        write: @escaping (UpdateReadyReport, URL) throws -> Void = { try UpdateHandoff.reportReady($0, to: $1) },
        log: @escaping (String) -> Void = HostUpdateLog.record
    ) {
        self.relaunch = relaunch
        self.makeReport = makeReport
        self.write = write
        self.log = log
    }

    /// Call on every listener ready. True for the first only, which is when
    /// the caller starts waiting for the replaced process to exit.
    public func listenerReady(_ ready: HostListenerReady) -> Bool {
        guard !hasReported else { return false }
        hasReported = true
        do {
            try write(makeReport(ready), relaunch.readyFile)
            log("reported ready as the replacement for an earlier host")
        } catch {
            log("could not report ready as the replacement for an earlier host: \(error)")
        }
        return true
    }
}

/// After a failed swap back the installed app is the refused new version
/// and this process's listener is stopped. Launching that app through the
/// ordinary handoff still gets the Mac a serving host.
@MainActor
public enum HostUpdateSwapBackRecovery {
    public enum Outcome: Equatable, Sendable {
        /// The launched app reported ready: quit now.
        case ready
        /// The installed app is not signed like this one, so it is not run.
        case requirementFailed
        case launchFailed
        /// No report from the launched process in time. It is left running.
        case readyLate
    }

    /// Accepts any report the launched process writes: the values are
    /// expected to differ, since it is the version just refused.
    public static func relaunchInstalled(
        installedAppURL: URL,
        readyFile: URL,
        requirement: any UpdateRequirementChecking,
        launcher: any UpdateAppLaunching,
        processIdentifier: pid_t = getpid(),
        readyTimeout: Duration = UpdateInstaller.Timing().readyTimeout,
        pollInterval: Duration = UpdateInstaller.Timing().pollInterval
    ) async -> Outcome {
        guard requirement.isSatisfied(byBundleAt: installedAppURL) else {
            return .requirementFailed
        }
        try? FileManager.default.removeItem(at: readyFile)
        let app: any UpdateLaunchedApp
        do {
            app = try await launcher.launch(
                appAt: installedAppURL,
                arguments: UpdateLaunchCommand.replacingArguments(pid: processIdentifier, readyFile: readyFile)
            )
        } catch {
            return .launchFailed
        }
        let deadline = ContinuousClock.now + readyTimeout
        repeat {
            if let report = UpdateReadyReport.read(from: readyFile), report.processIdentifier == app.processIdentifier {
                return .ready
            }
            if app.hasExited {
                return .readyLate
            }
            try? await Task.sleep(for: pollInterval)
        } while ContinuousClock.now < deadline
        return .readyLate
    }
}
