import CoreGraphics
import Foundation

/// Reads whether this Mac's screen is locked right now. Behind a protocol so
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

/// The real reader, over the public CoreGraphics session dictionary. macOS
/// publishes the lock state there under `CGSSessionScreenIsLocked`; an absent
/// or false value is a screen that is not locked.
public struct CGSessionScreenLockState: ScreenLockStateReading {
    public init() {}

    public func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
