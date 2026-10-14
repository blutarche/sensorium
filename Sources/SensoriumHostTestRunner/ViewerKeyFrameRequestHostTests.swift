import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// A viewer that asks for its own key frames says so once, and then asks per
/// surface. The host takes either only from an authenticated connection, and
/// passes a request to the send path only for a surface it is streaming.
@MainActor
func runViewerKeyFrameRequestHostTests() async {
    do {
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try controller.handle(.viewerKeyFrameRecovery) },
            "an unauthenticated peer cannot change how often the host sends key frames"
        )
        expect(!controller.viewerDeclaredKeyFrameRecovery, "and a refused declaration is not recorded")
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try controller.handle(.keyFrameRequest(surfaceID: 0)) },
            "an unauthenticated peer cannot ask for a key frame"
        )
    }

    do {
        let media = FakeCanvasMedia()
        let sink = FakeVideoSink()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(media),
            videoSink: sink
        )
        expect(!controller.viewerDeclaredKeyFrameRecovery, "a viewer that declared nothing has declared nothing")
        let reply = try! await coordinator.handleWritingResponse(.keyFrameRequest(surfaceID: 0))
        expect(reply == nil, "a key-frame request has no reply")
        expect(sink.viewerKeyFrameRequests.isEmpty, "a request before anything streams is ignored")

        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        _ = try! await coordinator.handleWritingResponse(.keyFrameRequest(surfaceID: 0))
        expect(
            sink.viewerKeyFrameRequests == [CanvasSurfaceID.allCases[0]],
            "a request for the streaming canvas reaches the send path, got \(sink.viewerKeyFrameRequests)"
        )
        _ = try! await coordinator.handleWritingResponse(.keyFrameRequest(surfaceID: 1))
        _ = try! await coordinator.handleWritingResponse(.keyFrameRequest(surfaceID: 7))
        expect(
            sink.viewerKeyFrameRequests.count == 1,
            "a request for a surface that is not streaming, or that cannot exist, is ignored, got \(sink.viewerKeyFrameRequests)"
        )

        let declared = try! await coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        expect(declared == nil, "a declaration has no reply")
        expect(
            controller.viewerDeclaredKeyFrameRecovery,
            "a declaration is taken even after the target was requested"
        )
    }

    do {
        let sink = FakeVideoSink()
        let fixture = makeHostScreenPreferenceFixture(videoSink: sink) { _, _ in FakeScalableCanvasMedia() }
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenRequest(token: hostScreenPreferenceToken(fixture.controller), resumeTicket: nil)
        )
        _ = try! await fixture.coordinator.handleWritingResponse(.keyFrameRequest(surfaceID: 0))
        expect(
            sink.viewerKeyFrameRequests == [CanvasSurfaceID.allCases[0]],
            "a request for the host screen reaches the send path under the surface it streams on, "
                + "got \(sink.viewerKeyFrameRequests)"
        )
    }

    print("PASS: the host takes a key-frame declaration and requests only from an authenticated viewer, and only for a surface it streams")
}
