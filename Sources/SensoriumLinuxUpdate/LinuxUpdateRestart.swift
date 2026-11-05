import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LinuxUpdateRestartOutcome: Equatable, Sendable {
    /// The new version reported ready: this process quits now.
    case tookOver
    /// `current` names the version it named before, and the new process, if
    /// one started, has been stopped. This process keeps running.
    case failed(LinuxUpdateFailure)
}

/// The old viewer's side of **Restart Now**, step 5 of section 11.4 of
/// `docs/self-update-design.md`: switch `current`, start the new version
/// with `--replacing`, and wait for its ready file.
public struct LinuxUpdateRestart: Sendable {
    public static let readyTimeout: TimeInterval = 60
    /// How long a new version that did not report in time is given to quit
    /// before it is killed.
    public static let quitGrace: TimeInterval = 10
    static let pollInterval: useconds_t = 50_000

    public let installation: LinuxUpdateInstallation
    let readyTimeout: TimeInterval
    let quitGrace: TimeInterval

    public init(
        installation: LinuxUpdateInstallation,
        readyTimeout: TimeInterval = LinuxUpdateRestart.readyTimeout,
        quitGrace: TimeInterval = LinuxUpdateRestart.quitGrace
    ) {
        self.installation = installation
        self.readyTimeout = readyTimeout
        self.quitGrace = quitGrace
    }

    /// `processIdentifier` is this process, which the new version names in
    /// its report.
    public func run(_ staged: LinuxStagedUpdate, processIdentifier: pid_t = getpid()) async -> LinuxUpdateRestartOutcome {
        await LinuxUpdateChildProcess.offThePool {
            hand(over: staged, processIdentifier: processIdentifier)
        }
    }

    private func hand(over staged: LinuxStagedUpdate, processIdentifier: pid_t) -> LinuxUpdateRestartOutcome {
        guard let folder = try? LinuxUpdateHandoff.makeFolder(in: installation) else {
            return .failed(.switchFailed)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let readyFile = folder.appendingPathComponent(LinuxUpdateHandoff.readyFileName)

        let switched: LinuxUpdatePendingSwitch
        switch installation.switchCurrent(to: staged) {
        case let .success(pending):
            switched = pending
        case let .failure(failure):
            return .failed(failure)
        }

        let process = Process()
        process.executableURL = staged.executable
        process.arguments = LinuxUpdateLaunchCommand.replacingArguments(pid: processIdentifier, readyFile: readyFile)
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            _ = installation.rollBack(switched)
            return .failed(.launchFailed)
        }

        let expected = LinuxUpdateReadyReport(processIdentifier: process.processIdentifier, version: staged.version)
        let deadline = Date().addingTimeInterval(readyTimeout)
        while true {
            // Whether the child is still running is read before the report,
            // so a report written just before it exited is still seen.
            let running = process.isRunning
            if let report = LinuxUpdateHandoff.readReport(at: readyFile) {
                if report == expected {
                    return .tookOver
                }
                break
            }
            if !running || Date() >= deadline {
                break
            }
            usleep(Self.pollInterval)
        }

        // The new version writes the ready file before it confirms, and
        // confirms under the engine's lock. The last look at the file and
        // the switch back are one step under that lock, so `current` never
        // goes back under a version that has confirmed. It goes back before
        // the new process is stopped, so a new version that tries to
        // confirm in the meantime finds nothing to confirm.
        if case .awaitingConfirmation = installation.rollBack(switched, unlessReported: { LinuxUpdateHandoff.readReport(at: readyFile) == expected }) {
            return .tookOver
        }
        stop(process)
        return .failed(.readyLate)
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(quitGrace)
        while process.isRunning, Date() < deadline {
            usleep(Self.pollInterval)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            usleep(1_000)
        }
    }
}
