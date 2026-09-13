import Foundation
import SensoriumClient
import SensoriumCore

private final class StopAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// What the viewer does when the host says a person ended the session.
///
/// A closed socket alone reads as a dropout, and the viewer's own automatic
/// redial puts the session straight back up -- which is what made Stop at the
/// host look like it did nothing at all. The host now names the ending, and
/// none of this is allowed to redial into it: design §6.5's "automatic
/// reconnection either presents a valid ticket or stops and waits for the
/// person."
@MainActor
func runViewerHostStopTests() async {
    do {
        // The host's own goodbye is read, and only for its reason
        expect(
            ClientSessionRunner.isStoppedByHost(.goodbye(reason: GoodbyeReason.stoppedByHost)),
            "the viewer reads the host's own Stop off the goodbye it arrives on"
        )
        expect(
            !ClientSessionRunner.isStoppedByHost(.goodbye(reason: "transport-closed")),
            "an ordinary ending is still an ordinary ending, worth redialling"
        )
        expect(
            !ClientSessionRunner.isStoppedByHost(.canvasRefused(reason: GoodbyeReason.stoppedByHost, surfaceID: nil)),
            "and nothing but a goodbye can claim to be one, whatever reason it carries"
        )

        print("PASS: the viewer recognises the host's Stop on the goodbye that carries it, and nothing else")
    }

    do {
        // A stopped session never redials
        let attempts = StopAttemptCounter()
        let events = RecordedReconnectEvents()
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
            runSession: {
                attempts.increment()
                throw ClientSessionError.stoppedByHost
            },
            sleep: { _ in
                expect(false, "a session a person at the host ended must never wait for a retry")
            },
            onEvent: { events.append($0) }
        )

        let outcome = await driver.runUntilConnectedSessionEnds()

        expect(outcome == .stopped, "a session a person at the host ended ends the run outright, got: \(outcome)")
        expect(attempts.value == 1, "no second connection attempt follows a Stop at the host")
        expect(
            events.all == [.attemptFailed(.stoppedByHost)],
            "exactly one ending is reported, with no retrying event ever following it"
        )

        print("PASS: a session a person at the host ended stops the run without a second attempt")
    }

    do {
        // The words the person at the viewer reads
        let line = ViewerSessionFailureCopy.line(for: .stoppedByHost, hostLabel: "Mac mini")
        expect(
            line == "Stopped: a person at Mac mini ended this session from that machine.",
            "the viewer says who ended the session and where they were -- got \"\(line)\""
        )
        expect(
            ViewerSessionFailureCopy.line(for: ClientSessionError.stoppedByHost, hostLabel: "Mac mini") == line,
            "and reaches the same words from the error the session itself throws"
        )

        print("PASS: a session stopped at the host says so, naming the machine the person was at")
    }

    do {
        // The ticket dies with the session it resumed
        let held = HostScreenResumeTicket(displayIdentity: "00000610-0000a038", ticket: Data([0x01, 0x02]))
        expect(
            HostScreenResumeTicketRetention.afterHostStoppedSession(held: held) == nil,
            "a ticket kept past a Stop at the host would resume the very session a person just ended"
        )
        expect(
            HostScreenResumeTicketRetention.ticketToPresent(
                for: .hostScreen(displayIdentity: "00000610-0000a038"),
                held: HostScreenResumeTicketRetention.afterHostStoppedSession(held: held)
            ) == nil,
            "so the next connect to that same display presents nothing and asks a person instead"
        )

        print("PASS: a Stop at the host drops the held resume ticket, so nothing resumes silently after it")
    }

    do {
        // The window says why it ended, not that the link dropped
        var machine = ViewerSessionStateMachine(hostName: "Mac mini")
        machine.handle(.connectStarted)
        machine.handle(.canvasReady)
        let reasonLine = ViewerSessionFailureCopy.line(for: .stoppedByHost, hostLabel: "Mac mini")
        let status = machine.handle(.stoppedByHost(reasonLine: reasonLine))

        expect(
            status.detail == "Stopped: a person at Mac mini ended this session from that machine.",
            "the panel carries the ending's own words -- got \"\(status.detail)\""
        )
        expect(
            status.headline != "Connection to Mac mini lost.",
            "and never the dropped-link headline, which says the wrong thing about an ending somebody chose"
        )
        expect(
            status.phase == .lost && status.tone == .bad && status.isOverlayVisible && status.dimsCanvas,
            "the frozen picture behind it is dimmed under an overlay, exactly as an ended session's is"
        )
        expect(
            status.buttons.map(\.title) == ["Quit Sensorium", "Your machines", "Try again"],
            "with the same actions an ordinary ending offers, so another session still needs a person to ask for one -- got \(status.buttons.map(\.title))"
        )

        print("PASS: a session a person at the host stopped says so in the window, over the dimmed picture it left")
    }
}
