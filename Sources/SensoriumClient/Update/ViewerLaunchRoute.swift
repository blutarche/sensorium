#if os(macOS) || os(Linux)
import Foundation
#if os(macOS)
import SensoriumUpdate
#else
import SensoriumLinuxUpdate
#endif

/// A new version launched to replace the running one: the process it
/// replaces, and where to report once its window is up.
public struct ViewerReplacement: Equatable, Sendable {
    public let pid: pid_t
    public let readyFile: URL

    public init(pid: pid_t, readyFile: URL) {
        self.pid = pid
        self.readyFile = readyFile
    }
}

/// What a launch of the viewer does, decided before
/// `ViewerApplication.run(arguments:)` parses anything: that parser ends an
/// argument it does not know with a usage message and exit status 2, which
/// the update self-test must never reach.
public enum ViewerLaunchRoute: Equatable, Sendable {
    /// Run `ViewerUpdateSelfTest` and exit with its status.
    case updateSelfTest
    /// Launch the viewer with `arguments`; `replacing` is set when this is a
    /// new version taking over from the one that launched it.
    case viewer(arguments: [String], replacing: ViewerReplacement?)

    /// `arguments` excludes the program's own path.
    public static func route(_ arguments: [String]) -> ViewerLaunchRoute {
        #if os(macOS)
        let command = UpdateLaunchCommand.parse(arguments)
        #else
        let command = LinuxUpdateLaunchCommand.parse(arguments)
        #endif
        switch command {
        case .selfTest:
            return .updateSelfTest
        case let .replacing(pid, readyFile):
            return .viewer(arguments: [], replacing: ViewerReplacement(pid: pid, readyFile: readyFile))
        case let .normal(arguments):
            return .viewer(arguments: arguments, replacing: nil)
        }
    }
}
#endif
