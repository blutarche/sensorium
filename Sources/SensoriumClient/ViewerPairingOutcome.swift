import Foundation
import Network
import SensoriumCore

/// How a pairing attempt ended, in the only distinctions the wire actually
/// supports. `HostPairingService` sends back one reason string per refusal, so
/// a refusal keeps that string and the copy below turns it into a sentence;
/// everything else collapses into the four cases a viewer can tell apart.
public enum ViewerPairingOutcome: Equatable, Sendable {
    /// The machine answered and said no, with its own reason off the wire.
    case refused(reason: String)
    /// Nothing answered. A wrong address, a sleeping machine and a host that is
    /// not running are indistinguishable from here, so they share one case.
    case unreachable
    /// Something answered but did not prove it is the machine that showed the code.
    case unverifiedHost
    case unexpectedReply
    case unknown

    public static func classify(_ error: any Error) -> ViewerPairingOutcome {
        if let error = error as? ClientSessionError {
            switch error {
            case let .pairingRejected(reason): return .refused(reason: reason)
            case .hostKeyMismatch: return .unverifiedHost
            case .unexpectedMessage: return .unexpectedReply
            case .notConnected, .timedOut: return .unreachable
            default: return .unknown
            }
        }
        if let error = error as? NetworkControlConnectionError {
            switch error {
            case .notReady, .closed, .peerFailed, .timedOut: return .unreachable
            // Unreachable in practice: pairing dials with no certificate hash
            // to pin against, so the verify block always accepts. Kept here
            // only so this switch stays exhaustive over the shared error type.
            case .certificatePinMismatch: return .unverifiedHost
            }
        }
        if error is NWError {
            return .unreachable
        }
        return .unknown
    }
}

/// What the window says when pairing fails, and where it puts the caret for the
/// next try. Never the raw reason string on its own: `code-already-consumed` is
/// a wire token, not a sentence someone pairing their first machine can act on.
public struct ViewerPairingFailureCopy: Equatable, Sendable {
    public let headline: String
    public let detail: String
    /// Which field the user most likely has to change, so the retry starts
    /// with the caret already there.
    public let focus: ViewerPairingField
    /// Whether another try needs a new code shown on the other machine first.
    /// Retyping a spent code can only fail again.
    public let needsFreshCode: Bool

    public init(headline: String, detail: String, focus: ViewerPairingField, needsFreshCode: Bool) {
        self.headline = headline
        self.detail = detail
        self.focus = focus
        self.needsFreshCode = needsFreshCode
    }

    /// `hostLabel` is what the user called the machine — their own name for it
    /// when they gave one, its address when they did not — so every sentence
    /// names a machine the reader recognises.
    public static func copy(
        for outcome: ViewerPairingOutcome,
        hostLabel: String
    ) -> ViewerPairingFailureCopy {
        switch outcome {
        case let .refused(reason):
            return refusalCopy(reason: reason, hostLabel: hostLabel)
        case .unreachable:
            return ViewerPairingFailureCopy(
                headline: "Could not reach \(hostLabel).",
                detail: "Check that it is awake and Sensorium Host is running.",
                focus: .address,
                needsFreshCode: false
            )
        case .unverifiedHost:
            return ViewerPairingFailureCopy(
                headline: "Could not verify \(hostLabel).",
                detail: "Pair only with a code read directly off that machine\u{2019}s screen.",
                focus: .address,
                needsFreshCode: true
            )
        case .unexpectedReply:
            return ViewerPairingFailureCopy(
                headline: "\(hostLabel) replied with something Sensorium did not expect.",
                detail: "Update Sensorium on both machines.",
                focus: .address,
                needsFreshCode: true
            )
        case .unknown:
            return ViewerPairingFailureCopy(
                headline: "Pairing did not finish.",
                detail: "Start pairing again on \(hostLabel).",
                focus: .code,
                needsFreshCode: true
            )
        }
    }

    /// The reasons `HostPairingService.handlePairRequest` can send. An unknown
    /// one is quoted rather than translated: inventing a cause for a string
    /// this version has never seen would be a guess dressed as an explanation.
    private static func refusalCopy(reason: String, hostLabel: String) -> ViewerPairingFailureCopy {
        switch reason {
        case "invalid-code":
            return ViewerPairingFailureCopy(
                headline: "Wrong code.",
                detail: "Check the six digits on \(hostLabel) and try again.",
                focus: .code,
                needsFreshCode: false
            )
        case "code-expired":
            return ViewerPairingFailureCopy(
                headline: "That code has expired.",
                detail: "Show a new one on \(hostLabel).",
                focus: .code,
                needsFreshCode: true
            )
        case "code-already-consumed":
            return ViewerPairingFailureCopy(
                headline: "That code was already used.",
                detail: "Show a new one on \(hostLabel).",
                focus: .code,
                needsFreshCode: true
            )
        case "code-attempts-exhausted":
            return ViewerPairingFailureCopy(
                headline: "Too many wrong tries.",
                detail: "Show a new code on \(hostLabel).",
                focus: .code,
                needsFreshCode: true
            )
        case "no-active-code":
            return ViewerPairingFailureCopy(
                headline: "\(hostLabel) is not showing a code.",
                detail: "Press Show pairing code there first.",
                focus: .code,
                needsFreshCode: true
            )
        case "invalid-request":
            return ViewerPairingFailureCopy(
                headline: "\(hostLabel) could not read the request.",
                detail: "Try again; if it repeats, update Sensorium on both machines.",
                focus: .code,
                needsFreshCode: false
            )
        default:
            return ViewerPairingFailureCopy(
                headline: "\(hostLabel) refused to pair.",
                detail: "It gave a reason this version of Sensorium does not know: \u{201C}\(reason)\u{201D}.",
                focus: .code,
                needsFreshCode: true
            )
        }
    }
}
