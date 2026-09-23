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
}
