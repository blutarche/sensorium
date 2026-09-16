import Foundation
import SensoriumClient
import SensoriumCore

/// Counts connect attempts from the driver's own task.
private final class SleepingDisplayAttemptCounter: @unchecked Sendable {
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

/// A host that ended a session because its own displays were asleep is a
/// different thing from a host that can no longer capture at all, and the
/// two must not read the same: one is a screen to wake, the other is an app
/// to reopen.
func testHostDisplaysAsleepCopyTests() {
    let asleep = ViewerSessionFailureCopy.line(for: .hostDisplaysAsleep, hostLabel: "Studio")
    expect(
        asleep.contains("asleep"),
        "a session ended by sleeping displays says so, got \(asleep)"
    )
    expect(
        !asleep.contains("quit") && !asleep.contains("reopen") && !asleep.contains("opened again"),
        "and never tells anyone to reopen an app that is working fine, got \(asleep)"
    )
    let unavailable = ViewerSessionFailureCopy.line(for: .hostCaptureUnavailable, hostLabel: "Studio")
    expect(
        unavailable != asleep,
        "the two endings read differently, since their remedies are nothing alike"
    )
    expect(
        unavailable.contains("quit"),
        "a host that cannot capture at all still names the one thing that fixes it, got \(unavailable)"
    )
    expect(
        unavailable.lowercased().components(separatedBy: "stopped").count == 2,
        "and says stopped once rather than twice in one breath, got \(unavailable)"
    )
    expect(
        ViewerSessionFailureCopy.rowLine(for: .hostDisplaysAsleep, hostLabel: "Studio").contains("asleep"),
        "the Your machines row says the same thing in its own short form, got "
            + ViewerSessionFailureCopy.rowLine(for: .hostDisplaysAsleep, hostLabel: "Studio")
    )
    expect(
        ClientSessionRunner.hostEnding(for: .goodbye(reason: GoodbyeReason.hostDisplaysAsleep)) == .hostDisplaysAsleep,
        "the wire token this host sends is what picks those words"
    )
    expect(
        ClientSessionRunner.hostEnding(for: .goodbye(reason: GoodbyeReason.captureUnavailable))
            == .hostCaptureUnavailable,
        "and the older token still picks its own"
    )
    expect(
        ClientSessionRunner.hostEnding(for: .goodbye(reason: GoodbyeReason.stoppedByHost)) == nil,
        "a person pressing Stop is neither, and keeps the ending it already had"
    )

    var machine = ViewerSessionStateMachine(hostName: "Studio")
    machine.handle(.connectStarted)
    machine.handle(.canvasReady)
    let status = machine.handle(.hostEnded(
        reasonLine: ViewerSessionFailureCopy.line(for: .hostDisplaysAsleep, hostLabel: "Studio")
    ))
    expect(
        status.detail.contains("asleep"),
        "the panel a person reads carries the reason, not just a lost connection, got \(status.detail)"
    )
    expect(
        !status.buttons.isEmpty,
        "and still offers a way back, since waking the screen is all this takes"
    )

    print("PASS: a session ended by sleeping host displays reads as that, never as a host that needs reopening")
}

/// Redialling into a host whose screens are asleep would put the same
/// session back up, find the same dark screen, and end the same way, over
/// and over. A person waking the screen is what changes the answer.
func testHostDisplaysAsleepStopsTheRunTests() async {
    let attempts = SleepingDisplayAttemptCounter()
    let events = RecordedReconnectEvents()
    let driver = ClientReconnectDriver(
        policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
        runSession: {
            attempts.increment()
            throw ClientSessionError.hostDisplaysAsleep
        },
        sleep: { _ in
            expect(false, "a session the host's own sleeping screens ended must never wait for a retry")
        },
        onEvent: { events.append($0) }
    )

    let outcome = await driver.runUntilConnectedSessionEnds()

    expect(
        outcome == .stopped,
        "a host with nothing on its screens ends the run outright, got \(outcome)"
    )
    expect(attempts.value == 1, "no second attempt follows, since the screen is what has to change")
    expect(
        events.all == [.attemptFailed(.hostDisplaysAsleep)],
        "exactly one ending is reported, with no retrying event after it, got \(events.all)"
    )
    expect(
        ViewerSessionFailure.classify(ClientSessionError.hostDisplaysAsleep) == .hostDisplaysAsleep,
        "and it carries the words a person reads rather than an unclassified ending"
    )

    print("PASS: a host whose screens are asleep stops the run instead of being redialled into forever")
}
