#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

/// Every key the canvas view forwards says whether Caps Lock is on at this
/// machine, read from the event AppKit delivered, so the host can type
/// capitals while it is.
@MainActor
func testCanvasSurfaceCapsLockTests() async {
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
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
    surface.windowStateProvider = {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    }

    func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
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
            expect(false, "AppKit refused a synthetic \(type) event")
            fatalError("unreachable")
        }
        return event
    }
    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    surface.keyDown(with: keyEvent(.keyDown, keyCode: 0, flags: [.capsLock]))
    surface.keyUp(with: keyEvent(.keyUp, keyCode: 0, flags: [.capsLock]))
    surface.keyDown(with: keyEvent(.keyDown, keyCode: 0, flags: []))
    surface.keyUp(with: keyEvent(.keyUp, keyCode: 0, flags: []))
    surface.flagsChanged(with: keyEvent(.flagsChanged, keyCode: 57, flags: [.capsLock]))
    surface.flagsChanged(with: keyEvent(.flagsChanged, keyCode: 57, flags: []))
    await settle()
    let sent = await sink.events.compactMap { event -> String? in
        guard case let .key(keyCode, isDown, modifiers, capsLock) = event else { return nil }
        return "\(keyCode) \(isDown ? "down" : "up") \(modifiers.rawValue) \(capsLock.map { $0 ? "on" : "off" } ?? "unsaid")"
    }
    expect(
        sent == ["0 down 0 on", "0 up 0 on", "0 down 0 off", "0 up 0 off", "57 down 0 on", "57 up 0 off"],
        "every forwarded key carries this machine's Caps Lock state and no modifier bit for it, got \(sent)"
    )
    print("PASS: the canvas view sends this machine's Caps Lock state on every key it forwards")
}
#endif
