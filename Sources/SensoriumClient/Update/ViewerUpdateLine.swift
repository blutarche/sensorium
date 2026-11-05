import Foundation
#if os(macOS)
import SensoriumUpdate
#endif

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

/// What the line needs to know of an updater's status, whichever platform's
/// updater reports it.
public enum ViewerUpdateLineStatus: Equatable, Sendable {
    case current
    /// Checking, downloading, or waiting for the next try: nothing the line
    /// says unless a chosen check is pending.
    case busy
    case ready(version: String)
    case failed(reason: String)
    case notUpdatable
}

/// Which viewer the line is for. The two install a staged update differently,
/// so two sentences differ.
public enum ViewerUpdatePlatform: Equatable, Sendable {
    /// Installs at **Restart Now** or at the next quit, and updates only from
    /// the Applications folder.
    case macOS
    /// Installs at **Restart Now** alone, into its own data folder.
    case linux

    public static var current: ViewerUpdatePlatform {
        #if os(Linux)
        .linux
        #else
        .macOS
        #endif
    }
}

/// The one line *Your Machines* shows beneath the list about updates.
public struct ViewerUpdateLine: Equatable, Sendable {
    public static let restartNowTitle = "Restart Now"

    public let text: String
    public let offersRestartNow: Bool
    /// True for the one line that reports a failure, which is drawn apart
    /// from the rest.
    public let isFailure: Bool

    public init(text: String, offersRestartNow: Bool, isFailure: Bool = false) {
        self.text = text
        self.offersRestartNow = offersRestartNow
        self.isFailure = isFailure
    }

    /// Nil when there is nothing to say. **Restart Now** is offered only
    /// while no session runs, which covers every moment a session window is
    /// open, and while no restart is already under way.
    public static func make(
        status: ViewerUpdateLineStatus,
        runningVersion: String,
        platform: ViewerUpdatePlatform,
        manualCheck: ViewerManualCheck,
        sessionInProgress: Bool,
        isRestarting: Bool,
        restartFailureReason: String?
    ) -> ViewerUpdateLine? {
        if let restartFailureReason {
            return failed(restartFailureReason, runningVersion: runningVersion)
        }
        switch status {
        case let .ready(version):
            let offersRestartNow = !sessionInProgress && !isRestarting
            return ViewerUpdateLine(
                text: offersRestartNow ? "Sensorium \(version) is ready." : readyLater(version, platform: platform),
                offersRestartNow: offersRestartNow
            )
        case let .failed(reason):
            return failed(reason, runningVersion: runningVersion)
        case .notUpdatable:
            return ViewerUpdateLine(text: notUpdatable(platform: platform), offersRestartNow: false)
        case .current where manualCheck == .answered(upToDate: true):
            return ViewerUpdateLine(text: "Sensorium \(runningVersion) is up to date.", offersRestartNow: false)
        case .current, .busy:
            return manualCheck == .pending
                ? ViewerUpdateLine(text: "Checking for updates\u{2026}", offersRestartNow: false)
                : nil
        }
    }

    /// The ready line while **Restart Now** is withheld. The Linux viewer
    /// never installs at quit, so it does not promise to.
    private static func readyLater(_ version: String, platform: ViewerUpdatePlatform) -> String {
        switch platform {
        case .macOS: "Sensorium \(version) is ready. It installs the next time Sensorium quits."
        case .linux: "Sensorium \(version) is ready."
        }
    }

    private static func notUpdatable(platform: ViewerUpdatePlatform) -> String {
        switch platform {
        case .macOS: "Move Sensorium to Applications and open it again to receive updates."
        case .linux: "Sensorium cannot update itself because it cannot write to its own folder."
        }
    }

    private static func failed(_ reason: String, runningVersion: String) -> ViewerUpdateLine {
        ViewerUpdateLine(
            text: "Sensorium could not update: \(reason). It keeps running \(runningVersion).",
            offersRestartNow: false,
            isFailure: true
        )
    }
}

#if os(macOS)
extension ViewerUpdateLine {
    public static func make(
        status: UpdateStatus,
        runningVersion: UpdateVersion,
        manualCheck: ViewerManualCheck,
        sessionInProgress: Bool,
        isRestarting: Bool,
        restartFailureReason: String?
    ) -> ViewerUpdateLine? {
        let neutral: ViewerUpdateLineStatus = switch status {
        case .current: .current
        case .checking, .downloading, .waiting: .busy
        case let .ready(version): .ready(version: version.description)
        case let .failed(reason): .failed(reason: reason)
        case .notUpdatable: .notUpdatable
        }
        return make(
            status: neutral,
            runningVersion: runningVersion.description,
            platform: .macOS,
            manualCheck: manualCheck,
            sessionInProgress: sessionInProgress,
            isRestarting: isRestarting,
            restartFailureReason: restartFailureReason
        )
    }
}
#endif
