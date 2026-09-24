#if !canImport(CryptoKit)
import COpenSSL
import Foundation

public extension SensoriumCrypto {
    // OpenSSL records a failed call in a thread-local error queue that
    // persists until cleared. Every function below that calls into OpenSSL
    // clears it on exit, so a stale entry never leaks into a later
    // `SSL_get_error` in the QUIC transport.

    /// An Ed25519 private key is 32 uniformly random bytes; the rest of the
    /// key schedule is derived from them.
    static func ed25519GeneratePrivateKey() -> Data {
        randomBytes(32)
    }

    static func ed25519PublicKey(privateKey: Data) throws -> Data {
        defer { ERR_clear_error() }
        let key = try signingKey(privateKey)
        defer { EVP_PKEY_free(key) }
        var publicKey = [UInt8](repeating: 0, count: ed25519PublicKeyLength)
        var length = publicKey.count
        guard EVP_PKEY_get_raw_public_key(key, &publicKey, &length) == 1,
              length == ed25519PublicKeyLength else {
            throw SensoriumCryptoError.invalidKey
        }
        return Data(publicKey)
    }

    static func ed25519Sign(privateKey: Data, message: Data) throws -> Data {
        defer { ERR_clear_error() }
        let key = try signingKey(privateKey)
        defer { EVP_PKEY_free(key) }
        guard let context = EVP_MD_CTX_new() else {
            throw SensoriumCryptoError.signingFailed
        }
        defer { EVP_MD_CTX_free(context) }
        // Ed25519 hashes the message itself, so it takes no digest here and
        // signs in one call rather than through update and final.
        guard EVP_DigestSignInit(context, nil, nil, nil, key) == 1 else {
            throw SensoriumCryptoError.signingFailed
        }
        var signature = [UInt8](repeating: 0, count: ed25519SignatureLength)
        var length = signature.count
        let signed = withContiguousBytes(message) { messageBytes, messageCount in
            EVP_DigestSign(context, &signature, &length, messageBytes, messageCount)
        }
        guard signed == 1, length == ed25519SignatureLength else {
            throw SensoriumCryptoError.signingFailed
        }
        return Data(signature)
    }

    static func ed25519Verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        defer { ERR_clear_error() }
        guard signature.count == ed25519SignatureLength,
              publicKey.count == ed25519PublicKeyLength else {
            return false
        }
        let key = [UInt8](publicKey).withUnsafeBufferPointer {
            EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nil, $0.baseAddress, $0.count)
        }
        guard let key else { return false }
        defer { EVP_PKEY_free(key) }
        guard let context = EVP_MD_CTX_new() else { return false }
        defer { EVP_MD_CTX_free(context) }
        guard EVP_DigestVerifyInit(context, nil, nil, nil, key) == 1 else { return false }
        return withContiguousBytes(signature) { signatureBytes, signatureCount in
            withContiguousBytes(message) { messageBytes, messageCount in
                EVP_DigestVerify(context, signatureBytes, signatureCount, messageBytes, messageCount) == 1
            }
        }
    }

    static func sha256(_ data: Data) -> Data {
        defer { ERR_clear_error() }
        var digest = [UInt8](repeating: 0, count: sha256Length)
        var length = UInt32(digest.count)
        let hashed = withContiguousBytes(data) { bytes, count in
            EVP_Digest(bytes, count, &digest, &length, EVP_sha256(), nil)
        }
        precondition(hashed == 1 && length == UInt32(sha256Length), "SHA-256 is unavailable")
        return Data(digest)
    }

    static func randomBytes(_ count: Int) -> Data {
        defer { ERR_clear_error() }
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(RAND_bytes(&bytes, Int32(count)) == 1, "the system random number generator is unavailable")
        return Data(bytes)
    }

    private static var ed25519PrivateKeyLength: Int { 32 }
    private static var ed25519PublicKeyLength: Int { 32 }
    private static var ed25519SignatureLength: Int { 64 }
    private static var sha256Length: Int { 32 }

    private static func signingKey(_ privateKey: Data) throws -> OpaquePointer {
        defer { ERR_clear_error() }
        guard privateKey.count == ed25519PrivateKeyLength else {
            throw SensoriumCryptoError.invalidKey
        }
        var bytes = [UInt8](privateKey)
        defer { OPENSSL_cleanse(&bytes, bytes.count) }
        let key = bytes.withUnsafeBufferPointer {
            EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, nil, $0.baseAddress, $0.count)
        }
        guard let key else { throw SensoriumCryptoError.invalidKey }
        return key
    }

    /// Hands `body` a pointer that is never null, which `Data` of zero bytes
    /// would otherwise give, and a length that is the real one.
    private static func withContiguousBytes<T>(
        _ data: Data,
        _ body: (UnsafePointer<UInt8>, Int) -> T
    ) -> T {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Swift.max(data.count, 1))
        buffer.initialize(repeating: 0, count: Swift.max(data.count, 1))
        defer {
            buffer.deinitialize(count: Swift.max(data.count, 1))
            buffer.deallocate()
        }
        data.copyBytes(to: buffer, count: data.count)
        return body(buffer, data.count)
    }
}
#endif
