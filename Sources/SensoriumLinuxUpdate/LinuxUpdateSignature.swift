import Foundation
import SensoriumCore

/// Checks `sensorium-update-linux-x86_64.json.sig` against the manifest's
/// exact bytes.
public enum LinuxUpdateSignature {
    /// The largest signature file accepted: base64 of 64 bytes is 88
    /// characters, plus a newline.
    static let maximumFileSize = 128

    /// `signatureFile` is the base64 of the 64-byte Ed25519 signature on one
    /// line, with an optional trailing newline. Anything else is refused.
    public static func isValid(
        signatureFile: Data,
        for manifest: Data,
        publicKey: Data = LinuxUpdatePublicKey.rawRepresentation
    ) -> Bool {
        guard signatureFile.count <= maximumFileSize,
              let text = String(data: signatureFile, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64,
              publicKey.count == 32 else {
            return false
        }
        return SensoriumCrypto.ed25519Verify(signature: signature, message: manifest, publicKey: publicKey)
    }
}
