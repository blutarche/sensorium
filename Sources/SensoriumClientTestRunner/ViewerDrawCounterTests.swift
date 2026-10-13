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

/// The evidence that tells a display link that stopped firing from a main
/// thread that stopped running, fed timestamps instead of timers.
func testViewerDrawTimingTests() {
    let millisecond: Int64 = 1_000_000
    var timing = ViewerDrawTiming()
    expect(timing.take() == ViewerDrawWindow(), "a window with nothing in it reports none of the fields")

    timing.recordDraw(atNanoseconds: 1_000 * millisecond)
    expect(timing.take().longestDrawGapMilliseconds == nil, "one draw has no gap to a previous one")
    timing.recordDraw(atNanoseconds: 1_016 * millisecond)
    timing.recordDraw(atNanoseconds: 5_016 * millisecond)
    timing.recordDraw(atNanoseconds: 5_032 * millisecond)
    expect(timing.take().longestDrawGapMilliseconds == 4_000, "two draws 4 s apart give a 4000 ms longest gap")
    timing.recordDraw(atNanoseconds: 5_048 * millisecond)
    expect(
        timing.take().longestDrawGapMilliseconds == 16,
        "the gap resets with the window, but starts from the last draw before it"
    )

    timing.recordHeartbeat(atNanoseconds: 0, hidden: false)
    timing.recordHeartbeat(atNanoseconds: 50 * millisecond, hidden: false)
    timing.recordHeartbeat(atNanoseconds: 100 * millisecond, hidden: true)
    timing.recordHeartbeat(atNanoseconds: 1_650 * millisecond, hidden: false)
    let reading = timing.take()
    expect(
        reading.longestMainThreadStallMilliseconds == 1_500,
        "a tick 1550 ms after the last, due at 50, is a 1500 ms stall, got \(String(describing: reading.longestMainThreadStallMilliseconds))"
    )
    expect(reading.hiddenFraction == 0.25, "one of four ticks hidden is 0.25, got \(String(describing: reading.hiddenFraction))")
    expect(timing.take() == ViewerDrawWindow(), "the heartbeat window resets, leaving no fraction without ticks")

    timing.recordHeartbeat(atNanoseconds: 1_700 * millisecond, hidden: false)
    expect(timing.take().longestMainThreadStallMilliseconds == 0, "an on-time tick across windows is no stall")
    timing.recordHeartbeat(atNanoseconds: 1_720 * millisecond, hidden: false)
    expect(timing.take().longestMainThreadStallMilliseconds == 0, "an early tick is no stall")
    timing.restartHeartbeat()
    timing.recordHeartbeat(atNanoseconds: 9_000 * millisecond, hidden: false)
    expect(
        timing.take().longestMainThreadStallMilliseconds == nil,
        "a heartbeat stopped and started again does not count the pause as a stall"
    )
    print("PASS: draw gaps, main thread stalls and hidden share are measured per window from timestamps")
}
