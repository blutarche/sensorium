import Foundation
import SensoriumClient

@MainActor
func testHostScreenResumeTicketRetentionTests() async {
    let displayIdentity = "00000610-0000a038"
    let held = HostScreenResumeTicket(displayIdentity: displayIdentity, ticket: Data([0xAB, 0xCD]))

    do {
        // A redial of the exact same target presents the held
        // ticket -- design §6.5's own "the ordinary case... must
        // be silent."
        expect(
            HostScreenResumeTicketRetention.ticketToPresent(
                for: .hostScreen(displayIdentity: displayIdentity),
                held: held
            ) == held.ticket,
            "a target matching the held ticket's own display presents that ticket"
        )
        print("PASS: a redial of the held ticket's own target presents it")
    }

    do {
        // A ticket held for one display is never presented for
        // another, or for the virtual display -- a stale or
        // unrelated ticket is never carried into a connect it was
        // never minted for.
        expect(
            HostScreenResumeTicketRetention.ticketToPresent(
                for: .hostScreen(displayIdentity: "a-different-display"),
                held: held
            ) == nil,
            "a ticket held for one display is never presented for another"
        )
        expect(
            HostScreenResumeTicketRetention.ticketToPresent(for: .sessionCanvas, held: held) == nil,
            "a session-canvas target never presents a resume ticket"
        )
        expect(
            HostScreenResumeTicketRetention.ticketToPresent(
                for: .hostScreen(displayIdentity: displayIdentity),
                held: nil
            ) == nil,
            "nothing is presented when no ticket is held at all"
        )
        print("PASS: a resume ticket is never presented outside the exact target it was minted for")
    }

    do {
        // Any change of target clears the held ticket -- even a
        // re-pick of the very display it was minted for, since that
        // pick is user-initiated and design §6.5 reserves a silent
        // resume for automatic reconnection alone.
        expect(
            HostScreenResumeTicketRetention.afterTargetChanged(
                from: .hostScreen(displayIdentity: displayIdentity),
                to: .sessionCanvas,
                held: held
            ) == nil,
            "picking the virtual display clears whatever ticket was held"
        )
        expect(
            HostScreenResumeTicketRetention.afterTargetChanged(
                from: .hostScreen(displayIdentity: displayIdentity),
                to: .hostScreen(displayIdentity: displayIdentity),
                held: held
            ) == held,
            "presenting the same target back unchanged (no actual change) leaves the held ticket alone"
        )
        expect(
            HostScreenResumeTicketRetention.afterTargetChanged(
                from: .hostScreen(displayIdentity: displayIdentity),
                to: .hostScreen(displayIdentity: "a-different-display"),
                held: held
            ) == nil,
            "re-picking a different display clears the ticket held for the old one"
        )
        print("PASS: any target change clears the held ticket, and a genuine no-op leaves it alone")
    }

    do {
        // Design §6.5 "never in a retry loop": only a signed proof
        // sent inside a person-initiated attempt is allowed; an
        // automatic redial holding no ticket must stop instead.
        expect(
            HostScreenResumeTicketRetention.mustStopBeforeSigning(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: nil,
                isPersonInitiated: false
            ),
            "an automatic redial with no ticket held must not sign"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopBeforeSigning(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: nil,
                isPersonInitiated: true
            ),
            "a person-initiated attempt with no ticket held may still sign"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopBeforeSigning(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: held.ticket,
                isPersonInitiated: false
            ),
            "an automatic redial that holds a ticket for the target presents it -- nothing to stop"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopBeforeSigning(
                target: .sessionCanvas,
                ticketToPresent: nil,
                isPersonInitiated: false
            ),
            "a session-canvas target never signs at all, so there is nothing to stop"
        )
        print("PASS: only a person-initiated attempt may fall back to signing when no ticket is held")
    }

    do {
        // `HostScreenConnectPlan` is computed once per attempt, so a
        // second automatic attempt's own plan never inherits the first
        // attempt's person flag -- even when that first attempt never
        // connected at all, so nothing about the target or the held
        // ticket changed between the two. Reading the flag after
        // `transport.start()`, which can throw and be retried, would let
        // a stale `true` survive into the automatic redial that followed.
        let target = SessionTarget.hostScreen(displayIdentity: displayIdentity)
        let firstAttemptPlan = HostScreenConnectPlan.compute(target: target, heldTicket: nil, isPersonInitiated: true)
        expect(!firstAttemptPlan.mustStopBeforeSigning, "the person-initiated first attempt may still sign")

        let secondAttemptPlan = HostScreenConnectPlan.compute(target: target, heldTicket: nil, isPersonInitiated: false)
        expect(
            secondAttemptPlan.mustStopBeforeSigning,
            "an automatic redial's own plan stops, holding no ticket and no person behind it, whether or not the first attempt ever connected"
        )
        print("PASS: a plan computed once per attempt never lets a second automatic attempt inherit the first attempt's own person flag")
    }
}
