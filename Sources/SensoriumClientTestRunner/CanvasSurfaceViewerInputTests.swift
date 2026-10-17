#if canImport(AppKit)
import AppKit
import CoreGraphics
import SensoriumClient
import SensoriumCore

/// What `CanvasSurfaceView` forwards for the pointer devices AppKit reports,
/// observed at the sink the viewport writes to.
@MainActor
func testCanvasSurfaceViewerInputTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let surface = CanvasSurfaceView(
        router: CanvasSurfaceEventRouter(viewport: viewport),
        shortcutRouter: SystemShortcutRouter(mode: .default),
        accessibilityGranted: false,
        surfaceID: 0
    )
    // Far larger than any display: a scroll event built from a CGEvent is
    // located wherever the system cursor is, and must still land on the canvas.
    surface.frame = NSRect(x: 0, y: 0, width: 100_000, height: 100_000)
    surface.windowStateProvider = {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    }

    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    func scrollEvent(units: CGScrollEventUnit, amount: Int32, exactAmount: Double? = nil) -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 1,
            wheel1: amount,
            wheel2: 0,
            wheel3: 0
        ) else {
            expect(false, "CoreGraphics refused a synthetic scroll event")
            fatalError("unreachable")
        }
        // Where an accelerated wheel's fractional lines arrive
        if let exactAmount {
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: exactAmount)
        }
        guard let event = NSEvent(cgEvent: cgEvent) else {
            expect(false, "AppKit refused a synthetic scroll event")
            fatalError("unreachable")
        }
        return event
    }

    func scrolledDeltaY() async -> Double? {
        await settle()
        for event in await sink.events {
            if case let .scrolled(_, deltaY, _, _, _, _, _, _) = event { return deltaY }
        }
        return nil
    }

    await settle()

    // A line-based wheel reports lines, and the host scrolls by points
    let wheel = scrollEvent(units: .line, amount: 3)
    expect(!wheel.hasPreciseScrollingDeltas, "a line-unit scroll is not precise")
    expect(wheel.scrollingDeltaY == 3, "a line-unit scroll of 3 reports 3 lines, got \(wheel.scrollingDeltaY)")
    surface.scrollWheel(with: wheel)
    let wheelDelta = await scrolledDeltaY()
    expect(
        wheelDelta == 3 * ScrollWheelUnits.pointsPerNotch,
        "three notches scroll \(3 * ScrollWheelUnits.pointsPerNotch) points, got \(String(describing: wheelDelta))"
    )

    // and sends its lines as well, exactly as AppKit reported them
    surface.scrollWheel(with: scrollEvent(units: .line, amount: 1, exactAmount: 1.5))
    await settle()
    let wheelScrolls = await sink.events.compactMap { event -> String? in
        guard case let .scrolled(deltaX, deltaY, _, _, _, _, lineDeltaX, lineDeltaY) = event else { return nil }
        return "\(deltaX) \(deltaY) lines \(lineDeltaX.map { "\($0)" } ?? "none") \(lineDeltaY.map { "\($0)" } ?? "none")"
    }
    expect(
        wheelScrolls == ["0.0 30.0 lines 0.0 3.0", "0.0 15.0 lines 0.0 1.5"],
        "a line-based wheel sends its lines next to its points, fractions and all, got \(wheelScrolls)"
    )

    // A trackpad's pixel deltas pass through unchanged
    let sinkForPixels = RecordingInputSink()
    let pixelViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sinkForPixels
    )
    await pixelViewport.canvasDidBecomeReady()
    let pixelSurface = CanvasSurfaceView(
        router: CanvasSurfaceEventRouter(viewport: pixelViewport),
        shortcutRouter: SystemShortcutRouter(mode: .default),
        accessibilityGranted: false,
        surfaceID: 0
    )
    pixelSurface.frame = surface.frame
    await settle()
    let trackpad = scrollEvent(units: .pixel, amount: 3)
    expect(trackpad.hasPreciseScrollingDeltas, "a pixel-unit scroll is precise")
    pixelSurface.scrollWheel(with: trackpad)
    await settle()
    let pixelDelta = await sinkForPixels.events.compactMap { event -> Double? in
        if case let .scrolled(_, deltaY, _, _, _, _, _, _) = event { return deltaY }
        return nil
    }.first
    expect(pixelDelta == 3, "a precise scroll of 3 stays 3, got \(String(describing: pixelDelta))")
    let pixelLines = await sinkForPixels.events.compactMap { event -> String? in
        guard case let .scrolled(_, _, _, _, _, _, lineDeltaX, lineDeltaY) = event else { return nil }
        return "\(String(describing: lineDeltaX)) \(String(describing: lineDeltaY))"
    }
    expect(pixelLines == ["nil nil"], "a precise scroll carries no lines, got \(pixelLines)")
    print("PASS: a line-based wheel scrolls by points per notch and sends its lines too, and a precise scroll is unchanged and carries no lines")

    // The click that activates the window is the host's click too
    expect(surface.acceptsFirstMouse(for: nil), "the click that activates the viewer window reaches the canvas")
    print("PASS: the click that activates the viewer window is forwarded")

    // Dragging with the middle button moves the host's pointer
    let before = await sink.points.count
    guard let drag = NSEvent.mouseEvent(
        with: .otherMouseDragged,
        location: NSPoint(x: 100, y: 100),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ) else {
        expect(false, "AppKit refused a synthetic drag event")
        return
    }
    surface.otherMouseDragged(with: drag)
    await settle()
    let after = await sink.points
    expect(after.count == before + 1, "a middle-button drag forwarded motion, got \(after)")
    print("PASS: a middle-button drag forwards pointer motion")

    // AppKit never hands a key-up to the view while Command is held, so the
    // window controller offers it here instead; it reaches the host once, and
    // only when the view forwarded the matching key-down.
    func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, command: Bool) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            expect(false, "AppKit refused a synthetic key event")
            fatalError("unreachable")
        }
        return event
    }
    func keys(code: UInt16) async -> [Bool] {
        await settle()
        return await sink.keys.compactMap { event in
            guard case let .key(keyCode, isDown, _, _) = event, keyCode == code else { return nil }
            return isDown
        }
    }

    // Cmd-C: the key-down is a forwarded key equivalent
    expect(surface.performKeyEquivalent(with: keyEvent(.keyDown, keyCode: 8, command: true)), "Cmd-C is claimed")
    let commandUp = keyEvent(.keyUp, keyCode: 8, command: true)
    expect(surface.forwardKeyUpIfOutstanding(commandUp), "the key-up of a forwarded Cmd-C is taken")
    expect(!surface.forwardKeyUpIfOutstanding(commandUp), "and taken only once")
    let copyKeys = await keys(code: 8)
    expect(copyKeys == [true, false], "Cmd-C went down once and up once, got \(copyKeys)")

    // A chord the view never forwarded leaves no key-up behind
    expect(
        !surface.forwardKeyUpIfOutstanding(keyEvent(.keyUp, keyCode: 18, command: true)),
        "the key-up of a chord that was not forwarded is not sent"
    )
    let strayKeys = await keys(code: 18)
    expect(strayKeys.isEmpty, "nothing was sent for the unforwarded chord, got \(strayKeys)")

    // A key-up AppKit does deliver is not sent a second time
    surface.keyDown(with: keyEvent(.keyDown, keyCode: 0, command: false))
    surface.keyUp(with: keyEvent(.keyUp, keyCode: 0, command: false))
    expect(
        !surface.forwardKeyUpIfOutstanding(keyEvent(.keyUp, keyCode: 0, command: true)),
        "a key already released through the ordinary path is not released again"
    )
    let plainKeys = await keys(code: 0)
    expect(plainKeys == [true, false], "a plain key went down once and up once, got \(plainKeys)")
    print("PASS: a key-up AppKit withholds while Command is held still reaches the host exactly once")

    // The viewer's own chords are Control-Option-Command plus the key, so the
    // same keys with other modifiers belong to the host.
    let all: NSEvent.ModifierFlags = [.control, .option, .command]
    expect(ViewerChord.matches(flags: all, key: "L", expected: "l"), "Control-Option-Command-L is the viewer's chord")
    expect(ViewerChord.matches(flags: all.union(.capsLock), key: "g", expected: "g"), "caps lock does not change the chord")
    expect(!ViewerChord.matches(flags: [.command, .shift], key: "l", expected: "l"), "Command-Shift-L is the host's")
    expect(!ViewerChord.matches(flags: all.union(.shift), key: "l", expected: "l"), "an extra Shift makes it another chord")
    expect(!ViewerChord.matches(flags: [.control, .command], key: "l", expected: "l"), "Control-Command-L is the host's")
    expect(!ViewerChord.matches(flags: all, key: "g", expected: "l"), "another key is not this chord")
    expect(!ViewerChord.matches(flags: all, key: nil, expected: "l"), "no key is not this chord")
    print("PASS: the viewer's own chords are exactly Control-Option-Command plus their key")
}
#endif
