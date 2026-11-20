import Foundation

/// Reads whether this machine's screen is locked right now. Behind a protocol so
/// the unlock flow can be driven without a real lock: a locked screen is not
/// something a unit test can produce, and the decision of whether an unlock is
/// even needed must still be verifiable.
public protocol ScreenLockStateReading: Sendable {
    /// `true` while the login window is up, `false` otherwise. A reader that
    /// cannot tell answers `false`: the unlock flow treats "not known to be
    /// locked" as "nothing to unlock" rather than typing a password into a
    /// screen that may already be in use.
    func isScreenLocked() -> Bool
}
