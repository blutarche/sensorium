import Foundation
import SensoriumClient
import SensoriumCore

/// Input-routing behaviour that needs no AppKit fixture: the surface router
/// itself, the input mapper's corner and clamp behaviour, a session's
/// disconnect releasing held input before it says goodbye, and the two
/// pointer/cursor balance policies. Moved out of the AppKit-gated test files
/// so the same coverage runs on Linux, where AppKit does not exist.
func testInputRoutingTests() async {
    let inputMapper = VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200)
    expect(
        inputMapper.map(
            x: 0, y: 0, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
        ) == CanvasInputPoint(x: 0, y: 0)
        && inputMapper.map(
            x: 1536, y: 960, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
        ) == CanvasInputPoint(x: 1920, y: 1200)
        && inputMapper.map(
            x: -4, y: 1000, sourceWidth: 1920, sourceHeight: 1200, viewportWidth: 1536, viewportHeight: 960
        ) == CanvasInputPoint(x: 0, y: 1200),
        "input mapper did not preserve corners and clamp outside viewport"
    )

    // A session's disconnect releases whatever input is still held before it
    // says goodbye, so a modifier a person was holding never stays pressed
    // on a machine nobody is sitting at.
    let transport = FakeClientTransport()
    let controller = ClientSessionController(transport: transport)
    _ = try! await controller.connect(deviceName: "Laptop")
    try! await controller.sendPointer(CanvasInputPoint(x: 10, y: 20))
    await controller.disconnect()
    expect(
        await transport.sent.suffix(2) == [
            .input(.releaseAllInput, surfaceID: nil),
            .goodbye(reason: "client-disconnected")
        ],
        "disconnecting did not release held input before saying goodbye"
    )

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

    let modifierSink = RecordingInputSink()
    let modifierViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: modifierSink
    )
    await modifierViewport.canvasDidBecomeReady()
    let modifierRouter = CanvasSurfaceEventRouter(viewport: modifierViewport)
    await modifierRouter.route(.modifiersChanged(keyCode: 56, modifiers: [.shift]))
    await modifierRouter.route(.modifiersChanged(keyCode: 56, modifiers: []))
    await modifierRouter.route(.modifiersChanged(keyCode: 56, modifiers: [.shift]))
    guard await modifierSink.events == [
        .key(keyCode: 56, isDown: true, modifiers: [.shift]),
        .key(keyCode: 56, isDown: false, modifiers: []),
        .key(keyCode: 56, isDown: true, modifiers: [.shift])
    ] else {
        print("FAIL: a modifier key pressed and held alone did not forward as a key event")
        Foundation.exit(1)
    }

    // Regression test: `CanvasModifierFlags` has no left/right distinction,
    // so Left Shift and Right Shift both report as `[.shift]`. Holding Left
    // Shift, then pressing and releasing Right Shift, must still forward
    // Right Shift's own key-down and key-up even though the aggregate mask
    // never changes across any of these three events (it is `[.shift]`
    // throughout).
    let sharedBitSink = RecordingInputSink()
    let sharedBitViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sharedBitSink
    )
    await sharedBitViewport.canvasDidBecomeReady()
    let sharedBitRouter = CanvasSurfaceEventRouter(viewport: sharedBitViewport)
    await sharedBitRouter.route(.modifiersChanged(keyCode: 56, modifiers: [.shift]))
    await sharedBitRouter.route(.modifiersChanged(keyCode: 60, modifiers: [.shift]))
    await sharedBitRouter.route(.modifiersChanged(keyCode: 60, modifiers: [.shift]))
    guard await sharedBitSink.events == [
        .key(keyCode: 56, isDown: true, modifiers: [.shift]),
        .key(keyCode: 60, isDown: true, modifiers: [.shift]),
        .key(keyCode: 60, isDown: false, modifiers: [.shift])
    ] else {
        print("FAIL: releasing Right Shift while Left Shift stays held did not forward Right Shift's own key-up even though the aggregate modifier mask never changed")
        Foundation.exit(1)
    }

    let focusSink = RecordingInputSink()
    let focusViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: focusSink
    )
    let focusRouter = CanvasSurfaceEventRouter(viewport: focusViewport)
    let focusLostBeforeReady = await focusRouter.route(.focusLost)
    await focusViewport.canvasDidBecomeReady()
    let focusLostWhileReady = await focusRouter.route(.focusLost)
    guard focusLostBeforeReady == .droppedNotConnected,
          focusLostWhileReady == .deliveredWithoutLocation,
          await focusSink.events == [.releaseAllInput] else {
        print("FAIL: losing focus did not release all input exactly once while the session was connected")
        Foundation.exit(1)
    }

    // Regression test: a modifier still held at focus loss must not leave the
    // router's own bookkeeping out of step with the release it just sent. A
    // held Shift, a focus loss, then the same physical key going down again
    // must reach the sink as a down, not an up.
    let stuckModifierSink = RecordingInputSink()
    let stuckModifierViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: stuckModifierSink
    )
    await stuckModifierViewport.canvasDidBecomeReady()
    let stuckModifierRouter = CanvasSurfaceEventRouter(viewport: stuckModifierViewport)
    await stuckModifierRouter.route(.modifiersChanged(keyCode: 56, modifiers: [.shift]))
    await stuckModifierRouter.route(.focusLost)
    let afterFocusLoss = await stuckModifierRouter.route(.modifiersChanged(keyCode: 56, modifiers: [.shift]))
    guard afterFocusLoss == .deliveredWithoutLocation,
          await stuckModifierSink.events == [
              .key(keyCode: 56, isDown: true, modifiers: [.shift]),
              .releaseAllInput,
              .key(keyCode: 56, isDown: true, modifiers: [.shift])
          ] else {
        print("FAIL: a modifier still held at focus loss left the router believing it was still down afterwards")
        Foundation.exit(1)
    }

    // The stuck-cursor regression: CGAssociateMouseAndMouseCursorPosition is
    // a machine-wide connection, not a per-session flag, so an unbalanced
    // disassociate is worse than an unbalanced NSCursor.hide() -- it leaves
    // the user's physical mouse dead with nothing on screen to click and fix
    // it. Proven the same way as the cursor-visibility balance: exact
    // transitions on every path, then a long fuzzed run.
    do {
        var policy = CanvasPointerAssociationPolicy()
        expect(!policy.isCapturing && !policy.isDisassociated, "a fresh policy starts connected")

        expect(policy.capturingPointerChanged(true) == .disassociate, "entering capture disconnects the physical mouse")
        expect(policy.isDisassociated, "the policy now believes the mouse is disconnected")
        expect(policy.capturingPointerChanged(true) == .none, "reporting the same capture state twice must not disassociate twice")
        expect(policy.capturingPointerChanged(false) == .associate, "leaving capture reconnects it")
        expect(!policy.isDisassociated, "reconnected after the only reason to be disconnected ended")
        expect(policy.capturingPointerChanged(false) == .none, "reporting the same release twice must not reconnect twice")

        // The abrupt-teardown case named explicitly: a session that ends
        // mid-capture, with no `capturingPointerChanged(false)` ever
        // reported, must still reconnect in exactly one call.
        var teardown = CanvasPointerAssociationPolicy()
        _ = teardown.capturingPointerChanged(true)
        expect(teardown.isDisassociated, "disconnected mid-capture, before any teardown")
        expect(teardown.reset() == .associate, "an abrupt teardown mid-capture still reconnects exactly once")
        expect(teardown.reset() == .none, "a second teardown call must not reconnect twice")
        expect(!teardown.isCapturing, "reset also clears capture itself, so a stray togglePointerCapture() after teardown cannot re-disassociate on a false premise")

        // The same 200-step fuzz as the cursor-visibility balance, over the
        // one signal this policy actually has: capture toggling and
        // teardown, interleaved, checked after every step.
        var fuzzed = CanvasPointerAssociationPolicy()
        var outstanding = 0
        for i in 0..<200 {
            let transition: CanvasPointerAssociationPolicy.Transition
            if i % 7 == 0 {
                transition = fuzzed.reset()
            } else {
                transition = fuzzed.capturingPointerChanged(i % 3 != 0)
            }
            switch transition {
            case .disassociate: outstanding += 1
            case .associate: outstanding -= 1
            case .none: break
            }
            expect(outstanding == 0 || outstanding == 1, "the mouse is disconnected by at most one outstanding call at step \(i)")
            expect((outstanding == 1) == fuzzed.isDisassociated, "the outstanding count and the policy's own isDisassociated agree at step \(i)")
        }
        _ = fuzzed.reset()
        expect(!fuzzed.isDisassociated, "the fuzzed run ends reconnected after a final teardown")

        print("PASS: the physical mouse is disconnected at most once, and every exit, abrupt teardown included, reconnects it exactly once")
    }

    // Two chords never interleave: the second waits for the first to finish,
    // so a modifier that belongs to one press cannot be released by the
    // other's key-up.
    let order = RecordedOrder()
    let queue = ShortcutChordQueue()
    await queue.enqueue {
        await order.append("first-start")
        for _ in 0..<8 {
            await Task.yield()
        }
        await order.append("first-end")
    }
    await queue.enqueue {
        await order.append("second-start")
        await order.append("second-end")
    }
    await queue.drain()
    expect(
        await order.entries == ["first-start", "first-end", "second-start", "second-end"],
        "a chord queued behind another starts only once that one has finished"
    )
}

/// `CanvasSourceOrigin.topLeft` passes coordinates through unflipped,
/// because a Wayland surface's origin is already the canvas's own top-left
/// corner; `.bottomLeft` (AppKit's convention, and the router's default)
/// still flips against the surface height.
func testCanvasSurfaceEventRouterSourceOriginTests() async {
    let topLeftSink = RecordingInputSink()
    let topLeftViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: topLeftSink
    )
    await topLeftViewport.canvasDidBecomeReady()
    let topLeftRouter = CanvasSurfaceEventRouter(viewport: topLeftViewport, sourceOrigin: .topLeft)
    await topLeftRouter.route(.boundsChanged(width: 960, height: 600))

    let bottomLeftSink = RecordingInputSink()
    let bottomLeftViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: bottomLeftSink
    )
    await bottomLeftViewport.canvasDidBecomeReady()
    let bottomLeftRouter = CanvasSurfaceEventRouter(viewport: bottomLeftViewport, sourceOrigin: .bottomLeft)
    await bottomLeftRouter.route(.boundsChanged(width: 960, height: 600))

    await topLeftRouter.route(.pointerMoved(x: 100, y: 50))
    await bottomLeftRouter.route(.pointerMoved(x: 100, y: 50))
    expect(
        await topLeftSink.points == [CanvasInputPoint(x: 200, y: 100)],
        "a top-left-origin router passed pointerMoved's y through unflipped"
    )
    expect(
        await bottomLeftSink.points == [CanvasInputPoint(x: 200, y: 1100)],
        "a bottom-left-origin router flipped pointerMoved's y against the surface height"
    )

    await topLeftRouter.route(.pointerButton(button: .left, isDown: true, x: 100, y: 50))
    await bottomLeftRouter.route(.pointerButton(button: .left, isDown: true, x: 100, y: 50))
    expect(
        await topLeftSink.events.last == .pointerButton(button: .left, isDown: true, x: 200, y: 100),
        "a top-left-origin router passed pointerButton's y through unflipped"
    )
    expect(
        await bottomLeftSink.events.last == .pointerButton(button: .left, isDown: true, x: 200, y: 1100),
        "a bottom-left-origin router flipped pointerButton's y against the surface height"
    )

    await topLeftRouter.route(.scrolled(deltaX: 1, deltaY: 2, x: 100, y: 50, phase: nil, momentumPhase: nil))
    await bottomLeftRouter.route(.scrolled(deltaX: 1, deltaY: 2, x: 100, y: 50, phase: nil, momentumPhase: nil))
    expect(
        await topLeftSink.events.last == .scrolled(deltaX: 1, deltaY: 2, x: 200, y: 100, phase: nil, momentumPhase: nil),
        "a top-left-origin router passed scrolled's y through unflipped"
    )
    expect(
        await bottomLeftSink.events.last == .scrolled(deltaX: 1, deltaY: 2, x: 200, y: 1100, phase: nil, momentumPhase: nil),
        "a bottom-left-origin router flipped scrolled's y against the surface height"
    )

    print("PASS: a CanvasSurfaceEventRouter given a top-left source origin passes pointer coordinates through unflipped, and a bottom-left one still flips them")
}
