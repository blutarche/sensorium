import Foundation

/// What `sensoriumd` writes to the terminal on the machine it is running on.
///
/// The menu bar shows the operator what is happening now; this is the record
/// of what happened while nobody was watching. Both are read by a person, so
/// neither may print a Swift value: a line that says `physicalDisplayRejected`
/// names an internal case and explains nothing.
public enum HostOperatorLog {
    /// The one entry point every failing stage logs through, so a new call
    /// site cannot reintroduce an interpolated error by accident.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? CanvasWorkspacePlacementError {
            return error.operatorLogLine
        }
        if let error = error as? CanvasCreationGateError {
            switch error {
            case .creationInProgress:
                return "Another session canvas was still being opened, so this one was not started. "
                    + "The other machine can ask again."
            }
        }
        if #available(macOS 13.0, *), let error = error as? HostMediaPipelineError {
            switch error {
            case .stillRefreshNotDelivered:
                return "The frame was encoded, and the link would not take it."
            }
        }
        if #available(macOS 13.0, *), let error = error as? StillFrameEncoderError {
            switch error {
            case .frameExceedsTransportLimit(let bytes):
                return "The frame came to \(describeFrameSize(bytes: bytes)), which is more than the link's "
                    + "frame format carries."
            case .noEncodedFrame:
                return "The encoder finished with the frame and produced no picture."
            case .sessionCreationFailed, .propertyUpdateFailed, .frameSubmissionFailed:
                return "The encoder refused the frame."
            }
        }
        if let message = systemMessage(for: error) {
            return "macOS reported: \(message)"
        }
        return unexplained
    }

    /// What nothing could be learned about. Named so `closeReason` can
    /// recognise it.
    private static let unexplained = "Sensorium stopped without saying why; nothing more about it reached this log."

    /// Why a connection ended, as a phrase to put alongside the line that
    /// reports the ending -- or `nil` when nothing was actually learned: a
    /// reason nobody learned reads worse than no reason at all.
    ///
    /// Errors this host defines its own words for are taken at those words;
    /// everything else goes through `describe`, which is where macOS's own
    /// message is turned into prose. The trailing full stop comes off either
    /// way, since the caller places this inside a sentence of its own.
    public static func closeReason(for error: any Error) -> String? {
        let described = (error as? HostSessionControllerError)?.operatorLogLine ?? describe(error)
        guard described != unexplained else {
            return nil
        }
        return described.hasSuffix(".") ? String(described.dropLast()) : described
    }

    /// How large a frame is, for a reader deciding whether the picture that
    /// went out was worth sending. Decimal units, matching the megabits a
    /// second this log already quotes elsewhere.
    public static func describeFrameSize(bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return "\(bytes / 1_000) KB"
    }

    public static func sourceRefused(address: String) -> String {
        // Without this line a machine dialling from the wrong network is
        // silence, and silence looks exactly like a network that is down.
        "Refused a connection from \(address): only machines reaching this machine over its tailnet address "
            + "may connect."
    }

    /// A message macOS itself wrote, or nothing.
    ///
    /// `localizedDescription` on a Swift error this project defines is not
    /// prose — it renders as "The operation couldn\u{2019}t be completed.
    /// (SensoriumHost.SomeError error 2.)", which is the type name again.
    private static func systemMessage(for error: any Error) -> String? {
        let error = error as NSError
        guard !error.domain.hasPrefix("Sensorium") else {
            return nil
        }
        let message = error.localizedDescription
        return message.isEmpty ? nil : message
    }
}

extension CanvasWorkspacePlacementError {
    /// Every one of these ends with the workspace window not opening, so each
    /// says which of them happened and what the operator can do about it.
    public var operatorLogLine: String {
        switch self {
        case .unownedCanvas:
            return "The workspace window was not opened: the canvas it would have opened on is not one "
                + "Sensorium created. Nothing on this machine\u{2019}s own screen was touched."
        case .unregisteredCanvas:
            return "The workspace window was not opened: the session canvas never finished registering "
                + "with macOS. Have the other machine connect again."
        case .physicalDisplayRejected:
            return "The workspace window was not opened: the target was one of this machine\u{2019}s real "
                + "displays rather than the session canvas. Sensorium places no workspace window on this "
                + "machine\u{2019}s own display, so it refused the session instead."
        case .offlineCanvas:
            return "The workspace window was not opened: the session canvas went offline first. Have "
                + "the other machine connect again."
        case .unexpectedCanvasDimensions:
            return "The workspace window was not opened: the session canvas came back a different size "
                + "than Sensorium asked for. Have the other machine connect again."
        }
    }
}

extension HostSessionControllerError {
    /// `nonisolated` for the same reason `isSessionFatal` is: the transport
    /// logs this from its own read loop, off the main actor.
    public nonisolated var operatorLogLine: String {
        switch self {
        case .invalidCanvasRequest:
            return "Ignored a request for a virtual display this machine cannot open."
        case .unexpectedMessage:
            return "Closed a connection that sent something out of order. The two machines are probably "
                + "running different versions of Sensorium."
        case .invalidAuthentication:
            return "Refused a connection that could not prove it is a machine this one has paired with."
        case .authenticationRequired:
            return "Refused a request that arrived before the other machine proved who it is. If this machine "
                + "has not been paired with yet, start pairing here and enter the code over there."
        case .inputSessionUnavailable:
            return "Ignored typing and clicking that arrived with no virtual display open."
        case .inputInjectionUnavailable:
            return "Ignored typing and clicking: this machine cannot deliver it. Approve Sensorium Host under "
                + "System Settings > Privacy & Security > Accessibility, then start the host again."
        case .invalidInput:
            return "Ignored typing or clicking that landed outside the virtual display."
        case .invalidViewerDrawableSize:
            return "Ignored a window size the other machine reported that this one cannot stream."
        case .invalidViewerFocus:
            return "Ignored a focus report naming a canvas this session does not have."
        case .invalidStreamScalePreference:
            return "Ignored a stream resolution choice naming a canvas this session does not have."
        case .deviceNotPaired:
            return "Refused a machine this one has not paired with. Start pairing here to let it in."
        case .pairingConnectionFailuresExceeded:
            return "Closed a connection after too many wrong pairing codes on it."
        case .helloAlreadyAccepted:
            return "Closed a connection that sent a hello twice. The other machine should open a new "
                + "connection to change what it is connected as."
        }
    }
}

/// Who is on this machine, for the terminal.
///
/// The transport reports a closed connection whether or not anyone ever
/// authenticated on it, and a refused viewer closing is not a session ending.
/// Keeping the last identified name here is what lets the log stay silent for
/// the first and name the person for the second.
public struct HostPeerActivityLog: Sendable {
    private var connectedPeer: String?

    public init() {}

    /// `nil` when there is nothing true to say.
    public mutating func line(for peer: HostPeerPresence) -> String? {
        switch peer {
        case let .identified(deviceName):
            connectedPeer = deviceName
            // The same hello precedes both targets; the line that follows
            // names which one it became.
            return "\(deviceName) is connected."
        case let .closed(reason):
            guard let peer = connectedPeer else {
                return nil
            }
            connectedPeer = nil
            // The reason goes where the ending is reported, not on a line of
            // its own: a drop and the cause of it read as one event.
            guard let reason else {
                return "\(peer) is no longer connected. Nothing on this machine is being shared now."
            }
            return "\(peer) is no longer connected (\(reason)). Nothing on this machine is being shared now."
        }
    }
}
