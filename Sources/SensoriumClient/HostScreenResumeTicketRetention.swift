import Foundation

/// A resume ticket held for exactly one host-screen target --
/// `docs/host-screen-design.md` §6.5: "a grant belongs to a host-screen session, not to a transport
/// connection, and the host decides what counts as the same session." The
/// viewer only ever holds the one ticket its last successful connect
/// carried, tagged with the display it was minted for.
public struct HostScreenResumeTicket: Equatable, Sendable {
    public let displayIdentity: String
    public let ticket: Data

    public init(displayIdentity: String, ticket: Data) {
        self.displayIdentity = displayIdentity
        self.ticket = ticket
    }
}

/// The pure decisions a held ticket needs: which ticket a connect may
/// present, what survives a target change or a Stop at the host, and when an
/// attempt holding none must stop instead of dialling. Kept out of
/// `ClientSessionHost` so the rules themselves are tested without a live
/// transport.
public enum HostScreenResumeTicketRetention {
    /// The ticket a connect for `target` may present -- `nil` for a
    /// session-canvas target, and `nil` whenever the held ticket belongs to
    /// a different display than `target` names, so a stale or unrelated
    /// ticket is never carried into a connect it was never minted for.
    public static func ticketToPresent(for target: SessionTarget, held: HostScreenResumeTicket?) -> Data? {
        guard case let .hostScreen(displayIdentity) = target,
              let held, held.displayIdentity == displayIdentity else {
            return nil
        }
        return held.ticket
    }

    /// What survives once the target changes. Automatic reconnection either
    /// presents a valid ticket or stops, and that only ever applies to a
    /// redial of the *same* target; a re-pick from the Screen
    /// menu -- even of the very display a ticket was minted for -- is a new
    /// user-initiated session, never the silent automatic-redial case a
    /// held ticket exists for, so any change of target clears it outright.
    public static func afterTargetChanged(
        from oldTarget: SessionTarget,
        to newTarget: SessionTarget,
        held: HostScreenResumeTicket?
    ) -> HostScreenResumeTicket? {
        guard oldTarget != newTarget else { return held }
        return nil
    }

    /// What survives a Stop at the host: nothing. The host invalidates that
    /// machine's tickets when a person ends a host-screen session there, so a
    /// ticket held past one resumes nothing anyway -- dropping it here is what
    /// keeps the viewer from dialling to find that out, and the surface
    /// having been torn down makes the next session a genuinely new one.
    public static func afterHostStoppedSession(held: HostScreenResumeTicket?) -> HostScreenResumeTicket? {
        nil
    }

    /// Never in a retry loop: without a ticket the host reads a host-screen
    /// connect as a new session, so a host set to ask first puts its prompt
    /// up for it. An automatic redial holding no ticket therefore stops and
    /// waits for the person at the viewer, rather than asking the person at
    /// the host once per backoff attempt, the same way a host's own refusal
    /// already stops without retrying. `.offeredHostScreen` is gated exactly
    /// like `.hostScreen`: its own request reaches the same person at the
    /// host, so a transport failure after it was sent must stop the same
    /// way. A session-canvas target presents no ticket at all, so this is
    /// always `false` for one.
    public static func mustStopWithoutTicket(
        target: SessionTarget,
        ticketToPresent: Data?,
        isPersonInitiated: Bool
    ) -> Bool {
        switch target {
        case .hostScreen, .offeredHostScreen:
            return ticketToPresent == nil && !isPersonInitiated
        case .sessionCanvas:
            return false
        }
    }
}

/// Everything `ClientSessionHost.runOnce()` needs to decide before it dials
/// -- computed once, from values already known before `transport.start()`,
/// so nothing later in that call (a network attempt that can throw and be
/// retried) can change what this attempt is allowed to do. `compute` is the
/// composition of `HostScreenResumeTicketRetention`'s own two decisions;
/// kept as one call so a caller cannot read `ticketToPresent` and
/// `mustStopWithoutTicket` from two different moments of
/// `isPersonInitiated` by accident.
public struct HostScreenConnectPlan: Equatable, Sendable {
    public let ticketToPresent: Data?
    public let mustStopWithoutTicket: Bool

    public init(ticketToPresent: Data?, mustStopWithoutTicket: Bool) {
        self.ticketToPresent = ticketToPresent
        self.mustStopWithoutTicket = mustStopWithoutTicket
    }

    public static func compute(
        target: SessionTarget,
        heldTicket: HostScreenResumeTicket?,
        isPersonInitiated: Bool
    ) -> HostScreenConnectPlan {
        let ticketToPresent = HostScreenResumeTicketRetention.ticketToPresent(for: target, held: heldTicket)
        return HostScreenConnectPlan(
            ticketToPresent: ticketToPresent,
            mustStopWithoutTicket: HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: target, ticketToPresent: ticketToPresent, isPersonInitiated: isPersonInitiated
            )
        )
    }
}
