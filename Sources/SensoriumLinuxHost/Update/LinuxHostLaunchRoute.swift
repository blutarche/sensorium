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
}
#endif
