#if os(Linux)

import Foundation

/// How long it has been since someone used this machine, or that this could
/// not be told. A reading that failed must stay distinguishable from a long
/// idle time: the two call for opposite outcomes.
public enum ScreenSaverIdleReading: Equatable, Sendable {
    case idleFor(TimeInterval)
    case unavailable
}

/// The lock state, relock and idle time of this desktop session, read from
/// `org.freedesktop.ScreenSaver` on the session bus.
///
/// The three methods have the shapes of the host's lock-state reader, local
/// activity signal and relock poster, so adapting them is a one-line
/// conformance each. All of them are synchronous, with a time limit, because
/// their callers are.
public struct ScreenSaverClient: Sendable {
    private static let service = "org.freedesktop.ScreenSaver"
    private static let objectPath = "/org/freedesktop/ScreenSaver"

    private let bus: any DBusConnecting
    private let timeout: TimeInterval

    public init(bus: any DBusConnecting, timeout: TimeInterval = 1) {
        self.bus = bus
        self.timeout = timeout
    }

    private func call(_ method: String) throws -> DBusReply {
        try bus.callSynchronously(
            DBusCall(destination: Self.service, path: Self.objectPath, interface: Self.service, method: method),
            timeout: timeout
        )
    }

    /// Whether the screen is locked. A read that cannot be made answers
    /// false: "not known to be locked" is treated as nothing to unlock,
    /// rather than typing into a screen that may be in use.
    public func isScreenLocked() -> Bool {
        guard let reply = try? call("GetActive"), case let .bool(active)? = reply.body.first else {
            return false
        }
        return active
    }

    /// Time since the last local input. `GetSessionIdleTime` answers in
    /// milliseconds (KDE's implementation; the interface has no written
    /// specification of the unit).
    public func currentReading() -> ScreenSaverIdleReading {
        guard let reply = try? call("GetSessionIdleTime"), let milliseconds = reply.body.first?.uint32Value else {
            return .unavailable
        }
        return .idleFor(TimeInterval(milliseconds) / 1000)
    }

    /// Locks the screen. Returns whether the call went through, not whether
    /// the desktop then locked.
    @discardableResult
    public func relock() -> Bool {
        (try? call("Lock")) != nil
    }
}

#endif
