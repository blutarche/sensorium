import Foundation
import SensoriumHost

private struct FakeLockAtStartLockState: ScreenLockStateReading {
    let locked: Bool
    func isScreenLocked() -> Bool { locked }
}

private final class FakeLockAtStartActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    let reading: HostLocalActivityReading
    init(reading: HostLocalActivityReading) { self.reading = reading }
    func currentReading() -> HostLocalActivityReading { reading }
}

private final class RecordingLockAtStartPoster: HostScreenRelocking, @unchecked Sendable {
    private(set) var relockCount = 0
    var succeeds = true
    func relock() -> Bool {
        relockCount += 1
        return succeeds
    }
}

/// `HostAutoLoginLockAtStart.shouldLock` decides whether a launch that found
/// the screen unlocked should lock it again, in case auto-login brought the
/// machine up with nobody there.
func runHostAutoLoginLockAtStartTests() {
    expect(
        HostAutoLoginLockAtStart.shouldLock(isScreenLocked: false, reading: .idleFor(19), systemUptime: 20),
        "idle time reaching back to within a second of boot, at a fresh uptime, reads as auto-login and locks"
    )
    print("PASS: idle time reaching back to boot locks a freshly-booted, unlocked screen")

    expect(
        !HostAutoLoginLockAtStart.shouldLock(isScreenLocked: false, reading: .idleFor(3), systemUptime: 3600),
        "fresh local input, as a person who just signed in themselves would leave, never locks"
    )
    print("PASS: an unlocked screen with fresh local input does not lock at start")

    expect(
        !HostAutoLoginLockAtStart.shouldLock(isScreenLocked: true, reading: .idleFor(1000), systemUptime: 1000),
        "an already-locked screen has nothing to do"
    )
    print("PASS: an already-locked screen is left alone at start")

    expect(
        !HostAutoLoginLockAtStart.shouldLock(isScreenLocked: false, reading: .idleFor(600), systemUptime: 259_200),
        "a plain relaunch or update three days after boot, with ten minutes of idle time, is not auto-login and must not lock"
    )
    print("PASS: a relaunch long after boot with ordinary idle time does not lock at start")

    expect(
        !HostAutoLoginLockAtStart.shouldLock(isScreenLocked: false, reading: .unavailable, systemUptime: 20),
        "an unreadable activity reading never locks: locking a person out mid-login is the costly direction"
    )
    print("PASS: an unreadable activity reading does not lock at start")

    do {
        let poster = RecordingLockAtStartPoster()
        let outcome = HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: FakeLockAtStartLockState(locked: false),
            activitySignal: FakeLockAtStartActivitySignal(reading: .idleFor(19)),
            systemUptime: 20,
            relockPoster: poster
        )
        expect(outcome == .locked, "an unlocked screen idle back to boot posts the relock shortcut")
        expect(poster.relockCount == 1, "and posts it exactly once")
        print("PASS: applyIfNeeded posts the relock shortcut for an auto-login launch")
    }

    do {
        let poster = RecordingLockAtStartPoster()
        let outcome = HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: FakeLockAtStartLockState(locked: false),
            activitySignal: FakeLockAtStartActivitySignal(reading: .idleFor(3)),
            systemUptime: 3600,
            relockPoster: poster
        )
        expect(outcome == .notNeeded, "an unlocked screen with fresh local input does not post the relock shortcut")
        expect(poster.relockCount == 0, "and never posts it")
        print("PASS: applyIfNeeded leaves a freshly-used, unlocked screen alone")
    }

    do {
        // The relock shortcut itself could not be posted: the caller must be
        // able to tell this apart from "nothing needed doing" so it logs the
        // failure rather than silently claiming a lock that never happened.
        let poster = RecordingLockAtStartPoster()
        poster.succeeds = false
        let outcome = HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: FakeLockAtStartLockState(locked: false),
            activitySignal: FakeLockAtStartActivitySignal(reading: .idleFor(19)),
            systemUptime: 20,
            relockPoster: poster
        )
        expect(outcome == .lockFailed, "a relock shortcut that could not post is reported as a failed lock, not a silent success")
        print("PASS: applyIfNeeded reports a failed relock post distinctly from nothing needing to be done")
    }
}
