import Foundation
import SensoriumCore

/// Whether a `hostScreenRequest`'s presence proof genuinely proves presence
/// for `devicePublicKey`, at least at `minimumStrength`, over `challenge`.
///
/// `minimumStrength` comes from the caller's own arming record, never from
/// the proof itself: a device does not get to name the strength its own
/// signature should be judged against. `challenge` is the single-use value
/// `HostSessionController` minted for this offer and is about to consume by
/// calling this -- a conformer checks the proof's signature against exactly
/// this value, never a value the proof itself could name, or replay across
/// sessions becomes possible. See `PresenceCredentialVerifier` for the real
/// implementation.
public protocol HostScreenPresenceProofVerifying: Sendable {
    func verify(
        proof: HostScreenPresenceProof,
        devicePublicKey: Data,
        minimumStrength: HostScreenCredentialStrength?,
        challenge: Data
    ) -> Bool
}
