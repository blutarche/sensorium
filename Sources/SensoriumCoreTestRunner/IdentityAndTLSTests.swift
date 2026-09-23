import Foundation
import SensoriumCore

func testDeviceIdentitySignsAndVerifiesHandshakeTranscript() {
    let identity = try! DeviceIdentity.generate()
    let transcript = Data("sensorium-handshake-v1".utf8)
    let signature = try! identity.sign(transcript)
    expect(
        DeviceIdentity.verify(signature: signature, message: transcript, publicKey: identity.publicKey),
        "device identity verifies its handshake signature"
    )
    expect(
        !DeviceIdentity.verify(signature: signature, message: Data("tampered".utf8), publicKey: identity.publicKey),
        "device identity rejects a tampered handshake"
    )
}

func testFileIdentityStorePersistsAndIsOwnerOnly() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-identity-test-\(UUID().uuidString)")
        .appendingPathComponent("identity.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = FileDeviceIdentityStore(url: url)
    let created = try! store.loadOrCreate()
    let reloaded = try! store.loadOrCreate()
    expect(created.publicKey == reloaded.publicKey, "a file-backed identity is stable across loads")

    let permissions = try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
    expect(
        permissions.int16Value & 0o077 == 0,
        "a private key on disk is readable only by its owner"
    )
}

/// A file that cannot be parsed is the one case where generating a
/// replacement silently would cost the person their pairing without ever
/// saying so. It is refused instead, and the failure screen offers the
/// replacement as a choice.
func testFileDeviceIdentityStoreRefusesACorruptFileRatherThanReplacingIt() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-identity-corrupt-test-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("identity.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let corrupt = Data("this is not an identity".utf8)
    try! corrupt.write(to: url)

    do {
        _ = try FileDeviceIdentityStore(url: url).loadOrCreate()
        expect(false, "a corrupt identity file is refused rather than loaded")
    } catch {
        expect(
            error as? FileDeviceIdentityStoreError == .invalidStoredValue,
            "a corrupt identity file is refused as an invalid stored value"
        )
    }
    expect(
        (try? Data(contentsOf: url)) == corrupt,
        "a refused identity file is left exactly as it was, never overwritten with a fresh key"
    )
}
