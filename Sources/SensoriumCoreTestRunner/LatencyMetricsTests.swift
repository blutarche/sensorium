import Foundation
import SensoriumCore

func testLatencyStatisticsComputePercentilesAndRejectBadSamples() {
    var samples = LatencySamples()
    expect(samples.percentile(0.5) == nil, "an empty sample set has no percentile")

    for nanoseconds in [30, 10, 50, 20, 40] {
        expect(samples.record(nanoseconds: Int64(nanoseconds)), "a positive sample is recorded")
    }
    expect(samples.count == 5, "every valid sample is counted")
    expect(samples.percentile(0.5) == 30, "p50 uses nearest-rank on sorted samples")
    expect(samples.percentile(0.95) == 50, "p95 reaches the slowest sample")
    expect(samples.percentile(0.2) == 10, "a low percentile reaches the fastest sample")

    expect(!samples.record(nanoseconds: -1), "a negative duration is rejected")
    expect(samples.count == 5, "a rejected sample does not change the distribution")
    expect(samples.percentile(0) == nil, "percentile zero is undefined")
    expect(samples.percentile(1.5) == nil, "a percentile above one is undefined")
}

/// Recording past `capacity` must evict the oldest sample, keep the ring's
/// own size capped, and still report a true lifetime `count` even though
/// the ring itself can no longer say how many samples ever passed through it.
func testLatencySamplesAreBoundedAndEvictTheOldest() {
    var samples = LatencySamples()
    for value in 0..<LatencySamples.capacity {
        expect(samples.record(nanoseconds: Int64(value)), "every value up to capacity is recorded")
    }
    expect(samples.count == LatencySamples.capacity, "count matches exactly at capacity")
    expect(samples.percentile(1.0) == Int64(LatencySamples.capacity - 1), "the ring holds every value up to capacity")

    // One more than capacity: the oldest value (0) must be evicted, not the
    // structure growing past its bound.
    expect(samples.record(nanoseconds: 999_999), "recording past capacity still succeeds")
    expect(samples.count == LatencySamples.capacity + 1, "count is a true lifetime total, unaffected by eviction")
    expect(samples.percentile(1.0) == 999_999, "the newest sample is present")
    expect(samples.percentile(0) == nil, "percentile zero is still undefined")
    // Filling the ring twice over must never grow it past capacity -- this
    // is the actual leak regression: an unbounded structure would keep
    // accepting samples at unbounded cost instead of wrapping.
    for value in 0..<(LatencySamples.capacity * 2) {
        _ = samples.record(nanoseconds: Int64(value) + 1_000_000)
    }
    expect(
        samples.count == LatencySamples.capacity + 1 + LatencySamples.capacity * 2,
        "count keeps counting past several times around the ring"
    )
    // Every value now in the ring came from the last fill loop (all
    // >= 1_000_000), proving nothing from before that loop survived --
    // the ring wrapped rather than growing to hold all of it.
    expect(samples.percentile(0) == nil, "still undefined")
    let median = samples.percentile(0.5)
    expect(median != nil && median! >= 1_000_000, "old, evicted samples never influence a later percentile")
}

func testStageMetricsRejectOutOfOrderTimestamps() {
    var metrics = SessionMetrics()
    expect(
        metrics.record(stage: .encode, startedAtNanoseconds: 100, endedAtNanoseconds: 400),
        "a forward-ordered stage sample is recorded"
    )
    expect(
        !metrics.record(stage: .encode, startedAtNanoseconds: 400, endedAtNanoseconds: 100),
        "an out-of-order stage sample is rejected"
    )
    expect(metrics.samples(for: .encode).count == 1, "only the ordered sample survives")
    expect(metrics.samples(for: .decode).count == 0, "stages are measured independently")
    expect(metrics.samples(for: .encode).percentile(0.5) == 300, "stage latency is the elapsed duration")
}

func testMediaFlowMonitorReportsRatesAndSilence() {
    var monitor = MediaFlowMonitor(reportInterval: 1, silenceThreshold: 1.5)
    expect(
        monitor.record(packetBytes: 100, droppedFramesTotal: 20, atSeconds: 0) == nil,
        "the monitor does not report before its first interval"
    )
    expect(
        monitor.record(packetBytes: 100, droppedFramesTotal: 20, atSeconds: 0.5) == nil,
        "the monitor stays quiet inside an interval"
    )

    guard let report = monitor.record(packetBytes: 300, droppedFramesTotal: 21, atSeconds: 1.0) else {
        expect(false, "the monitor reports once its interval elapses")
        return
    }
    expect(report.frames == 3, "the report counts every frame in the interval")
    expect(report.bytes == 500, "the report totals the bytes in the interval")
    expect(report.framesPerSecond == 3, "the report states the observed frame rate")
    expect(
        report.droppedFrames == 1,
        "the report counts the frames dropped inside this interval, not every one the session has ever dropped"
    )

    expect(
        monitor.record(packetBytes: 10, droppedFramesTotal: 21, atSeconds: 1.2) == nil,
        "counting restarts after a report"
    )
    guard let second = monitor.record(packetBytes: 10, droppedFramesTotal: 21, atSeconds: 2.2) else {
        expect(false, "the monitor reports again once the next interval elapses")
        return
    }
    expect(
        second.droppedFrames == 0,
        "an interval that dropped nothing says so, however many the intervals before it dropped"
    )

    // Two streams share one monitor, so two readings of one running total can
    // reach it in the other order. A total lower than the one this interval
    // opened with is not evidence that frames came back.
    _ = monitor.record(packetBytes: 10, droppedFramesTotal: 21, atSeconds: 2.4)
    guard let third = monitor.record(packetBytes: 10, droppedFramesTotal: 20, atSeconds: 3.4) else {
        expect(false, "the monitor reports again once the next interval elapses")
        return
    }
    expect(
        third.droppedFrames == 0,
        "a total that reads lower than the one the interval opened with is never a negative count, got \(third.droppedFrames)"
    )
    // And the interval after it opens from the highest total seen, not from
    // the low reading: opening from 20 would charge the next interval for the
    // twenty-first drop, which the first interval already reported.
    _ = monitor.record(packetBytes: 10, droppedFramesTotal: 21, atSeconds: 3.6)
    guard let fourth = monitor.record(packetBytes: 10, droppedFramesTotal: 21, atSeconds: 4.6) else {
        expect(false, "the monitor reports again once the next interval elapses")
        return
    }
    expect(
        fourth.droppedFrames == 0,
        "a drop already reported is never reported again because one reading arrived out of order, got \(fourth.droppedFrames)"
    )

    guard let silence = monitor.checkForSilence(atSeconds: 6.4) else {
        expect(false, "a stream that stops delivering frames is reported as silent")
        return
    }
    expect(silence >= 1.7, "the silence report says how long it has been since the last frame")
    expect(monitor.checkForSilence(atSeconds: 6.5) == nil, "silence is reported once, not every tick")
}

