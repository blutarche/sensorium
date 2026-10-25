import Foundation
import SensoriumUpdate

/// The host window's update line, under **Open at login**.
public enum HostUpdateStatusLine {
    /// Nil while checking or downloading, when the window keeps the line it
    /// had, since a check that finds nothing should not flicker. Nil also for
    /// a running version the scheduler starts on as current without having
    /// asked: `upToDateAnswered` is whether a check during this launch has
    /// answered up to date, and the line claims nothing until one has.
    public static func line(for status: UpdateStatus, runningVersion: UpdateVersion, upToDateAnswered: Bool) -> String? {
        switch status {
        case .current:
            upToDateAnswered ? "Sensorium Host \(runningVersion) is up to date." : nil
        case .checking, .downloading:
            nil
        case let .ready(version), let .waiting(version):
            "Sensorium Host \(version) will install when no machine is connected."
        case let .failed(reason):
            failed(reason: reason, runningVersion: runningVersion)
        case .notUpdatable:
            "Move Sensorium Host to Applications and open it again to receive updates."
        }
    }

    public static func failed(reason: String, runningVersion: UpdateVersion) -> String {
        "\(failurePrefix)\(reason). It keeps running \(runningVersion)."
    }

    /// Whether `line` is the one `failed` words, so the window can draw it
    /// apart from the rest. The window is handed the line as text.
    static func isFailure(_ line: String) -> Bool {
        line.hasPrefix(failurePrefix)
    }

    private static let failurePrefix = "Sensorium Host could not update: "
}
