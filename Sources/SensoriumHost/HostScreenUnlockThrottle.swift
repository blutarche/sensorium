import Foundation

/// The wrong-guess budget for host-screen lock-screen unlock, kept on the host
/// alone. A budget that lived on one connection would reset to a fresh five the
/// moment an attacker holding a device key and a resume ticket reconnected,
/// turning the login window into an unbounded online password oracle. This
/// budget is keyed by the verified device identity and the arming record it was
/// granted under, so every connection that same device opens spends one shared
/// count. The ceiling is five wrong guesses per host uptime, which is not an
/// oracle; a host restart clears this store and voids every resume ticket
/// anyway, so nothing about it needs to survive one.
///
/// It is reset on a successful unlock. It is not reset by re-arming through any
/// explicit call: re-arming changes the arming record's `armedAt`, hence the
/// `HostScreenArmingFingerprint`, hence the key, so a re-armed device simply
/// begins spending a fresh budget with no leftover count. There is no time
/// decay: a count spent stays spent until one of those two things happens.
public protocol HostScreenUnlockThrottling: AnyObject, Sendable {
    /// Atomically claims one guess slot: the cap check and the charge are one
    /// indivisible step, which is the whole point. Returns `true` and has
    /// charged one guess when a slot was free; returns `false` and charged
    /// nothing when the device is already at the cap. This is the ONLY way the
    /// budget is ever spent -- there is deliberately no separate "is it
    /// exhausted?" query, because a check and a later charge on opposite sides
    /// of the multi-second unlock attempt is exactly the race this closes: N
    /// connections could all read the same pre-charge count and all pass.
    func tryReserve(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) -> Bool
    /// Releases one slot a `tryReserve` claimed for an attempt that turned out
    /// to consume no real guess (an empty submit never gets this far, but an
    /// unreachable screen-sharing service, an already-unlocked screen, an
    /// over-long password, or a connection that died mid-attempt all do).
    /// Never goes below zero.
    func refund(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint)
    /// Clears this device's count under this arming record, as a successful
    /// unlock does.
    func reset(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint)
    /// How many guesses this device has spent under this arming record. For
    /// tests and diagnostics only; never consulted to decide whether an
    /// attempt may proceed -- `tryReserve` alone decides that, atomically.
    func failureCount(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) -> Int
}

/// The real, in-process implementation. Holds every count in memory only, with
/// no disk persistence, for the reason the doc comment on the protocol gives: a
/// restarted host starts this store empty, which is exactly the invalidation
/// this budget wants for free.
public final class HostScreenUnlockThrottle: HostScreenUnlockThrottling, @unchecked Sendable {
    /// Wrong guesses one device may spend, per host uptime, before
    /// `tryReserve` starts refusing further ones. Reached across every
    /// connection that device opens, not per connection.
    public static let maximumUnlockFailures = 5

    /// The whole identity of a budget: a device's verified public key and the
    /// arming record it was granted under. A re-arm changes the fingerprint and
    /// so the key, which is what starts a fresh budget without an explicit
    /// reset.
    private struct Key: Hashable {
        let devicePublicKey: Data
        let armingFingerprint: HostScreenArmingFingerprint
    }

    private let lock = NSLock()
    private var counts: [Key: Int] = [:]

    public init() {}

    public func tryReserve(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(devicePublicKey: devicePublicKey, armingFingerprint: armingFingerprint)
        let current = counts[key] ?? 0
        guard current < Self.maximumUnlockFailures else {
            return false
        }
        counts[key] = current + 1
        return true
    }

    public func refund(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(devicePublicKey: devicePublicKey, armingFingerprint: armingFingerprint)
        counts[key] = max(0, (counts[key] ?? 0) - 1)
    }

    public func reset(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) {
        lock.lock()
        defer { lock.unlock() }
        counts[Key(devicePublicKey: devicePublicKey, armingFingerprint: armingFingerprint)] = nil
    }

    public func failureCount(devicePublicKey: Data, armingFingerprint: HostScreenArmingFingerprint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[Key(devicePublicKey: devicePublicKey, armingFingerprint: armingFingerprint)] ?? 0
    }
}
