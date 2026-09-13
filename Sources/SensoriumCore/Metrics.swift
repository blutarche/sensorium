import Foundation

/// Nearest-rank percentiles over the most recent recorded durations. Rejects
/// impossible samples rather than letting a negative duration flatter a
/// latency report.
///
/// Bounded at `capacity` rather than exact over the session:
/// `percentile(_:)` reflects only the newest `capacity` samples, which is
/// what a live reading of current latency wants. `count` stays a true
/// lifetime total.
public struct LatencySamples: Equatable, Sendable {
    /// ~68 seconds of samples at 60fps: a hard cap for a session running for
    /// hours.
    public static let capacity = 4096

    private var ring: [Int64] = []
    private var writeIndex = 0
    private var totalRecorded = 0

    public init() {}

    public var count: Int { totalRecorded }

    @discardableResult
    public mutating func record(nanoseconds: Int64) -> Bool {
        guard nanoseconds >= 0 else {
            return false
        }
        if ring.count < Self.capacity {
            ring.append(nanoseconds)
        } else {
            ring[writeIndex] = nanoseconds
            writeIndex = (writeIndex + 1) % Self.capacity
        }
        totalRecorded += 1
        return true
    }

    /// `percentile` is exclusive of zero and inclusive of one. Sorts a
    /// snapshot of the ring on every call rather than keeping it sorted on
    /// every `record(nanoseconds:)`: queries (a HUD tick, a written trace
    /// line) are far rarer than 60fps writes, and `capacity` bounds the sort
    /// itself to a few thousand elements either way.
    public func percentile(_ percentile: Double) -> Int64? {
        guard percentile > 0, percentile <= 1, !ring.isEmpty else {
            return nil
        }
        let sorted = ring.sorted()
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    public var p50: Int64? { percentile(0.5) }
    public var p95: Int64? { percentile(0.95) }
}

public enum SessionMetricStage: String, CaseIterable, Equatable, Sendable {
    case capture
    /// Host-only: a frame's own capture callback to the moment it is handed
    /// to the encoder (`VTCompressionSessionEncodeFrame`) -- the admission
    /// queue wait and the session/machine encode-gate wait, with the actual
    /// encode compute excluded. It ends exactly where `encode` begins, so the
    /// two never overlap and a queue that is backing up cannot be mistaken
    /// for an encoder that has slowed down.
    case admit
    /// On the host, the encoder alone: `VTCompressionSessionEncodeFrame` to
    /// that frame's compression output callback, with the wait ahead of it
    /// left to `admit`.
    case encode
    case send
    case receive
    case decode
    case present
    case inputRoundTrip
    /// Host capture to client present, across both machines. Only measurable
    /// once a clock offset exists.
    case endToEnd
}

/// Per-stage latency for one session. Timestamps come from a monotonic clock at
/// the call site; this type only measures the intervals between them.
public struct SessionMetrics: Equatable, Sendable {
    private var stages: [SessionMetricStage: LatencySamples] = [:]

    public init() {}

    @discardableResult
    public mutating func record(
        stage: SessionMetricStage,
        startedAtNanoseconds: Int64,
        endedAtNanoseconds: Int64
    ) -> Bool {
        guard endedAtNanoseconds >= startedAtNanoseconds else {
            return false
        }
        var samples = stages[stage] ?? LatencySamples()
        let recorded = samples.record(nanoseconds: endedAtNanoseconds - startedAtNanoseconds)
        stages[stage] = samples
        return recorded
    }

    public func samples(for stage: SessionMetricStage) -> LatencySamples {
        stages[stage] ?? LatencySamples()
    }

    /// Records one presented frame's client-local stages, and its
    /// cross-machine ones once a capture time translated into client time is
    /// available. Pulled out of `SessionLatencyRecorder` so a per-surface
    /// `SessionMetrics` can record the identical rule without duplicating it
    /// or owning a clock synchronizer of its own.
    ///
    /// Returns whether the host-relative stages were recorded; the
    /// client-local stages (`decode`, `present`) are recorded either way.
    @discardableResult
    public mutating func recordFrame(
        capturedInClientTimeNanoseconds: Int64?,
        receivedAtNanoseconds: Int64,
        decodedAtNanoseconds: Int64,
        presentedAtNanoseconds: Int64
    ) -> Bool {
        record(stage: .decode, startedAtNanoseconds: receivedAtNanoseconds, endedAtNanoseconds: decodedAtNanoseconds)
        record(stage: .present, startedAtNanoseconds: decodedAtNanoseconds, endedAtNanoseconds: presentedAtNanoseconds)
        guard let capturedInClientTimeNanoseconds, capturedInClientTimeNanoseconds <= receivedAtNanoseconds else {
            return false
        }
        record(stage: .receive, startedAtNanoseconds: capturedInClientTimeNanoseconds, endedAtNanoseconds: receivedAtNanoseconds)
        return record(stage: .endToEnd, startedAtNanoseconds: capturedInClientTimeNanoseconds, endedAtNanoseconds: presentedAtNanoseconds)
    }

    /// One JSON line per stage that has samples, ordered for stable diffs.
    public func traceLines(session: String? = nil) -> [String] {
        SessionMetricStage.allCases.compactMap { stage in
            let samples = samples(for: stage)
            guard let p50 = samples.p50, let p95 = samples.p95 else {
                return nil
            }
            let label = session.map { #""session":"\#($0)","# } ?? ""
            return #"{\#(label)"stage":"\#(stage.rawValue)","count":\#(samples.count),"p50Nanoseconds":\#(p50),"p95Nanoseconds":\#(p95)}"#
        }
    }
}
