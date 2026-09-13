import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A host-screen connection's keys must reach the host's own keyboard focus
/// whatever canvas confinement this process was wired with. `sensoriumd`
/// wires one `HostKeyConfinement` for the whole process -- `.confined`, for
/// the canvas connections that own a workspace window -- and a connection
/// that turns out to be a host-screen one has no window to confine a key to
/// (docs/host-screen-design.md §4). A gate keyed on that process-wide wiring
/// rather than on the connection's own shape silently drops every key of a
/// host-screen session, which is the whole of its keyboard.
@MainActor
private func hostScreenKeyInputDisplay(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 3840,
        pixelHeight: 2160,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 3840,
        modePixelHeight: 2160,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 41
    )
}

private final class AlwaysApprovingHostScreenKeyVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    func verify(
        proof: HostScreenPresenceProof,
        devicePublicKey: Data,
        minimumStrength: HostScreenCredentialStrength?,
        challenge: Data
    ) -> Bool {
        true
    }
}

private final class AlwaysIdleHostScreenKeySignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
func runHostScreenKeyInputTests() async {
    do {
        // A host-screen session types, under the canvas confinement sensoriumd wires
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenKeyInputDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [HostScreenDisplayIdentity(display)],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let injectorFactory = FakeInputInjectorFactory()
        // Exactly what `sensoriumd` hands every connection it serves: the
        // canvas workspaces and a window scan. Nothing in that wiring knows
        // yet whether the connection about to arrive is a canvas one or a
        // host-screen one.
        let workspaces = CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
            surface0: FakeCanvasWorkspace(),
            surface1: NoCanvasWorkspace()
        )
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .confined(to: workspaces, scanning: FakeFrontmostWindowScan()),
            hostScreenArmingProvider: { arming },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: AlwaysApprovingHostScreenKeyVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleHostScreenKeySignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Probe",
            publicKey: identity.publicKey,
            signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the fixture's offer names at least one display")
            return
        }
        let ready = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            presence: .signed(
                credentialID: Data([0x01]),
                credentialFormat: "apple-secure-enclave-p256",
                signature: Data([0x02])
            )
        ))
        guard case .hostScreenReady = ready else {
            expect(false, "the host-screen request is admitted normally")
            return
        }

        let downReply = try! controller.handle(
            .input(.key(keyCode: 0, isDown: true, modifiers: []), surfaceID: nil, sequence: 1)
        )
        expect(
            injectorFactory.injector.events == [.key(keyCode: 0, isDown: true, modifiers: [])],
            "a host-screen session's key down is injected even though this process wired canvas confinement"
        )
        expect(
            downReply == .inputApplied(sequence: 1),
            "an injected host-screen key down is acknowledged, not silently dropped"
        )

        let upReply = try! controller.handle(
            .input(.key(keyCode: 0, isDown: false, modifiers: []), surfaceID: nil, sequence: 2)
        )
        expect(
            injectorFactory.injector.events == [
                .key(keyCode: 0, isDown: true, modifiers: []),
                .key(keyCode: 0, isDown: false, modifiers: [])
            ],
            "the matching key up is injected too, so no key is left held on the host's own screen"
        )
        expect(
            upReply == .inputApplied(sequence: 2),
            "the host-screen key up is acknowledged the same way its key down was"
        )
        expect(
            controller.keyConfinementDropCount == 0,
            "no host-screen key was counted as a confinement drop"
        )

        print("PASS: a host-screen session's keys are injected under the canvas confinement sensoriumd wires")
    }

    do {
        // The canvas gate is untouched: a key with no workspace window is still dropped
        let injector = FakeInputInjector()
        let canvasController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: injector,
            keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                surface0: FakeCanvasWorkspace(),
                surface1: NoCanvasWorkspace()
            ))
        )
        _ = try! canvasController.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        let droppedReply = try! canvasController.handle(
            .input(.key(keyCode: 0, isDown: true, modifiers: []), surfaceID: nil, sequence: 3)
        )
        expect(droppedReply == nil, "a canvas connection's key outside a confined window is still dropped")
        expect(injector.events.isEmpty, "the dropped canvas key really never reached the injector")
        expect(canvasController.keyConfinementDropCount == 1, "the canvas drop was counted")

        print("PASS: a canvas session's key confinement is unaffected by host screen")
    }
}
