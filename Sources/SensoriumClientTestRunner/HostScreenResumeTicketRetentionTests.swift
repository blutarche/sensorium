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
        // An automatic redial that holds no ticket for its target stops
        // instead of dialling. Without a ticket the host reads the connect
        // as a new session, and a host asking first would put its prompt up
        // once per backoff attempt; the person at the viewer asks again
        // instead. A session canvas is never gated this way.
        expect(
            HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: nil,
                isPersonInitiated: false
            ),
            "an automatic redial holding no ticket for the target stops"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: nil,
                isPersonInitiated: true
            ),
            "a person's own attempt dials with no ticket, because the person is there to answer for it"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: .hostScreen(displayIdentity: displayIdentity),
                ticketToPresent: held.ticket,
                isPersonInitiated: false
            ),
            "an automatic redial that holds a ticket for the target presents it -- nothing to stop"
        )
        expect(
            !HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: .sessionCanvas,
                ticketToPresent: nil,
                isPersonInitiated: false
            ),
            "a session-canvas target needs no ticket at all, so there is nothing to stop"
        )
        expect(
            HostScreenResumeTicketRetention.mustStopWithoutTicket(
                target: .offeredHostScreen(preferredDisplayIdentity: nil),
                ticketToPresent: nil,
                isPersonInitiated: false
            ),
            "an offered-host-screen automatic redial holding no ticket stops exactly like a named .hostScreen target"
        )
        print("PASS: an automatic redial stops without a ticket, and a person's own attempt does not")
    }

    do {
        // `HostScreenConnectPlan` is computed once per attempt, from the
        // ticket held at that moment: a plan for a target no ticket was
        // minted for presents nothing, and the one for the display the
        // held ticket names presents exactly that ticket. The plan is also
        // where the person flag is consumed, so a second automatic attempt
        // can never inherit the first attempt's own `true`.
        let target = SessionTarget.hostScreen(displayIdentity: displayIdentity)
        expect(
            HostScreenConnectPlan.compute(target: target, heldTicket: nil, isPersonInitiated: true)
                .ticketToPresent == nil,
            "an attempt holding no ticket presents none"
        )
        expect(
            HostScreenConnectPlan.compute(target: target, heldTicket: held, isPersonInitiated: false)
                .ticketToPresent == held.ticket,
            "and one holding this display's own ticket presents it"
        )
        expect(
            HostScreenConnectPlan.compute(target: .sessionCanvas, heldTicket: held, isPersonInitiated: false)
                .ticketToPresent == nil,
            "a session-canvas target presents nothing, whatever is held"
        )
        expect(
            !HostScreenConnectPlan.compute(target: target, heldTicket: nil, isPersonInitiated: true)
                .mustStopWithoutTicket,
            "the person-initiated first attempt dials"
        )
        expect(
            HostScreenConnectPlan.compute(target: target, heldTicket: nil, isPersonInitiated: false)
                .mustStopWithoutTicket,
            "and the automatic redial that follows it stops, holding no ticket and no person behind it"
        )
        print("PASS: a connect plan presents exactly the ticket held for the target it names, and stops an automatic redial holding none")
    }
}
