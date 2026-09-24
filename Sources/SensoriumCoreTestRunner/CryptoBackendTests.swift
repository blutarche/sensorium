import Foundation
import SensoriumCore

/// Turns a lower-case hex string from a published test vector into bytes.
private func bytes(hex: String) -> Data {
    var characters = Array(hex)
    var data = Data()
    while characters.count >= 2 {
        data.append(UInt8(String(characters.removeFirst()) + String(characters.removeFirst()), radix: 16)!)
    }
    return data
}

/// RFC 8032, section 7.1, test vector 1. A round trip alone passes even when
/// a backend is wrong in a way its own verifier agrees with, so the published
/// key and the published signature are what every backend is held to.
///
/// The published signature is checked by verifying it, not by reproducing it:
/// Ed25519 as specified is deterministic, but a backend is free to randomise
/// the nonce it derives, and CryptoKit does.
func testEd25519ReproducesRFC8032TestVector() {
    let privateKey = bytes(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    let expectedPublicKey = bytes(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let expectedSignature = bytes(hex: """
        e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015\
        55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
        """)

    let publicKey = try! SensoriumCrypto.ed25519PublicKey(privateKey: privateKey)
    expect(publicKey == expectedPublicKey, "Ed25519 derives the published public key from the published private key")

    expect(
        SensoriumCrypto.ed25519Verify(signature: expectedSignature, message: Data(), publicKey: expectedPublicKey),
        "Ed25519 verifies the published signature over the empty message"
    )
    let signature = try! SensoriumCrypto.ed25519Sign(privateKey: privateKey, message: Data())
    #if !canImport(CryptoKit)
    expect(signature == expectedSignature, "a backend that derives its nonce as RFC 8032 does reproduces the published signature")
    #endif
    expect(
        SensoriumCrypto.ed25519Verify(signature: signature, message: Data(), publicKey: expectedPublicKey),
        "Ed25519 signs the empty message under the published key"
    )
    expect(
        !SensoriumCrypto.ed25519Verify(signature: expectedSignature, message: Data([0]), publicKey: expectedPublicKey),
        "the published signature does not verify over a different message"
    )
}

func testEd25519RefusesAKeyThatIsNotThirtyTwoBytes() {
    do {
        _ = try SensoriumCrypto.ed25519PublicKey(privateKey: Data(repeating: 0, count: 31))
        expect(false, "a private key of the wrong length is refused")
    } catch {
        expect(
            error as? SensoriumCryptoError == .invalidKey,
            "a private key of the wrong length is refused as an invalid key"
        )
    }
}

func testEd25519SignsVerifiesAndRejectsATamperedSignature() {
    let privateKey = SensoriumCrypto.ed25519GeneratePrivateKey()
    expect(privateKey.count == 32, "a generated Ed25519 private key is 32 bytes")
    let publicKey = try! SensoriumCrypto.ed25519PublicKey(privateKey: privateKey)
    expect(publicKey.count == 32, "an Ed25519 public key is 32 bytes")

    let message = Data("sensorium-crypto-backend".utf8)
    let signature = try! SensoriumCrypto.ed25519Sign(privateKey: privateKey, message: message)
    expect(signature.count == 64, "an Ed25519 signature is 64 bytes")
    expect(
        SensoriumCrypto.ed25519Verify(signature: signature, message: message, publicKey: publicKey),
        "a freshly made Ed25519 signature verifies"
    )

    var flipped = signature
    flipped[0] ^= 0x01
    expect(
        !SensoriumCrypto.ed25519Verify(signature: flipped, message: message, publicKey: publicKey),
        "one flipped bit is enough to fail Ed25519 verification"
    )
    expect(
        !SensoriumCrypto.ed25519Verify(signature: signature, message: Data("tampered".utf8), publicKey: publicKey),
        "a signature does not verify over a different message"
    )
}

func testSHA256ReproducesTheKnownDigestOfABC() {
    expect(
        SensoriumCrypto.sha256(Data("abc".utf8))
            == bytes(hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        "SHA-256 reproduces the published digest of \"abc\""
    )
    expect(SensoriumCrypto.sha256(Data()).count == 32, "a SHA-256 digest is 32 bytes")
}

func testRandomBytesFillsTheRequestedLengthAndDiffers() {
    expect(SensoriumCrypto.randomBytes(0).isEmpty, "asking for no random bytes gives none")
    let first = SensoriumCrypto.randomBytes(32)
    let second = SensoriumCrypto.randomBytes(32)
    expect(first.count == 32 && second.count == 32, "random bytes come back at the requested length")
    expect(first != second, "two draws of 32 random bytes differ")
}
