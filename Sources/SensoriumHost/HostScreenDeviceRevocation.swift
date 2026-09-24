import Foundation

/// Whatever holds the set of paired devices this host admits.
@MainActor
public protocol PairedDeviceRemoving {
    func removeApprovedDevice(_ publicKey: Data)
}

extension HostPairingService: PairedDeviceRemoving {}

/// What turning a device off for host screen, or removing it as a paired
/// device, does to this machine, through the same Stop path the host's own
/// controls use. Turning a device off ends only its live host-screen session.
/// Removing it ends every connection it has, because an authenticated
/// connection is otherwise never checked against pairing again.
@MainActor
public struct HostScreenDeviceRevocation {
    private let armingStore: HostScreenArmingStore
    private let pairedDevices: any PairedDeviceRemoving
    private let liveSessions: any HostScreenLiveSessionRegistering
    private let connections: HostDeviceConnectionRegistry

    public init(
        armingStore: HostScreenArmingStore,
        pairedDevices: any PairedDeviceRemoving,
        liveSessions: any HostScreenLiveSessionRegistering,
        connections: HostDeviceConnectionRegistry
    ) {
        self.armingStore = armingStore
        self.pairedDevices = pairedDevices
        self.liveSessions = liveSessions
        self.connections = connections
    }

    public func turnOff(devicePublicKey: Data) {
        armingStore.disarm(devicePublicKey: devicePublicKey)
        liveSessions.stopSession(for: devicePublicKey)
    }

    /// Removing a paired machine removes its host-screen arming with it.
    public func removePairedDevice(devicePublicKey: Data) {
        pairedDevices.removeApprovedDevice(devicePublicKey)
        armingStore.revoke(devicePublicKey: devicePublicKey)
        connections.stopConnections(for: devicePublicKey)
    }
}
