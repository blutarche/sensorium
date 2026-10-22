import Foundation
import os

/// Where the host's session lines are recorded: connections, refusals,
/// capture and display events, and host-screen input diagnostics. A host
/// opened by LaunchServices has nowhere for standard output to go, so every
/// line also goes to the unified log, under subsystem `com.sensorium.host`,
/// category `session`.
///
/// Unlike `HostUpdateLog`, these lines are not logged as public. Some of
/// them name a paired device or the network address a connection came from,
/// so the unified log redacts the line unless private data is enabled for
/// this subsystem; standard output still carries it whole. The one
/// exception is `HostScreenInputLogLine`, whose wording is fixed: it is the
/// only type that can be recorded as readable, so an arbitrary string never
/// is.
///
/// Some callers build their lines with the "Sensorium host: " prefix already
/// on them and some do not. Each line is printed under that prefix exactly
/// once, and reaches the unified log without it. A line that opens with the
/// host name and no colon ("Sensorium host bound ...") is printed as it is:
/// the smoke scripts wait on that wording in the host's standard output.
public enum HostSessionLog {
    private static let logger = Logger(subsystem: "com.sensorium.host", category: "session")
    private static let prefix = "Sensorium host: "
    private static let subject = "Sensorium host "

    /// How the unified log treats a line's text.
    public enum UnifiedLogPrivacy: Equatable, Sendable {
        /// Redacted unless private data is enabled for the subsystem.
        case redacted
        /// Shown to anyone reading the log.
        case readable
    }

    public static func record(_ line: String) {
        record(line, privacy: .redacted, unifiedLog: writeToUnifiedLog)
    }

    public static func record(_ line: HostScreenInputLogLine) {
        record(line.text, privacy: .readable, unifiedLog: writeToUnifiedLog)
    }

    /// As `record(_:)`, handing the unified-log write to `unifiedLog` in
    /// place of the system log.
    public static func record(_ line: String, unifiedLog: (UnifiedLogPrivacy, String) -> Void) {
        record(line, privacy: .redacted, unifiedLog: unifiedLog)
    }

    /// As `record(_:)` for a fixed-wording line, handing the unified-log
    /// write to `unifiedLog` in place of the system log.
    public static func record(_ line: HostScreenInputLogLine, unifiedLog: (UnifiedLogPrivacy, String) -> Void) {
        record(line.text, privacy: .readable, unifiedLog: unifiedLog)
    }

    private static func record(
        _ line: String, privacy: UnifiedLogPrivacy, unifiedLog: (UnifiedLogPrivacy, String) -> Void
    ) {
        unifiedLog(privacy, unifiedLogLine(line))
        print(printedLine(line))
    }

    private static func writeToUnifiedLog(_ privacy: UnifiedLogPrivacy, _ line: String) {
        switch privacy {
        case .redacted: logger.notice("\(line, privacy: .private)")
        case .readable: logger.notice("\(line, privacy: .public)")
        }
    }

    public static func printedLine(_ line: String) -> String {
        line.hasPrefix(subject) || line.hasPrefix(prefix) ? line : prefix + line
    }

    public static func unifiedLogLine(_ line: String) -> String {
        if line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        if line.hasPrefix(subject) {
            return String(line.dropFirst(subject.count))
        }
        return line
    }
}
