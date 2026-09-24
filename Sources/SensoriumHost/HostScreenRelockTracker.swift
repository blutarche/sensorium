import Foundation

/// Decides whether a host-screen session's own end should relock this
/// machine: only when the machine was unlocked at the machine at some point
/// during the session after having been observed locked, so a session that
/// found the screen already unlocked -- or that leaves it locked, either
/// because it was locked the whole time or because the person at the host
/// locked it again themselves -- never relocks a screen that was not this
/// session's doing to unlock.
///
/// A machine someone is actually using must never be relocked out from under
/// them, so two further readings can each veto a relock that the lock/unlock
/// history alone would otherwise call for: hardware input at the moment the
/// screen was found freshly unlocked -- a person at the machine unlocked it
/// themselves -- and hardware input found at the decision itself -- someone
/// is there now, whatever unlocked the screen. Both readings are the
/// caller's own, already discounted against this session's own forwarded
/// input; see `SelfPostDiscountingLocalActivitySignal`.
///
/// Fed every raw lock-state reading a session takes, in whatever order they
/// arrive, and consulted once, at session end.
public struct HostScreenRelockTracker {
    private var everObservedLocked = false
    private var isLockedNow = false
    private var hasConsumedDecision = false
    /// The hardware-activity reading that came with the observation that
    /// found the screen freshly unlocked after having been locked -- `false`
    /// until that transition has actually happened. Not overwritten by any
    /// later, quieter observation: the person who unlocked the machine
    /// having since stepped away does not make their own unlock any less
    /// theirs.
    private var hardwareActivityAtUnlockTransition = false

    public init() {}

    /// Records one reading of `ScreenLockStateReading.isScreenLocked()`,
    /// paired with whether hardware input looked recent at the same moment.
    public mutating func observe(isLocked: Bool, hardwareActivityNearby: Bool) {
        if isLockedNow, !isLocked {
            hardwareActivityAtUnlockTransition = hardwareActivityNearby
        }
        if isLocked {
            everObservedLocked = true
        }
        isLockedNow = isLocked
    }

    /// Whether this session should relock the machine now, given every
    /// reading `observe(isLocked:hardwareActivityNearby:)` has seen so far
    /// and one more, freshest hardware-activity reading taken at the
    /// decision itself. Answers `true` at most once: every call after the
    /// first, on this same instance, answers `false`, so a session end
    /// reached from more than one place -- a normal end and a host quit
    /// tearing down the same session -- never relocks twice.
    public mutating func consumeShouldRelock(hardwareActivityNearby: Bool) -> Bool {
        defer { hasConsumedDecision = true }
        guard !hasConsumedDecision else {
            return false
        }
        guard everObservedLocked, !isLockedNow else {
            return false
        }
        return !hardwareActivityAtUnlockTransition && !hardwareActivityNearby
    }
}
