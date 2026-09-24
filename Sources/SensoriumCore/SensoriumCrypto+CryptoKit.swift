#if canImport(CryptoKit)
import CryptoKit
import Foundation

public extension SensoriumCrypto {
    static func ed25519GeneratePrivateKey() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    static func ed25519PublicKey(privateKey: Data) throws -> Data {
        try signingKey(privateKey).publicKey.rawRepresentation
    }

    static func ed25519Sign(privateKey: Data, message: Data) throws -> Data {
        let key = try signingKey(privateKey)
        guard let signature = try? key.signature(for: message) else {
            throw SensoriumCryptoError.signingFailed
        }
        return signature
    }

    static func ed25519Verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// `SystemRandomNumberGenerator` is the platform's own cryptographic
    /// generator; Swift documents it as suitable for cryptographic use.
    static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    private static func signingKey(_ privateKey: Data) throws -> Curve25519.Signing.PrivateKey {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw SensoriumCryptoError.invalidKey
        }
        return key
    }
}
#endif
