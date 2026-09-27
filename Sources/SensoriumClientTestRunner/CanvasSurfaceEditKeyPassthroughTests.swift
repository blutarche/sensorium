#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

/// The real seam `testEditKeyPassthroughRoutingTests` cannot reach: whether
/// `CanvasSurfaceView.performKeyEquivalent(with:)` -- the method AppKit calls
/// on the whole key window's view hierarchy before it ever asks the menu bar
/// -- actually claims the six standard editing chords and forwards them,
/// exactly as it already claims Cmd-Q/W/H/M.
@MainActor
func testCanvasSurfaceEditKeyPassthroughTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport)
    let surface = CanvasSurfaceView(
        router: router,
        shortcutRouter: SystemShortcutRouter(mode: .default),
        accessibilityGranted: false,
        surfaceID: 0
    )
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
    surface.windowStateProvider = {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    }

    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    func keyEquivalentEvent(keyCode: UInt16, command: Bool, shift: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = [.command]
        if shift { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            expect(false, "AppKit refused a synthetic key-equivalent event")
            fatalError("unreachable")
        }
        return event
    }

    // Cmd-C: claimed here, and forwarded, exactly as Cmd-Q already is.
    let claimed = surface.performKeyEquivalent(with: keyEquivalentEvent(keyCode: 8, command: true))
    await settle()
    expect(claimed, "the canvas claims Cmd-C as a key equivalent, ahead of any Edit menu item")
    let sent = await sink.events
    expect(
        sent.contains { event in
            guard case let .key(keyCode, isDown, modifiers) = event else { return false }
            return keyCode == 8 && isDown && modifiers == [.command]
        },
        "and forwards it to the host, got \(sent)"
    )

    // Cmd-Shift-C (Share Clipboard) is a different chord and must not be
    // claimed by this same path -- the menu item, not the canvas, owns it.
    let clipboardClaimed = surface.performKeyEquivalent(
        with: keyEquivalentEvent(keyCode: 8, command: true, shift: true)
    )
    expect(!clipboardClaimed, "Cmd-Shift-C is left for its own menu item, not swept up as an edit chord")

    print("PASS: the canvas claims the standard editing chords as key equivalents and forwards them to the host")
}
#endif
