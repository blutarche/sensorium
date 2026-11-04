import Foundation

/// The Ed25519 public key every release manifest is signed for, as the
/// base64 of its 32 raw bytes. It is the same key the macOS apps compile in
/// (`Sources/SensoriumUpdate/UpdatePublicKey.swift`), because one update key
/// signs every manifest of a release. The two copies must change together;
/// the Linux update runner fails while they differ.
///
/// A release that changes it is installed by hand once, since the viewers
/// already installed keep trusting the key they were built with.
public enum LinuxUpdatePublicKey {
    public static let base64 = "sOkFVaNfKsyaQ+gTeLxnX0/MOvpQkjjTK3uqTdPYou0="

    public static var rawRepresentation: Data {
        Data(base64Encoded: base64) ?? Data()
    }
}
