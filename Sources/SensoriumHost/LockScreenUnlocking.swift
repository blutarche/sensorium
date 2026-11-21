import Foundation
import SensoriumCore

/// Types a viewer-supplied login password into this machine's locked login
/// window, where the platform offers a route for that. The password is used
/// for one unlock and is never written to disk and never logged.
public protocol LockScreenUnlocking: Sendable {
    func unlock(password: Data) async -> HostScreenUnlockOutcome
}
