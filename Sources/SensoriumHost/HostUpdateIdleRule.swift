import Foundation

/// When the host may install an update: listening, with no session live, no
/// pairing approved or under way, and no pairing code on screen.
///
/// A host that is not listening is not idle. Its replacement reports ready
/// only once its own listener does, so a handover from a host that cannot
/// listen would end in a rollback every time.
public enum HostUpdateIdleRule {
    public static func isIdle(_ status: HostOperatorStatus, now: Date) -> Bool {
        guard case .hosting = status.connection else {
            return false
        }
        // The store keeps an expired code as `.showing`; it is off the screen
        // all the same, so it holds nothing up.
        if case let .showing(_, expiresAt, _) = status.pairing, expiresAt > now {
            return false
        }
        return true
    }
}

/// Tells each moment the host becomes idle, so a waiting update installs
/// as soon as a session or pairing ends rather than at the next check.
public struct HostUpdateIdleWatch: Sendable {
    private var wasIdle = false

    public init() {}

    /// True when `status` is idle and the one before it was not.
    public mutating func observe(_ status: HostOperatorStatus, now: Date) -> Bool {
        let isIdle = HostUpdateIdleRule.isIdle(status, now: now)
        defer { wasIdle = isIdle }
        return isIdle && !wasIdle
    }
}
