#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

/// A sink whose first send waits until `release()`, so a test can hold one
/// event in flight while later ones arrive.
private actor GatedInputSink: CanvasInputSending {
    private(set) var events: [SensoriumInputEvent] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var isFirstSend = true
    private var isOpen = false

    func sendInput(_ event: SensoriumInputEvent) async {
        if isFirstSend {
            isFirstSend = false
            if !isOpen {
                await withCheckedContinuation { waiter = $0 }
            }
        }
        events.append(event)
    }

    func release() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async {}
    func sendStreamScalePreference(_ preference: StreamScalePreference) async {}
}

/// Events leave `CanvasSurfaceView` in the order AppKit delivered them, even
/// while an earlier one is still being sent.
@MainActor
func testCanvasSurfaceInputOrderTests() async {
    let sink = GatedInputSink()
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
    surface.windowStateProvider = {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    }

    func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    func keyEvent(_ type: NSEvent.EventType) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            expect(false, "AppKit refused a synthetic key event")
            fatalError("unreachable")
        }
        return event
    }

    surface.keyDown(with: keyEvent(.keyDown))
    surface.keyUp(with: keyEvent(.keyUp))
    await settle()
    let early = await sink.events
    expect(early.isEmpty, "a key-up does not overtake the key-down still being sent, got \(early)")
    await sink.release()
    await settle()
    let sent = await sink.events
    expect(
        sent == [
            .key(keyCode: 0, isDown: true, modifiers: []),
            .key(keyCode: 0, isDown: false, modifiers: [])
        ],
        "the key-down reaches the host before its key-up, got \(sent)"
    )
    print("PASS: the canvas view sends events to the host in the order AppKit delivered them")
}
#endif
