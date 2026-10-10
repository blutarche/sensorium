#if os(macOS)
import CryptoKit
import Foundation
import SensoriumUpdate

func signatureFile(signing manifest: Data, with key: Curve25519.Signing.PrivateKey, trailingNewline: Bool = true) -> Data {
    let signature = try! key.signature(for: manifest)
    return Data((signature.base64EncodedString() + (trailingNewline ? "\n" : "")).utf8)
}

func testSignatureVerifiesOnlyTheExactBytesWithTheRightKey() {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation
    let manifest = serialized(sampleManifestObject())

    expect(
        UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: key), for: manifest, publicKey: publicKey),
        "a signature over the exact bytes verifies"
    )
    expect(
        UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: key, trailingNewline: false), for: manifest, publicKey: publicKey),
        "a signature file with no trailing newline verifies"
    )

    var tampered = manifest
    tampered[tampered.count / 2] ^= 0x01
    expect(
        !UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: key), for: tampered, publicKey: publicKey),
        "one changed byte in the manifest fails verification"
    )

    let otherKey = Curve25519.Signing.PrivateKey()
    expect(
        !UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: otherKey), for: manifest, publicKey: publicKey),
        "a signature made with another key fails"
    )

    let raw = try! key.signature(for: manifest)
    expect(
        !UpdateSignature.isValid(signatureFile: raw, for: manifest, publicKey: publicKey),
        "the raw 64 signature bytes are not the release's signature file format"
    )
    let split = raw.base64EncodedString()
    let twoLines = Data((String(split.prefix(40)) + "\n" + String(split.dropFirst(40)) + "\n").utf8)
    expect(
        !UpdateSignature.isValid(signatureFile: twoLines, for: manifest, publicKey: publicKey),
        "a signature split over two lines is refused"
    )
    expect(
        !UpdateSignature.isValid(signatureFile: Data((raw.prefix(63).base64EncodedString() + "\n").utf8), for: manifest, publicKey: publicKey),
        "a signature of 63 bytes is refused"
    )
    expect(
        !UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: key), for: manifest, publicKey: publicKey.prefix(31)),
        "a public key that is not 32 bytes verifies nothing"
    )
}

func testCompiledPublicKeyIsAKeyAndRejectsAFreshSigner() {
    expect(UpdatePublicKey.rawRepresentation.count == 32, "the compiled key is 32 bytes")
    expect(
        (try? Curve25519.Signing.PublicKey(rawRepresentation: UpdatePublicKey.rawRepresentation)) != nil,
        "the compiled key is a valid Ed25519 public key"
    )
    let manifest = serialized(sampleManifestObject())
    expect(
        !UpdateSignature.isValid(signatureFile: signatureFile(signing: manifest, with: Curve25519.Signing.PrivateKey()), for: manifest),
        "the compiled key does not accept a signature from a key made here"
    )
}
#endif
