import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Runs both of `HostScreenPresenceRule`'s entry points in sequence, the
/// way a real caller would: ask whether a prompt is even needed, and only
/// if it is, resolve the prompt's outcome. `nil` means "still waiting", the
/// same meaning `HostScreenPresenceRule.decide` itself gives it.
private func evaluatePresence(
    reading: HostLocalActivityReading,
    presenceThreshold: TimeInterval,
    answer: HostScreenPresenceRule.Answer?,
    elapsedSinceAsked: TimeInterval
) -> HostScreenPresenceOutcome? {
    switch HostScreenPresenceRule.assess(reading: reading, presenceThreshold: presenceThreshold) {
    case .mayProceed:
        return .proceed
    case .mustAsk:
        return HostScreenPresenceRule.decide(answer: answer, elapsedSinceAsked: elapsedSinceAsked)
    }
}

@MainActor
func runHostScreenPresenceRuleTests() async {
    let threshold = HostScreenPresenceRule.recommendedPresenceThreshold
    let timeout = HostScreenPresenceRule.promptTimeout

    do {
        // assess: absent proceeds, present asks
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(threshold + 1), presenceThreshold: threshold) == .mayProceed,
            "idle well past the threshold may proceed with no prompt -- the case the feature exists for"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(threshold), presenceThreshold: threshold) == .mustAsk,
            "idle for exactly the threshold, not past it, still must ask -- the boundary favours asking, not skipping the ask"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(threshold - 1), presenceThreshold: threshold) == .mustAsk,
            "idle short of the threshold must ask"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(0), presenceThreshold: threshold) == .mustAsk,
            "no idle time at all must ask"
        )

        // Unknown is not absent, regardless of how generous the threshold is.
        expect(
            HostScreenPresenceRule.assess(reading: .unavailable, presenceThreshold: threshold) == .mustAsk,
            "an idle reading that could not be taken must ask, the same as someone actually being there"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .unavailable, presenceThreshold: 0) == .mustAsk,
            "unavailable must ask even against a threshold of zero, which every real idle reading would clear -- a broken sensor is never treated as absence, at any threshold"
        )

        print("PASS: HostScreenPresenceRule.assess proceeds only once idle time genuinely exceeds the threshold, and treats an unreadable signal as presence, never absence")
    }

    do {
        // decide: an answer settles it, silence only denies once the
        // timeout has actually elapsed
        expect(
            HostScreenPresenceRule.decide(answer: .approved, elapsedSinceAsked: 0) == .proceed,
            "an approval answered immediately proceeds"
        )
        expect(
            HostScreenPresenceRule.decide(answer: .approved, elapsedSinceAsked: timeout) == .proceed,
            "an approval that arrives at exactly the timeout still counts -- the boundary favours the person, matching StreamScalePolicy.isWorthReconfiguring's own boundary"
        )
        expect(
            HostScreenPresenceRule.decide(answer: .approved, elapsedSinceAsked: timeout + 1) == .refused(reason: "that machine is in use and the prompt was not answered"),
            "an approval that arrives after the window already closed does not reopen it -- the elapsed check wins over the answer"
        )
        expect(
            HostScreenPresenceRule.decide(answer: .declined, elapsedSinceAsked: 0) == .refused(reason: "the connection was declined at that machine"),
            "a decline refuses immediately, with its own reason distinct from a timeout's"
        )
        expect(
            HostScreenPresenceRule.decide(answer: nil, elapsedSinceAsked: 0) == nil,
            "no answer yet, well within the window, is not a decision at all"
        )
        expect(
            HostScreenPresenceRule.decide(answer: nil, elapsedSinceAsked: timeout) == nil,
            "no answer at exactly the timeout is still within it, not yet expired"
        )
        expect(
            HostScreenPresenceRule.decide(answer: nil, elapsedSinceAsked: timeout + 1) == .refused(reason: "that machine is in use and the prompt was not answered"),
            "no answer once the timeout has actually elapsed denies, with the exact wording design §6.2 names for the viewer"
        )

        print("PASS: HostScreenPresenceRule.decide lets a timely answer settle it, refuses a decline immediately, and refuses silence only once the timeout has genuinely elapsed")
    }

    do {
        // The property that matters: refusal, never degradation.
        // Every representative point across both dimensions -- assessed
        // presence and the prompt's outcome -- lands in exactly one of
        // HostScreenPresenceOutcome's two cases. Nothing here can leave a
        // session partially admitted, video-off, or view-only: the type
        // returned has no case for that, and this sweeps enough of the
        // input space to show the rule never manufactures a third one.
        let readings: [HostLocalActivityReading] = [
            .idleFor(-1), .idleFor(0), .idleFor(threshold - 1), .idleFor(threshold),
            .idleFor(threshold + 1), .idleFor(threshold * 100), .unavailable
        ]
        let answers: [HostScreenPresenceRule.Answer?] = [nil, .approved, .declined]
        let elapsedValues: [TimeInterval] = [0, timeout / 2, timeout, timeout + 1, timeout * 100]

        var outcomesSeen = Set<String>()
        var stillWaitingCount = 0
        for reading in readings {
            for answer in answers {
                for elapsed in elapsedValues {
                    switch evaluatePresence(
                        reading: reading, presenceThreshold: threshold, answer: answer, elapsedSinceAsked: elapsed
                    ) {
                    case .proceed:
                        outcomesSeen.insert("proceed")
                    case let .refused(reason):
                        outcomesSeen.insert("refused:\(reason)")
                    case nil:
                        stillWaitingCount += 1
                    }
                }
            }
        }
        expect(
            outcomesSeen.isSubset(of: [
                "proceed",
                "refused:that machine is in use and the prompt was not answered",
                "refused:the connection was declined at that machine"
            ]),
            "across every reading, answer, and elapsed time swept, the only outcomes ever produced are proceed or one of the two named refusals -- nothing else"
        )
        expect(stillWaitingCount > 0, "the sweep includes at least one still-waiting case, so nil is exercised too, not just the two decided outcomes")

        print("PASS: across the whole swept input space, the presence rule only proceeds, refuses by name, or waits, never reduces")
    }

    do {
        // countdownLabel: the pure remaining-seconds -> label mapping
        // the presence prompt's own live countdown line is built from.
        expect(
            HostScreenPresenceRule.countdownLabel(remainingSeconds: 30) == "Don\u{2019}t Allow will be chosen automatically in 0:30.",
            "thirty seconds remaining reads as the design's own thirty-second window, at its start"
        )
        expect(
            HostScreenPresenceRule.countdownLabel(remainingSeconds: 0) == "Don\u{2019}t Allow will be chosen automatically in 0:00.",
            "no time remaining reads as 0:00, exactly when the prompt refuses on its own"
        )
        expect(
            HostScreenPresenceRule.countdownLabel(remainingSeconds: -5) == "Don\u{2019}t Allow will be chosen automatically in 0:00.",
            "a negative remaining duration -- the tick that lands after the deadline already passed -- still reads 0:00, never a negative or nonsense value"
        )
        expect(
            HostScreenPresenceRule.countdownLabel(remainingSeconds: 65) == "Don\u{2019}t Allow will be chosen automatically in 1:05.",
            "the format is minutes:seconds, seconds zero-padded, the same shape HostOperatorPresentation's own pairing countdown uses"
        )

        print("PASS: HostScreenPresenceRule.countdownLabel maps remaining seconds to the prompt's own live countdown line")
    }

    do {
        // The per-machine "ask me first" flag: false always proceeds,
        // even with somebody right there; true defers entirely to
        // the idle-time rule above, unchanged.
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(0), presenceThreshold: threshold, asksWhenInUse: false) == .mayProceed,
            "flag false and recent activity still proceeds without asking -- arming the machine is itself the consent"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(0), presenceThreshold: threshold, asksWhenInUse: true) == .mustAsk,
            "flag true and recent activity must ask, the same as the rule always has"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .idleFor(threshold + 1), presenceThreshold: threshold, asksWhenInUse: true) == .mayProceed,
            "flag true and idle time past the threshold may proceed, unaffected by the flag being on"
        )
        expect(
            HostScreenPresenceRule.assess(reading: .unavailable, presenceThreshold: threshold, asksWhenInUse: false) == .mayProceed,
            "flag false proceeds even when the idle signal itself could not be read"
        )

        print("PASS: HostScreenPresenceRule.assess's ask-first overload proceeds unconditionally when the flag is off, and defers to the idle-time rule unchanged when it is on")
    }
}
