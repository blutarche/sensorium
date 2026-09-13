import CryptoKit
import Foundation
import Security
import SensoriumCore

/// The production `PresenceCredentialProviding` -- `docs/host-screen-design.md` §6.3's
/// `hardwareBound` tier. The private key is a CryptoKit
/// `SecureEnclave.P256.Signing.PrivateKey` under a `.userPresence` access
/// control: it never leaves the Secure Enclave, and every signature needs a
/// fresh confirmation from whoever is at this machine at that moment.
///
/// The key's wrapped blob is kept beside its own record in
/// `PresenceCredentialRecordStore`, so the registration a host holds stays
/// valid across rebuilds of this app -- see `PersistedPresenceCredential`
/// for what keeping it in a plain file does and does not protect.
///
/// Production only; anything that needs a `PresenceCredentialProviding`
/// without the Secure Enclave uses `SoftwarePresenceCredential`.
public final class SecureEnclavePresenceCredential: PresenceCredentialProviding, @unchecked Sendable {
    /// The same format `PresenceCredentialVerifier.supportedCredentialFormat`
    /// checks -- see `SoftwarePresenceCredential`'s own note on why both
    /// strengths share one format.
    public static let credentialFormat = "apple-secure-enclave-p256"

    public let strength = PresenceCredentialStrength.hardwareBound

    private let recordStore: PresenceCredentialRecordStore

    public init(recordStoreURL: URL) {
        recordStore = PresenceCredentialRecordStore(url: recordStoreURL)
    }

    /// Creates or loads the key -- the tier is discovered by attempting it.
    /// A record whose key still loads is reused outright, so
    /// re-pairing never mints a second credential for the same device; a
    /// missing or unloadable one registers fresh.
    public func register() async throws -> PresenceCredentialRegistration {
        if let record = recordStore.load(),
           let existingKey = loadKey(record),
           existingKey.publicKey.rawRepresentation == record.publicKey {
            return record.registration
        }
        guard SecureEnclave.isAvailable else {
            throw PresenceCredentialRegistrationError.noSecureEnclave
        }
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessControlError
        ) else {
            throw PresenceCredentialRegistrationError.keystoreFailed(
                reason: (accessControlError?.takeRetainedValue() as Error?)?.localizedDescription
                    ?? "could not build the access control"
            )
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        } catch {
            throw PresenceCredentialRegistrationError.keystoreFailed(reason: String(describing: error))
        }
        let record = PersistedPresenceCredential(
            credentialID: Data(SHA256.hash(data: key.publicKey.rawRepresentation)),
            publicKey: key.publicKey.rawRepresentation,
            credentialFormat: Self.credentialFormat,
            strength: strength.rawValue,
            wrappedPrivateKey: key.dataRepresentation
        )
        recordStore.save(record)
        return record.registration
    }

    /// Triggers the Secure Enclave's own presence confirmation -- this call
    /// is the only one in this type that can prompt. Session-time use of it
    /// is part 2; this method exists now so the round trip is provable.
    public func sign(challenge: Data) async throws -> Data {
        guard let record = recordStore.load(), let key = loadKey(record) else {
            throw PresenceCredentialRegistrationError.keystoreFailed(
                reason: "no Secure Enclave key is on record; pair again to register one"
            )
        }
        return try key.signature(for: challenge).rawRepresentation
    }

    /// Rebuilds the key from the blob stored beside the record. Reading the
    /// blob prompts nobody: the enclave asks for a person only when the key
    /// is used to sign.
    private func loadKey(_ record: PersistedPresenceCredential) -> SecureEnclave.P256.Signing.PrivateKey? {
        guard let wrappedPrivateKey = record.wrappedPrivateKey else {
            return nil
        }
        return try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: wrappedPrivateKey)
    }
}
