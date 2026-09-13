import Foundation
import SensoriumCore

/// What the presence question settled to. No third case: like
/// `HostScreenSelectionRefusal`, nothing here can represent a reduced or
/// view-only session -- `.proceed` streams video, `.refused` refuses the
/// whole session, and there is nothing between them.
public enum HostScreenPresenceOutcome: Equatable, Sendable {
    case proceed
    case refused(reason: String)
}

/// Whether starting a host-screen session may skip asking, and once it may
/// not, what a person's answer -- or the lack of one -- decides.
///
/// Both entry points are pure functions over values the caller already
/// has: an idle reading and an elapsed duration the caller already
/// measured. This type owns no clock and no signal of its own.
public enum HostScreenPresenceRule {
    /// The recommended value, used by `HostSessionController` as its own
    /// default for `presenceThreshold`.
    public static let recommendedPresenceThreshold: TimeInterval = 5 * 60

    /// Held in `SensoriumCore` as
    /// `SessionTimeouts.hostScreenPresencePromptTimeout` so the viewer's own
    /// `SessionTimeouts.remoteDefault.hostScreenGrant`, sized against this
    /// same window, cannot drift out of step with it.
    public static let promptTimeout: TimeInterval = SessionTimeouts.hostScreenPresencePromptTimeout

    public enum Assessment: Equatable, Sendable {
        case mayProceed
        case mustAsk
    }

    /// Whether a session may start without asking anyone.
    ///
    /// `.unavailable` always yields `.mustAsk`: unknown is not absent. An
    /// idle reading that could not be taken is exactly what a broken
    /// sensor produces, and it must never be read as nobody being home.
    ///
    /// The boundary -- `idleFor` exactly equal to `presenceThreshold` --
    /// reads as `.mustAsk`, not `.mayProceed`. The design calls a false
    /// "present" cheap (one retry) and does not say the same of a false
    /// "absent", so an exact tie resolves toward asking.
    public static func assess(
        reading: HostLocalActivityReading,
        presenceThreshold: TimeInterval
    ) -> Assessment {
        switch reading {
        case let .idleFor(seconds):
            return seconds > presenceThreshold ? .mayProceed : .mustAsk
        case .unavailable:
            return .mustAsk
        }
    }

    /// The per-machine "ask me first" setting folded in: a device armed
    /// with `asksWhenInUse` false may always proceed without asking, no
    /// matter how recently this machine saw local input -- arming a
    /// machine is itself the consent this feature needs, and asking first
    /// is an extra the person arming may switch on. `true` defers entirely
    /// to the idle-time rule above.
    public static func assess(
        reading: HostLocalActivityReading,
        presenceThreshold: TimeInterval,
        asksWhenInUse: Bool
    ) -> Assessment {
        guard asksWhenInUse else { return .mayProceed }
        return assess(reading: reading, presenceThreshold: presenceThreshold)
    }

    public enum Answer: Equatable, Sendable {
        case approved
        case declined
    }

    /// Zero-padded m:ss, matching the pairing countdown. Negative input
    /// clamps to zero.
    public static func countdownLabel(remainingSeconds: TimeInterval) -> String {
        let whole = max(0, Int(remainingSeconds.rounded()))
        return String(
            format: "Don\u{2019}t Allow will be chosen automatically in %d:%02d.",
            whole / 60, whole % 60
        )
    }

    /// The outcome once a prompt was required, given whatever answer has
    /// arrived so far (`nil` if none has) and how long it has been since
    /// the prompt was shown. Returns `nil` while still waiting: not yet
    /// decided is not a session outcome, degraded or otherwise -- it is
    /// just not an answer yet, and a caller must keep calling rather than
    /// treat `nil` as any kind of admission.
    ///
    /// The elapsed check is made first and wins over `answer`: once
    /// `elapsedSinceAsked` exceeds `promptTimeout`, the request is refused
    /// even if `answer` says `.approved` -- an approval that reaches this
    /// function after its own window closed does not get to reopen it.
    /// Exactly at the timeout is still within it, not yet expired.
    public static func decide(
        answer: Answer?,
        elapsedSinceAsked: TimeInterval,
        promptTimeout: TimeInterval = HostScreenPresenceRule.promptTimeout
    ) -> HostScreenPresenceOutcome? {
        guard elapsedSinceAsked <= promptTimeout else {
            return .refused(reason: unansweredReason)
        }
        switch answer {
        case .approved:
            return .proceed
        case .declined:
            return .refused(reason: declinedReason)
        case nil:
            return nil
        }
    }

    /// Mapped by `HostSessionController` to the wire reason
    /// `host-screen-presence-declined`.
    public static let declinedReason = "the connection was declined at that machine"

    /// The thirty-second window closing with no answer.
    public static let unansweredReason = "that machine is in use and the prompt was not answered"
}
