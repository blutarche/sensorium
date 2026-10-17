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
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    func scrollEvent(units: CGScrollEventUnit, amount: Int32) -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 1,
            wheel1: amount,
            wheel2: 0,
            wheel3: 0
        ), let event = NSEvent(cgEvent: cgEvent) else {
            expect(false, "AppKit refused a synthetic scroll event")
            fatalError("unreachable")
        }
        return event
    }

    func scrolledDeltaY() async -> Double? {
        await settle()
        for event in await sink.events {
            if case let .scrolled(_, deltaY, _, _, _, _) = event { return deltaY }
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
        if case let .scrolled(_, deltaY, _, _, _, _) = event { return deltaY }
        return nil
    }.first
    expect(pixelDelta == 3, "a precise scroll of 3 stays 3, got \(String(describing: pixelDelta))")
    print("PASS: a line-based wheel scrolls by points per notch and a precise scroll is unchanged")
}
#endif
