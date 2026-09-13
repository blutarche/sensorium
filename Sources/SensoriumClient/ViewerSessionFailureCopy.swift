import Foundation
import Network
import SensoriumCore

/// Why a session attempt ended, in the distinctions a person can act on
/// differently. `ViewerPairingOutcome` covers the one-time ceremony; this
/// covers every dial after it.
public enum ViewerSessionFailure: Hashable, Sendable {
    /// Nothing answered. A sleeping machine, a wrong address and a host that is
    /// not running are indistinguishable from here, so they share one case.
    case unreachable
    /// The host answered but presented a key other than the one pinned at
    /// pairing.
    case unverifiedHost
    /// The host refused the canvas the session cannot do without, with its own
    /// reason off the wire.
    case canvasRefused(reason: String)
    /// The host named a canvas this viewer never asked for.
    case canvasIdentityMismatch
    case unexpectedReply
    /// This machine has no identity to present, so it cannot prove who it is.
    case identityMissing
    /// The machine answered the pairing request and said no, with its own reason.
    case pairingRefused(reason: String)
    /// A `.hostScreen` connect ended in anything but `hostScreenReady`, with
    /// the host's own named reason -- `docs/host-screen-design.md` §6.3's session-time flow.
    case hostScreenRefused(reason: String)
    /// A person at the host ended the live session from that machine. Not a
    /// failure of anything here, and the one ending this viewer must never
    /// redial: redialling would put the session straight back up and make the
    /// host's Stop control look like it did nothing.
    case stoppedByHost
    /// The host ended the session because its own displays were asleep and
    /// would not wake, so nothing on that machine was being drawn and there
    /// was no picture to send. Nothing here failed, and nothing at that
    /// machine is broken: a screen has to come back on.
    case hostDisplaysAsleep
    /// The host ended the session because it could no longer get a picture
    /// out of that machine at all. Told apart from the case above because
    /// the remedies are nothing alike.
    case hostCaptureUnavailable
    case unknown

    public static func classify(_ error: any Error) -> ViewerSessionFailure {
        if let error = error as? ClientSessionError {
            switch error {
            case .notConnected, .timedOut: return .unreachable
            case .hostKeyMismatch: return .unverifiedHost
            case let .canvasRefused(reason): return .canvasRefused(reason: reason)
            case .surfaceIDMismatch: return .canvasIdentityMismatch
            case .unexpectedMessage: return .unexpectedReply
            case .identityRequired: return .identityMissing
            case let .pairingRejected(reason): return .pairingRefused(reason: reason)
            case let .hostScreenRefused(reason): return .hostScreenRefused(reason: reason)
            case .stoppedByHost: return .stoppedByHost
            case .hostDisplaysAsleep: return .hostDisplaysAsleep
            case .invalidInput: return .unknown
            }
        }
        if let error = error as? NetworkControlConnectionError {
            switch error {
            case .notReady, .closed, .peerFailed, .timedOut: return .unreachable
            case .certificatePinMismatch: return .unverifiedHost
            }
        }
        if error is NWError {
            return .unreachable
        }
        return .unknown
    }
}

/// What a failed session says in the terminal.
///
/// Nothing here interpolates an error value. A message assembled around
/// system-supplied text is a message no later edit can safely touch.
public enum ViewerSessionFailureCopy {
    public static func line(for error: any Error, hostLabel: String) -> String {
        line(for: ViewerSessionFailure.classify(error), hostLabel: hostLabel)
    }

    public static func line(for failure: ViewerSessionFailure, hostLabel: String) -> String {
        switch failure {
        case .unreachable:
            return "Could not reach \(hostLabel). Nothing answered at that address. Check that the "
                + "other machine is awake, that Sensorium Host is running on it, and that both "
                + "machines are on the same network."
        case .unverifiedHost:
            // Security-relevant, and the one failure where trying again is the
            // wrong reflex: pairing again would pin whatever answered.
            return "Stopped: \(hostLabel) did not prove it is the machine this one paired with. The key it "
                + "presented is not the key saved at pairing. That is what a host reinstalled or reset "
                + "on that machine looks like, and also what another machine answering in its place would "
                + "look like. Check at the machine itself before pairing with it again."
        case let .canvasRefused(reason):
            return canvasRefusalLine(reason: reason, hostLabel: hostLabel)
        case .canvasIdentityMismatch:
            return "\(hostLabel) opened a session canvas this machine did not ask for, so nothing was shown. "
                + "The two machines are probably running different versions of Sensorium; update both, then "
                + "try again."
        case .unexpectedReply:
            return "\(hostLabel) replied with something Sensorium did not expect. The two machines are "
                + "probably running different versions of Sensorium; update both, then try again."
        case .identityMissing:
            return "This machine has no Sensorium identity to present, so it cannot prove who it is. Pair "
                + "with \(hostLabel) again to make one."
        case let .pairingRefused(reason):
            // The one-time ceremony already has words for every reason the
            // host can send; writing a second set would let the two drift.
            let copy = ViewerPairingFailureCopy.copy(for: .refused(reason: reason), hostLabel: hostLabel)
            return "\(copy.headline) \(copy.detail)"
        case let .hostScreenRefused(reason):
            // Same reasoning as `.pairingRefused` above: the session-time
            // host-screen flow already has words for every reason the host
            // can send, in `HostScreenRefusalCopy`, so this reuses them
            // rather than writing a second set that could drift. They are
            // read under a headline that names the host, so no label here.
            return HostScreenRefusalCopy.line(reason: reason)
        case .stoppedByHost:
            // Nothing here failed, and nothing here is being retried, so this
            // says what happened and stops. "Stopped:" is the same opening
            // `.unverifiedHost` uses for an ending only a person can undo.
            return "Stopped: a person at \(hostLabel) ended this session from that machine."
        case .hostDisplaysAsleep:
            // Not a failure of anything here, and not a failure of the host
            // app either. macOS draws nothing while a screen sleeps, so there
            // was no picture to send.
            return "Stopped: the screens on \(hostLabel) are asleep, so there was nothing to send. Sensorium "
                + "asked that machine to wake them and they did not come back. Wake a screen at the machine "
                + "itself, then try again."
        case .hostCaptureUnavailable:
            return "Stopped: \(hostLabel) is no longer giving Sensorium any picture to send. Its Sensorium "
                + "Host app needs to be quit and opened again at the machine itself before this machine can "
                + "connect."
        case .unknown:
            return "The session with \(hostLabel) stopped, and Sensorium could not tell why. Try "
                + "again; if it keeps failing, quit and reopen Sensorium on both machines."
        }
    }

    /// What the redial loop reports, in words. The driver hands over values,
    /// never sentences, so the host's name and the product's own verbs are
    /// chosen in exactly one place.
    public static func line(for event: ClientReconnectEvent, hostLabel: String) -> String {
        switch event {
        case let .attemptFailed(failure):
            return line(for: failure, hostLabel: hostLabel)
        case let .retrying(afterSeconds):
            return String(format: "Trying %@ again in %.1f seconds.", hostLabel, afterSeconds)
        }
    }

    /// The short fragment a `Your machines` row appends after its address --
    /// never the panel's own explanation, which stays reachable through
    /// `line(for:hostLabel:)` above for the status overlay alone. No case
    /// here repeats the host's name: the row already shows it as the address
    /// beside this fragment.
    public static func rowLine(for failure: ViewerSessionFailure, hostLabel: String) -> String {
        switch failure {
        case .unreachable:
            return "no answer"
        case .unverifiedHost:
            return "answered with a key other than the one saved at pairing; check it at the machine "
                + "before pairing again"
        case let .canvasRefused(reason):
            return canvasRefusalRowLine(reason: reason)
        case .canvasIdentityMismatch, .unexpectedReply:
            return "version mismatch; update both machines"
        case .identityMissing:
            return "this machine has no identity; pair again"
        case let .pairingRefused(reason):
            let copy = ViewerPairingFailureCopy.copy(for: .refused(reason: reason), hostLabel: hostLabel)
            return rowFragment(fromHeadline: copy.headline, hostLabel: hostLabel)
        case let .hostScreenRefused(reason):
            return stripTrailingPeriod(HostScreenRefusalCopy.line(reason: reason))
        case .stoppedByHost:
            return "stopped from that machine"
        case .hostDisplaysAsleep:
            return "its screens are asleep; wake one at that machine"
        case .hostCaptureUnavailable:
            return "stopped sending a picture; quit and reopen Sensorium Host there"
        case .unknown:
            return "stopped; reason unknown"
        }
    }

    /// The reasons `canvasRefused` can name, in the row's own short form. An
    /// unknown one is quoted rather than translated, the same discipline
    /// `canvasRefusalLine` follows for the panel.
    private static func canvasRefusalRowLine(reason: String) -> String {
        switch reason {
        case CanvasRefusalReason.creationInProgress:
            return "busy opening a canvas for another connection; try again in a moment"
        case CanvasRefusalReason.canvasUnavailable:
            return "could not open a session canvas; quit and reopen Sensorium Host there"
        default:
            return "refused: \u{201C}\(reason)\u{201D}"
        }
    }

    /// A pairing headline, cut down to a row fragment: its trailing period
    /// dropped, and its first letter lowercased unless the headline opens
    /// with `hostLabel` itself -- a proper noun, never lowercased.
    private static func rowFragment(fromHeadline headline: String, hostLabel: String) -> String {
        let trimmed = stripTrailingPeriod(headline)
        guard !trimmed.hasPrefix(hostLabel), let first = trimmed.first else { return trimmed }
        return first.lowercased() + trimmed.dropFirst()
    }

    private static func stripTrailingPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// The reasons `canvasRefused` can name. An unknown one is quoted rather
    /// than translated: inventing a cause for a token this version has never
    /// seen would be a guess dressed as an explanation.
    private static func canvasRefusalLine(reason: String, hostLabel: String) -> String {
        switch reason {
        case CanvasRefusalReason.creationInProgress:
            return "\(hostLabel) is already opening a session canvas for another connection, so it "
                + "could not open one for this machine. Wait a moment, then try again."
        case CanvasRefusalReason.canvasUnavailable:
            // Nothing here can be tried again: the host asked macOS for a
            // canvas under every identity it has and was refused each time, so
            // the only thing that changes the answer happens at that machine.
            return "Stopped: \(hostLabel) could not open a session canvas. Its Sensorium Host app needs "
                + "to be quit and opened again at the machine itself before this machine can connect."
        default:
            return "\(hostLabel) would not open a session canvas. It gave a reason this version of "
                + "Sensorium does not know: \u{201C}\(reason)\u{201D}. Try again, and if it keeps "
                + "failing, update Sensorium on both machines."
        }
    }
}
