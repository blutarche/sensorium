import Foundation
import SensoriumUpdate

/// A launch that replaces a running host for an update: started beside the
/// old process once that process stopped listening, and expected to report
/// ready to `readyFile`.
public struct HostUpdateRelaunch: Equatable, Sendable {
    public let replacedProcess: pid_t
    public let readyFile: URL

    public init(replacedProcess: pid_t, readyFile: URL) {
        self.replacedProcess = replacedProcess
        self.readyFile = readyFile
    }
}

/// What a launch of the host does, decided from its arguments before
/// anything else reads them. The update arguments come first because the
/// existing parsing ends any launch it does not recognise with a usage
/// message.
public enum HostLaunchRoute: Equatable, Sendable {
    /// Run the read-only self-test and exit with its status.
    case selfTest
    /// Start the GUI host as the replacement for an older one.
    case updateRelaunch(HostUpdateRelaunch)
    /// Anything else, for the existing argument parsing.
    case normal([String])

    /// `arguments` excludes the program's own path.
    public static func route(_ arguments: [String]) -> HostLaunchRoute {
        switch UpdateLaunchCommand.parse(arguments) {
        case .selfTest:
            .selfTest
        case let .replacing(pid, readyFile):
            .updateRelaunch(HostUpdateRelaunch(replacedProcess: pid, readyFile: readyFile))
        case let .normal(arguments):
            .normal(arguments)
        }
    }
}
