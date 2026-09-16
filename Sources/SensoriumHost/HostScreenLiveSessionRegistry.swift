import Foundation

/// A claim on the one live host-screen session a device is allowed to hold at a
/// time. Opaque to callers: the admitting connection keeps it and returns it to
/// the registry when its session ends. The token makes a release name the exact
/// session it was minted for, so a teardown still in flight when the same device
/// has already opened a new session releases nothing rather than evicting that
/// newer one -- the same reservation-captured-identity discipline the unlock
/// throttle's refund follows.
public struct HostScreenLiveSessionClaim: Equatable, Sendable {
    fileprivate let devicePublicKey: Data
    fileprivate let token: UInt64
}

/// Records which devices currently hold a live host-screen session, so a second
/// concurrent one for a device already streaming is refused rather than silently
/// replacing the first. Shared across every connection of one host process, the
/// same way the unlock throttle and the resume-ticket store are: the fact "this
/// device already has a live session" has to outlive any single connection.
@MainActor
public protocol HostScreenLiveSessionRegistering: AnyObject {
    /// Records a live host-screen session for `devicePublicKey` and hands back a
    /// claim, or returns `nil` when one is already live for it. `isLive` is how
    /// the registry answers "is that recorded session still live?" without
    /// depending on a teardown ever firing: a recorded entry whose `isLive` now
    /// answers `false` (a connection dropped without releasing) is evicted and
    /// the new session admitted, so a headless host is never left permanently
    /// busy for a device by a leaked entry.
    func admit(devicePublicKey: Data, isLive: @escaping @MainActor () -> Bool) -> HostScreenLiveSessionClaim?
    /// Releases the entry `claim` recorded, and only that one. A release whose
    /// token no longer matches the current entry -- the device re-admitted after
    /// this teardown began -- removes nothing, so a mid-flight teardown never
    /// evicts a newer session.
    func release(_ claim: HostScreenLiveSessionClaim)
}

/// The real, in-process implementation. Main-actor isolated, like the
/// connections that drive it: admission and teardown both run on the main actor,
/// so the map needs no lock of its own.
@MainActor
public final class HostScreenLiveSessionRegistry: HostScreenLiveSessionRegistering {
    private struct Entry {
        let token: UInt64
        let isLive: @MainActor () -> Bool
    }

    private var entries: [Data: Entry] = [:]
    private var nextToken: UInt64 = 0

    public init() {}

    public func admit(devicePublicKey: Data, isLive: @escaping @MainActor () -> Bool) -> HostScreenLiveSessionClaim? {
        if let existing = entries[devicePublicKey], existing.isLive() {
            return nil
        }
        // No entry, or a stale one whose session is no longer live: (re)record.
        nextToken += 1
        let issued = nextToken
        entries[devicePublicKey] = Entry(token: issued, isLive: isLive)
        return HostScreenLiveSessionClaim(devicePublicKey: devicePublicKey, token: issued)
    }

    public func release(_ claim: HostScreenLiveSessionClaim) {
        guard let existing = entries[claim.devicePublicKey], existing.token == claim.token else {
            return
        }
        entries[claim.devicePublicKey] = nil
    }
}
