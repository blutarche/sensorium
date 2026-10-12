import Foundation
import SensoriumClient
import SensoriumCore

/// What the viewer's draw callbacks did, counted for the life of a window and
/// turned into per-second rates one tick at a time.
func testViewerDrawCounterTests() {
    let counter = ViewerDrawCounter()
    expect(counter.counts == ViewerDrawCounts(), "nothing has been drawn at the start")

    counter.recordDraw()
    counter.recordDraw()
    counter.recordDraw()
    counter.recordNotShown(.noDrawable)
    counter.recordNotShown(.noDrawable)
    counter.recordNotShown(.noCommandBuffer)
    counter.recordNotShown(.emptyDestination)
    counter.recordNotShown(.renderFailure)
    expect(
        counter.counts == ViewerDrawCounts(
            draws: 3, noDrawable: 2, noCommandBuffer: 1, emptyDestination: 1, renderFailure: 1
        ) && counter.counts.notShown == 5,
        "every draw callback and every reason a waiting frame was not shown is counted apart, got \(counter.counts)"
    )

    var builder = ViewerTelemetryBuilder()
    let second: Int64 = 1_000_000_000
    let stream = ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil)
    let first = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: stream,
        presentedFrameCount: 0,
        drawCounts: ViewerDrawCounts(draws: 100, noDrawable: 10),
        atNanoseconds: 10 * second
    )
    expect(first.drawReport == nil, "with no earlier tick there is no report, not a report of zeroes")
    let next = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: stream,
        presentedFrameCount: 0,
        drawCounts: ViewerDrawCounts(
            draws: 160, noDrawable: 24, noCommandBuffer: 1, emptyDestination: 2, renderFailure: 3
        ),
        atNanoseconds: 11 * second
    )
    expect(
        next.drawReport == ViewerDrawReport(
            drawsPerSecond: 60,
            noDrawablePerSecond: 14,
            noCommandBufferPerSecond: 1,
            emptyDestinationPerSecond: 2,
            renderFailurePerSecond: 3
        ),
        "each count becomes a rate over the real gap between ticks, got \(String(describing: next.drawReport))"
    )
    let halfTick = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: stream,
        presentedFrameCount: 0,
        drawCounts: ViewerDrawCounts(
            draws: 190, noDrawable: 31, noCommandBuffer: 1, emptyDestination: 2, renderFailure: 3
        ),
        atNanoseconds: 11 * second + second / 2
    )
    expect(
        halfTick.drawReport?.drawsPerSecond == 60 && halfTick.drawReport?.noDrawablePerSecond == 14,
        "a tick that came half a second later is measured over that half second"
    )
    let withoutCounts = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: stream,
        presentedFrameCount: 0,
        atNanoseconds: 13 * second
    )
    expect(withoutCounts.drawReport == nil, "a window that counts no draws reports no draw report")
    print("PASS: draw callbacks are counted by reason and reported as rates over the real gap between ticks")
}
