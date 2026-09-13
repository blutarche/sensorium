import SensoriumCore

/// Turns `HostMediaLatencyRecorder`'s per-surface state into the wire
/// payload, one tick at a time. Pure and stateless except for the previous
/// tick's encoded-frame counts, which is what `framesPerSecond` is derived
/// from -- kept here rather than in the recorder because "rate since the
/// last telemetry tick" is a property of the telemetry cadence, not of the
/// latency bookkeeping itself.
///
/// Fidelity in force is supplied by the caller: it lives in
/// `HostSessionCoordinator` and is not derivable from the latency
/// bookkeeping.
///
/// A surface with no captured or encoded frames yet is omitted from the
/// result entirely, not included with every field `nil`/zero: the common
/// single-canvas session should not carry a second, empty surface entry on
/// every tick, and a viewer with no window for that surface has nothing to
/// do with an empty entry anyway.
public struct HostTelemetrySnapshotBuilder {
    private var previousEncoded = [Int?](repeating: nil, count: CanvasSurfaceID.capacity)
    private var previousAtNanoseconds: Int64?

    public init() {}

    public mutating func snapshot(
        metrics: (CanvasSurfaceID) -> SessionMetrics,
        frameCounts: (CanvasSurfaceID) -> HostFrameCounts,
        sendQueueDropped: (CanvasSurfaceID) -> Int,
        appliedStreamScale: (CanvasSurfaceID) -> Double?,
        sustainableScaleCeiling: (CanvasSurfaceID) -> Double?,
        clampedFromUserChoice: (CanvasSurfaceID) -> Double?,
        hostRequestedStreamScale: (CanvasSurfaceID) -> Double? = { _ in nil },
        appliedFramesPerSecond: (CanvasSurfaceID) -> Int?,
        qualityScale: (CanvasSurfaceID) -> Double?,
        fidelityLimitReason: (CanvasSurfaceID) -> String?,
        atNanoseconds now: Int64
    ) -> [SurfaceTelemetrySample] {
        var samples: [SurfaceTelemetrySample] = []
        for surface in CanvasSurfaceID.allCases {
            let counts = frameCounts(surface)
            guard counts.captured > 0 || counts.encoded > 0 else {
                previousEncoded[surface.index] = nil
                continue
            }
            let surfaceMetrics = metrics(surface)
            samples.append(SurfaceTelemetrySample(
                surfaceID: surface.wireValue,
                capture: stageSample(surfaceMetrics, .capture),
                encode: stageSample(surfaceMetrics, .encode),
                send: stageSample(surfaceMetrics, .send),
                framesPerSecond: framesPerSecond(surface: surface, encoded: counts.encoded, now: now),
                encoderInputDropped: counts.encoderInputDropped,
                globalAdmissionDropped: counts.globalAdmissionDropped,
                sendQueueDropped: sendQueueDropped(surface),
                appliedStreamScale: appliedStreamScale(surface),
                sustainableScaleCeiling: sustainableScaleCeiling(surface),
                clampedFromUserChoice: clampedFromUserChoice(surface),
                hostRequestedStreamScale: hostRequestedStreamScale(surface),
                appliedFramesPerSecond: appliedFramesPerSecond(surface),
                qualityScale: qualityScale(surface),
                fidelityLimitReason: fidelityLimitReason(surface)
            ))
            previousEncoded[surface.index] = counts.encoded
        }
        previousAtNanoseconds = now
        return samples
    }

    private func stageSample(_ metrics: SessionMetrics, _ stage: SessionMetricStage) -> StageLatencySample? {
        let samples = metrics.samples(for: stage)
        guard let p50 = samples.p50, let p95 = samples.p95 else {
            return nil
        }
        return StageLatencySample(p50Nanoseconds: p50, p95Nanoseconds: p95)
    }

    private mutating func framesPerSecond(surface: CanvasSurfaceID, encoded: Int, now: Int64) -> Double? {
        guard let previousAtNanoseconds, let previousEncoded = previousEncoded[surface.index],
              now > previousAtNanoseconds else {
            return nil
        }
        let seconds = Double(now - previousAtNanoseconds) / 1_000_000_000
        return Double(encoded - previousEncoded) / seconds
    }
}
