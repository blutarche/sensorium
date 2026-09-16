import Foundation
import SensoriumHost

/// Stands in for the real, AppKit-driven prompt: records what it was asked
/// and returns whatever `answer` says, `nil` standing for the design's own
/// "the window closed with neither button pressed" -- its own thirty-second
/// timeout, the only way that can happen for real.
private final class FakeHostScreenPresencePrompting: HostScreenPresencePrompting {
    var answer: HostScreenPresenceRule.Answer?
    private(set) var calls: [HostScreenBadgeContent] = []
    /// Set to call back into the very `HostScreenPresenceGate` under test
    /// from inside `ask`, simulating the real reentrancy risk this gate's
    /// own `isPromptShowing` exists for: another connection's already-
    /// queued `@MainActor` work resuming while a real modal session is
    /// still pumping the run loop, before the first `ask` has returned.
    var reentrantAsk: (() -> HostScreenPresenceOutcome)?
    private(set) var reentrantResult: HostScreenPresenceOutcome?

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceRule.Answer? {
        calls.append(content)
        if let reentrantAsk {
            reentrantResult = reentrantAsk()
        }
        return answer
    }

    func takeReentrantResult() -> HostScreenPresenceOutcome? {
        reentrantResult
    }
}

private let testContent = HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")

@MainActor
func runHostScreenPresenceGateTests() async {
    do {
        // An answer that arrives settles it, exactly as
        // HostScreenPresenceRule.decide already does for a timely
        // one.
        let prompting = FakeHostScreenPresencePrompting()
        prompting.answer = .approved
        let gate = HostScreenPresenceGate(prompting: prompting)

        let outcome = gate.ask(content: testContent)

        expect(outcome == .proceed, "an approval reached within the window proceeds")
        expect(prompting.calls == [testContent], "the real prompt is asked exactly once, with exactly the content given")
        expect(!gate.isPromptShowing, "once ask returns, no prompt is left showing")

        print("PASS: HostScreenPresenceGate proceeds on an approval, asking the real prompt with exactly the content it was given")
    }

    do {
        // A decline refuses with HostScreenPresenceRule.decide's
        // own reason -- this gate never invents its own wording.
        let prompting = FakeHostScreenPresencePrompting()
        prompting.answer = .declined
        let gate = HostScreenPresenceGate(prompting: prompting)

        let outcome = gate.ask(content: testContent)

        expect(
            outcome == .refused(reason: "the connection was declined at that machine"),
            "a decline refuses with HostScreenPresenceRule.decide's own reason, unchanged"
        )

        print("PASS: HostScreenPresenceGate refuses a decline with HostScreenPresenceRule.decide's own reason")
    }

    do {
        // The prompt's own timeout -- nil, its only way to happen --
        // refuses with decide's own timeout reason, not this gate's.
        let prompting = FakeHostScreenPresencePrompting()
        prompting.answer = nil
        let gate = HostScreenPresenceGate(prompting: prompting)

        let outcome = gate.ask(content: testContent)

        expect(
            outcome == .refused(reason: "that machine is in use and the prompt was not answered"),
            "the prompt's own timeout (nil) refuses with HostScreenPresenceRule.decide's own timeout reason -- exactly as if it had genuinely run out the clock, because it did"
        )

        print("PASS: HostScreenPresenceGate treats the prompt's own nil as its timeout, refusing with decide's own timeout reason")
    }

    do {
        // Never more than one at a time: a second ask arriving
        // while the first is still inside prompting.ask refuses
        // immediately, without a second window ever being asked
        // for.
        let prompting = FakeHostScreenPresencePrompting()
        prompting.answer = .approved
        let gate = HostScreenPresenceGate(prompting: prompting)
        prompting.reentrantAsk = { gate.ask(content: testContent) }

        let outcome = gate.ask(content: testContent)

        expect(
            prompting.takeReentrantResult() == .refused(reason: HostScreenPresenceGate.alreadyAskingReason),
            "a second ask arriving while the first is still showing refuses immediately, naming that a prompt is already up"
        )
        expect(prompting.calls.count == 1, "the real prompt is shown exactly once -- the reentrant second call never reaches it")
        expect(outcome == .proceed, "the original, outermost ask still settles normally once its own prompt answers")
        expect(!gate.isPromptShowing, "once the outermost ask returns, no prompt is left showing, so a later ask is not permanently locked out")

        print("PASS: HostScreenPresenceGate refuses a second ask that arrives while the first is still showing, without ever asking a second window")
    }

    do {
        // Not permanently locked: a later ask, after an earlier one
        // has genuinely finished, proceeds normally.
        let prompting = FakeHostScreenPresencePrompting()
        prompting.answer = .approved
        let gate = HostScreenPresenceGate(prompting: prompting)
        _ = gate.ask(content: testContent)

        let second = gate.ask(content: testContent)

        expect(second == .proceed, "a second, later ask -- not concurrent with the first -- is shown its own prompt and settles normally")
        expect(prompting.calls.count == 2, "each non-overlapping ask reaches the real prompt")

        print("PASS: HostScreenPresenceGate's exclusivity only ever blocks a genuinely concurrent ask, never a later, sequential one")
    }
}
