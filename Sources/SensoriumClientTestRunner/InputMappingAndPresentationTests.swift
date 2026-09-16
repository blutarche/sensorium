import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testInputMappingAndPresentationTests() async {
        let inputMapper = VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200)
        guard inputMapper.map(
                x: 0, y: 0, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
              ) == CanvasInputPoint(x: 0, y: 0),
              inputMapper.map(
                x: 1536, y: 960, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
              ) == CanvasInputPoint(x: 1920, y: 1200),
              inputMapper.map(
                x: -4, y: 1000, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
              ) == CanvasInputPoint(x: 0, y: 1200) else {
            print("FAIL: input mapper did not preserve corners and clamp outside viewport")
            Foundation.exit(1)
        }

        // Regression coverage for the reported resize bug: the destination
        // rect must always be an aspect-preserving SCALE of the whole source,
        // never a 1:1 crop, in every relationship between source and viewport.
        let source = (width: 1920.0, height: 1200.0) // 16:10, matches the canvas.

        // Wider-than-source viewport: bars on the left/right (pillarbox).
        let pillarboxed = CanvasPresentationLayout.videoRect(
            sourceWidth: source.width, sourceHeight: source.height,
            viewportWidth: 2000, viewportHeight: 1000
        )
        guard pillarboxed == CanvasVideoRect(x: 200, y: 0, width: 1600, height: 1000) else {
            print("FAIL: a viewport wider than the source did not pillarbox: \(pillarboxed)")
            Foundation.exit(1)
        }

        // Taller-than-source viewport: bars on the top/bottom (letterbox).
        let letterboxed = CanvasPresentationLayout.videoRect(
            sourceWidth: source.width, sourceHeight: source.height,
            viewportWidth: 1000, viewportHeight: 1000
        )
        guard letterboxed == CanvasVideoRect(x: 0, y: 187.5, width: 1000, height: 625) else {
            print("FAIL: a viewport taller than the source did not letterbox: \(letterboxed)")
            Foundation.exit(1)
        }

        // Exact aspect match: the video fills the viewport with no bars.
        let exactMatch = CanvasPresentationLayout.videoRect(
            sourceWidth: source.width, sourceHeight: source.height,
            viewportWidth: 960, viewportHeight: 600
        )
        guard exactMatch == CanvasVideoRect(x: 0, y: 0, width: 960, height: 600) else {
            print("FAIL: an exact-aspect viewport produced bars: \(exactMatch)")
            Foundation.exit(1)
        }

        // A viewport much smaller than the source, and a different aspect
        // ratio besides: this must still SCALE the whole source down to fit
        // and letterbox the remainder, never crop a source-sized region.
        let shrunk = CanvasPresentationLayout.videoRect(
            sourceWidth: source.width, sourceHeight: source.height,
            viewportWidth: 400, viewportHeight: 400
        )
        guard shrunk == CanvasVideoRect(x: 0, y: 75, width: 400, height: 250) else {
            print("FAIL: a viewport smaller than the source cropped instead of scaling: \(shrunk)")
            Foundation.exit(1)
        }

        // The round trip: a click at the centre of the displayed video lands
        // at the centre of the canvas, at each displayed corner it lands at
        // the corresponding canvas corner, and both hold whether the video is
        // pillarboxed or letterboxed.
        guard inputMapper.map(
                x: 1000, y: 500, sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 960, y: 600),
              inputMapper.map(
                x: pillarboxed.x, y: pillarboxed.y,
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 0, y: 0),
              inputMapper.map(
                x: pillarboxed.x, y: pillarboxed.y + pillarboxed.height,
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 0, y: 1200),
              inputMapper.map(
                x: pillarboxed.x + pillarboxed.width, y: pillarboxed.y,
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 1920, y: 0),
              inputMapper.map(
                x: pillarboxed.x + pillarboxed.width, y: pillarboxed.y + pillarboxed.height,
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 1920, y: 1200) else {
            print("FAIL: input mapper did not round-trip the displayed video's centre and corners")
            Foundation.exit(1)
        }

        // Letterbox-margin decision: a point over a bar clamps to the nearest
        // canvas edge rather than being rejected, so a button held down while
        // the cursor drifts into the bar still delivers its eventual release.
        guard inputMapper.map(
                x: 500, y: 50, // below the letterboxed rect's bottom bar
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 1000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 960, y: 0),
              inputMapper.map(
                x: 500, y: 950, // above the letterboxed rect's top bar
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 1000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 960, y: 1200),
              inputMapper.map(
                x: 50, y: 500, // left of the pillarboxed rect's left bar
                sourceWidth: source.width, sourceHeight: source.height,
                viewportWidth: 2000, viewportHeight: 1000
              ) == CanvasInputPoint(x: 0, y: 600) else {
            print("FAIL: input mapper did not clamp letterbox-margin input to the nearest canvas edge")
            Foundation.exit(1)
        }
        let videoIngress = VideoFrameIngress()
        await videoIngress.receive(EncodedVideoFramePacket(
            sequence: 2,
            presentationTimeNanoseconds: 20,
            isKeyFrame: false,
            payload: Data([2])
        ))
        guard await videoIngress.takeNewest() == nil else {
            print("FAIL: decoder ingress accepted an interframe before a keyframe")
            Foundation.exit(1)
        }
        await videoIngress.receive(EncodedVideoFramePacket(
            sequence: 3,
            presentationTimeNanoseconds: 30,
            isKeyFrame: true,
            payload: Data([3])
        ))
        await videoIngress.receive(EncodedVideoFramePacket(
            sequence: 4,
            presentationTimeNanoseconds: 40,
            isKeyFrame: false,
            payload: Data([4])
        ))
        await videoIngress.receive(EncodedVideoFramePacket(
            sequence: 3,
            presentationTimeNanoseconds: 30,
            isKeyFrame: true,
            payload: Data([3])
        ))
        guard await videoIngress.takeNewest()?.sequence == 4 else {
            print("FAIL: decoder ingress did not retain the newest non-stale video frame")
            Foundation.exit(1)
        }
        let buffer = LatestFrameBuffer<Int>()
        await buffer.push(1)
        await buffer.push(2)
        await buffer.push(3)
        let newest = await buffer.takeNewest()
        guard newest == 3 else {
            print("FAIL: latest-frame-wins buffer retained a stale frame")
            Foundation.exit(1)
        }
        guard await buffer.takeNewest() == nil else {
            print("FAIL: latest-frame-wins buffer did not drain")
            Foundation.exit(1)
        }
        let channel = InMemoryControlChannel()
        try! await channel.send(.hello(protocolVersion: 1, deviceName: "Laptop"))
        guard try! await channel.receive() == .hello(protocolVersion: 1, deviceName: "Laptop") else {
            print("FAIL: control channel did not deliver a hello message")
            Foundation.exit(1)
        }
        let transport = FakeClientTransport()
        let controller = ClientSessionController(transport: transport)
        do {
            try await controller.sendPointer(CanvasInputPoint(x: 10, y: 20))
            print("FAIL: client controller sent pointer input before canvas readiness")
            Foundation.exit(1)
        } catch ClientSessionError.notConnected {
        } catch {
            print("FAIL: client controller reported the wrong pre-canvas input error")
            Foundation.exit(1)
        }
        let handle = try! await controller.connect(deviceName: "Laptop")
        guard handle == .canvas(displayID: 42, hostScreenOffer: []) else {
            print("FAIL: client controller did not accept the canvas-ready display")
            Foundation.exit(1)
        }
        // FakeClientTransport's canvasReady omits surfaceID entirely, exactly
        // like a host built before the field existed: the client must read
        // that as "no capability", not invent one.
        guard await controller.hostSupportsSurfaceIDs == false else {
            print("FAIL: client claimed surfaceID capability from a host that never echoed it")
            Foundation.exit(1)
        }
        try! await controller.sendPointer(CanvasInputPoint(x: 10, y: 20))
        let sentBeforeDisconnect = await transport.sent
        guard sentBeforeDisconnect == [
            .hello(protocolVersion: 1, deviceName: "Laptop"),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
            .input(.pointerMoved(x: 10, y: 20), surfaceID: nil, sequence: 0)
        ] else {
            print("FAIL: client controller sent the wrong connect sequence: \(sentBeforeDisconnect)")
            Foundation.exit(1)
        }
        await controller.disconnect()
        guard await transport.sent.suffix(2) == [
            .input(.releaseAllInput, surfaceID: nil),
            .goodbye(reason: "client-disconnected")
        ] else {
            print("FAIL: client did not release held input before saying goodbye")
            Foundation.exit(1)
        }
        guard await transport.sent.last == .goodbye(reason: "client-disconnected") else {
            print("FAIL: client controller did not send goodbye")
            Foundation.exit(1)
        }
        let noViewportSink = RecordingInputSink()
        let unsizedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: noViewportSink
        )
        guard await unsizedViewport.movePointer(x: 10, y: 10) == .droppedNoViewport,
              await noViewportSink.points.isEmpty else {
            print("FAIL: viewport controller sent pointer input without a known viewport size")
            Foundation.exit(1)
        }

        let mappingSink = RecordingInputSink()
        let mappingViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: mappingSink
        )
        await mappingViewport.setViewportSize(width: 1536, height: 960)
        await mappingViewport.canvasDidBecomeReady()
        guard await mappingViewport.movePointer(x: 0, y: 0) == .delivered(CanvasInputPoint(x: 0, y: 0)),
              await mappingViewport.movePointer(x: 1536, y: 960) == .delivered(CanvasInputPoint(x: 1920, y: 1200)),
              await mappingViewport.movePointer(x: 2000, y: -5) == .delivered(CanvasInputPoint(x: 1920, y: 0)),
              await mappingSink.points == [
                  CanvasInputPoint(x: 0, y: 0),
                  CanvasInputPoint(x: 1920, y: 1200),
                  CanvasInputPoint(x: 1920, y: 0)
              ] else {
            print("FAIL: viewport controller did not map viewport corners onto the owned canvas")
            Foundation.exit(1)
        }

        let disconnectedSink = RecordingInputSink(failure: .notConnected)
        let disconnectedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: disconnectedSink
        )
        await disconnectedViewport.setViewportSize(width: 1536, height: 960)
        await disconnectedViewport.canvasDidBecomeReady()
        guard await disconnectedViewport.movePointer(x: 100, y: 100) == .droppedNotConnected,
              await disconnectedSink.points.isEmpty else {
            print("FAIL: viewport controller reported delivery while the session was not connected")
            Foundation.exit(1)
        }

        let gatedSink = GatedPointerSink()
        let coalescingViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: gatedSink
        )
        await coalescingViewport.setViewportSize(width: 1920, height: 1200)
        await coalescingViewport.canvasDidBecomeReady()
        let inFlight = Task { await coalescingViewport.movePointer(x: 100, y: 100) }
        await gatedSink.waitUntilFirstSendEntered()
        let superseded = await coalescingViewport.movePointer(x: 200, y: 200)
        let newestPointer = await coalescingViewport.movePointer(x: 300, y: 300)
        await gatedSink.openGate()
        let inFlightResult = await inFlight.value
        guard inFlightResult == .delivered(CanvasInputPoint(x: 100, y: 100)),
              superseded == .coalesced,
              newestPointer == .coalesced,
              await gatedSink.points == [
                  CanvasInputPoint(x: 100, y: 100),
                  CanvasInputPoint(x: 300, y: 300)
              ] else {
            print("FAIL: viewport controller did not coalesce pointer motion behind an in-flight send")
            Foundation.exit(1)
        }

        let presenter = RecordingFramePresenter()
        let presentingViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: RecordingInputSink(),
            framePresenter: presenter
        )
        await presentingViewport.presentDecodedFrame(DecodedFrame(pixelBuffer: makeTestPixelBuffer()))
        guard await presenter.presentedCount == 0 else {
            print("FAIL: viewport controller presented a frame before the session canvas was ready")
            Foundation.exit(1)
        }
        await presentingViewport.canvasDidBecomeReady()
        await presentingViewport.presentDecodedFrame(DecodedFrame(pixelBuffer: makeTestPixelBuffer()))
        guard await presenter.presentedCount == 1 else {
            print("FAIL: viewport controller did not present a frame from the ready session canvas")
            Foundation.exit(1)
        }
        await presentingViewport.canvasDidEnd()
        await presentingViewport.presentDecodedFrame(DecodedFrame(pixelBuffer: makeTestPixelBuffer()))
        guard await presenter.presentedCount == 1 else {
            print("FAIL: viewport controller presented a stale frame after the session canvas ended")
            Foundation.exit(1)
        }

        let endedSink = RecordingInputSink()
        let endedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: endedSink
        )
        await endedViewport.setViewportSize(width: 1920, height: 1200)
        await endedViewport.canvasDidBecomeReady()
        _ = await endedViewport.movePointer(x: 5, y: 5)
        await endedViewport.canvasDidEnd()
        guard await endedViewport.movePointer(x: 6, y: 6) == .droppedNotConnected,
              await endedSink.points == [CanvasInputPoint(x: 5, y: 5)] else {
            print("FAIL: viewport controller sent pointer input after the session canvas ended")
            Foundation.exit(1)
        }

        let unboundedSink = RecordingInputSink()
        let unboundedRouter = CanvasSurfaceEventRouter(
            viewport: ClientViewportController(
                mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
                pointerSink: unboundedSink
            )
        )
        guard await unboundedRouter.route(.pointerMoved(x: 10, y: 10)) == .droppedNoViewport,
              await unboundedSink.points.isEmpty else {
            print("FAIL: surface router forwarded a pointer event before the view reported bounds")
            Foundation.exit(1)
        }

        let flipSink = RecordingInputSink()
        let flipViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: flipSink
        )
        await flipViewport.canvasDidBecomeReady()
        let flipRouter = CanvasSurfaceEventRouter(viewport: flipViewport)
        await flipRouter.route(.boundsChanged(width: 960, height: 600))
        let topLeft = await flipRouter.route(.pointerMoved(x: 0, y: 600))
        let bottomLeft = await flipRouter.route(.pointerMoved(x: 0, y: 0))
        let center = await flipRouter.route(.pointerMoved(x: 480, y: 300))
        guard topLeft == .delivered(CanvasInputPoint(x: 0, y: 0)),
              bottomLeft == .delivered(CanvasInputPoint(x: 0, y: 1200)),
              center == .delivered(CanvasInputPoint(x: 960, y: 600)),
              await flipSink.points == [
                  CanvasInputPoint(x: 0, y: 0),
                  CanvasInputPoint(x: 0, y: 1200),
                  CanvasInputPoint(x: 960, y: 600)
              ] else {
            print("FAIL: surface router did not flip AppKit bottom-left coordinates onto the top-left canvas")
            Foundation.exit(1)
        }

        let resizeSink = RecordingInputSink()
        let resizeViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: resizeSink
        )
        await resizeViewport.canvasDidBecomeReady()
        let resizeRouter = CanvasSurfaceEventRouter(viewport: resizeViewport)
        await resizeRouter.route(.boundsChanged(width: 960, height: 600))
        await resizeRouter.route(.boundsChanged(width: 480, height: 300))
        let afterResize = await resizeRouter.route(.pointerMoved(x: 240, y: 300))
        await resizeRouter.route(.boundsChanged(width: 0, height: 0))
        let afterDetach = await resizeRouter.route(.pointerMoved(x: 10, y: 10))
        guard afterResize == .delivered(CanvasInputPoint(x: 960, y: 0)),
              afterDetach == .droppedNoViewport,
              await resizeSink.points == [CanvasInputPoint(x: 960, y: 0)] else {
            print("FAIL: surface router did not re-anchor on resize and disarm on detach")
            Foundation.exit(1)
        }

        let malformedSink = RecordingInputSink()
        let malformedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: malformedSink
        )
        await malformedViewport.canvasDidBecomeReady()
        let malformedRouter = CanvasSurfaceEventRouter(viewport: malformedViewport)
        await malformedRouter.route(.boundsChanged(width: 960, height: 600))
        let notANumber = await malformedRouter.route(.pointerMoved(x: Double.nan, y: 100))
        let infinite = await malformedRouter.route(.pointerMoved(x: 100, y: .infinity))
        guard notANumber == .droppedInvalidLocation,
              infinite == .droppedInvalidLocation,
              await malformedSink.points.isEmpty else {
            print("FAIL: surface router forwarded a non-finite pointer location")
            Foundation.exit(1)
        }

        let richSink = RecordingInputSink()
        let richViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: richSink
        )
        await richViewport.canvasDidBecomeReady()
        let richRouter = CanvasSurfaceEventRouter(viewport: richViewport)
        await richRouter.route(.boundsChanged(width: 960, height: 600))
        await richRouter.route(.pointerButton(button: .left, isDown: true, x: 0, y: 600))
        await richRouter.route(.scrolled(deltaX: -2, deltaY: 3, x: 960, y: 0, phase: nil, momentumPhase: nil))
        await richRouter.route(.key(keyCode: 55, isDown: true, modifiers: [.command]))
        guard await richSink.events == [
            .pointerButton(button: .left, isDown: true, x: 0, y: 0),
            .scrolled(deltaX: -2, deltaY: 3, x: 1920, y: 1200, phase: nil, momentumPhase: nil),
            .key(keyCode: 55, isDown: true, modifiers: [.command])
        ] else {
            print("FAIL: surface router did not carry button, scroll, and key input onto the owned canvas")
            Foundation.exit(1)
        }

        await richRouter.route(.scrolled(deltaX: 0, deltaY: 0.4, x: 960, y: 0, phase: .began, momentumPhase: nil))
        await richRouter.route(.pointerMovedRelative(deltaX: -6, deltaY: 12))
        await richRouter.route(.pointerCaptureChanged(isCaptured: true))
        guard await richSink.events.suffix(3) == [
            .scrolled(deltaX: 0, deltaY: 0.4, x: 1920, y: 1200, phase: .began, momentumPhase: nil),
            .pointerMovedRelative(deltaX: -6, deltaY: 12),
            .pointerCaptureChanged(isCaptured: true)
        ] else {
            print("FAIL: surface router did not carry a scroll phase, relative motion, and a capture toggle onto the owned canvas")
            Foundation.exit(1)
        }

        guard CanvasScrollPhase(.began) == .began,
              CanvasScrollPhase([.stationary, .began]) == .began,
              CanvasScrollPhase(.changed) == .changed,
              CanvasScrollPhase(.ended) == .ended,
              CanvasScrollPhase(.cancelled) == .cancelled,
              CanvasScrollPhase(.mayBegin) == .mayBegin,
              CanvasScrollPhase([]) == nil else {
            print("FAIL: NSEvent.Phase did not translate to CanvasScrollPhase, or a plain scroll-wheel mouse's empty phase produced one anyway")
            Foundation.exit(1)
        }
        guard CanvasScrollMomentumPhase(.began) == .begin,
              CanvasScrollMomentumPhase(.changed) == .continue,
              CanvasScrollMomentumPhase(.ended) == .end,
              CanvasScrollMomentumPhase([]) == nil else {
            print("FAIL: NSEvent's momentum phase did not translate to CanvasScrollMomentumPhase")
            Foundation.exit(1)
        }
}
