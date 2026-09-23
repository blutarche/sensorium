import Foundation

public enum DeviceIdentityError: Error, Equatable {
    case invalidPrivateKey
}

public struct DeviceIdentity: Sendable {
    private let privateKeyData: Data
    public let publicKey: Data

    public static func generate() throws -> DeviceIdentity {
        let privateKeyData = SensoriumCrypto.ed25519GeneratePrivateKey()
        return DeviceIdentity(
            privateKeyData: privateKeyData,
            publicKey: try SensoriumCrypto.ed25519PublicKey(privateKey: privateKeyData)
        )
    }

    public init(privateKeyData: Data) throws {
        guard let publicKey = try? SensoriumCrypto.ed25519PublicKey(privateKey: privateKeyData) else {
            throw DeviceIdentityError.invalidPrivateKey
        }
        self.privateKeyData = privateKeyData
        self.publicKey = publicKey
    }

    private init(privateKeyData: Data, publicKey: Data) {
        self.privateKeyData = privateKeyData
        self.publicKey = publicKey
    }

    public func sign(_ message: Data) throws -> Data {
        try SensoriumCrypto.ed25519Sign(privateKey: privateKeyData, message: message)
    }

    internal func privateKeyDataForStorage() -> Data {
        privateKeyData
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        SensoriumCrypto.ed25519Verify(signature: signature, message: message, publicKey: publicKey)
    }
}
