#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumLinuxHost

/// A clock a test moves by hand.
private final class HandClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 5_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private final class Answers: @unchecked Sendable {
    var all: [AskFirstOutcome] = []
}

private func makePrompt(
    _ clock: HandClock, _ answers: Answers, device: String = "Kestrel Laptop", display: String = "Built-in Display"
) -> AskFirstPromptModel {
    AskFirstPromptModel(
        content: AskFirstPromptContent(deviceName: device, displayLabel: display),
        now: { clock.date },
        onOutcome: { answers.all.append($0) }
    )
}

/// The ask-first prompt: its words, its countdown, and that it times out to
/// Don't Allow the way the macOS prompt does.
@MainActor
enum AskFirstPromptTests {
    static let all: [(String, () async -> Void)] = [
        ("the prompt names the device and the display in the macOS prompt's words", testPromptWords),
        ("the countdown reads m:ss and falls with the clock", testCountdownFallsWithTheClock),
        ("the prompt times out to a refusal after the shared timeout, never before", testTimeoutRefuses),
        ("an answer at exactly the limit still counts, one after it does not", testTheLimitItselfIsStillOpen),
        ("the first answer wins and the outcome is reported once", testTheFirstAnswerWins),
        ("the default timeout is the one the viewer's own wait is sized against", testDefaultTimeoutIsTheSharedOne)
    ]

    static func testPromptWords() async {
        let prompt = makePrompt(HandClock(), Answers())
        expect(prompt.windowTitle == "Allow Seeing and Controlling This Screen?", "the window title")
        expect(prompt.eyebrow == "Sensorium Host \u{00B7} Host Screen Request", "the eyebrow names the app and the request")
        expect(
            prompt.headline == "Kestrel Laptop wants to see and control a display of this machine.",
            "the headline names the device"
        )
        expect(
            prompt.subtitle == "If you allow, Kestrel Laptop sees and controls Built-in Display until you click Stop on the "
                + "badge that stays on screen, or it disconnects. You\u{2019}re asked because this machine was used in the "
                + "last few minutes.",
            "the subtitle names the device and the display and says why it asks, got \(prompt.subtitle)"
        )
        expect(prompt.allowTitle == "Allow", "the allow button")
        expect(prompt.denyTitle == "Don\u{2019}t Allow", "the refusing button is Don't Allow, the default")
    }

    static func testCountdownFallsWithTheClock() async {
        let clock = HandClock()
        let prompt = makePrompt(clock, Answers())
        expect(prompt.countdownLine == "Don\u{2019}t Allow will be chosen automatically in 0:30.", "starts at the full timeout")
        clock.advance(12)
        expect(prompt.countdownLine == "Don\u{2019}t Allow will be chosen automatically in 0:18.", "falls by the seconds that passed")
        clock.advance(17.6)
        expect(prompt.countdownLine == "Don\u{2019}t Allow will be chosen automatically in 0:00.", "a fraction under half a second rounds to zero")
        clock.advance(60)
        expect(prompt.countdownLine == "Don\u{2019}t Allow will be chosen automatically in 0:00.", "never reads a negative time")
    }

    static func testTimeoutRefuses() async {
        let clock = HandClock()
        let answers = Answers()
        let prompt = makePrompt(clock, answers)
        clock.advance(29)
        prompt.tick()
        expect(answers.all.isEmpty && prompt.outcome == nil, "still waiting inside the window")
        clock.advance(2)
        prompt.tick()
        expect(answers.all == [.timedOut], "an unanswered prompt resolves to a timeout, which refuses")
        expect(prompt.outcome == .timedOut && prompt.outcome?.allows == false, "a timeout never allows")
    }

    static func testTheLimitItselfIsStillOpen() async {
        let clock = HandClock()
        let answers = Answers()
        let prompt = makePrompt(clock, answers)
        clock.advance(30)
        prompt.tick()
        expect(answers.all.isEmpty, "exactly at the limit the prompt is still open")
        prompt.allow()
        expect(answers.all == [.allowed], "an Allow at exactly the limit counts")

        let lateClock = HandClock()
        let lateAnswers = Answers()
        let late = makePrompt(lateClock, lateAnswers)
        lateClock.advance(30.5)
        late.allow()
        expect(lateAnswers.all == [.timedOut], "an Allow that arrives after the window closed does not reopen it")
    }

    static func testTheFirstAnswerWins() async {
        let clock = HandClock()
        let answers = Answers()
        let prompt = makePrompt(clock, answers)
        prompt.deny()
        prompt.allow()
        clock.advance(100)
        prompt.tick()
        expect(answers.all == [.denied], "Don't Allow, then anything else, is one refusal")
        expect(prompt.outcome?.allows == false, "a refusal does not allow")

        let allowedAnswers = Answers()
        let allowed = makePrompt(HandClock(), allowedAnswers)
        allowed.allow()
        allowed.deny()
        expect(allowedAnswers.all == [.allowed] && allowed.outcome?.allows == true, "Allow first stays Allow")
    }

    static func testDefaultTimeoutIsTheSharedOne() async {
        expect(AskFirstPromptModel.defaultTimeout == SessionTimeouts.hostScreenPresencePromptTimeout, "no number of its own")
    }
}
#endif
