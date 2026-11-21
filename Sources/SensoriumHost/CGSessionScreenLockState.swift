#if os(macOS)
import CoreGraphics
import Foundation

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
#endif
