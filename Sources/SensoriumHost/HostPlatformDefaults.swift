import Foundation
import SensoriumCore

/// What a host uses for the pieces that have a platform implementation when a
/// caller supplies none.
///
/// On macOS each is the system's own. Elsewhere none exists here, so each
/// stands in with an answer that refuses or does nothing rather than one that
/// lets a session carry on: a host target for another platform has to inject
/// the real thing.
public enum HostPlatformDefaults {
    /// `nil` where the platform has no lock-state reader of its own. A host
    /// with no reader offers no host screen at all: whether the screen is
    /// locked decides what input may do and what the viewer is shown, and
    /// guessing "unlocked" is not an answer to give.
    public static let screenLockState: (any ScreenLockStateReading)? = {
        #if os(macOS)
        CGSessionScreenLockState()
        #else
        nil
        #endif
    }()
}

#if os(macOS)
public typealias PlatformLockScreenUnlocker = RFBLockScreenUnlocker
public typealias PlatformScreenRelocker = CoreGraphicsHostScreenRelockPoster
public typealias PlatformSharpScreenModeSetter = CoreGraphicsSharpScreenModeSetter
#else
// Where the platform offers no route, each stands in with an answer that
// refuses or does nothing.
public typealias PlatformLockScreenUnlocker = UnavailableLockScreenUnlocker
public typealias PlatformScreenRelocker = UnavailableScreenRelocker
public typealias PlatformSharpScreenModeSetter = UnavailableSharpScreenModeSetter

/// Where no unlock route exists, the answer is that nothing was typed.
public struct UnavailableLockScreenUnlocker: LockScreenUnlocking {
    public init() {}

    public func unlock(password: Data) async -> HostScreenUnlockOutcome {
        .screenSharingUnavailable
    }
}

/// Where no relock route exists, nothing is posted and `relock()` says so.
public struct UnavailableScreenRelocker: HostScreenRelocking {
    public init() {}
    public func relock() -> Bool { false }
}

@MainActor
public final class UnavailableSharpScreenModeSetter: SharpScreenModeSetting {
    public init() {}
    public func modes(for displayID: UInt32) -> [SharpScreenMode] { [] }
    public func set(modeID: Int, on displayID: UInt32) -> Bool { false }
}
#endif
