#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

/// AppKit delivers the middle button and the side buttons alike as
/// other-mouse events, told apart only by `buttonNumber`: 2 is middle, and
/// 3 and 4 are the side buttons a browser reads as Back and Forward.
@MainActor
func testCanvasSurfaceOtherButtonTests() async {
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
    _ = await router.route(.boundsChanged(width: 960, height: 600))

    func event(_ type: NSEvent.EventType, buttonNumber: Int64) -> NSEvent {
        guard let synthetic = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 480, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let cgEvent = synthetic.cgEvent else {
            expect(false, "AppKit refused a synthetic \(type) event")
            fatalError("unreachable")
        }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        guard let numbered = NSEvent(cgEvent: cgEvent), numbered.buttonNumber == Int(buttonNumber) else {
            expect(false, "AppKit did not keep button number \(buttonNumber) on a synthetic \(type) event")
            fatalError("unreachable")
        }
        return numbered
    }
    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    for buttonNumber: Int64 in [2, 3, 4, 5, 7] {
        surface.otherMouseDown(with: event(.otherMouseDown, buttonNumber: buttonNumber))
        surface.otherMouseUp(with: event(.otherMouseUp, buttonNumber: buttonNumber))
    }
    await settle()
    let buttons = await sink.events.compactMap { sent -> String? in
        guard case let .pointerButton(button, isDown, _, _) = sent else { return nil }
        return "\(button.rawValue) \(isDown ? "down" : "up")"
    }
    expect(
        buttons == ["middle down", "middle up", "back down", "back up", "forward down", "forward up"],
        "button 2 is middle, 3 back, 4 forward, and a button past those is not forwarded at all, got \(buttons)"
    )
    print("PASS: the canvas view forwards other-mouse buttons 2, 3 and 4 as middle, back and forward, and no other")
}
#endif
