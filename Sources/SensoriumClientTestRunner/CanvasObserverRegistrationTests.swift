import Foundation
import SensoriumClient
import SensoriumCore

/// The gate every session canvas is behind: a viewport presents nothing until
/// the session it belongs to has been handed that viewport as its canvas
/// observer and has connected.
///
/// A viewer that builds a window and forgets the registration looks entirely
/// healthy -- it connects, it decodes, it reports no drop -- and shows a
/// blank window, because every decoded frame stops at the closed gate. That
/// is a wiring mistake no window can catch for itself, so it is pinned here,
/// with a scripted connection and no compositor, window server or socket.
@MainActor
func testCanvasObserverRegistrationTests() async {
    let unregistered = GatedCanvas()
    let unregisteredSession = ClientSessionController(transport: ScriptedClientTransport(responses: [
        .canvasReady(displayID: 1, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ]))
    _ = try! await unregisteredSession.connect(deviceName: "Laptop")
    await unregistered.viewport.presentDecodedFrame(makeCanvasObserverTestFrame())
    expect(
        await unregistered.presenter.presentedCount == 0,
        "a canvas whose viewport was never registered as the session's observer presents nothing"
    )

    let registered = GatedCanvas()
    let session = ClientSessionController(transport: ScriptedClientTransport(responses: [
        .canvasReady(displayID: 2, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ]))
    await session.setCanvasObserver(registered.viewport)
    _ = try! await session.connect(deviceName: "Laptop")
    await registered.viewport.presentDecodedFrame(makeCanvasObserverTestFrame())
    expect(
        await registered.presenter.presentedCount == 1,
        "a registered viewport presents the first frame of the session it was registered on"
    )

    print("PASS: a decoded frame reaches the presenter only once the session holds that canvas's viewport as its observer")
}

/// One canvas's two halves: the viewport a session registers, and the
/// presenter a frame has to reach.
@MainActor
private final class GatedCanvas {
    let presenter = RecordingFramePresenter()
    let viewport: ClientViewportController

    init() {
        viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: RecordingInputSink(),
            framePresenter: presenter
        )
    }
}

#if canImport(CoreVideo)
private func makeCanvasObserverTestFrame() -> DecodedFrame {
    DecodedFrame(pixelBuffer: makeTestPixelBuffer())
}
#else
/// Stands in for the platform image. Nothing on this path reads it: what is
/// being watched is whether the frame travels at all.
private final class UnreadPicture {}

private func makeCanvasObserverTestFrame() -> DecodedFrame {
    DecodedFrame(payload: UnreadPicture(), width: 1920, height: 1200)
}
#endif
