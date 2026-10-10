import Foundation
import Security
import SensoriumCore

/// `--update-self-test`, run by an older host on a newly downloaded version
/// before installing it: can this version read what the host serves with?
///
/// Reads only. The stores' own `loadOrCreate()` would make a key that is
/// missing and delete what an interrupted write left behind, so each file is
/// decoded here instead, in the shape its store writes. Binds nothing,
/// shows nothing.
public enum HostUpdateSelfTest {
    public struct Files: Sendable {
        public var deviceIdentity: URL
        public var tlsIdentity: URL
        public var approvedDevices: URL

        public init(deviceIdentity: URL, tlsIdentity: URL, approvedDevices: URL) {
            self.deviceIdentity = deviceIdentity
            self.tlsIdentity = tlsIdentity
            self.approvedDevices = approvedDevices
        }
    }

    /// 0 when every file that exists reads back, 1 when one does not. A
    /// missing file is a host that has not made it yet, which the running
    /// version would make the same way.
    public static func run(_ files: Files, report: (String) -> Void = { print("Sensorium host update self-test: \($0)") }) -> Int32 {
        let checks: [(URL, (Data) -> Bool)] = [
            (files.deviceIdentity, readsAsDeviceIdentity),
            (files.tlsIdentity, readsAsTLSIdentity),
            (files.approvedDevices, readsAsApprovedDevices)
        ]
        var status: Int32 = 0
        for (url, reads) in checks where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), reads(data) else {
                report("\(url.lastPathComponent) could not be read")
                status = 1
                continue
            }
        }
        return status
    }

    /// `FileDeviceIdentityStore`'s shape.
    private static func readsAsDeviceIdentity(_ data: Data) -> Bool {
        struct Stored: Decodable {
            let privateKey: String
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let key = Data(base64Encoded: stored.privateKey) else {
            return false
        }
        return (try? DeviceIdentity(privateKeyData: key)) != nil
    }

    /// `FileHostTLSIdentityStore`'s shape, checked as far as the listener
    /// would use it: a certificate, a P-256 private key, and an identity made
    /// from the two, all in memory.
    private static func readsAsTLSIdentity(_ data: Data) -> Bool {
        struct Stored: Decodable {
            let certificateDER: String
            let privateKey: String
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let certificateDER = Data(base64Encoded: stored.certificateDER),
              let keyData = Data(base64Encoded: stored.privateKey),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            return false
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        return SecIdentityCreate(nil, certificate, key) != nil
    }

    /// `FileApprovedDeviceStore`'s shape, or the plain list of keys an older
    /// build wrote. The store itself reads an unreadable file as no paired
    /// machines at all, which is exactly what an update must not do.
    private static func readsAsApprovedDevices(_ data: Data) -> Bool {
        struct Stored: Decodable {
            let publicKey: String
        }
        let keys: [String]
        if let devices = try? JSONDecoder().decode([Stored].self, from: data) {
            keys = devices.map(\.publicKey)
        } else if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            keys = legacy
        } else {
            return false
        }
        return keys.allSatisfy { Data(base64Encoded: $0) != nil }
    }
}
