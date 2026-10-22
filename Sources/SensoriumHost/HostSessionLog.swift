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
/// this subsystem; standard output still carries it whole.
///
/// Some callers build their lines with the "Sensorium host: " prefix already
/// on them and some do not. Each line is printed under that prefix exactly
/// once, and reaches the unified log without it.
public enum HostSessionLog {
    private static let logger = Logger(subsystem: "com.sensorium.host", category: "session")
    private static let prefix = "Sensorium host: "

    public static func record(_ line: String) {
        let bare = unifiedLogLine(line)
        logger.notice("\(bare)")
        print(prefix + bare)
    }

    public static func printedLine(_ line: String) -> String {
        prefix + unifiedLogLine(line)
    }

    public static func unifiedLogLine(_ line: String) -> String {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
    }
}
