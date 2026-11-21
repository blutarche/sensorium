import Foundation
import SensoriumHost

struct FakeScreenLockState: ScreenLockStateReading {
    let locked: Bool
    func isScreenLocked() -> Bool { locked }
}

/// A lock reader that starts locked and reports unlocked once flipped, so a
/// success path that types and then re-checks can be driven deterministically.
final class FlippableLockState: ScreenLockStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private var locked: Bool
    init(locked: Bool) { self.locked = locked }
    func setLocked(_ value: Bool) { lock.lock(); locked = value; lock.unlock() }
    func isScreenLocked() -> Bool { lock.lock(); defer { lock.unlock() }; return locked }
}
