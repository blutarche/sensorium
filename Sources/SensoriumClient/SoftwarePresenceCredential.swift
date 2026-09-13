import CryptoKit
import Foundation
import SensoriumCore

/// A presence credential backed by an ordinary, in-memory CryptoKit key --
/// never the Secure Enclave, never Keychain, never a biometric prompt. It
/// exists so a test can drive `PresenceCredentialProviding` end to end
/// without any of the production dependencies `SecureEnclavePresenceCredential`
/// carries.
///
/// Reports `.softwarePresence`, honestly: a key sitting in this process's own
/// memory proves nothing about a human confirming its use, so nothing built
/// on this type may claim the stronger tier.
public final class SoftwarePresenceCredential: PresenceCredentialProviding, @unchecked Sendable {
    /// The same format `PresenceCredentialVerifier.supportedCredentialFormat`
    /// checks: raw P-256 ECDSA over the raw challenge bytes. The format names
    /// the verification routine, which is identical for both strengths --
    /// `docs/host-screen-design.md` §6.3 -- not the strength itself.
    public static let credentialFormat = "apple-secure-enclave-p256"

    public let strength = PresenceCredentialStrength.softwarePresence
    /// Opaque -- derived from the public key so two calls to `register()`
    /// on the same instance report the same identifier.
    public let credentialID: Data
    private let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
        self.credentialID = Data(SHA256.hash(data: key.publicKey.rawRepresentation))
    }

    public func register() async throws -> PresenceCredentialRegistration {
        PresenceCredentialRegistration(
            credentialID: credentialID,
            publicKey: key.publicKey.rawRepresentation,
            credentialFormat: Self.credentialFormat,
            strength: strength.rawValue
        )
    }

    public func sign(challenge: Data) async throws -> Data {
        try key.signature(for: challenge).rawRepresentation
    }
}
