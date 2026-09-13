import Foundation

public enum FileDeviceIdentityStoreError: Error, Equatable, LocalizedError {
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            return "The file holding the key that identifies this Mac could not be read"
        }
    }
}

/// Keeps the device key in an owner-only file under Application Support.
///
/// The key is protected by file permissions and FileVault: any process
/// running as this user can read it. See docs/threat-model.md.
public final class FileDeviceIdentityStore: DeviceIdentityProviding, DeviceIdentityReplacing, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// A file that exists but cannot be read back as a key is refused
    /// rather than replaced: generating a new key here would cost the owner
    /// every pairing without ever saying so.
    public func loadOrCreate() throws -> DeviceIdentity {
        OwnerOnlyFileWrite.removeStalePartialFiles(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
                  let keyData = Data(base64Encoded: stored.privateKey) else {
                throw FileDeviceIdentityStoreError.invalidStoredValue
            }
            return try DeviceIdentity(privateKeyData: keyData)
        }

        let identity = try makeReplacementIdentity()
        try store(identity)
        return identity
    }

    /// "Make a new key": every device this Mac paired with knows the old
    /// public key, so pairing has to be done again once this key is stored.
    public func makeReplacementIdentity() throws -> DeviceIdentity {
        try DeviceIdentity.generate()
    }

    public func store(_ identity: DeviceIdentity) throws {
        let stored = StoredIdentity(privateKey: identity.privateKeyDataForStorage().base64EncodedString())
        try OwnerOnlyFileWrite.write(JSONEncoder().encode(stored), to: url)
    }

    private struct StoredIdentity: Codable {
        let privateKey: String
    }
}
