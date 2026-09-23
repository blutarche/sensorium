import Foundation

#if canImport(Security)
import Security
#endif

public enum HostTLSIdentityError: Error, Equatable {
    case keyGenerationFailed
    case publicKeyUnavailable
    case signingFailed
    case invalidCertificate
    case identityCreationFailed
}

/// A per-host, self-signed TLS credential for Network.framework QUIC.
///
/// This is deliberately separate from `DeviceIdentity`: TLS requires an X.509
/// certificate and P-256 signing key, whereas application pairing uses Ed25519.
/// The pairing ceremony pins `certificateHash` alongside the host device key.
public struct HostTLSIdentity: Sendable {
    public let certificateDER: Data
    public let certificateHash: Data
    let privateKeyData: Data

    init(certificateDER: Data, privateKeyData: Data) {
        self.certificateDER = certificateDER
        certificateHash = Self.certificateHash(for: certificateDER)
        self.privateKeyData = privateKeyData
    }

    #if canImport(Security)
    public static func generate(commonName: String) throws -> HostTLSIdentity {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw HostTLSIdentityError.publicKeyUnavailable
        }
        guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw HostTLSIdentityError.keyGenerationFailed
        }

        let tbsCertificate = Self.tbsCertificate(
            commonName: commonName,
            publicKeyData: publicKeyData
        )
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            throw HostTLSIdentityError.signingFailed
        }
        let certificate = DER.sequence([
            tbsCertificate,
            Self.ecdsaWithSHA256Algorithm,
            DER.bitString(signature)
        ])
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
            throw HostTLSIdentityError.signingFailed
        }
        return HostTLSIdentity(
            certificateDER: certificate,
            privateKeyData: privateKeyData
        )
    }
    #else
    /// A platform whose keys and certificates this project does not know how
    /// to mint yet. Reading a certificate pin works everywhere; making one
    /// does not.
    public static func generate(commonName: String) throws -> HostTLSIdentity {
        throw HostTLSIdentityError.keyGenerationFailed
    }
    #endif

    public static func certificateHash(for certificateDER: Data) -> Data {
        SensoriumCrypto.sha256(certificateDER)
    }

    #if canImport(Security)
    func makePrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error) else {
            throw HostTLSIdentityError.keyGenerationFailed
        }
        return key
    }

    public func makeSecIdentity() throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw HostTLSIdentityError.invalidCertificate
        }
        guard let identity = SecIdentityCreate(nil, certificate, try makePrivateKey()) else {
            throw HostTLSIdentityError.identityCreationFailed
        }
        return identity
    }
    #endif

    private static func tbsCertificate(commonName: String, publicKeyData: Data) -> Data {
        let serial = SensoriumCrypto.randomBytes(16)
        let subject = DER.name(commonName)
        let validity = DER.sequence([
            DER.generalizedTime(Date().addingTimeInterval(-60)),
            DER.generalizedTime(Date().addingTimeInterval(60 * 60 * 24 * 365 * 10))
        ])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([
                DER.oid("1.2.840.10045.2.1"),
                DER.oid("1.2.840.10045.3.1.7")
            ]),
            DER.bitString(publicKeyData)
        ])
        let extensions = DER.explicit(tag: 3, value: DER.sequence([
            DER.extensionValue(
                oid: "2.5.29.19",
                critical: true,
                value: DER.sequence([])
            ),
            DER.extensionValue(
                oid: "2.5.29.15",
                critical: true,
                value: DER.bitString(Data([0x80]), unusedBits: 7)
            ),
            DER.extensionValue(
                oid: "2.5.29.37",
                critical: false,
                value: DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])
            )
        ]))
        return DER.sequence([
            DER.explicit(tag: 0, value: DER.integer(2)),
            DER.integer(serial),
            ecdsaWithSHA256Algorithm,
            subject,
            validity,
            subject,
            subjectPublicKeyInfo,
            extensions
        ])
    }

    private static let ecdsaWithSHA256Algorithm = DER.sequence([
        DER.oid("1.2.840.10045.4.3.2")
    ])
}

private enum DER {
    static func sequence(_ values: [Data]) -> Data { tagged(0x30, values.reduce(into: Data(), { $0.append($1) })) }
    static func set(_ values: [Data]) -> Data { tagged(0x31, values.reduce(into: Data(), { $0.append($1) })) }
    static func explicit(tag: UInt8, value: Data) -> Data { tagged(0xA0 | tag, value) }
    static func utf8String(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }
    static func generalizedTime(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tagged(0x18, Data(formatter.string(from: value).utf8))
    }
    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0x00])) }
    static func octetString(_ value: Data) -> Data { tagged(0x04, value) }
    static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
        tagged(0x03, Data([unusedBits]) + value)
    }
    static func integer(_ value: Int) -> Data {
        var bytes = withUnsafeBytes(of: UInt64(value).bigEndian, Array.init)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }
    static func integer(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }
    static func oid(_ value: String) -> Data {
        let arcs = value.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2 && arcs[0] <= 2 && arcs[1] < 40)
        var bytes = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var encoded = [UInt8(arc & 0x7F)]
            var remainder = arc >> 7
            while remainder > 0 {
                encoded.insert(UInt8(remainder & 0x7F) | 0x80, at: 0)
                remainder >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return tagged(0x06, Data(bytes))
    }
    static func name(_ commonName: String) -> Data {
        sequence([set([sequence([oid("2.5.4.3"), utf8String(commonName)])])])
    }
    static func extensionValue(oid: String, critical: Bool, value: Data) -> Data {
        var fields = [self.oid(oid)]
        if critical { fields.append(boolean(true)) }
        fields.append(octetString(value))
        return sequence(fields)
    }
    static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + length(value.count) + value
    }
    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var bytes = withUnsafeBytes(of: UInt64(count).bigEndian, Array.init)
        while bytes.first == 0 { bytes.removeFirst() }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
