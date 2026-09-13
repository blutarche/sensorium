import SensoriumCore
import Foundation

/// Timestamps one frame collects on its way through the viewer. `nil` timing
/// means the frame was never tied to a receipt, so it is presented but not
/// measured — a missing sample, never an invented one.
public struct FrameTiming: Equatable, Sendable {
    public let hostCapturedAtNanoseconds: Int64
    public let receivedAtNanoseconds: Int64
    public let decodedAtNanoseconds: Int64

    public init(
        hostCapturedAtNanoseconds: Int64,
        receivedAtNanoseconds: Int64,
        decodedAtNanoseconds: Int64
    ) {
        self.hostCapturedAtNanoseconds = hostCapturedAtNanoseconds
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.decodedAtNanoseconds = decodedAtNanoseconds
    }
}

/// The viewer's latency bookkeeping for one session: it issues the time-sync
/// requests, folds in the replies, and turns presented frames into percentiles.
public actor SessionLatencyMonitor {
    private var recorder = SessionLatencyRecorder()
    /// A second, per-surface view of the same presented frames, kept
    /// alongside the session-wide `recorder` above rather than instead of
    /// it: `metrics()`/`summaryLine()` stay session-wide.
    /// Fixed two slots, matching the `{0, 1}` surfaceID cap everywhere else
    /// on the viewer -- an out-of-range surfaceID is dropped, not stored.
    private var surfaceMetrics: [SessionMetrics] = [SessionMetrics(), SessionMetrics()]
    private var trace: LatencyTraceWriter?
    /// Frames this viewer gave up rather than showed, across every canvas of
    /// this session. Set from the counters the windows keep, on the session's
    /// telemetry tick, rather than counted here: the drops happen on the
    /// decode path, which cannot afford to await an actor.
    private var droppedAtViewer = 0

    public init() {}

    public func attachTrace(_ writer: LatencyTraceWriter) {
        trace = writer
    }

    public func makeClockRequest(atNanoseconds now: Int64) -> SensoriumMessage {
        recorder.makeClockRequest(atNanoseconds: now)
    }

    @discardableResult
    public func receiveClockReply(
        clientTimeNanoseconds: Int64,
        hostTimeNanoseconds: Int64,
        receivedAtNanoseconds: Int64
    ) -> Bool {
        recorder.receiveClockReply(
            clientTimeNanoseconds: clientTimeNanoseconds,
            hostTimeNanoseconds: hostTimeNanoseconds,
            receivedAtNanoseconds: receivedAtNanoseconds
        )
    }

    /// `surfaceID` defaults to 0, the only canvas a single-window session has.
    @discardableResult
    public func recordPresentedFrame(
        surfaceID: UInt32 = 0,
        timing: FrameTiming,
        presentedAtNanoseconds: Int64
    ) -> Bool {
        let recordedAggregate = recorder.recordFrame(
            hostCapturedAtNanoseconds: timing.hostCapturedAtNanoseconds,
            receivedAtNanoseconds: timing.receivedAtNanoseconds,
            decodedAtNanoseconds: timing.decodedAtNanoseconds,
            presentedAtNanoseconds: presentedAtNanoseconds
        )
        if let index = Self.index(for: surfaceID) {
            // Reuses the one clock synchronizer `recorder` already owns:
            // both machines' clock offset is a property of the session, not
            // of one surface, so there is exactly one to read here.
            _ = surfaceMetrics[index].recordFrame(
                capturedInClientTimeNanoseconds: recorder.clientTime(
                    forHostCapturedAtNanoseconds: timing.hostCapturedAtNanoseconds
                ),
                receivedAtNanoseconds: timing.receivedAtNanoseconds,
                decodedAtNanoseconds: timing.decodedAtNanoseconds,
                presentedAtNanoseconds: presentedAtNanoseconds
            )
        }
        return recordedAggregate
    }

    public func metrics() -> SessionMetrics {
        recorder.metrics
    }

    /// A running total, not an increment: the windows' own counters are
    /// cumulative, so a tick that read the same number twice must not report
    /// it twice.
    public func setDroppedAtViewerCount(_ count: Int) {
        droppedAtViewer = max(0, count)
    }

    /// Records one `input`/`inputApplied` round trip under
    /// `SessionMetricStage.inputRoundTrip` -- see `ClientSessionController.recordInputApplied`,
    /// the receive loop's own caller.
    @discardableResult
    public func recordInputRoundTrip(sentAtNanoseconds: Int64, repliedAtNanoseconds: Int64) -> Bool {
        recorder.recordInputRoundTrip(sentAtNanoseconds: sentAtNanoseconds, repliedAtNanoseconds: repliedAtNanoseconds)
    }

    /// This surface's own decode/present/receive/end-to-end percentiles.
    /// `SessionMetrics()` (no samples) for a surfaceID outside `{0, 1}`.
    public func metrics(forSurfaceID surfaceID: UInt32) -> SessionMetrics {
        guard let index = Self.index(for: surfaceID) else {
            return SessionMetrics()
        }
        return surfaceMetrics[index]
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }

    /// `nil` until an end-to-end sample exists. A session that never
    /// synchronised its clocks reports nothing, which is the honest answer.
    public func summaryLine() -> String? {
        let endToEnd = recorder.metrics.samples(for: .endToEnd)
        guard let p50 = endToEnd.p50,
              let p95 = endToEnd.p95,
              let offset = recorder.clockOffsetNanoseconds,
              let roundTrip = recorder.clockRoundTripNanoseconds else {
            return nil
        }
        var line = "latency \(endToEnd.count) frames; end-to-end p50 \(milliseconds(p50))ms p95 \(milliseconds(p95))ms; "
            + "decode p50 \(milliseconds(recorder.metrics.samples(for: .decode).p50 ?? 0))ms; "
            + "clock offset \(milliseconds(offset))ms over a \(milliseconds(roundTrip))ms round trip"
        let inputRoundTrip = recorder.metrics.samples(for: .inputRoundTrip)
        if let inputP50 = inputRoundTrip.p50, let inputP95 = inputRoundTrip.p95 {
            line += "; input round trip p50 \(milliseconds(inputP50))ms p95 \(milliseconds(inputP95))ms"
        }
        // Named only when it happened. A session that showed every frame it
        // received has nothing to report here, and a "0" would invite the
        // reader to wonder what it was counting.
        if droppedAtViewer > 0 {
            line += "; dropped at viewer \(droppedAtViewer)"
        }
        // Named only when it happened. A session that showed every frame it
        // received has nothing to report here, and a "0" would invite the
        // reader to wonder what it was counting.
        return line
    }

    public func writeTrace() {
        try? trace?.write(recorder.metrics)
    }

    private func milliseconds(_ nanoseconds: Int64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1_000_000)
    }
}
