import CryptoKit
import Foundation

public enum DeviceIdentityError: Error, Equatable {
    case invalidPrivateKey
}

public struct DeviceIdentity: Sendable {
    private let privateKeyData: Data
    public let publicKey: Data

    public static func generate() throws -> DeviceIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return DeviceIdentity(privateKeyData: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    public init(privateKeyData: Data) throws {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            throw DeviceIdentityError.invalidPrivateKey
        }
        self.privateKeyData = privateKeyData
        publicKey = key.publicKey.rawRepresentation
    }

    private init(privateKeyData: Data, publicKey: Data) {
        self.privateKeyData = privateKeyData
        self.publicKey = publicKey
    }

    public func sign(_ message: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return try key.signature(for: message)
    }

    internal func privateKeyDataForStorage() -> Data {
        privateKeyData
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}
