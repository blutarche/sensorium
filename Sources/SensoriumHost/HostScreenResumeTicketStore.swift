import Foundation
import Security

/// A snapshot of everything about a device's own arming record that a
/// resumed session must not silently outlive: the credential strength
/// required of it, when it was armed, and whether it asks first. Two
/// fingerprints taken from arming records that differ in any of these
/// compare unequal, so a ticket minted under one arming record is refused
/// the moment the record it was minted under changes, enforced by
/// comparing values rather than by a side channel a call site could forget
/// to check.
///
/// Which display a ticket may resume is not arming state -- arming is per
/// machine -- and is bound by the ticket's own `displayIdentity` instead.
public struct HostScreenArmingFingerprint: Equatable, Hashable, Sendable {
    private let minimumCredentialStrength: HostScreenCredentialStrength?
    private let armedAt: Date
    private let asksWhenSomeoneIsUsingThisMachine: Bool

    public init(_ device: HostScreenDeviceArming) {
        minimumCredentialStrength = device.minimumCredentialStrength
        armedAt = device.armedAt
        asksWhenSomeoneIsUsingThisMachine = device.asksWhenSomeoneIsUsingThisMachine
    }
}

/// The host alone decides what counts as the same host-screen session; the
/// viewer is never trusted to decide when it may skip its own presence
/// check. This is that decision: minting a resume ticket on admission, and
/// validating a later presentation of one against a five-minute grace
/// window (refreshed on every successful resume), a twelve-hour ceiling
/// measured from the original mint, and a bind to the exact device key,
/// display, and arming record the ticket was minted under. Any mismatch, an
/// unknown token, or either window having elapsed refuses outright -- there
/// is no partial credit, matching every other host-screen refusal in this
/// codebase.
///
/// A ticket answers only "does this resume something already granted?", it
/// is never itself a presence proof, and `HostSessionController` never
/// asks this store about a `.signed` proof.
public protocol HostScreenResumeTicketStoring: AnyObject, Sendable {
    /// Mints a fresh, single ticket for exactly this device/display/arming
    /// combination, replacing nothing -- a device may hold more than one
    /// live ticket if it opens more than one host-screen session over time,
    /// and minting a new one never invalidates an older still-valid one on
    /// its own.
    func mint(
        devicePublicKey: Data,
        displayIdentity: HostScreenDisplayIdentity,
        armingFingerprint: HostScreenArmingFingerprint
    ) -> Data

    /// `true` only when `token` is a ticket this store itself minted, for
    /// exactly this device, this display, and this arming fingerprint, and
    /// neither of its two windows has elapsed. A successful validation
    /// refreshes the five-minute grace window; the twelve-hour ceiling is
    /// never refreshed, by design -- it measures from the original grant,
    /// not from the most recent use.
    func validate(
        token: Data,
        devicePublicKey: Data,
        displayIdentity: HostScreenDisplayIdentity,
        armingFingerprint: HostScreenArmingFingerprint
    ) -> Bool

    /// Every ticket this device currently holds stops resuming anything.
    func invalidateAll(for devicePublicKey: Data)
}

/// One resume ticket's own record. Never handed whole to a caller outside
/// this file -- the opaque `token` is returned once, at mint time, and
/// nothing about a record crosses this store's boundary again except a
/// plain yes/no from `validate`.
private struct HostScreenResumeTicketRecord {
    let devicePublicKey: Data
    let displayIdentity: HostScreenDisplayIdentity
    let armingFingerprint: HostScreenArmingFingerprint
    let mintedAtSeconds: Double
    var lastResumedAtSeconds: Double
}

/// The real, in-process implementation. Deliberately holds every ticket in
/// memory only, with no disk persistence: a resume ticket is a bearer
/// credential that substitutes for a live presence check, and keeping it
/// nowhere but this process's own memory is what makes a host restart an
/// invalidation this store enforces for free, by construction -- a
/// restarted process starts this store empty.
public final class HostScreenResumeTicketStore: HostScreenResumeTicketStoring, @unchecked Sendable {
    /// Enough for a network handover or a closed lid, not enough for a
    /// machine that changed hands.
    public static let graceWindowSeconds: TimeInterval = 5 * 60
    /// A grant never survives more than twelve hours of resumes, however
    /// often it is refreshed within the grace window.
    public static let ceilingSeconds: TimeInterval = 12 * 60 * 60

    private let lock = NSLock()
    private var records: [Data: HostScreenResumeTicketRecord] = [:]
    /// Injected so a test can advance time deterministically across a
    /// five-minute or twelve-hour window.
    private let now: () -> Double

    public init(now: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    public func mint(
        devicePublicKey: Data,
        displayIdentity: HostScreenDisplayIdentity,
        armingFingerprint: HostScreenArmingFingerprint
    ) -> Data {
        let token = Self.secureRandomToken()
        let atSeconds = now()
        lock.lock()
        records[token] = HostScreenResumeTicketRecord(
            devicePublicKey: devicePublicKey,
            displayIdentity: displayIdentity,
            armingFingerprint: armingFingerprint,
            mintedAtSeconds: atSeconds,
            lastResumedAtSeconds: atSeconds
        )
        lock.unlock()
        return token
    }

    public func validate(
        token: Data,
        devicePublicKey: Data,
        displayIdentity: HostScreenDisplayIdentity,
        armingFingerprint: HostScreenArmingFingerprint
    ) -> Bool {
        let atSeconds = now()
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[token] else {
            return false
        }
        guard record.devicePublicKey == devicePublicKey,
              record.displayIdentity == displayIdentity,
              record.armingFingerprint == armingFingerprint else {
            return false
        }
        guard atSeconds - record.lastResumedAtSeconds <= Self.graceWindowSeconds,
              atSeconds - record.mintedAtSeconds <= Self.ceilingSeconds else {
            // An expired ticket cannot be resurrected by a later, otherwise
            // well-formed presentation of the same token -- once either
            // window has closed, this token is exactly as dead as one that
            // was never minted.
            records[token] = nil
            return false
        }
        record.lastResumedAtSeconds = atSeconds
        records[token] = record
        return true
    }

    public func invalidateAll(for devicePublicKey: Data) {
        lock.lock()
        records = records.filter { $0.value.devicePublicKey != devicePublicKey }
        lock.unlock()
    }

    /// 32 bytes from the platform CSPRNG -- never a counter, a hash of
    /// anything this method already knows, or any other value a viewer
    /// could derive. Fatal on failure rather than falling back to a weaker
    /// source, matching `HostSessionController.secureRandomToken()`'s own
    /// reasoning: `SecRandomCopyBytes` failing is not a condition this
    /// function can recover from and still hand back something that is
    /// actually unguessable.
    private static func secureRandomToken() -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
