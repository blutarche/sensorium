import CoreMedia
import Foundation
import SensoriumCore

/// The same presentation-time-to-nanoseconds conversion `H264SampleBufferPacketizer`
/// uses, so a capture/encode timestamp and a packet's `presentationTimeNanoseconds`
/// are directly comparable keys.
@available(macOS 13.0, *)
enum CMSampleBufferPresentationTiming {
    static func nanoseconds(_ sampleBuffer: CMSampleBuffer) -> Int64? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return nil }
        let scaledTime = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        guard scaledTime.value >= 0 else { return nil }
        return scaledTime.value
    }
}

/// Plain, unconditional per-stage counters: incremented once per callback no
/// matter what the percentile matching above decides, so they cannot be
/// fooled by a rejected or unmatched percentile sample. This is the ground
/// truth to reconcile `SessionMetrics.samples(for:).count` against.
public struct HostFrameCounts: Equatable, Sendable {
    public let captured: Int
    public let encoded: Int
    public let encodeSubmissionFailures: Int
    /// Captured frames dropped before they ever reached the encoder because
    /// capture outran it, per `EncodeAdmissionGate`.
    public let encoderInputDropped: Int
    /// Frames dropped by `SharedEncodeAdmissionGate` because the shared
    /// bound across every pipeline was reached, distinct from
    /// `encoderInputDropped`, which is this one pipeline's own local bound.
    public let globalAdmissionDropped: Int
    /// Frames that reached the encoder and never came back out as a picture:
    /// VideoToolbox dropped them, or the pipeline was torn down before they
    /// could be submitted. Distinct from both drop counters above, which
    /// count frames that never reached the encoder at all, and from
    /// `encodeSubmissionFailures`, which counts the ones it reported an error
    /// for. Without this, the difference between `captured` and `encoded`
    /// has no name and an encoder quietly discarding frames looks like a
    /// healthy stream that simply produced fewer.
    public let encoderOutputDropped: Int
    /// Frames this host asked the encoder for rather than ones capture
    /// delivered: today, the whole frame a still screen is sent of the picture
    /// it is holding. Counted inside `captured`, because that is what happened
    /// to it, and reported separately so a reader asking what the screen did
    /// can subtract it -- one host-requested frame is not the screen changing.
    public let hostRequested: Int
    /// Complete frames the capture stream delivered with an empty dirty-rect
    /// list: the same picture again, neither encoded nor counted as capture.
    /// Counted so a log can say what a stream delivers while a screen sits
    /// still, which is invisible everywhere downstream of the encoder because
    /// a still screen produces no packets at all.
    public let unchangedFrames: Int
    /// `.idle` notices from the capture stream: no change, and no picture
    /// attached. Separate from `unchangedFrames` because which of the two a
    /// static display sends is exactly what a live log has to settle.
    public let noChangeNotices: Int
    /// Deliveries that were neither a change, an unchanged frame, nor a
    /// no-change notice -- `.blank`, `.suspended`, `.started`, `.stopped`, or
    /// a sample with no status attachment at all. Counted separately so a
    /// stream delivering only these does not read the same as one that has
    /// stopped delivering altogether: both would otherwise report zero
    /// everywhere this struct is read.
    public let otherStatusDeliveries: Int

    public init(
        captured: Int,
        encoded: Int,
        encodeSubmissionFailures: Int,
        encoderInputDropped: Int = 0,
        globalAdmissionDropped: Int = 0,
        encoderOutputDropped: Int = 0,
        hostRequested: Int = 0,
        unchangedFrames: Int = 0,
        noChangeNotices: Int = 0,
        otherStatusDeliveries: Int = 0
    ) {
        self.captured = captured
        self.encoded = encoded
        self.encodeSubmissionFailures = encodeSubmissionFailures
        self.encoderInputDropped = encoderInputDropped
        self.globalAdmissionDropped = globalAdmissionDropped
        self.encoderOutputDropped = encoderOutputDropped
        self.hostRequested = hostRequested
        self.unchangedFrames = unchangedFrames
        self.noChangeNotices = noChangeNotices
        self.otherStatusDeliveries = otherStatusDeliveries
    }
}

/// Host-side per-frame latency, matched by presentation timestamp across the
/// capture callback, the encoder's compressed-output callback, and the moment
/// the encoded packet is actually handed off to the transport.
///
/// Every stage boundary is looked up by presentation timestamp rather than
/// assumed to be the next call: a frame whose earlier stage was never
/// recorded (or already consumed) produces no sample for the later stage,
/// never a wrong one. `SessionMetrics.record` already refuses a negative
/// interval, so a clock mismatch shows up as a missing sample too.
public final class HostMediaLatencyRecorder: @unchecked Sendable {
    /// Two canvases capture independently and can legitimately produce frames
    /// sharing one presentation timestamp, so the timestamp alone does not
    /// identify a frame: one surface's entry would overwrite the other's and
    /// the stage intervals would be matched across surfaces. Mirrors the
    /// viewer's `FrameReceiptLedger` key.
    private struct SurfaceFrameKey: Hashable {
        let surface: CanvasSurfaceID
        let presentationTimeNanoseconds: Int64
    }

    /// Mutable counterpart to `HostFrameCounts`, one per surface, so the
    /// per-surface accessor below can build the public, immutable value on
    /// read without the surface slots ever exposing their storage directly.
    private struct MutableFrameCounts {
        var captured = 0
        var encoded = 0
        var encodeSubmissionFailures = 0
        var encoderInputDropped = 0
        var globalAdmissionDropped = 0
        var encoderOutputDropped = 0
        var hostRequested = 0
        var unchangedFrames = 0
        var noChangeNotices = 0
        var otherStatusDeliveries = 0

        var value: HostFrameCounts {
            HostFrameCounts(
                captured: captured,
                encoded: encoded,
                encodeSubmissionFailures: encodeSubmissionFailures,
                encoderInputDropped: encoderInputDropped,
                globalAdmissionDropped: globalAdmissionDropped,
                encoderOutputDropped: encoderOutputDropped,
                hostRequested: hostRequested,
                unchangedFrames: unchangedFrames,
                noChangeNotices: noChangeNotices,
                otherStatusDeliveries: otherStatusDeliveries
            )
        }
    }

    private let lock = NSLock()
    private var metricsValue = SessionMetrics()
    private var captureEntries: [SurfaceFrameKey: Int64] = [:]
    private var encodeEntries: [SurfaceFrameKey: Int64] = [:]
    /// When a frame was actually handed to the encoder (`recordEncodeSubmit`),
    /// distinct from `captureEntries`: capture happens before this frame's
    /// admission-queue and session/machine-gate wait, submit happens after
    /// it, immediately before `VTCompressionSessionEncodeFrame`. This is the
    /// start point both the session-wide `.encode` stage and the
    /// sustainability checkpoint below measure from, so neither one charges
    /// the encoder for time the frame spent waiting to reach it.
    private var submitEntries: [SurfaceFrameKey: Int64] = [:]
    private var capturedFrameCount = 0
    private var encodedFrameCount = 0
    private var encodeSubmissionFailureCount = 0
    private var encoderInputDroppedCount = 0
    private var globalAdmissionDroppedCount = 0
    private var encoderOutputDroppedCount = 0
    private var hostRequestedFrameCount = 0
    private var unchangedFrameCount = 0
    private var noChangeNoticeCount = 0
    private var otherStatusDeliveryCount = 0
    /// A per-surface view of the same events; the session-wide totals feed
    /// the end-of-session summary and stay as they are.
    private var perSurfaceMetrics = CanvasSurfaceSlots<SessionMetrics> { _ in SessionMetrics() }
    private var perSurfaceCounts = CanvasSurfaceSlots<MutableFrameCounts> { _ in MutableFrameCounts() }
    /// Encode-stage latency since that surface's last `resetEncodeCheckpoint`
    /// call. `perSurfaceMetrics`'s percentile is cumulative for the whole
    /// session, which is exactly wrong for asking "is the scale applied
    /// *right now* sustainable" -- a scale that ran fine for minutes before
    /// a viewer enlarged the window would still look fine in a percentile
    /// dominated by those old, cheap samples.
    private var perSurfaceEncodeCheckpoint = CanvasSurfaceSlots<LatencySamples> { _ in LatencySamples() }
    /// Set by `resetEncodeCheckpoint`, cleared by the next recorded sample:
    /// the first frame out of a freshly (re)built `VTCompressionSession` is
    /// its opening IDR, the largest and slowest frame it will ever produce,
    /// and would otherwise open every checkpoint with the one sample least
    /// representative of the scale's ongoing cost.
    private var perSurfaceEncodeCheckpointSkipsNextSample = CanvasSurfaceSlots<Bool> { _ in false }
    /// Frames whose encode cost is deliberately not evidence about whether the
    /// frame rate in force is sustainable, keyed exactly like the entries
    /// above and holding the time they were marked, so an eviction sweep
    /// retires one whose frame never came out of the encoder.
    private var checkpointExemptEntries: [SurfaceFrameKey: Int64] = [:]

    /// Frames dropped anywhere between capture and their matching later
    /// stage never produce the later call that would otherwise remove their
    /// entry from `captureEntries`, `encodeEntries`, or `submitEntries`, so
    /// without this every drop -- at any stage, on any path -- orphans one
    /// entry forever: a slow, unbounded leak over a long session. Age is the
    /// simplest bound that needs no plumbing through every drop call site:
    /// several of them (VideoToolbox's `.dropped` and `.failed` outcomes)
    /// never hand back a presentation timestamp to key an eviction on. Five
    /// seconds is far longer than any frame legitimately stays in flight in
    /// a one-in-flight, one-waiting pipeline.
    private static let staleEntryThresholdNanoseconds: Int64 = 5_000_000_000

    public init() {}

    private func evictStaleEntries(nowNanoseconds: Int64) {
        let cutoff = nowNanoseconds - Self.staleEntryThresholdNanoseconds
        captureEntries = captureEntries.filter { $0.value >= cutoff }
        encodeEntries = encodeEntries.filter { $0.value >= cutoff }
        submitEntries = submitEntries.filter { $0.value >= cutoff }
        checkpointExemptEntries = checkpointExemptEntries.filter { $0.value >= cutoff }
    }

    public var metrics: SessionMetrics {
        lock.lock()
        defer { lock.unlock() }
        return metricsValue
    }

    public var frameCounts: HostFrameCounts {
        lock.lock()
        defer { lock.unlock() }
        return HostFrameCounts(
            captured: capturedFrameCount,
            encoded: encodedFrameCount,
            encodeSubmissionFailures: encodeSubmissionFailureCount,
            encoderInputDropped: encoderInputDroppedCount,
            globalAdmissionDropped: globalAdmissionDroppedCount,
            encoderOutputDropped: encoderOutputDroppedCount,
            hostRequested: hostRequestedFrameCount,
            unchangedFrames: unchangedFrameCount,
            noChangeNotices: noChangeNoticeCount,
            otherStatusDeliveries: otherStatusDeliveryCount
        )
    }

    /// This surface's own capture/encode/send percentiles, distinct from the
    /// session-wide `metrics` both surfaces feed.
    public func metrics(for surface: CanvasSurfaceID) -> SessionMetrics {
        lock.lock()
        defer { lock.unlock() }
        return perSurfaceMetrics[surface]
    }

    /// This surface's own ground-truth counts, distinct from the session-wide
    /// `frameCounts` both surfaces feed.
    public func frameCounts(for surface: CanvasSurfaceID) -> HostFrameCounts {
        lock.lock()
        defer { lock.unlock() }
        return perSurfaceCounts[surface].value
    }

    /// Call at the moment the capture callback actually runs for a frame.
    public func recordCapture(surface: CanvasSurfaceID, presentationTimeNanoseconds: Int64, atNanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        capturedFrameCount += 1
        perSurfaceCounts[surface].captured += 1
        _ = metricsValue.record(
            stage: .capture,
            startedAtNanoseconds: presentationTimeNanoseconds,
            endedAtNanoseconds: atNanoseconds
        )
        _ = perSurfaceMetrics[surface].record(
            stage: .capture,
            startedAtNanoseconds: presentationTimeNanoseconds,
            endedAtNanoseconds: atNanoseconds
        )
        captureEntries[SurfaceFrameKey(surface: surface, presentationTimeNanoseconds: presentationTimeNanoseconds)] = atNanoseconds
        evictStaleEntries(nowNanoseconds: atNanoseconds)
    }

    /// Call immediately before the frame is actually handed to the encoder
    /// (`VTCompressionSessionEncodeFrame`). It closes the `.admit` stage
    /// (capture to submit -- the admission-queue wait and the session/machine
    /// gate wait, with no encode compute in it) and opens the `.encode` stage
    /// `recordEncodeOutput` closes, so the two stages meet exactly here and
    /// neither one contains the other.
    public func recordEncodeSubmit(surface: CanvasSurfaceID, presentationTimeNanoseconds: Int64, atNanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let key = SurfaceFrameKey(surface: surface, presentationTimeNanoseconds: presentationTimeNanoseconds)
        // Looked up, not removed: this frame's entries are retired together
        // by `recordEncodeOutput`, the one call that ends its life here.
        if let captureAt = captureEntries[key] {
            _ = metricsValue.record(stage: .admit, startedAtNanoseconds: captureAt, endedAtNanoseconds: atNanoseconds)
            _ = perSurfaceMetrics[surface].record(stage: .admit, startedAtNanoseconds: captureAt, endedAtNanoseconds: atNanoseconds)
        }
        submitEntries[key] = atNanoseconds
    }

    /// Call at the moment the encoder's compressed-output callback fires for
    /// a frame. The `.encode` stage this records is bounded by that frame's
    /// own `recordEncodeSubmit` -- the `VTCompressionSessionEncodeFrame` call
    /// -- so it reports what the encoder cost and nothing else. The wait ahead
    /// of it has its own stage, `.admit`; measured as one interval, a
    /// saturated admission queue reads as a slow encoder.
    public func recordEncodeOutput(surface: CanvasSurfaceID, presentationTimeNanoseconds: Int64, atNanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        encodedFrameCount += 1
        perSurfaceCounts[surface].encoded += 1
        let key = SurfaceFrameKey(surface: surface, presentationTimeNanoseconds: presentationTimeNanoseconds)
        // Removed without being read: `.admit` already measured this entry's
        // interval at submit time, and leaving it in place would orphan it
        // until the staleness sweep.
        captureEntries.removeValue(forKey: key)
        if let submitAt = submitEntries.removeValue(forKey: key) {
            _ = metricsValue.record(
                stage: .encode,
                startedAtNanoseconds: submitAt,
                endedAtNanoseconds: atNanoseconds
            )
            _ = perSurfaceMetrics[surface].record(
                stage: .encode,
                startedAtNanoseconds: submitAt,
                endedAtNanoseconds: atNanoseconds
            )
            if checkpointExemptEntries.removeValue(forKey: key) != nil {
                // Exempt, and not counted as the skipped opening sample
                // either: a frame nobody asked the encoder to produce at this
                // budget must neither be measured nor spend the one skip a
                // freshly built session is owed.
            } else if perSurfaceEncodeCheckpointSkipsNextSample[surface] {
                perSurfaceEncodeCheckpointSkipsNextSample[surface] = false
            } else {
                _ = perSurfaceEncodeCheckpoint[surface].record(nanoseconds: atNanoseconds - submitAt)
            }
        }
        encodeEntries[key] = atNanoseconds
    }

    /// Call instead of `recordCapture` for a frame this host asked the encoder
    /// for rather than one capture delivered -- today, the frame a still
    /// screen is sent again of the picture it is holding.
    ///
    /// It is counted, because it is a real frame with a real cost, and it is
    /// kept out of all three places a captured frame would otherwise land:
    /// the capture percentile, whose stage is the age of a frame the screen
    /// produced and which this frame's freshly minted timestamp would report
    /// as near zero; the sustainability checkpoint, which decides whether the
    /// frame rate in force can be sustained and would read a deliberate whole
    /// key frame as an encoder falling behind; and the count a fidelity tick
    /// reads as how much the screen changed, where one such frame is exactly
    /// the difference between a still screen and a moving one.
    ///
    /// The queue and gate wait ahead of the encoder is still measured, since
    /// that is a real wait this frame really had.
    public func recordHostRequestedFrame(
        surface: CanvasSurfaceID,
        presentationTimeNanoseconds: Int64,
        atNanoseconds: Int64
    ) {
        lock.lock()
        defer { lock.unlock() }
        capturedFrameCount += 1
        perSurfaceCounts[surface].captured += 1
        hostRequestedFrameCount += 1
        perSurfaceCounts[surface].hostRequested += 1
        let key = SurfaceFrameKey(surface: surface, presentationTimeNanoseconds: presentationTimeNanoseconds)
        captureEntries[key] = atNanoseconds
        checkpointExemptEntries[key] = atNanoseconds
        evictStaleEntries(nowNanoseconds: atNanoseconds)
    }

    /// Call for every delivery the capture stream made that was not the screen
    /// changing.
    ///
    /// None of these is a frame the encoder ever sees, so no capture count and
    /// no percentile moves for them. They are counted because they are the only
    /// evidence of what a capture stream is doing while a screen sits still:
    /// nothing downstream of the encoder produces a single packet then, so
    /// every other counter reads the same whether the stream is delivering
    /// unchanged frames at the frame rate or has stopped delivering at all.
    public func recordCaptureDelivery(_ delivery: ScreenCaptureDelivery, surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        switch delivery {
        case .unchangedFrame:
            unchangedFrameCount += 1
            perSurfaceCounts[surface].unchangedFrames += 1
        case .noChangeNotice:
            noChangeNoticeCount += 1
            perSurfaceCounts[surface].noChangeNotices += 1
        case .otherStatus:
            otherStatusDeliveryCount += 1
            perSurfaceCounts[surface].otherStatusDeliveries += 1
        case .screenChange:
            // Counted by `recordCapture`, which also gives it its
            // capture-stage measurement.
            break
        }
    }

    /// Marks the start of a fresh observation window for `surface`'s encode
    /// latency, discarding samples recorded before it. Call whenever that
    /// surface's encoder is rebuilt at a new scale, so a sustainability check
    /// measures only what the scale running right now actually costs.
    public func resetEncodeCheckpoint(for surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        perSurfaceEncodeCheckpoint[surface] = LatencySamples()
        perSurfaceEncodeCheckpointSkipsNextSample[surface] = true
    }

    /// This surface's encode-stage latency since the last
    /// `resetEncodeCheckpoint` call, distinct from the session-wide
    /// `metrics(for:)` percentile both draw from the same recorded events.
    public func encodeLatencySinceCheckpoint(for surface: CanvasSurfaceID) -> LatencySamples {
        lock.lock()
        defer { lock.unlock() }
        return perSurfaceEncodeCheckpoint[surface]
    }

    /// Call whenever a frame is submitted to the encoder but VideoToolbox
    /// refuses it (a nonzero `OSStatus`), so that failure is counted and
    /// surfaced instead of vanishing behind `try?`. `EncodeAdmissionGate`
    /// passes its own surface; `surface` defaults to `nil` only for tests
    /// that do not need per-surface attribution.
    public func recordEncodeSubmissionFailure(status: Int32, surface: CanvasSurfaceID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        encodeSubmissionFailureCount += 1
        if let surface {
            perSurfaceCounts[surface].encodeSubmissionFailures += 1
        }
    }

    /// Call whenever a captured frame is dropped before it ever reaches the
    /// encoder because capture is outrunning it, so this loss cannot become
    /// invisible behind a healthy-looking encode stage.
    public func recordEncoderInputDrop(surface: CanvasSurfaceID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        encoderInputDroppedCount += 1
        if let surface {
            perSurfaceCounts[surface].encoderInputDropped += 1
        }
    }

    /// Call whenever `SharedEncodeAdmissionGate` drops a frame because the
    /// bound shared across every pipeline was reached, so contention between
    /// two canvases cannot become an invisible loss either.
    public func recordGlobalEncoderInputDrop(surface: CanvasSurfaceID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        globalAdmissionDroppedCount += 1
        if let surface {
            perSurfaceCounts[surface].globalAdmissionDropped += 1
        }
    }

    /// Call whenever a frame that was submitted to the encoder produces no
    /// picture at all: VideoToolbox dropped it, or there was no encoder left
    /// to submit it to. Counted rather than ignored so a session losing
    /// frames inside the encoder is visible next to the ones lost before it.
    public func recordEncoderOutputDrop(surface: CanvasSurfaceID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        encoderOutputDroppedCount += 1
        if let surface {
            perSurfaceCounts[surface].encoderOutputDropped += 1
        }
    }

    /// Call once a frame's send has actually completed (or, absent transport
    /// completion, once it has been handed off).
    public func recordSendCompleted(surface: CanvasSurfaceID, presentationTimeNanoseconds: Int64, atNanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let encodeAt = encodeEntries.removeValue(
            forKey: SurfaceFrameKey(surface: surface, presentationTimeNanoseconds: presentationTimeNanoseconds)
        ) else {
            return
        }
        _ = metricsValue.record(
            stage: .send,
            startedAtNanoseconds: encodeAt,
            endedAtNanoseconds: atNanoseconds
        )
        _ = perSurfaceMetrics[surface].record(
            stage: .send,
            startedAtNanoseconds: encodeAt,
            endedAtNanoseconds: atNanoseconds
        )
    }
}

/// A one-line host stage report, honest about absence: a stage with no
/// samples is left out rather than shown as a flattering zero, and a session
/// that measured nothing reports `nil` rather than an empty line.
public enum HostLatencySummary {
    public static func line(metrics: SessionMetrics, droppedFrameCount: Int, frameCounts: HostFrameCounts? = nil) -> String? {
        let stages: [(SessionMetricStage, String)] = [
            (.capture, "capture"), (.admit, "admit"), (.encode, "encode"), (.send, "send")
        ]
        let parts = stages.compactMap { stage, label -> String? in
            let samples = metrics.samples(for: stage)
            guard let p50 = samples.p50, let p95 = samples.p95 else { return nil }
            return "\(label) p50 \(milliseconds(p50))ms p95 \(milliseconds(p95))ms"
        }
        guard !parts.isEmpty else { return nil }
        // `droppedFrameCount` is the transport hand-off's own count; folding in
        // `encoderInputDropped` and `globalAdmissionDropped` here means a
        // reader glancing at this one number sees every frame lost to keep
        // up, at any stage, not just one of them.
        let totalDropped = droppedFrameCount
            + (frameCounts?.encoderInputDropped ?? 0)
            + (frameCounts?.globalAdmissionDropped ?? 0)
            + (frameCounts?.encoderOutputDropped ?? 0)
        var line = "host stage latency: " + parts.joined(separator: "; ") + "; \(totalDropped) dropped to keep up"
        if let frameCounts {
            line += "; ground truth frames captured=\(frameCounts.captured) encoded=\(frameCounts.encoded)"
            line += " encoderInputDropped=\(frameCounts.encoderInputDropped)"
            line += " globalAdmissionDropped=\(frameCounts.globalAdmissionDropped)"
            line += " encoderOutputDropped=\(frameCounts.encoderOutputDropped)"
            if frameCounts.encodeSubmissionFailures > 0 {
                line += " encodeSubmissionFailures=\(frameCounts.encodeSubmissionFailures)"
            }
        }
        return line
    }

    private static func milliseconds(_ nanoseconds: Int64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1_000_000)
    }
}
