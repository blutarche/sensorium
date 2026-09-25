import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// `SessionMetricStage.inputRoundTrip`'s host half: `.input`'s own
/// `sequence` tag, and the `.inputApplied` reply this controller sends only
/// once the named event has actually reached `InputInjecting.inject(_:)`.
/// Never for an event this controller refused, suppressed, or never
/// injected at all -- a refusal is already reported another way (a thrown
/// `HostSessionControllerError`, or a dropped key `keyConfinementDropCount`
/// already counts) and is not a round trip worth measuring.
@MainActor
private func hostScreenTestDisplay(id: UInt32 = 7) -> DisplaySnapshot {
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

private final class AlwaysIdleInputRoundTripSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
func runInputRoundTripTests() async {
    do {
        // A tagged, successfully injected event is acknowledged
        let injector = FakeInputInjector()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: injector,
            keyConfinement: .unconfined
        )
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))

        let reply = try! controller.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil, sequence: 1))
        expect(
            reply == .inputApplied(sequence: 1),
            "a tagged event that actually injects is acknowledged with its own sequence, only after injection"
        )
        expect(injector.events == [.pointerMoved(x: 10, y: 20)], "the event was actually injected before the reply was built")

        // An untagged event (an old client) gets no reply
        let untaggedReply = try! controller.handle(.input(.pointerMoved(x: 11, y: 21), surfaceID: nil))
        expect(untaggedReply == nil, "an input event carrying no sequence gets no inputApplied reply")

        // Each tagged event gets exactly its own reply -- no coalescing
        let firstReply = try! controller.handle(.input(.pointerMoved(x: 30, y: 30), surfaceID: nil, sequence: 5))
        let secondReply = try! controller.handle(.input(.pointerMoved(x: 31, y: 31), surfaceID: nil, sequence: 6))
        expect(
            firstReply == .inputApplied(sequence: 5) && secondReply == .inputApplied(sequence: 6),
            "successive tagged events are each acknowledged individually, one reply per input"
        )

        // releaseAllInput never calls inject, so it is never acknowledged
        let releaseReply = try! controller.handle(.input(.releaseAllInput, surfaceID: nil, sequence: 9))
        expect(releaseReply == nil, "releaseAllInput never reaches the injector, so a tag on it still gets no reply")

        print("PASS: tagged input is acknowledged once per injection, and an untagged or uninjected event gets no reply")
    }

    do {
        // An event the host refuses to inject (no Accessibility) is never acknowledged
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expectThrows(
            HostSessionControllerError.inputInjectionUnavailable,
            { _ = try controller.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil, sequence: 1)) },
            "an event the host cannot inject throws rather than answering with an acknowledgement"
        )

        print("PASS: an input the host refuses to inject is never acknowledged")
    }

    do {
        // A key the confinement gate drops is never acknowledged either
        let droppedInjector = FakeInputInjector()
        let droppedController = HostSessionController(
            sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
            inputInjector: droppedInjector,
            keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                surface0: FakeCanvasWorkspace(),
                surface1: NoCanvasWorkspace()
            ))
        )
        _ = try! droppedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let droppedReply = try! droppedController.handle(
            .input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil, sequence: 3)
        )
        expect(droppedReply == nil, "a key the confinement gate drops before it reaches the injector gets no acknowledgement")
        expect(droppedInjector.events.isEmpty, "the dropped key really was never injected")

        print("PASS: a key the confinement gate drops is never acknowledged")
    }

    do {
        // A tagged event against the host-screen surface is acknowledged the same way
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date()
            )
        ])
        let injectorFactory = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceActivitySignal: AlwaysIdleInputRoundTripSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "the fixture's offer names at least one display")
            return
        }
        let hostScreenReady = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            resumeTicket: nil
        ))
        guard case .hostScreenReady = hostScreenReady else {
            expect(false, "the host-screen request is admitted normally")
            return
        }

        let reply = try! controller.handle(.input(.pointerMoved(x: 100, y: 100), surfaceID: nil, sequence: 42))
        expect(reply == .inputApplied(sequence: 42), "a host-screen session acknowledges a tagged, actually-injected event the same way a canvas one does")

        let releaseReply = try! controller.handle(.input(.releaseAllInput, surfaceID: nil, sequence: 43))
        expect(releaseReply == nil, "a host-screen releaseAllInput is never acknowledged, matching the canvas path")

        print("PASS: a host-screen session's tagged input is acknowledged the same way a canvas session's is")
    }
}
