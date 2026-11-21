#if os(Linux)
import COpenSSL
import Foundation
import SensoriumCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message) }
}

func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-linux-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testIdentityMintsStoresAndLoads() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileHostTLSIdentityStore(
        url: directory.appendingPathComponent("tls.json"),
        commonName: "Sensorium Host"
    )
    let minted = try store.loadOrCreate()
    let loaded = try store.loadOrCreate()
    try require(minted.certificateDER == loaded.certificateDER, "a second load returns the stored certificate")
    try require(
        minted.certificateHash == HostTLSIdentity.certificateHash(for: minted.certificateDER),
        "the pin is the SHA-256 of the DER certificate"
    )

    let credentials = try loaded.makeOpenSSLCredentials()
    defer {
        X509_free(credentials.certificate)
        EVP_PKEY_free(credentials.privateKey)
    }
    try require(
        X509_check_private_key(credentials.certificate, credentials.privateKey) == 1,
        "the stored key belongs to the stored certificate"
    )
    var reencoded: UnsafeMutablePointer<UInt8>?
    let length = i2d_X509(credentials.certificate, &reencoded)
    defer { CRYPTO_free(reencoded, #file, #line) }
    try require(
        length > 0 && reencoded.map { Data(bytes: $0, count: Int(length)) } == minted.certificateDER,
        "the certificate parses and re-encodes to the same bytes"
    )
}
#endif
