import Foundation

public enum SensoriumCryptoError: Error, Equatable {
    case invalidKey
    case signingFailed
}

/// The one place this project asks for cryptography, so that every platform
/// it runs on needs a single backend rather than one per call site.
///
/// Ed25519 keys and signatures cross the wire and sit in files written by one
/// machine and read by another, so every backend speaks the same raw
/// encodings: a 32-byte private key, a 32-byte public key, and a 64-byte
/// signature, exactly as RFC 8032 defines them.
public enum SensoriumCrypto {}
