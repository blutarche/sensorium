#if os(macOS)
import Foundation
import SensoriumUpdate

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

/// What a launch of the macOS viewer does, decided before
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
        switch UpdateLaunchCommand.parse(arguments) {
        case .selfTest:
            .updateSelfTest
        case let .replacing(pid, readyFile):
            .viewer(arguments: [], replacing: ViewerReplacement(pid: pid, readyFile: readyFile))
        case let .normal(arguments):
            .viewer(arguments: arguments, replacing: nil)
        }
    }
}
#endif
