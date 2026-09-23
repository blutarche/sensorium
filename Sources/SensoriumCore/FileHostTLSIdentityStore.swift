import Foundation

public enum FileHostTLSIdentityStoreError: Error, Equatable, LocalizedError {
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            return "The file holding this machine\u{2019}s TLS certificate and key could not be read"
        }
    }
}

/// Keeps the host's TLS certificate and key in an owner-only file under
/// Application Support, alongside the device key.
public final class FileHostTLSIdentityStore: HostTLSIdentityProviding, HostTLSIdentityReplacing, @unchecked Sendable {
    private let url: URL
    private let commonName: String

    public init(url: URL, commonName: String) {
        self.url = url
        self.commonName = commonName
    }

    public func loadOrCreate() throws -> HostTLSIdentity {
        OwnerOnlyFileWrite.removeStalePartialFiles(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
                  let certificateDER = Data(base64Encoded: stored.certificateDER),
                  let privateKeyData = Data(base64Encoded: stored.privateKey) else {
                throw FileHostTLSIdentityStoreError.invalidStoredValue
            }
            #if canImport(Security)
            guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
                throw FileHostTLSIdentityStoreError.invalidStoredValue
            }
            #endif
            let identity = HostTLSIdentity(certificateDER: certificateDER, privateKeyData: privateKeyData)
            #if canImport(Security)
            _ = try identity.makeSecIdentity()
            #endif
            return identity
        }

        let identity = try makeReplacementIdentity()
        try store(identity)
        return identity
    }

    /// "Make a new key": a viewer pinned the old certificate at pairing, so
    /// pairing has to be done again once this one is stored.
    public func makeReplacementIdentity() throws -> HostTLSIdentity {
        try HostTLSIdentity.generate(commonName: commonName)
    }

    public func store(_ identity: HostTLSIdentity) throws {
        let stored = StoredIdentity(
            certificateDER: identity.certificateDER.base64EncodedString(),
            privateKey: identity.privateKeyData.base64EncodedString()
        )
        try OwnerOnlyFileWrite.write(JSONEncoder().encode(stored), to: url)
    }

    private struct StoredIdentity: Codable {
        let certificateDER: String
        let privateKey: String
    }
}
