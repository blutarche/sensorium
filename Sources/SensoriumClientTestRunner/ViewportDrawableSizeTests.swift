import Foundation
import SensoriumClient
import SensoriumCore

/// A window can be asked for its size before the compositor has ever given it
/// one. What must not happen then is a stream scale derived from nothing: a
/// zero-sized report is refused outright, nothing is sent to the host, and the
/// size the viewport already knew is left standing.
@MainActor
func testViewportDrawableSizeTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()

    let real = await viewport.setDrawableSize(pixelWidth: 3840, pixelHeight: 2400)
    expect(real == .sent(2), "a real drawable size derives a stream scale and is sent: \(real)")

    let zero = await viewport.setDrawableSize(pixelWidth: 0, pixelHeight: 0)
    expect(zero == .invalid, "a zero drawable size is refused rather than sent: \(zero)")
    let sentSizes = await sink.drawableSizes.count
    expect(sentSizes == 1, "nothing is sent to the host for a zero drawable size: \(sentSizes) reports")
    let keptWidth = await viewport.requestedDrawablePixelWidth
    expect(keptWidth == 3840, "the size the viewport already knew survives a zero report: \(keptWidth ?? -1)")

    print("PASS: a zero drawable size is refused, sends nothing to the host, and leaves the known size standing")

    // A window's menus follow the geometry the host named, including a later
    // change of display mode, not the session-canvas preset it started with.
    let geometryViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: RecordingInputSink()
    )
    let heard = GeometryLog()
    await geometryViewport.setGeometryObserver { width, height in heard.record(width, height) }
    await geometryViewport.updateMapper(geometry: SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2))
    await geometryViewport.updateMapper(geometry: SessionSurfaceGeometry(logicalWidth: 1728, logicalHeight: 1117, backingScale: 2))
    expect(
        heard.sizes == [[1920, 1200], [2560, 1440], [1728, 1117]],
        "the observer hears the starting size, then every geometry the host names: \(heard.sizes)"
    )
    var model = SessionControlsWindowModel()
    model.updateStreamGeometry(logicalWidth: 2560, logicalHeight: 1440)
    let titles = model.menuBarState(isPointerCaptured: false, isFullscreen: false).streamScale.items.map(\.title)
    expect(
        titles.contains("1.00x (2560 \u{00D7} 1440)") && !titles.contains { $0.contains("1920") },
        "the scale rows label the live 2560x1440 geometry, not the 1920x1200 preset: \(titles)"
    )
    print("PASS: the scale menu follows the geometry the host named for the session")
}

private final class GeometryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [[Double]] = []

    func record(_ width: Double, _ height: Double) {
        lock.lock()
        defer { lock.unlock() }
        heard.append([width, height])
    }

    var sizes: [[Double]] {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }
}
