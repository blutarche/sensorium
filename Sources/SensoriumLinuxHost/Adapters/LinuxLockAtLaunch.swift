#if os(Linux)
import Foundation
import Glibc
import SensoriumHost

/// How long ago this login session began, from logind on the system bus.
///
/// The lock-at-launch rule compares idle time with the time since login: a
/// session whose idle time reaches back to its own start was never touched,
/// which only an automatic login leaves behind. macOS measures from boot;
/// here the session's own start is the closer origin, because the desktop's
/// idle counter starts with the session, not with the machine.
public enum LogindSessionAge {
    private static let destination = "org.freedesktop.login1"
    /// logind resolves `auto` to the session of the process asking.
    private static let sessionPath = "/org/freedesktop/login1/session/auto"

    /// The age in seconds, or nil when logind does not answer.
    /// `monotonicMicroseconds` is `CLOCK_MONOTONIC` now, the clock logind's
    /// `TimestampMonotonic` is on.
    public static func read(
        bus: any DBusConnecting,
        monotonicMicroseconds: @Sendable () -> UInt64 = LogindSessionAge.monotonicMicroseconds
    ) async -> TimeInterval? {
        let call = DBusCall(
            destination: destination,
            path: sessionPath,
            interface: "org.freedesktop.DBus.Properties",
            method: "Get",
            parameters: [.string("org.freedesktop.login1.Session"), .string("TimestampMonotonic")]
        )
        guard let reply = try? await bus.call(call),
              let started = reply.body.first?.uint64Value,
              started > 0 else {
            return nil
        }
        let now = monotonicMicroseconds()
        guard now >= started else { return nil }
        return TimeInterval(now - started) / 1_000_000
    }

    public static func monotonicMicroseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_nsec) / 1000
    }
}

/// The shared lock-at-launch rule with the login session's age in place of
/// the machine's uptime. A session of unknown age is never locked: locking
/// someone out mid-login is the worse mistake.
public enum LinuxLockAtLaunch {
    @discardableResult
    public static func apply(
        lockState: any ScreenLockStateReading,
        activity: any HostLocalActivitySignal,
        sessionAge: TimeInterval?,
        relocker: any HostScreenRelocking,
        isUpdateRelaunch: Bool = false
    ) -> HostAutoLoginLockAtStart.Outcome {
        guard let sessionAge else { return .notNeeded }
        return HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: lockState,
            activitySignal: activity,
            systemUptime: sessionAge,
            relockPoster: relocker,
            isUpdateRelaunch: isUpdateRelaunch
        )
    }
}
#endif
