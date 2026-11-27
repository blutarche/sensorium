#if os(Linux)
import Foundation
import SensoriumLinuxUpdate

/// A new version started to replace the running host: the process it
/// replaces, and where to report once it serves.
public struct LinuxHostReplacement: Equatable, Sendable {
    public let pid: pid_t
    public let readyFile: URL

    public init(pid: pid_t, readyFile: URL) {
        self.pid = pid
        self.readyFile = readyFile
    }
}

/// Whether a `--replacing` launch is the update handover it claims to be.
public enum LinuxHostReplacementVerdict: Equatable, Sendable {
    /// Take the application name over, skip the lock-at-launch check and
    /// report ready.
    case relaunch
    /// Start as any host does, with `reason` for the log.
    case ordinary(reason: String)
}

/// What a launch of the host does, decided before GLib or the host's own
/// option parsing sees an argument: both end an argument they do not know,
/// which the update self-test and the replacing launch must never reach.
public enum LinuxHostLaunchRoute: Equatable, Sendable {
    /// Run `LinuxHostUpdateSelfTest` and exit with its status.
    case updateSelfTest
    /// Launch the host with `arguments`. `replacing` is set when this is a
    /// new version taking over from the one that started it, which runs
    /// with no window, as a host started at login does.
    case host(arguments: [String], replacing: LinuxHostReplacement?)

    /// `arguments` excludes the program's own path.
    public static func route(_ arguments: [String]) -> LinuxHostLaunchRoute {
        switch LinuxUpdateLaunchCommand.parse(arguments) {
        case .selfTest:
            .updateSelfTest
        case let .replacing(pid, readyFile):
            .host(arguments: ["--background"], replacing: LinuxHostReplacement(pid: pid, readyFile: readyFile))
        case let .normal(arguments):
            .host(arguments: arguments, replacing: nil)
        }
    }

    /// The command line alone names the process to replace, and any local
    /// process can write it. A launch is the update handover only when the
    /// replaced host started it, and the installation has a switch to this
    /// version waiting for confirmation, which only the updater writes.
    public static func verdict(
        for replacement: LinuxHostReplacement,
        parentProcess: pid_t,
        pendingVersion: String?,
        runningVersion: String
    ) -> LinuxHostReplacementVerdict {
        guard parentProcess == replacement.pid else {
            return .ordinary(reason: "its parent process is not the host it names")
        }
        guard let pendingVersion else {
            return .ordinary(reason: "no update switch is pending")
        }
        guard pendingVersion == runningVersion else {
            return .ordinary(reason: "the pending update switch is to another version")
        }
        return .relaunch
    }

    /// `replacing` if this launch is the update handover, else nil, in which
    /// case the host starts as it would from the launcher.
    public static func verified(
        replacing replacement: LinuxHostReplacement?,
        dataRoot: URL,
        releaseVersion: String,
        parentProcess: pid_t = getppid(),
        log: (String) -> Void = { print("Sensorium host: \($0)") }
    ) -> LinuxHostReplacement? {
        guard let replacement else { return nil }
        let installation = LinuxUpdateInstallation(dataRoot: dataRoot, app: .host)
        let running = LinuxUpdateVersion(releaseVersion)?.description ?? releaseVersion
        switch verdict(
            for: replacement,
            parentProcess: parentProcess,
            pendingVersion: installation.pendingSwitch()?.version.description,
            runningVersion: running
        ) {
        case .relaunch:
            return replacement
        case let .ordinary(reason):
            log("ignoring --replacing and starting as an ordinary launch: \(reason)")
            return nil
        }
    }
}
#endif
