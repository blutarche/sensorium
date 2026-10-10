#if os(macOS)
import Foundation

/// The Ed25519 public key every release manifest is signed for, as the
/// base64 of its 32 raw bytes. An app accepts an update only when the
/// manifest's signature verifies with this key. A release that changes it
/// is installed by hand once, since the apps already installed keep trusting
/// the key they were built with.
public enum UpdatePublicKey {
    public static let base64 = "sOkFVaNfKsyaQ+gTeLxnX0/MOvpQkjjTK3uqTdPYou0="

    public static var rawRepresentation: Data {
        Data(base64Encoded: base64) ?? Data()
    }
}
#endif
