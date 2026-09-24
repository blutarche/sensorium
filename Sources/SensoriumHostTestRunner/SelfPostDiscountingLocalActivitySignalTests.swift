import Foundation
import SensoriumHost

/// `SelfPostDiscountingLocalActivitySignal` discounts a raw idle reading
/// against this host's own last post to `.cghidEventTap`, so that forwarded
/// input never reads as evidence of a person at the machine.
func runSelfPostDiscountingLocalActivitySignalTests() {
    do {
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(10)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: nil)
        )
        expect(
            signal.currentReading() == .idleFor(10),
            "a recent idle time with no host-injected post recorded is trusted as real"
        )
        print("PASS: a recent idle reading with nothing ever posted at the hid tap is trusted")
    }

    do {
        // The idle reading is fully explained by this host's own post,
        // moments ago -- the self-defeating case this type exists to
        // avoid: without discounting, a viewer typing through the locked
        // screen would always look like local activity, and neither the
        // presence gate nor a relock would ever treat this host as
        // unattended again.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(0.2)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 0.2)
        )
        expect(
            signal.currentReading() == .idleFor(.infinity),
            "an idle reading explained by this host's own last post reads as no evidence of genuine activity"
        )
        print("PASS: an idle reading explained by this host's own post is discounted")
    }

    do {
        // Real hardware activity strictly newer than this host's own last
        // post: idle time is measurably smaller than the time since that
        // post, so it cannot be explained by the post alone.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(0.1)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 5)
        )
        expect(
            signal.currentReading() == .idleFor(0.1),
            "an idle reading newer than this host's own last post is trusted as genuine local activity"
        )
        print("PASS: an idle reading newer than this host's own last post is trusted")
    }

    do {
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .unavailable),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 0.1)
        )
        expect(
            signal.currentReading() == .unavailable,
            "an unavailable raw reading passes through unchanged: there is no idle time to discount"
        )
        print("PASS: an unavailable raw reading is left alone")
    }

    do {
        // Repeated self-posting, as a continuous stream of forwarded
        // keystrokes would produce: every reading stays fully explained by
        // the host's own most recent post, never reading as a real person.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(0)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 0)
        )
        expect(
            signal.currentReading() == .idleFor(.infinity),
            "our own hid-tap typing alone, with nothing genuinely newer, never counts as local"
        )
        print("PASS: continuous self-posting alone never counts as local activity")
    }

    do {
        // A real key was proven by a pre-post sample before our own later
        // post masked it from the raw reading -- exactly the masking gap
        // pre-post sampling exists to close. The raw reading is fully
        // explained by our post; the proven sample is what survives.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(0)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 0, secondsSinceProvenHardwareActivity: 30)
        )
        expect(
            signal.currentReading() == .idleFor(30),
            "local input a pre-post sample proved, then only our own post since, still counts as local"
        )
        print("PASS: local input proven by a pre-post sample survives a later post of our own")
    }

    do {
        // Our own posts only, ever: no pre-post sample has ever proven
        // genuine hardware activity, so there is nothing to fall back to.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(0)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 0, secondsSinceProvenHardwareActivity: nil)
        )
        expect(
            signal.currentReading() == .idleFor(.infinity),
            "with no pre-post sample ever proving genuine activity, our posts alone still never count as local"
        )
        print("PASS: our own posts only, with nothing ever proven, never count as local")
    }

    do {
        // Genuine activity newer than what the proven sample caught: the
        // fresher of the two wins.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .idleFor(2)),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: 500, secondsSinceProvenHardwareActivity: 30)
        )
        expect(
            signal.currentReading() == .idleFor(2),
            "the more recent of the discounted raw reading and the proven sample wins"
        )
        print("PASS: the fresher of the raw and proven readings wins")
    }

    do {
        // An unavailable raw reading with a proven sample on record: the
        // broken sensor is reported as broken, not papered over with a
        // stale proven time that could only make it read as more absent.
        let signal = SelfPostDiscountingLocalActivitySignal(
            raw: FakeRawLocalActivitySignal(reading: .unavailable),
            ownActivity: FakeHostInjectedHIDActivity(secondsSinceLastPost: nil, secondsSinceProvenHardwareActivity: 45)
        )
        expect(
            signal.currentReading() == .unavailable,
            "an unavailable raw reading stays unavailable, even with a proven sample on record"
        )
        print("PASS: an unavailable raw reading is never replaced by a proven sample")
    }
}

private final class FakeRawLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    private let reading: HostLocalActivityReading
    init(reading: HostLocalActivityReading) { self.reading = reading }
    func currentReading() -> HostLocalActivityReading { reading }
}

private final class FakeHostInjectedHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    private let seconds: TimeInterval?
    private let provenSeconds: TimeInterval?
    init(secondsSinceLastPost seconds: TimeInterval?, secondsSinceProvenHardwareActivity provenSeconds: TimeInterval? = nil) {
        self.seconds = seconds
        self.provenSeconds = provenSeconds
    }
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { seconds }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { provenSeconds }
}
