import Foundation

/// Decides whether the host should post its own relock shortcut right after
/// launch, when auto-login could have brought this machine up unlocked with
/// nobody there to notice.
///
/// Pure by design: it takes an already-computed lock state and activity
/// reading rather than polling anything itself, so a launch sequence can call
/// it once it has both in hand.
public enum HostAutoLoginLockAtStart {
    /// `true` means post the relock shortcut now.
    ///
    /// An already-locked screen has nothing to do. An unavailable or
    /// unreadable activity reading never locks: the harm of locking a person
    /// out mid-login is worse than the harm of occasionally leaving an
    /// auto-logged-in, unattended screen unlocked a little longer.
    ///
    /// The one sign of auto-login this locks on: idle time reaching all the
    /// way back to system startup, within
    /// `SelfPostDiscountingLocalActivitySignal.discountTolerance` -- nothing
    /// has touched `hidSystemState` since boot at all, which only an
    /// unattended auto-login leaves behind. A plain relaunch or update of
    /// the host on a machine someone is already using shows idle time far
    /// short of uptime instead, and must not lock. Whether the idle
    /// counter is in fact reported relative to boot, rather than some other
    /// origin, is unconfirmed pending a real-host test.
    public static func shouldLock(isScreenLocked: Bool, reading: HostLocalActivityReading, systemUptime: TimeInterval) -> Bool {
        guard !isScreenLocked else { return false }
        guard case let .idleFor(idleSeconds) = reading else { return false }
        return idleSeconds >= systemUptime - SelfPostDiscountingLocalActivitySignal.discountTolerance
    }

    /// What `applyIfNeeded` decided and, when it tried to lock, whether the
    /// relock shortcut actually posted.
    public enum Outcome: Equatable, Sendable {
        /// `shouldLock` found no reason to lock: either the screen was
        /// already locked, or the activity reading did not read as
        /// auto-login.
        case notNeeded
        /// `shouldLock` said to lock, and the relock shortcut posted.
        case locked
        /// `shouldLock` said to lock, but `relockPoster.relock()` reported
        /// it could not post the shortcut.
        case lockFailed
    }

    /// Reads the current lock state and activity, decides through
    /// `shouldLock`, and posts `relockPoster.relock()` if so. Returns the
    /// outcome, so a caller can log it. Meant to run once, at the GUI app's
    /// own launch -- never on the CLI verb path, which has no auto-login to
    /// guard against.
    @discardableResult
    public static func applyIfNeeded(
        lockStateReader: any ScreenLockStateReading,
        activitySignal: any HostLocalActivitySignal,
        systemUptime: TimeInterval,
        relockPoster: any HostScreenRelocking
    ) -> Outcome {
        guard shouldLock(
            isScreenLocked: lockStateReader.isScreenLocked(),
            reading: activitySignal.currentReading(),
            systemUptime: systemUptime
        ) else {
            return .notNeeded
        }
        return relockPoster.relock() ? .locked : .lockFailed
    }
}
