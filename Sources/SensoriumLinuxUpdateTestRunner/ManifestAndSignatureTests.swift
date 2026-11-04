import Foundation
import SensoriumCore
import SensoriumLinuxUpdate

func testManifestParsesTheDesignShape() {
    let manifest = try? LinuxUpdateManifest.parse(serialized(sampleManifestObject(version: "0.6.0")))
    expect(manifest?.version == LinuxUpdateVersion("0.6.0"), "the manifest's version parses")
    expect(manifest?.file == "Sensorium-0.6.0-linux-x86_64.tar.gz", "the manifest's file parses")
    expect(manifest?.size == 4_194_304, "the manifest's size parses")
    expect(manifest?.sha256 == sampleDigest, "the manifest's digest parses")
    expect(
        LinuxUpdateManifest.archiveFileName(for: LinuxUpdateVersion("1.2.3")!) == "Sensorium-1.2.3-linux-x86_64.tar.gz",
        "the release file is named from the version alone"
    )

    var extra = sampleManifestObject()
    extra["notes"] = "a field a later release may add"
    expect((try? LinuxUpdateManifest.parse(serialized(extra))) != nil, "a field this viewer does not read is ignored")
}

func testManifestRefusesEveryMalformedField() {
    func refusal(_ object: [String: Any]) -> LinuxUpdateManifestError? {
        do {
            _ = try LinuxUpdateManifest.parse(serialized(object))
            return nil
        } catch let error as LinuxUpdateManifestError {
            return error
        } catch {
            return nil
        }
    }
    func setting(_ field: String, to value: Any?) -> [String: Any] {
        var object = sampleManifestObject()
        object[field] = value
        return object
    }

    expect((try? LinuxUpdateManifest.parse(Data("not json".utf8))) == nil, "bytes that are not JSON are refused")
    do {
        _ = try LinuxUpdateManifest.parse(Data("[1]".utf8))
        expect(false, "a JSON array is refused")
    } catch {
        expect(error as? LinuxUpdateManifestError == .notJSON, "a JSON array is not a manifest")
    }

    expect(refusal(setting("format", to: 2)) == .unsupportedFormat, "format 2 is a format this viewer does not read")
    expect(
        refusal(["format": 2, "anything": "else"]) == .unsupportedFormat,
        "a later format is recognised as such even when its other fields changed shape"
    )
    expect(refusal(setting("format", to: nil)) == .notJSON, "a manifest with no format is refused")
    expect(refusal(setting("format", to: "1")) == .notJSON, "a format written as text is refused")

    for bad in ["0.6", "0.06.0", "v0.6.0", ""] {
        expect(refusal(setting("version", to: bad)) == .invalidVersion, "version \"\(bad)\" is refused")
    }
    expect(refusal(setting("version", to: nil)) == .notJSON, "a manifest with no version is refused")

    for bad in [
        "Sensorium-0.6.1-linux-x86_64.tar.gz",
        "Sensorium-0.6.0-linux-aarch64.tar.gz",
        "Sensorium-0.6.0.zip",
        "../Sensorium-0.6.0-linux-x86_64.tar.gz",
        "dir/Sensorium-0.6.0-linux-x86_64.tar.gz",
        "Sensorium-0.6.0-linux-x86_64.tar.gz ",
        "https://example.invalid/Sensorium-0.6.0-linux-x86_64.tar.gz",
        ""
    ] {
        expect(refusal(setting("file", to: bad)) == .invalidFile, "file \"\(bad)\" is refused")
    }

    for bad: Int64 in [0, -1, LinuxUpdateManifest.maximumArchiveSize + 1] {
        expect(refusal(setting("size", to: bad)) == .invalidSize, "size \(bad) is refused")
    }
    expect(refusal(setting("size", to: LinuxUpdateManifest.maximumArchiveSize)) == nil, "the largest allowed size is accepted")
    expect(refusal(setting("size", to: "4194304")) == .notJSON, "a size written as text is refused")

    for bad in [
        String(repeating: "AB", count: 32),
        String(repeating: "ab", count: 31),
        String(repeating: "ab", count: 33),
        String(repeating: "ag", count: 32),
        String(repeating: "ab", count: 31) + "a ",
        ""
    ] {
        expect(refusal(setting("sha256", to: bad)) == .invalidDigest, "sha256 \"\(bad)\" is refused")
    }
}

func linuxSignatureFile(signing manifest: Data, with privateKey: Data, trailingNewline: Bool = true) -> Data {
    let signature = try! SensoriumCrypto.ed25519Sign(privateKey: privateKey, message: manifest)
    return Data((signature.base64EncodedString() + (trailingNewline ? "\n" : "")).utf8)
}

func testSignatureVerifiesOnlyTheExactBytesWithTheRightKey() {
    let privateKey = SensoriumCrypto.ed25519GeneratePrivateKey()
    let publicKey = try! SensoriumCrypto.ed25519PublicKey(privateKey: privateKey)
    let manifest = serialized(sampleManifestObject())

    expect(
        LinuxUpdateSignature.isValid(signatureFile: linuxSignatureFile(signing: manifest, with: privateKey), for: manifest, publicKey: publicKey),
        "a signature over the exact bytes verifies"
    )
    expect(
        LinuxUpdateSignature.isValid(
            signatureFile: linuxSignatureFile(signing: manifest, with: privateKey, trailingNewline: false),
            for: manifest,
            publicKey: publicKey
        ),
        "a signature file with no trailing newline verifies"
    )

    var tampered = manifest
    tampered[tampered.count / 2] ^= 0x01
    expect(
        !LinuxUpdateSignature.isValid(signatureFile: linuxSignatureFile(signing: manifest, with: privateKey), for: tampered, publicKey: publicKey),
        "one changed byte in the manifest fails verification"
    )
    expect(
        !LinuxUpdateSignature.isValid(
            signatureFile: linuxSignatureFile(signing: manifest, with: SensoriumCrypto.ed25519GeneratePrivateKey()),
            for: manifest,
            publicKey: publicKey
        ),
        "a signature made with another key fails"
    )

    let raw = try! SensoriumCrypto.ed25519Sign(privateKey: privateKey, message: manifest)
    expect(
        !LinuxUpdateSignature.isValid(signatureFile: raw, for: manifest, publicKey: publicKey),
        "the raw 64 signature bytes are not the release's signature file format"
    )
    let encoded = raw.base64EncodedString()
    let twoLines = Data((String(encoded.prefix(40)) + "\n" + String(encoded.dropFirst(40)) + "\n").utf8)
    expect(
        !LinuxUpdateSignature.isValid(signatureFile: twoLines, for: manifest, publicKey: publicKey),
        "a signature split over two lines is refused"
    )
    expect(
        !LinuxUpdateSignature.isValid(signatureFile: Data((raw.prefix(63).base64EncodedString() + "\n").utf8), for: manifest, publicKey: publicKey),
        "a signature of 63 bytes is refused"
    )
    let padded = Data((encoded + "\n" + String(repeating: " ", count: 200)).utf8)
    expect(
        !LinuxUpdateSignature.isValid(signatureFile: padded, for: manifest, publicKey: publicKey),
        "a signature file past the size cap is refused"
    )
    expect(
        !LinuxUpdateSignature.isValid(
            signatureFile: linuxSignatureFile(signing: manifest, with: privateKey),
            for: manifest,
            publicKey: publicKey.prefix(31)
        ),
        "a public key that is not 32 bytes verifies nothing"
    )
}

func testCompiledPublicKeyIsAKeyAndRejectsAFreshSigner() {
    expect(LinuxUpdatePublicKey.rawRepresentation.count == 32, "the compiled key is 32 bytes")
    let manifest = serialized(sampleManifestObject())
    expect(
        !LinuxUpdateSignature.isValid(
            signatureFile: linuxSignatureFile(signing: manifest, with: SensoriumCrypto.ed25519GeneratePrivateKey()),
            for: manifest
        ),
        "the compiled key does not accept a signature from a key made here"
    )
}

/// The Linux viewer trusts the same update key as the macOS apps. Both copies
/// of the key are compiled in, so this reads the macOS copy's source.
func testCompiledPublicKeyMatchesTheMacOSUpdater() {
    let macOSKeyFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SensoriumUpdate/UpdatePublicKey.swift")
    guard let source = try? String(contentsOf: macOSKeyFile, encoding: .utf8) else {
        expect(false, "the macOS update key's source is readable at \(macOSKeyFile.path)")
        return
    }
    let marker = "public static let base64 = \""
    guard let start = source.range(of: marker),
          let end = source[start.upperBound...].firstIndex(of: "\"") else {
        expect(false, "the macOS update key's source declares `\(marker)...\"`")
        return
    }
    let macOSKey = String(source[start.upperBound..<end])
    expect(
        macOSKey == LinuxUpdatePublicKey.base64,
        "the Linux viewer's update key equals the macOS apps' key; change both together"
    )
}
