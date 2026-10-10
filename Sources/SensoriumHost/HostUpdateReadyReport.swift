import CryptoKit
import Foundation
import SensoriumUpdate

/// What one listener ready tells: the tailnet address it was started for,
/// the port it bound, and the certificate it serves.
public struct HostListenerReady: Equatable, Sendable {
    public var address: String
    public var port: UInt16
    public var certificateHash: Data

    public init(address: String, port: UInt16, certificateHash: Data) {
        self.address = address
        self.port = port
        self.certificateHash = certificateHash
    }
}

/// How the listener serves, as an update's ready report carries it.
public struct HostListeningValues: Equatable, Sendable {
    public var tailnetAddress: String
    public var port: UInt16
    /// Nil when the listener is on every interface.
    public var interfaceName: String?
    public var allowsLocalNetwork: Bool

    public init(tailnetAddress: String, port: UInt16, interfaceName: String?, allowsLocalNetwork: Bool) {
        self.tailnetAddress = tailnetAddress
        self.port = port
        self.interfaceName = interfaceName
        self.allowsLocalNetwork = allowsLocalNetwork
    }

    /// Read the way `HostNetworkListener` chooses: scoped to the interface
    /// that owns the tailnet address unless the local network is allowed.
    public static func current(
        tailnetAddress: String,
        port: UInt16,
        allowsLocalNetwork: Bool,
        interfaceName: (String) -> String? = TailnetInterfaceLocator.interfaceName(owningAddress:)
    ) -> HostListeningValues {
        HostListeningValues(
            tailnetAddress: tailnetAddress,
            port: port,
            interfaceName: allowsLocalNetwork ? nil : interfaceName(tailnetAddress),
            allowsLocalNetwork: allowsLocalNetwork
        )
    }
}

/// Builds the host's update ready report. The old version builds its
/// baseline with this and the new version its report, so the two compare
/// equal exactly when the host serves the same way.
///
/// The fingerprint and digest formats are compared across versions: a
/// release that changed either would be refused by every older one.
public enum HostUpdateReadyReport {
    public static func make(
        version: UpdateVersion,
        permissions: HostPermissionRequestResult,
        loginItemStatus: String,
        certificateHash: Data,
        approvedDeviceKeys: Set<Data>,
        listening: HostListeningValues
    ) -> UpdateReadyReport {
        UpdateReadyReport(
            version: version,
            screenRecordingGranted: permissions.screenCapture == .granted,
            accessibilityGranted: permissions.accessibility == .granted,
            loginItemStatus: loginItemStatus,
            host: UpdateReadyReport.Host(
                identityFingerprint: identityFingerprint(certificateHash: certificateHash),
                pairedMachinesDigest: pairedMachinesDigest(approvedDeviceKeys),
                tailnetAddress: listening.tailnetAddress,
                port: listening.port,
                interfaceName: listening.interfaceName,
                allowsLocalNetwork: listening.allowsLocalNetwork
            )
        )
    }

    /// The TLS certificate hash viewers pin, in lowercase hex.
    public static func identityFingerprint(certificateHash: Data) -> String {
        hex(certificateHash)
    }

    /// SHA-256, in lowercase hex, over every approved key in ascending byte
    /// order, each preceded by its length as four big-endian bytes.
    public static func pairedMachinesDigest(_ keys: Set<Data>) -> String {
        var hasher = SHA256()
        for key in keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let length = UInt32(key.count).bigEndian
            withUnsafeBytes(of: length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: key)
        }
        return hex(Data(hasher.finalize()))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
