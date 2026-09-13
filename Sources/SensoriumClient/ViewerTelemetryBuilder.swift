import Foundation
import SensoriumCore

/// Turns what the viewer already holds -- its own per-surface percentiles, its
/// own byte count, and how many frames it has actually put on screen -- into
/// the one message the host has no other way to learn any of it from.
///
/// Pure and clock-injected: the only state it keeps is what the previous tick
/// saw, which is the minimum a rate needs and the reason a rate cannot be
/// computed from a single snapshot. Nothing here reaches for a connection, a
/// window, or `Date()`, so every number the viewer sends is verifiable without
/// a session.
public struct ViewerTelemetryBuilder: Sendable {
    private struct Tick {
        var presentedFrameCount: Int
        var decodedFrameCount: Int
        var atNanoseconds: Int64
    }

    /// Fixed two slots, matching the `{0, 1}` surfaceID cap everywhere else on
    /// the viewer. A surface outside it keeps no history, so it reports no
    /// rate rather than another surface's.
    private var lastTick: [Tick?] = [nil, nil]

    public init() {}

    /// One surface's reading for this tick. Every stage with no samples yet is
    /// absent rather than zero: a zero would tell the host the link is
    /// perfect, which is the one wrong answer a host steering its own encoder
    /// must never be given.
    ///
    /// The input round trip is deliberately not among them. The viewer
    /// measures it and shows it, but nothing a host does about a stream it is
    /// producing follows from how long a keystroke took to come back.
    public mutating func sample(
        surfaceID: UInt32,
        metrics: SessionMetrics,
        stream: ClientStreamReading,
        presentedFrameCount: Int,
        atNanoseconds now: Int64
    ) -> ViewerTelemetrySample {
        let sample = ViewerTelemetrySample(
            surfaceID: surfaceID,
            endToEnd: Self.stage(metrics, .endToEnd),
            receive: Self.stage(metrics, .receive),
            decode: Self.stage(metrics, .decode),
            presentedFramesPerSecond: rate(
                surfaceID: surfaceID,
                count: presentedFrameCount,
                atNanoseconds: now,
                since: \.presentedFrameCount
            ),
            decodedFramesPerSecond: rate(
                surfaceID: surfaceID,
                count: stream.decodedFrameCount,
                atNanoseconds: now,
                since: \.decodedFrameCount
            ),
            receivedBitsPerSecond: stream.bitsPerSecond
        )
        if let index = Self.index(for: surfaceID) {
            lastTick[index] = Tick(
                presentedFrameCount: presentedFrameCount,
                decodedFrameCount: stream.decodedFrameCount,
                atNanoseconds: now
            )
        }
        return sample
    }

    /// `nil` on a surface's first tick, since there is no earlier tick to
    /// measure a rate against -- the same rule the host's own
    /// `framesPerSecond` follows. Measured against the real gap between
    /// ticks rather than the nominal send interval: a tick that ran late
    /// would otherwise report a rate that never happened, and a host reading
    /// it would step fidelity down for nothing.
    private func rate(
        surfaceID: UInt32,
        count: Int,
        atNanoseconds now: Int64,
        since previousCount: KeyPath<Tick, Int>
    ) -> Double? {
        guard let index = Self.index(for: surfaceID), let previous = lastTick[index] else {
            return nil
        }
        let elapsedSeconds = Double(now - previous.atNanoseconds) / 1_000_000_000
        guard elapsedSeconds > 0, count >= previous[keyPath: previousCount] else {
            return nil
        }
        return Double(count - previous[keyPath: previousCount]) / elapsedSeconds
    }

    private static func stage(_ metrics: SessionMetrics, _ stage: SessionMetricStage) -> StageLatencySample? {
        let samples = metrics.samples(for: stage)
        guard let p50 = samples.p50, let p95 = samples.p95 else {
            return nil
        }
        return StageLatencySample(p50Nanoseconds: p50, p95Nanoseconds: p95)
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}
