import SensoriumHost

/// `HostScreenRelockTracker` decides, from every lock-state reading a
/// host-screen session took, whether ending that session should relock the
/// machine -- see the type's own doc comment for the rule. Every call below
/// passes `hardwareActivityNearby: false` unless a scenario is specifically
/// about that veto: it stands in for `HostScreenPresenceRule.assess` run
/// against `SelfPostDiscountingLocalActivitySignal`'s own reading, computed
/// by `HostSessionCoordinator.hardwareActivityNearby()`.
func runHostScreenRelockTrackerTests() {
    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(!tracker.consumeShouldRelock(hardwareActivityNearby: false), "a screen never seen locked is never relocked")
        print("PASS: a session that never saw the screen locked does not relock it")
    }

    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "locked then unlocked during the session relocks it at session end"
        )
        print("PASS: a screen locked and then unlocked during the session is relocked")
    }

    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        expect(
            !tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "a screen locked for the whole session is already locked; nothing to redo"
        )
        print("PASS: a screen locked for the whole session is not relocked")
    }

    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "unlocked, locked, then unlocked again still ends unlocked and relocks"
        )
        print("PASS: a screen that cycles unlocked-locked-unlocked is relocked")
    }

    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        expect(
            !tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "locked, unlocked, then locked again by the person at the host is already locked; nothing to redo"
        )
        print("PASS: a screen the person at the host locked again themselves is not relocked")
    }

    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "first read of a locked-then-unlocked session answers true"
        )
        expect(
            !tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "a second read on the same instance never relocks a second time"
        )
        print("PASS: consumeShouldRelock answers true at most once per tracker")
    }

    // A person at the machine unlocked it themselves: hardware activity was
    // seen at the very moment the transition from locked to unlocked was
    // observed. No later, quieter reading un-sticks that veto.
    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: true)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            !tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "hardware activity at the unlock transition means a person unlocked it, never a remote unlock to relock over"
        )
        print("PASS: a screen a person at the machine unlocked is not relocked")
    }

    // A remote unlock, but the person at the machine sat down and used it
    // before the session ended: caught by the final, fresh reading rather
    // than the transition itself.
    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            !tracker.consumeShouldRelock(hardwareActivityNearby: true),
            "hardware activity found at session end means someone is there now, whatever unlocked the screen"
        )
        print("PASS: a screen someone is using right now is not relocked")
    }

    // A remote unlock and nobody ever at the machine: the case relock
    // exists for.
    do {
        var tracker = HostScreenRelockTracker()
        tracker.observe(isLocked: true, hardwareActivityNearby: false)
        tracker.observe(isLocked: false, hardwareActivityNearby: false)
        expect(
            tracker.consumeShouldRelock(hardwareActivityNearby: false),
            "a remote unlock with no hardware activity anywhere still relocks"
        )
        print("PASS: a remotely unlocked screen with nobody at the machine is relocked")
    }
}
