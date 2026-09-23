import Foundation
import SensoriumHost

/// `MutableHostInjectedHIDActivity.sampleBeforePost` is the real
/// pre-post-sampling logic `SelfPostDiscountingLocalActivitySignal`'s own
/// tests only ever exercise through a canned fake. These drive the real
/// class, with a scripted clock and raw signal in place of real time and
/// real `hidSystemState`, so a mutation to the sampling logic itself is
/// caught.
func runMutableHostInjectedHIDActivityTests() {
    do {
        // Local input at t=98, then our own post at t=100 (sampling first,
        // as the real call sites do), decided at t=150: still within
        // `HostScreenPresenceRule.recommendedPresenceThreshold` of the real
        // input, so it must still count as local, not be masked by the post
        // that came after it.
        let clock = ScriptedClock(time: 50)
        let rawSignal = ScriptedLocalActivitySignal(reading: .idleFor(1000))
        let activity = MutableHostInjectedHIDActivity(rawActivity: rawSignal, now: clock.now)

        // An earlier post of our own, to exercise the "explained by our own
        // previous post" skip guard, not only the no-previous-post path.
        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 98
        rawSignal.reading = .idleFor(0) // the person's real input, right now

        clock.time = 100
        rawSignal.reading = .idleFor(2) // sampled just before our post: proves t=98
        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 150
        expect(
            activity.secondsSinceProvenHardwareActivity() == 52,
            "local input proven by a pre-post sample at t=98, decided at t=150, reads as 52 seconds idle, not masked by our t=100 post"
        )
        print("PASS: local input proven by a pre-post sample survives a later post of our own")
    }

    do {
        // Only this host's own posts, ever: no real hardware activity
        // anywhere in the script.
        let clock = ScriptedClock(time: 1000)
        let rawSignal = ScriptedLocalActivitySignal(reading: .idleFor(900))
        let activity = MutableHostInjectedHIDActivity(rawActivity: rawSignal, now: clock.now)

        // First post: nothing before it to compare against, so its raw idle
        // time is recorded as (falsely) proven -- genuinely old, so it never
        // reads as recent regardless.
        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 1005
        rawSignal.reading = .idleFor(5) // reflects only our own post five seconds ago
        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 1010
        expect(
            activity.secondsSinceProvenHardwareActivity()! > HostScreenPresenceRule.recommendedPresenceThreshold,
            "with nothing but this host's own posts, the proven reading never reads as recent"
        )
        print("PASS: this host's own posts only never read as recent local activity")
    }

    do {
        // Locked typing alone, with no real person ever in the script, read
        // through `HostScreenPresenceRule.assess` via
        // `SelfPostDiscountingLocalActivitySignal`, the way
        // `HostSessionController`'s presence gate actually reads it: it
        // must not force asking first over evidence that is only our own.
        let clock = ScriptedClock(time: 1000)
        let rawSignal = ScriptedLocalActivitySignal(reading: .idleFor(900))
        let activity = MutableHostInjectedHIDActivity(rawActivity: rawSignal, now: clock.now)
        let signal = SelfPostDiscountingLocalActivitySignal(raw: rawSignal, ownActivity: activity)

        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 1002
        rawSignal.reading = .idleFor(2) // reflects only our own post, two seconds ago
        activity.sampleBeforePost()
        activity.recordPost()

        clock.time = 1004
        rawSignal.reading = .idleFor(2) // still only our own post
        expect(
            HostScreenPresenceRule.assess(
                reading: signal.currentReading(),
                presenceThreshold: HostScreenPresenceRule.recommendedPresenceThreshold
            ) == .mayProceed,
            "locked typing alone, with nothing genuinely newer, does not force asking first"
        )
        print("PASS: HostScreenPresenceRule reads locked typing alone as no reason to ask first")
    }
}

private final class ScriptedClock: @unchecked Sendable {
    var time: TimeInterval
    init(time: TimeInterval) { self.time = time }
    func now() -> TimeInterval { time }
}

private final class ScriptedLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading
    init(reading: HostLocalActivityReading) { self.reading = reading }
    func currentReading() -> HostLocalActivityReading { reading }
}
