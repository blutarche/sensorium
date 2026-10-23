import Foundation
import SensoriumUpdate

/// The host window's update line, under **Open at login**.
public enum HostUpdateStatusLine {
    /// Nil while checking or downloading: the window keeps the line it had,
    /// since a check that finds nothing should not flicker.
    public static func line(for status: UpdateStatus, runningVersion: UpdateVersion) -> String? {
        switch status {
        case .current:
            "Sensorium Host \(runningVersion), up to date."
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
        "Sensorium Host could not update: \(reason). It keeps running \(runningVersion)."
    }
}
