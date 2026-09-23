import Foundation
import SensoriumClient
import SensoriumCore

/// A Wayland surface reports pointer positions with the origin at its
/// top-left corner, the same corner the canvas counts from. A router built
/// for that surface must therefore leave y alone: the flip an AppKit view
/// needs would put a click near the top of the window near the bottom of the
/// far machine's screen.
@MainActor
func testWaylandPointerRoutingTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport, sourceOrigin: .topLeft)
    await router.route(.boundsChanged(width: 1920, height: 1200))
    await router.route(.pointerMoved(x: 10, y: 20))

    expect(
        await sink.points == [CanvasInputPoint(x: 10, y: 20)],
        "a Wayland pointer 20 units below the top of a 1920x1200 window reaches the canvas 20 units below its top"
    )

    print("PASS: a Wayland surface's pointer position reaches the canvas measured from the top, not flipped")
}

/// A pointer that entered one of the window's own overlays is not the far
/// machine's pointer, and the click it makes there never reaches the canvas.
///
/// The window itself cannot be built without a compositor, so what is driven
/// here is the pair it asks on every button: which overlay the compositor
/// named as the surface under the pointer, and what
/// `CanvasChromeClickPolicy` makes of that. That the window asks them in this
/// order is what the harness run shows.
@MainActor
func testWaylandOverlayPointerRoutingTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport, sourceOrigin: .topLeft)
    await router.route(.boundsChanged(width: 1920, height: 1200))

    let picture = OpaquePointer(bitPattern: 0x1000)
    let panel = OpaquePointer(bitPattern: 0x2000)
    let strip = OpaquePointer(bitPattern: 0x3000)
    let targets = WaylandOverlayPointerTargets(targets: [
        .init(kind: .statusPanel, surface: panel, isVisible: true),
        .init(kind: .shortcutStrip, surface: strip, isVisible: false)
    ])

    expect(targets.kind(for: panel) == .statusPanel, "the compositor's own surface names which overlay it is")
    expect(targets.kind(for: picture) == nil, "the picture is not one of them")
    expect(targets.kind(for: strip) == nil, "and neither is an overlay that is hidden right now")
    expect(targets.kind(for: nil) == nil, "a pointer on no surface at all is on no overlay")

    var clicks = CanvasChromeClickPolicy()

    /// What `WaylandSessionWindow.handlePointerButton` does with one button
    /// event: ask which surface the pointer is on, then ask the policy, and
    /// only then hand it to the session.
    func button(_ button: CanvasPointerButton, isDown: Bool, on surface: OpaquePointer?) async {
        let isOverChrome = targets.kind(for: surface) != nil
        let forwards = isDown
            ? clicks.shouldForwardPress(button, isOverChrome: isOverChrome)
            : clicks.shouldForwardRelease(button)
        guard forwards else { return }
        await router.route(.pointerButton(button: button, isDown: isDown, x: 40, y: 40))
    }

    await button(.left, isDown: true, on: panel)
    await button(.left, isDown: false, on: panel)
    expect(
        await sink.events.isEmpty,
        "a press on the status panel and the release that ends it reach the far machine not at all"
    )

    await button(.left, isDown: true, on: picture)
    await button(.left, isDown: false, on: strip)
    expect(
        await sink.events.count == 2,
        "while a press on the picture is sent, and released even though the pointer ended up elsewhere"
    )

    print("PASS: a click on a Linux session window's own overlay never reaches the machine being worked on")
}

/// Where a pointer lands on the far machine once a pinned strip has taken a
/// band off the top of the window.
///
/// The picture moves down by the band and shrinks by it, so a point measured
/// against the window is not a point on the picture until the band is taken
/// off it, and the bounds the mapper is given have to be the picture's, not
/// the window's. Both are what `WaylandSessionWindow` reports; the window
/// needs a compositor, so the rule it applies is driven here directly.
@MainActor
func testWaylandBandedPointerMappingTests() async {
    let band = 44.0
    let windowWidth = 1280.0
    let windowHeight = 800.0

    let area = WaylandOverlayLayout.videoArea(
        windowWidth: windowWidth, windowHeight: windowHeight, topInset: band
    )
    expect(area.x == 0 && area.y == band, "the picture starts below the band")
    expect(
        area.width == windowWidth && area.height == windowHeight - band,
        "and is the window minus the band, never the whole window"
    )
    let whole = WaylandOverlayLayout.videoArea(
        windowWidth: windowWidth, windowHeight: windowHeight, topInset: 0
    )
    expect(
        whole.y == 0 && whole.height == windowHeight,
        "with no band the picture is the whole window, as it was"
    )

    func mapped(band: Double, pointerY: Double) async -> CanvasInputPoint? {
        let sink = RecordingInputSink()
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: sink
        )
        await viewport.canvasDidBecomeReady()
        let router = CanvasSurfaceEventRouter(viewport: viewport, sourceOrigin: .topLeft)
        let area = WaylandOverlayLayout.videoArea(
            windowWidth: windowWidth, windowHeight: windowHeight, topInset: band
        )
        await router.route(.boundsChanged(width: area.width, height: area.height))
        await router.route(.pointerMoved(x: 640, y: pointerY - area.y))
        return await sink.points.first
    }

    // The middle of the picture is the middle of the far machine's screen,
    // whether or not a band has moved the picture down the window.
    let unpinnedCentre = await mapped(band: 0, pointerY: windowHeight / 2)
    let pinnedCentre = await mapped(band: band, pointerY: band + (windowHeight - band) / 2)
    expect(unpinnedCentre == CanvasInputPoint(x: 960, y: 600), "the middle of an unbanded window is the middle of the screen")
    expect(pinnedCentre == unpinnedCentre, "and so is the middle of the picture a pinned strip left behind")

    expect(
        await mapped(band: band, pointerY: band)?.y == 0,
        "the first row of the picture is the first row of the far machine's screen, not a row below it"
    )
    expect(
        await mapped(band: band, pointerY: windowHeight)?.y == 1200,
        "and the last row is still the last row"
    )

    // What the same press would have done before the band was taken off it:
    // the picture's own top edge read as a point well down the screen.
    let ignoringBand = CanvasInputPoint(
        x: 960,
        y: (band / windowHeight) * 1200
    )
    expect(
        ignoringBand.y > 0,
        "a press that ignored the band would have landed further down the far machine's screen"
    )

    // What the host is asked to stream: the picture's own pixels, not the
    // window's, so a pinned strip does not have it sending rows nothing will
    // ever draw. The same rule `CanvasSurfaceView` applies by converting its
    // already-shrunk video bounds to backing pixels.
    let drawableHeight = 1600.0
    expect(
        WaylandOverlayLayout.videoDrawablePixelHeight(
            drawablePixelHeight: drawableHeight, topInset: 0, scale: 2
        ) == drawableHeight,
        "with no band the host streams the whole drawable, as it did"
    )
    expect(
        WaylandOverlayLayout.videoDrawablePixelHeight(
            drawablePixelHeight: drawableHeight, topInset: band, scale: 2
        ) == drawableHeight - band * 2,
        "a pinned strip takes its own band off in real pixels, at the surface's own scale"
    )
    expect(
        WaylandOverlayLayout.videoDrawablePixelHeight(
            drawablePixelHeight: 20, topInset: 400, scale: 2
        ) >= 1,
        "a band taller than the drawable still leaves a drawable a compositor will take"
    )

    print("PASS: a pinned strip moves the picture without moving where a click lands on the far machine")
}

/// A resize has to reach the compositor as one atomic update: the picture at
/// its new size and every overlay at its new place, never a frame of one
/// without the other. A subsurface set synchronised commits with its parent,
/// so the overlays are put in sync while the surface is being re-configured
/// and let go again once the picture behind them has been drawn at the new
/// size.
func testWaylandOverlaySyncGateTests() {
    var gate = WaylandOverlaySyncGate()
    expect(!gate.isSynchronised, "overlays commit on their own clock while nothing is resizing")
    expect(!gate.pictureDrawn(), "a drawn picture with no resize behind it changes nothing")

    expect(gate.surfaceResized(), "a configure that changed the size puts every overlay in sync")
    expect(gate.isSynchronised, "and leaves it there")
    expect(!gate.surfaceResized(), "a second configure before the picture caught up changes nothing again")
    expect(gate.isSynchronised, "the overlays are still held")

    expect(gate.pictureDrawn(), "the first picture drawn at the new size lets them go")
    expect(!gate.isSynchronised, "back to their own clock")
    expect(!gate.pictureDrawn(), "and every picture after that changes nothing")

    print("PASS: overlays are held to the parent's commit across a resize and let go once the picture caught up")
}

/// A host that reports its screen locked changes nothing about where the
/// Linux session window's keys go: the person types into the lock screen in
/// the picture, and every key, Return included, reaches the transport exactly
/// as it would at an unlocked host.
///
/// The window itself cannot be built without a compositor, so what is driven
/// here is `WaylandKeyPath`, which is the whole of the window's decision, and
/// the router the window hands a `.canvas` event to.
@MainActor
func testWaylandLockedHostKeyRoutingTests() async {
    /// KEY_A and KEY_ENTER, and KEY_LEFTSHIFT reported the way the real
    /// keyboard reports a modifier: as the change it makes.
    struct FakeKeyTranslator: WaylandKeyTranslating {
        var modifiers: CanvasModifierFlags = []

        func key(evdev code: UInt32, isDown: Bool) -> CanvasSurfaceEvent? {
            switch code {
            case 30: .key(keyCode: 0, isDown: isDown, modifiers: modifiers)
            case 28: .key(keyCode: 36, isDown: isDown, modifiers: modifiers)
            case 42: .modifiersChanged(keyCode: 56, modifiers: isDown ? [.shift] : [])
            default: nil
            }
        }
    }

    let (sent, endedReason) = await runnerAfterLockedHostReport()
    expect(
        !sent.contains { if case .hostScreenUnlockRequest = $0 { true } else { false } },
        "a locked host makes the viewer send no unlock request -- sent: \(sent)"
    )
    expect(
        endedReason == "\(ControlChannelError.closed)",
        "and neither the lock report nor the unlock answer ends the session -- ended: \(endedReason ?? "<never>")"
    )

    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport, sourceOrigin: .topLeft)
    await router.route(.boundsChanged(width: 1920, height: 1200))

    func deliver(_ destination: WaylandKeyDestination) async {
        guard case let .canvas(event) = destination else {
            expect(false, "a key typed at a locked host goes to the canvas -- got \(destination)")
            return
        }
        await router.route(event)
    }

    var keyboard = FakeKeyTranslator()
    func press(_ evdev: UInt32, isDown: Bool) async {
        await deliver(WaylandKeyPath.destination(evdev: evdev, isDown: isDown, keyboard: keyboard))
    }
    await press(30, isDown: true)
    await press(30, isDown: false)
    await press(28, isDown: true)
    await press(28, isDown: false)
    await press(42, isDown: true)
    keyboard.modifiers = [.shift]
    await press(30, isDown: true)
    await press(30, isDown: false)
    keyboard.modifiers = []
    await press(42, isDown: false)

    let keys = await sink.keys
    let expected: [SensoriumInputEvent] = [
        .key(keyCode: 0, isDown: true, modifiers: []),
        .key(keyCode: 0, isDown: false, modifiers: []),
        .key(keyCode: 36, isDown: true, modifiers: []),
        .key(keyCode: 36, isDown: false, modifiers: []),
        .key(keyCode: 56, isDown: true, modifiers: [.shift]),
        .key(keyCode: 0, isDown: true, modifiers: [.shift]),
        .key(keyCode: 0, isDown: false, modifiers: [.shift]),
        .key(keyCode: 56, isDown: false, modifiers: []),
    ]
    expect(
        keys == expected,
        "every key and modifier typed at a locked host reaches the transport unchanged -- got \(keys)"
    )

    print("PASS: the Linux key path sends a locked host every key, Return and modifiers included, and no unlock request")
}
