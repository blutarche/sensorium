import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Design §2.3: once authenticated, an armed device is offered its screens
/// unprompted, and an unarmed device is refused outright -- neither waits to
/// be asked. These prove `HostNetworkSession` itself sends that offer right
/// after a successful `authenticatedHello`, over the real transport loop,
/// not just that `HostSessionController.offerHostScreenList()` computes the
/// right answer when a test calls it directly (already covered by
/// `HostScreenSessionControllerAdmissionTests.swift`).
@MainActor
private func offerOnHelloTestDisplay(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

@MainActor
private func helloScript(for identity: DeviceIdentity, deviceName: String = "Probe") -> SensoriumMessage {
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: deviceName, publicKey: identity.publicKey
    )
    return .authenticatedHello(
        protocolVersion: 1, deviceName: deviceName, publicKey: identity.publicKey,
        signature: try! identity.sign(transcript)
    )
}

private func sentControlMessages(_ channel: FakeHostByteChannel) -> [SensoriumMessage] {
    channel.sentPackets.compactMap {
        guard case let .control(message) = $0 else { return nil }
        return message
    }
}

@MainActor
func runHostScreenOfferOnHelloTests() async {
    armedDeviceCheck: do {
        // Armed device: the list arrives unprompted
        let identity = try! DeviceIdentity.generate()
        let display = offerOnHelloTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [HostScreenDisplayIdentity(display)],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            ),
        ])
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            hostScreenArmingProvider: { arming },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [helloScript(for: identity)])
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.start()
        try! await Task.sleep(for: .milliseconds(200))
        let sent = sentControlMessages(channel)
        expect(sent.count == 1, "the offer is the only thing the host sends an armed device after its hello")
        guard case let .hostScreenList(displays, _) = sent.first else {
            expect(false, "an armed device's hello is answered with hostScreenList, unprompted")
            break armedDeviceCheck
        }
        expect(displays.count == 1, "the offer names the one display this device is armed for")

        print("PASS: an armed device receives hostScreenList unprompted, right after its authenticatedHello")
    }

    do {
        // Unarmed device: refused, never silence
        let identity = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            hostScreenArmingProvider: { HostScreenArming() },
            hostScreenPreSessionSnapshotProvider: { [] },
            hostScreenCurrentDisplaysProvider: { [] }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [helloScript(for: identity)])
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.start()
        try! await Task.sleep(for: .milliseconds(200))
        let sent = sentControlMessages(channel)
        expect(
            sent == [.hostScreenRefused(reason: "host-screen-not-allowed")],
            "an unarmed device is refused outright, unprompted, right after its authenticatedHello"
        )

        print("PASS: an unarmed device receives hostScreenRefused unprompted, right after its authenticatedHello")
    }

    do {
        // The pushed offer never blocks the canvas that follows it
        // design §5.4/§9's one-shape-per-connection gate must not see the
        // offer itself as a shape: a device that ignores the offer and asks
        // for a canvas instead must still get one.
        let identity = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            hostScreenArmingProvider: { HostScreenArming() },
            hostScreenPreSessionSnapshotProvider: { [] },
            hostScreenCurrentDisplaysProvider: { [] }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            helloScript(for: identity),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
        ])
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.start()
        try! await Task.sleep(for: .milliseconds(200))
        let sent = sentControlMessages(channel)
        expect(
            sent.first == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "the pushed offer still comes first"
        )
        expect(
            sent.contains { if case .canvasReady = $0 { return true } else { return false } },
            "a canvas request right after the pushed offer still succeeds -- the offer is not a shape"
        )

        print("PASS: a canvas request following the pushed offer is admitted, not refused as a mixed shape")
    }
}
