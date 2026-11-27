#if !canImport(Security) && canImport(COpenSSL)
import COpenSSL
import Foundation

/// Minting and loading for platforms with OpenSSL instead of Security.
///
/// The stored private key keeps the layout Security exports for a P-256 key,
/// the ANSI X9.63 form `04 || X || Y || K` (97 bytes), so an identity file
/// written on one platform loads on the other.
extension HostTLSIdentity {
    private static let uncompressedPointLength = 65
    private static let scalarLength = 32

    static func generateWithOpenSSL(commonName: String) throws -> HostTLSIdentity {
        // OpenSSL records a failed call in a thread-local error queue; clear
        // it so a stale entry never leaks into a later `SSL_get_error`.
        defer { ERR_clear_error() }
        guard let keyContext = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nil) else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        defer { EVP_PKEY_CTX_free(keyContext) }
        guard EVP_PKEY_keygen_init(keyContext) == 1,
              EVP_PKEY_CTX_set_ec_paramgen_curve_nid(keyContext, NID_X9_62_prime256v1) > 0 else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        var generated: OpaquePointer?
        guard EVP_PKEY_keygen(keyContext, &generated) == 1, let key = generated else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        defer { EVP_PKEY_free(key) }

        let publicKeyData = try publicPoint(of: key)
        let scalar = try privateScalar(of: key)
        let tbs = tbsCertificate(commonName: commonName, publicKeyData: publicKeyData)
        let signature = try sign(tbs, with: key)
        let certificate = DER.sequence([
            tbs,
            ecdsaWithSHA256Algorithm,
            DER.bitString(signature)
        ])
        return HostTLSIdentity(
            certificateDER: certificate,
            privateKeyData: publicKeyData + scalar
        )
    }

    /// The certificate and private key, as OpenSSL objects for a TLS server.
    /// The caller owns both and releases them with `X509_free` and
    /// `EVP_PKEY_free`. The certificate is parsed from the stored bytes, not
    /// rebuilt, so the pin the viewers hold still matches what is served.
    public func makeOpenSSLCredentials() throws -> (certificate: OpaquePointer, privateKey: OpaquePointer) {
        defer { ERR_clear_error() }
        guard privateKeyData.count == Self.uncompressedPointLength + Self.scalarLength,
              privateKeyData.first == 0x04 else {
            throw HostTLSIdentityError.identityCreationFailed
        }
        let publicKeyData = privateKeyData.prefix(Self.uncompressedPointLength)
        let scalar = privateKeyData.suffix(Self.scalarLength)
        // RFC 5915 ECPrivateKey, which `d2i_PrivateKey` reads for an EC key.
        let ecPrivateKey = DER.sequence([
            DER.integer(1),
            DER.octetString(Data(scalar)),
            DER.explicit(tag: 0, value: DER.oid("1.2.840.10045.3.1.7")),
            DER.explicit(tag: 1, value: DER.bitString(Data(publicKeyData)))
        ])
        let key: OpaquePointer? = [UInt8](ecPrivateKey).withUnsafeBufferPointer { buffer in
            var cursor: UnsafePointer<UInt8>? = buffer.baseAddress
            return d2i_PrivateKey(EVP_PKEY_EC, nil, &cursor, buffer.count)
        }
        guard let key else {
            throw HostTLSIdentityError.identityCreationFailed
        }
        let certificate: OpaquePointer? = [UInt8](certificateDER).withUnsafeBufferPointer { buffer in
            var cursor: UnsafePointer<UInt8>? = buffer.baseAddress
            return d2i_X509(nil, &cursor, buffer.count)
        }
        guard let certificate else {
            EVP_PKEY_free(key)
            throw HostTLSIdentityError.invalidCertificate
        }
        guard X509_check_private_key(certificate, key) == 1 else {
            X509_free(certificate)
            EVP_PKEY_free(key)
            throw HostTLSIdentityError.identityCreationFailed
        }
        return (certificate, key)
    }

    /// Whether a stored certificate and key would serve: parsed and matched
    /// exactly as `makeOpenSSLCredentials()` does for the listener, in
    /// memory, with nothing kept.
    public static func servesWithOpenSSL(certificateDER: Data, privateKeyData: Data) -> Bool {
        guard let credentials = try? HostTLSIdentity(certificateDER: certificateDER, privateKeyData: privateKeyData)
            .makeOpenSSLCredentials() else {
            return false
        }
        X509_free(credentials.certificate)
        EVP_PKEY_free(credentials.privateKey)
        return true
    }

    private static func publicPoint(of key: OpaquePointer) throws -> Data {
        var point = [UInt8](repeating: 0, count: uncompressedPointLength)
        var length = 0
        guard EVP_PKEY_get_octet_string_param(key, "pub", &point, point.count, &length) == 1,
              length == uncompressedPointLength, point[0] == 0x04 else {
            throw HostTLSIdentityError.publicKeyUnavailable
        }
        return Data(point)
    }

    private static func privateScalar(of key: OpaquePointer) throws -> Data {
        var number: OpaquePointer?
        guard EVP_PKEY_get_bn_param(key, "priv", &number) == 1, let number else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        defer { BN_clear_free(number) }
        var scalar = [UInt8](repeating: 0, count: scalarLength)
        guard BN_bn2binpad(number, &scalar, Int32(scalar.count)) == Int32(scalar.count) else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        return Data(scalar)
    }

    /// ECDSA over SHA-256, DER-encoded as X.509 expects.
    private static func sign(_ message: Data, with key: OpaquePointer) throws -> Data {
        guard let context = EVP_MD_CTX_new() else {
            throw HostTLSIdentityError.signingFailed
        }
        defer { EVP_MD_CTX_free(context) }
        guard EVP_DigestSignInit(context, nil, EVP_sha256(), nil, key) == 1 else {
            throw HostTLSIdentityError.signingFailed
        }
        let bytes = [UInt8](message)
        var length = 0
        guard EVP_DigestSign(context, nil, &length, bytes, bytes.count) == 1 else {
            throw HostTLSIdentityError.signingFailed
        }
        var signature = [UInt8](repeating: 0, count: length)
        guard EVP_DigestSign(context, &signature, &length, bytes, bytes.count) == 1 else {
            throw HostTLSIdentityError.signingFailed
        }
        return Data(signature.prefix(length))
    }
}
#endif
