import CryptoKit
import Foundation
import SensoriumCore

/// The real `HostScreenPresenceProofVerifying`.
///
/// Checks a `.signed` proof's signature against the credential
/// `ApprovedDeviceStoring` has on record for the device, over exactly the
/// challenge `HostSessionController` minted for this offer. The record's own
/// `strength`, never anything the proof carries, is what `minimumStrength`
/// is compared against: enforced by requiring the pairing ceremony to
/// change the registered key, never by trusting the strength a device
/// reports. `HostScreenPresenceProof` has no strength field to trust in
/// the first place.
///
/// `supportedCredentialFormat` pins the one signature shape both Secure
/// Enclave and CryptoKit produce natively: P-256 ECDSA over the raw
/// challenge bytes. This is the same routine regardless of registered
/// strength -- the math a hardware-bound and a software-presence key both
/// produce is identical; only how the private half is held differs, and
/// that is reported, never verified.
public final class PresenceCredentialVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    public static let supportedCredentialFormat = "apple-secure-enclave-p256"

    private let approvedDeviceStore: any ApprovedDeviceStoring

    public init(approvedDeviceStore: any ApprovedDeviceStoring) {
        self.approvedDeviceStore = approvedDeviceStore
    }

    public func verify(
        proof: HostScreenPresenceProof,
        devicePublicKey: Data,
        minimumStrength: HostScreenCredentialStrength?,
        challenge: Data
    ) -> Bool {
        guard case let .signed(credentialID, credentialFormat, signature) = proof else {
            return false
        }
        guard credentialFormat == Self.supportedCredentialFormat else {
            return false
        }
        guard let record = approvedDeviceStore.presenceCredential(for: devicePublicKey),
              record.credentialID == credentialID,
              record.credentialFormat == credentialFormat else {
            return false
        }
        // `nil` is never "any strength is acceptable" -- only a device armed
        // before `minimumCredentialStrength` began being snapshotted at arm
        // time reads back with one, and that record has nothing to hold a
        // signature to. `HostSessionController` names this refusal
        // `host-screen-needs-rearming`, distinct from an ordinary failed
        // check, because arming again is what fixes it.
        guard let minimumStrength, record.strength >= minimumStrength else {
            return false
        }
        return Self.verifySignature(signature, credentialPublicKey: record.publicKey, challenge: challenge)
    }

    static func verifySignature(_ signatureData: Data, credentialPublicKey: Data, challenge: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: credentialPublicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: challenge)
    }
}
