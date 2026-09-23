#if canImport(Security)
import Foundation
import SensoriumCore
import Security

/// Both stores write into the same directory, which another store may have
/// created with looser permissions first.
func testFileIdentityStoresTightenTheirDirectoryAndLeaveNoTemporaryFile() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-identity-permissions-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    try! FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )

    let identityURL = directory.appendingPathComponent("device-identity.json")
    let tlsURL = directory.appendingPathComponent("host-tls-identity.json")
    _ = try! FileDeviceIdentityStore(url: identityURL).loadOrCreate()
    _ = try! FileHostTLSIdentityStore(url: tlsURL, commonName: "Sensorium Host").loadOrCreate()

    func mode(of path: String) -> Int16 {
        (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).int16Value
    }

    expect(
        mode(of: directory.path) == 0o700,
        "a directory holding keys is tightened to owner-only even when it already existed"
    )
    expect(mode(of: identityURL.path) == 0o600, "the device key file is owner-read-write only")
    expect(mode(of: tlsURL.path) == 0o600, "the TLS key file is owner-read-write only")

    let contents = try! FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    expect(
        contents == ["device-identity.json", "host-tls-identity.json"],
        "an atomic write leaves no temporary file behind"
    )
}

/// "Make a new key" on both stores: a fresh key lands in the same file and
/// every later load reads it back.
func testFileIdentityStoresReplaceWithAFreshKey() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-identity-replace-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let identityURL = directory.appendingPathComponent("device-identity.json")
    let identityStore = FileDeviceIdentityStore(url: identityURL)
    let firstKey = try! identityStore.loadOrCreate()
    let replacedKey = try! identityStore.replaceWithFreshIdentity()
    expect(firstKey.publicKey != replacedKey.publicKey, "replacing the device key mints a different key")
    expect(
        try! identityStore.loadOrCreate().publicKey == replacedKey.publicKey,
        "the replacement device key is the one later loads read back"
    )

    let tlsURL = directory.appendingPathComponent("host-tls-identity.json")
    let tlsStore = FileHostTLSIdentityStore(url: tlsURL, commonName: "Sensorium Host")
    let firstCertificate = try! tlsStore.loadOrCreate()
    let replacedCertificate = try! tlsStore.replaceWithFreshIdentity()
    expect(
        firstCertificate.certificateHash != replacedCertificate.certificateHash,
        "replacing the TLS identity mints a different certificate"
    )
    expect(
        try! tlsStore.loadOrCreate().certificateHash == replacedCertificate.certificateHash,
        "the replacement TLS certificate is the one later loads read back"
    )

    let permissions = try! FileManager.default.attributesOfItem(atPath: identityURL.path)[.posixPermissions] as! NSNumber
    expect(permissions.int16Value & 0o077 == 0, "a replaced key on disk is still readable only by its owner")
}

func testHostTLSIdentityGeneratesParseableCertificateAndPin() {
    let identity = try! HostTLSIdentity.generate(commonName: "Sensorium Host")
    expect(
        SecCertificateCreateWithData(nil, identity.certificateDER as CFData) != nil,
        "a generated host TLS certificate is parseable by Security.framework"
    )
    expect(identity.certificateHash.count == 32, "a host TLS certificate pin is SHA-256")
    expect(
        identity.certificateHash == HostTLSIdentity.certificateHash(for: identity.certificateDER),
        "the advertised pin binds exactly the generated certificate"
    )
}

func testFileHostTLSIdentityStorePersistsCertificatePinAndPrivateKey() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-tls-test-\(UUID().uuidString)")
        .appendingPathComponent("tls-identity.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = FileHostTLSIdentityStore(url: url, commonName: "Sensorium Host")
    let created = try! store.loadOrCreate()
    let reloaded = try! store.loadOrCreate()
    expect(created.certificateDER == reloaded.certificateDER, "a file-backed TLS certificate survives a host restart")
    expect(created.certificateHash == reloaded.certificateHash, "a persisted TLS certificate keeps its paired pin")
    let secIdentity = try! reloaded.makeSecIdentity()
    var certificate: SecCertificate?
    expect(
        SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess && certificate != nil,
        "a persisted TLS private key recreates a Security identity"
    )
    expect(
        certificate.map { SecCertificateCopyData($0) as Data } == reloaded.certificateDER,
        "the recreated Security identity contains the persisted certificate"
    )

    let permissions = try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
    expect(permissions.int16Value & 0o077 == 0, "a persisted TLS private key is readable only by its owner")
}

/// A stored value that parses as JSON but is not a usable certificate and
/// key is refused, exactly as a corrupt device key file is.
func testFileHostTLSIdentityStoreRefusesAnInvalidStoredValue() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-tls-corrupt-test-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("host-tls-identity.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try! Data("{\"certificateDER\":\"\",\"privateKey\":\"\"}".utf8).write(to: url)

    do {
        _ = try FileHostTLSIdentityStore(url: url, commonName: "Sensorium Host").loadOrCreate()
        expect(false, "an unusable stored TLS value is refused")
    } catch {
        expect(
            error as? FileHostTLSIdentityStoreError == .invalidStoredValue,
            "an unusable stored TLS value is refused as an invalid stored value"
        )
    }
}
#endif
