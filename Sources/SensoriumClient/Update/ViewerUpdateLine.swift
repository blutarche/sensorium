#if os(macOS)
import Foundation
import SensoriumUpdate

/// Where a **Check for Updates…** the person chose stands. The scheduler
/// reports an automatic check and a chosen one the same way; only a chosen
/// one is answered on the line.
public enum ViewerManualCheck: Equatable, Sendable {
    case none
    /// Chosen, and not answered yet.
    case pending
    /// Answered. `upToDate` is false when the release page could not be
    /// reached, which is not an answer the line can give.
    case answered(upToDate: Bool)
}

/// The one line *Your Machines* shows beneath the list about updates.
public struct ViewerUpdateLine: Equatable, Sendable {
    public static let restartNowTitle = "Restart Now"

    public let text: String
    public let offersRestartNow: Bool

    public init(text: String, offersRestartNow: Bool) {
        self.text = text
        self.offersRestartNow = offersRestartNow
    }

    /// Nil when there is nothing to say. **Restart Now** is offered only
    /// while no session runs, which covers every moment a session window is
    /// open, and while no restart is already under way.
    public static func make(
        status: UpdateStatus,
        runningVersion: UpdateVersion,
        manualCheck: ViewerManualCheck,
        sessionInProgress: Bool,
        isRestarting: Bool,
        restartFailureReason: String?
    ) -> ViewerUpdateLine? {
        if let restartFailureReason {
            return failed(restartFailureReason)
        }
        switch status {
        case let .ready(version):
            return ViewerUpdateLine(
                text: "Sensorium \(version) is ready.",
                offersRestartNow: !sessionInProgress && !isRestarting
            )
        case let .failed(reason):
            return failed(reason)
        case .notUpdatable:
            return ViewerUpdateLine(
                text: "Move Sensorium to Applications and open it again to receive updates.",
                offersRestartNow: false
            )
        case .current where manualCheck == .answered(upToDate: true):
            return ViewerUpdateLine(text: "Sensorium \(runningVersion) is up to date.", offersRestartNow: false)
        case .current, .checking, .downloading, .waiting:
            return manualCheck == .pending
                ? ViewerUpdateLine(text: "Checking for updates\u{2026}", offersRestartNow: false)
                : nil
        }
    }

    private static func failed(_ reason: String) -> ViewerUpdateLine {
        ViewerUpdateLine(text: "Sensorium could not update: \(reason).", offersRestartNow: false)
    }
}
#endif
