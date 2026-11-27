#if os(Linux)
import Foundation
import SensoriumLinuxUpdate

/// The host window's update line, in the macOS host's words.
public enum LinuxHostUpdateStatusLine {
    /// Nil while checking or downloading, when the window keeps the line it
    /// had, since a check that finds nothing should not flicker. Nil also for
    /// a running version the scheduler starts on as current without having
    /// asked: `upToDateAnswered` is whether a check during this launch has
    /// answered up to date, and the line claims nothing until one has.
    public static func line(
        for status: LinuxUpdateStatus, runningVersion: LinuxUpdateVersion, upToDateAnswered: Bool
    ) -> HostWindowUpdateLine? {
        switch status {
        case .current:
            upToDateAnswered ? plain("Sensorium Host \(runningVersion) is up to date.") : nil
        case .checking, .downloading:
            nil
        case let .ready(version), let .waiting(version):
            // The host has no Restart Now: a staged update always waits for
            // an idle moment.
            plain("Sensorium Host \(version) will install when no machine is connected.")
        case let .failed(reason):
            HostWindowUpdateLine(
                text: "Sensorium Host could not update: \(reason). It keeps running \(runningVersion).", isFailure: true
            )
        case .notUpdatable:
            plain("Sensorium Host cannot update itself because it cannot write to its own folder.")
        }
    }

    private static func plain(_ text: String) -> HostWindowUpdateLine {
        HostWindowUpdateLine(text: text, isFailure: false)
    }
}
#endif
