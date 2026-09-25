import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// docs/ux-spec.md: the number of session displays is entirely the
/// viewer's own choice, changeable live. `SensoriumMessage.displayCount`
/// always names the *second* canvas's presence -- the first is whatever an
/// explicit `canvasRequest` for it already established, unaffected by this
/// message. Live bring-up reuses `admitCanvas` and the coordinator's
/// existing `canvasReady` bring-up path with no changes to either; live
/// removal is `tearDownSurfaceLive`.
@MainActor
func runDisplayCountTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]
    let surfaceOne = CanvasSurfaceID.allCases[1]

    do {
        // Live add: the second display comes up mid-session
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let fakeWorkspaces = CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        let events = DiagnosticsRecorder()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined),
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { surface in fakeWorkspaces[surface] },
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(mediaZero.startedDisplayIDs.count == 1, "the first display starts as an ordinary canvasRequest already would")

        let response = try! await coordinator.handleWritingResponse(.displayCount(2))
        guard case let .canvasReady(_, _, _, _, surfaceID, _) = response else {
            expect(false, "displayCount(2) brings the second display up and answers exactly as an explicit canvasRequest for it would")
            return
        }
        expect(surfaceID == surfaceOne.wireValue, "the reply names the second surface")
        expect(mediaOne.startedDisplayIDs.count == 1, "the second display's own media pipeline actually starts")
        expect(fakeWorkspaces[surfaceOne].startedDisplayIDs.count == 1, "the second display's own workspace actually starts")
        expect(mediaZero.startedDisplayIDs.count == 1, "the first display is untouched by bringing the second one up")

        // Idempotent: asking again for the same count changes nothing.
        let repeatResponse = try! await coordinator.handleWritingResponse(.displayCount(2))
        expect(repeatResponse == nil, "asking for a display count already satisfied answers nothing -- there is no change to report")
        expect(mediaOne.startedDisplayIDs.count == 1, "a repeated displayCount(2) never restarts the second display's media")

        print("PASS: displayCount(2) brings the second display up live exactly as an explicit canvasRequest would, and repeats as a no-op")
    }

    do {
        // Live remove: the second display comes down, the first is untouched
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let fakeWorkspaces = CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined),
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { surface in fakeWorkspaces[surface] }
        )
        _ = try! await coordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        expect(mediaOne.startedDisplayIDs.count == 1, "the second display is up before this test's own assertion begins")

        let response = try! await coordinator.handleWritingResponse(.displayCount(1))
        expect(response == nil, "removing a display never fails and needs no reply -- the viewer already knows, having asked for it")
        expect(mediaOne.stopCount == 1, "the second display's media stops")
        expect(fakeWorkspaces[surfaceOne].stopCount == 1, "the second display's workspace stops -- docs/ux-spec.md: removing a display closes that window")
        expect(mediaZero.stopCount == 0, "the first display's media is untouched by removing the second")
        expect(fakeWorkspaces[surfaceZero].stopCount == 0, "the first display's workspace is untouched by removing the second")

        // Idempotent: asking to remove an already-absent display changes nothing further.
        let repeatResponse = try! await coordinator.handleWritingResponse(.displayCount(1))
        expect(repeatResponse == nil, "removing an already-absent display is a no-op, not a repeated stop")
        expect(mediaOne.stopCount == 1, "a repeated displayCount(1) never stops the second display's media twice")

        print("PASS: displayCount(1) takes the second display down live, mid-session, leaving the first untouched, and repeating it is a no-op")
    }

    do {
        // A failed change leaves the session as it was and tells the viewer
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                maxSurfaceCount: 1
            ),
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            videoSink: FakeVideoSink()
        )
        _ = try! await coordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))

        let response = try! await coordinator.handleWritingResponse(.displayCount(2))
        expect(
            response == .canvasRefused(reason: "display-count-exceeds-host-limit", surfaceID: surfaceOne.wireValue),
            "a displayCount that would exceed the host's own cap refuses and tells the viewer why, rather than a silent no-op"
        )
        expect(mediaOne.startedDisplayIDs.isEmpty, "the session is left exactly as it was -- the second display never started")
        expect(mediaZero.startedDisplayIDs.count == 1, "the first display's own session is unaffected by the refused change")

        print("PASS: a displayCount change the host's own cap refuses leaves the session as it was and tells the viewer why")
    }

    do {
        // Mixed sessions stay refused: displayCount on a host-screen-shaped connection
        let identity = try! DeviceIdentity.generate()
        let display = DisplaySnapshot(
            id: 7, pixelWidth: 5120, pixelHeight: 2880, modeWidth: 2560, modeHeight: 1440,
            modePixelWidth: 5120, modePixelHeight: 2880, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            online: true, builtin: false, main: false, vendorNumber: 1552, modelNumber: 40
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey, deviceName: "Probe", armedAt: Date()
            )
        ])
        final class AlwaysIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
            func currentReading() -> HostLocalActivityReading { .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1) }
        }
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, hostCertificateHash: nil)
        _ = try! controller.handle(.authenticatedHello(protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)))
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "the fixture's offer names at least one display")
            return
        }
        let ready = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            resumeTicket: nil
        ))
        guard case .hostScreenReady = ready else {
            expect(false, "the host-screen request is admitted, fixing this connection's shape")
            return
        }

        let response = try! controller.handle(.displayCount(2))
        expect(
            response == .canvasRefused(reason: "host-screen-session-active", surfaceID: surfaceOne.wireValue),
            "a displayCount message on a host-screen-shaped connection refuses the same way a canvasRequest would, never a silent no-op"
        )

        print("PASS: displayCount refuses on a connection a host-screen request already committed")
    }
}
