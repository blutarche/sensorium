import Foundation
import SensoriumCore

/// What this machine last registered as its presence credential: the public
/// halves a host verifies against, and `wrappedPrivateKey`, the key's own
/// `dataRepresentation` as the Secure Enclave hands it back.
///
/// What that blob is protected by, exactly. It is usable only by this
/// machine's own Secure Enclave, which cannot be made to hand the private
/// key over, and it signs nothing until the access control the key was
/// created under -- `.userPresence` -- is satisfied by a person confirming
/// at that moment, every single time.
///
/// What it is not protected by. A file carries no check on which program is
/// reading it, so any process running as this user can load this blob and
/// ask the enclave to sign with it, which raises that confirmation prompt
/// on this machine's screen. What stands between such a process and a
/// signature is the person who sees the prompt. The file is written
/// readable by this user alone, which keeps other accounts out and does
/// nothing about this one. A signed build can ask for a keychain access
/// group instead, which would restrict the blob to this application's own
/// identity; the record's shape does not have to change for that.
///
/// `wrappedPrivateKey` is optional because a record may have none; that
/// reads back as "no key on record," the same signal a missing file gives
/// -- register a fresh one.
public struct PersistedPresenceCredential: Codable, Equatable, Sendable {
    public let credentialID: Data
    public let publicKey: Data
    public let credentialFormat: String
    public let strength: String
    public let wrappedPrivateKey: Data?

    public init(
        credentialID: Data,
        publicKey: Data,
        credentialFormat: String,
        strength: String,
        wrappedPrivateKey: Data? = nil
    ) {
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.credentialFormat = credentialFormat
        self.strength = strength
        self.wrappedPrivateKey = wrappedPrivateKey
    }

    public init(_ registration: PresenceCredentialRegistration) {
        self.init(
            credentialID: registration.credentialID,
            publicKey: registration.publicKey,
            credentialFormat: registration.credentialFormat,
            strength: registration.strength
        )
    }

    public var registration: PresenceCredentialRegistration {
        PresenceCredentialRegistration(
            credentialID: credentialID,
            publicKey: publicKey,
            credentialFormat: credentialFormat,
            strength: strength
        )
    }
}

/// Plain file I/O: a JSON file under Application Support rather than the
/// Keychain, so the record belongs to this machine and this file instead of
/// to the identity of the binary that wrote it -- an unsigned build has no
/// stable identity to address a keychain item by. The file and the
/// directory the store creates for it
/// are this user's alone; see `PersistedPresenceCredential` for what that
/// does and does not protect.
public struct PresenceCredentialRecordStore: Equatable, Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PersistedPresenceCredential? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedPresenceCredential.self, from: data)
    }

    public func save(_ record: PersistedPresenceCredential) {
        guard let data = try? JSONEncoder().encode(record) else {
            return
        }
        try? OwnerOnlyFileWrite.write(data, to: url)
    }
}
