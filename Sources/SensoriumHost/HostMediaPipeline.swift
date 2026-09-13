import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore

@available(macOS 13.0, *)
public enum HostMediaPipelineError: Error, Equatable {
    /// A still-screen refresh was encoded and then not taken by whatever is
    /// behind this pipeline: the packetizer refused it, or the transport
    /// discarded it. Reported rather than swallowed, because the alternative
    /// is telling the person reading the host log that a picture went out.
    case stillRefreshNotDelivered
}

@available(macOS 13.0, *)
@MainActor
public final class HostMediaPipeline {
    private let capture: ScreenCaptureSession
    private let encoder: VideoToolboxEncoder
    private let admissionGate: EncodeAdmissionGate
    private let lastCapturedFrame = LastCapturedFrame()
    private let surface: CanvasSurfaceID
    private let latencyRecorder: HostMediaLatencyRecorder?
    /// What the frames this pipeline encodes are worth, for the one frame a
    /// still-screen refresh sends. Held rather than read back from the
    /// encoder because a rebuilt pipeline is the only thing that changes it.
    private let configuration: VideoEncoderConfiguration
    /// Where an encoded frame goes next. Held as well as given to the
    /// admission gate because a still-screen refresh is encoded outside the
    /// stream's own session and so never passes through the gate.
    ///
    /// Answers whether the frame was taken. A stream frame has nothing to do
    /// about a refusal; a still-screen refresh reports one.
    private let deliverEncodedFrame: @Sendable (CMSampleBuffer) -> Bool
    /// Where a still-screen refresh is encoded. Off the main actor because a
    /// whole key frame of a large screen takes tens of milliseconds -- 57 ms
    /// measured at 2880x1800 -- and input injection runs on that actor, so
    /// encoding there is a visible stall on every key the person is pressing.
    /// Serial: two refreshes of the same surface have no reason to run at once.
    private let stillRefreshQueue = DispatchQueue(label: "sensorium.still-refresh-encode")
    /// Bumped by `stop`. A refresh encoded off the actor comes back to an
    /// actor that may have torn this pipeline down while it was away, and a
    /// frame belonging to a pipeline that has stopped is not sent.
    private var generation = 0

    /// Frames dropped before they ever reached the encoder because capture
    /// outran it. Distinct from `HostMediaLatencyRecorder`'s
    /// `encodeSubmissionFailures`, which counts frames VideoToolbox itself
    /// refused. Counted per pipeline, so a resolution change restarts it; the
    /// count that spans a whole session is the recorder's
    /// `encoderInputDropped`, which the host summary reports.
    public var droppedCaptureFrameCount: Int { admissionGate.droppedFrameCount }

    public init(
        contentFilter: SCContentFilter,
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        captureTarget: CaptureCursorPolicy.Target,
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Bool
    ) throws {
        // Bounds the frames outstanding between capture and
        // VTCompressionSessionEncodeFrame: without it, a capture callback that
        // outruns the encoder (true even with kVTCompressionPropertyKey_-
        // MaxFrameDelayCount = 0, which does not bound this) queues frames
        // unboundedly and turns into growing end-to-end latency instead of a
        // visibly older picture. `sessionAdmissionGate` additionally bounds
        // this across every pipeline sharing the same encoder hardware, not
        // just this one — see `SharedEncodeAdmissionGate`. It is supplied
        // rather than defaulted: the gate belongs to a session, and a pipeline
        // silently inventing its own would bound nothing.
        let admissionGate = EncodeAdmissionGate(
            latencyRecorder: latencyRecorder,
            sessionGate: sessionAdmissionGate,
            surface: surface,
            focus: focus,
            encodedFrameHandler: { sampleBuffer in
                if let latencyRecorder, let presentationTime = CMSampleBufferPresentationTiming.nanoseconds(sampleBuffer) {
                    latencyRecorder.recordEncodeOutput(
                        surface: surface,
                        presentationTimeNanoseconds: presentationTime,
                        atNanoseconds: MonotonicClock.nowNanoseconds()
                    )
                }
                _ = encodedFrameHandler(sampleBuffer)
            }
        )
        // Every outcome releases the frame's slot; only the successful ones
        // go onward.
        let encoder = try VideoToolboxEncoder(
            configuration: configuration,
            frameOutcomeHandler: { outcome in
                admissionGate.frameFinished(outcome)
            }
        )
        self.encoder = encoder
        deliverEncodedFrame = encodedFrameHandler
        admissionGate.encoder = encoder
        self.admissionGate = admissionGate
        self.configuration = configuration
        self.surface = surface
        self.latencyRecorder = latencyRecorder
        let lastCapturedFrame = lastCapturedFrame
        capture = try ScreenCaptureSession(
            contentFilter: contentFilter,
            configuration: configuration,
            captureTarget: captureTarget,
            deliveryHandler: { delivery in
                latencyRecorder?.recordCaptureDelivery(delivery, surface: surface)
            },
            streamStoppedHandler: streamStoppedHandler
        ) { sampleBuffer in
            lastCapturedFrame.record(sampleBuffer)
            if let latencyRecorder, let presentationTime = CMSampleBufferPresentationTiming.nanoseconds(sampleBuffer) {
                latencyRecorder.recordCapture(
                    surface: surface,
                    presentationTimeNanoseconds: presentationTime,
                    atNanoseconds: MonotonicClock.nowNanoseconds()
                )
            }
            admissionGate.admit(sampleBuffer)
        }
    }

    /// `packetizer` is passed in rather than created here so a resolution
    /// change can carry the same one — and so the same monotonic sequence and
    /// keyframe gate — across the pipeline rebuild.
    public convenience init(
        contentFilter: SCContentFilter,
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        captureTarget: CaptureCursorPolicy.Target,
        packetizer: H264SampleBufferPacketizer = H264SampleBufferPacketizer(),
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        encodedPacketHandler: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) throws {
        try self.init(
            contentFilter: contentFilter,
            surface: surface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: sessionAdmissionGate,
            focus: focus,
            captureTarget: captureTarget,
            streamStoppedHandler: streamStoppedHandler,
            // Through `deliver`, not `packet(from:)`: the sequence number and
            // the hand-off to the transport are one step, so a still-screen
            // refresh raced against a stream frame cannot reach the transport
            // numbered behind a frame the viewer has already admitted.
            encodedFrameHandler: { sampleBuffer in
                (try? packetizer.deliver(from: sampleBuffer) { packet in
                    encodedPacketHandler(packet)
                }) ?? false
            }
        )
    }

    /// The encoder is told first: it must already expect the new rate when
    /// the first frame captured at that rate arrives, not one frame later.
    ///
    /// If capture then refuses the change, the encoder is put back. Left
    /// alone it would budget bits for a rate capture is not delivering, and
    /// a step that failed is exactly when the two halves must still agree.
    public func apply(framesPerSecond: Int) async throws {
        let previousFramesPerSecond = encoder.appliedFramesPerSecond
        try encoder.apply(framesPerSecond: framesPerSecond)
        do {
            try await capture.apply(framesPerSecond: framesPerSecond)
        } catch {
            // Best effort: if putting the encoder back also fails, the
            // original refusal is still what the caller needs to hear, and
            // the media above has not recorded the new rate either, so the
            // next attempt re-applies both halves from the rate still in
            // force.
            try? encoder.apply(framesPerSecond: previousFramesPerSecond)
            throw error
        }
    }

    /// Quality is an encoder-side lever only: capture delivers the same
    /// pixels either way, and how many bits they are worth is decided after.
    public func apply(qualityScale: Double) throws {
        try encoder.apply(qualityScale: qualityScale)
    }

    public func requestKeyFrame() {
        encoder.requestKeyFrame()
    }

    /// Sends the frame this pipeline last captured again, whole, so a screen
    /// that has stopped changing stops being represented by a delta encoded
    /// for a moving one.
    ///
    /// It is encoded by `StillFrameEncoder` against a quality target, on a
    /// compression session of its own, because the stream's session cannot be
    /// asked for a sharp single frame: its rate control spends a fraction of a
    /// second's budget on any one frame no matter what budget it is given.
    /// Nothing about the stream's own session is changed by this, so there is
    /// nothing to put back afterwards.
    ///
    /// The stream's next frame is asked to be a key frame, and that is not
    /// optional: this frame carries the still session's parameter sets, so the
    /// viewer rebuilds its decoder around them and keeps no reference frames
    /// from the stream's session. A delta built on those references would
    /// arrive at a decoder that no longer holds them.
    ///
    /// Returns how many bytes the frame that went out is, or `nil` when there
    /// was nothing to send -- a surface that has captured nothing yet, or one
    /// whose capture stopped while this frame was being encoded. Neither is a
    /// failure, but neither sent a picture, so neither may be reported as
    /// having done so.
    ///
    /// Throws when there was a picture and it did not go out: an encode that
    /// failed, a frame the wire format will not carry, or a frame the
    /// packetizer or the transport refused. Every one of those is a refresh
    /// the person reading the host log must not be told happened.
    @discardableResult
    public func refreshStillPicture() async throws -> Int? {
        guard let captured = lastCapturedFrame.take(),
              let imageBuffer = CMSampleBufferGetImageBuffer(captured) else {
            return nil
        }
        let presentationTime = MonotonicClock.nowNanoseconds()
        // Counted, because it is one more frame through this pipeline and a
        // tick that saw it encoded without seeing it captured would read as an
        // encoder producing frames from nowhere -- but counted as the host's
        // own frame, so nothing mistakes it for the screen changing or for
        // evidence about what the frame rate in force costs.
        latencyRecorder?.recordHostRequestedFrame(
            surface: surface,
            presentationTimeNanoseconds: presentationTime,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        let encodedAgainst = generation
        let submittedAt = MonotonicClock.nowNanoseconds()
        let refreshed = try await encodeStillFrame(
            imageBuffer: imageBuffer,
            configuration: configuration,
            presentationTimeNanoseconds: presentationTime
        )
        guard encodedAgainst == generation else {
            // This pipeline stopped while the frame was being encoded. Its
            // encoder is finished with and its surface belongs to a capture
            // session that has gone, so the frame is given up rather than
            // pushed at a transport that has moved on.
            return nil
        }
        // Both stages after the fact, from the times either side of the
        // encode, and both against the timestamp the frame itself carries --
        // which is the same on every attempt, so a picture that needed a
        // softer second try is still the frame `recordSendCompleted` finds.
        latencyRecorder?.recordEncodeSubmit(
            surface: surface,
            presentationTimeNanoseconds: presentationTime,
            atNanoseconds: submittedAt
        )
        latencyRecorder?.recordEncodeOutput(
            surface: surface,
            presentationTimeNanoseconds: presentationTime,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        encoder.completeFramesRequestingKeyFrame()
        guard deliverEncodedFrame(refreshed) else {
            throw HostMediaPipelineError.stillRefreshNotDelivered
        }
        return CMSampleBufferGetTotalSampleSize(refreshed)
    }

    /// `StillFrameEncoder` off the main actor, on this pipeline's own serial
    /// queue. The picture and the configuration are read on the actor and
    /// handed across, so nothing here reads pipeline state that the actor
    /// could be changing meanwhile.
    private func encodeStillFrame(
        imageBuffer: CVImageBuffer,
        configuration: VideoEncoderConfiguration,
        presentationTimeNanoseconds: Int64
    ) async throws -> CMSampleBuffer {
        let queue = stillRefreshQueue
        let box = StillRefreshEncodeInput(imageBuffer: imageBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try StillFrameEncoder.encodeKeyFrame(
                        imageBuffer: box.imageBuffer,
                        configuration: configuration,
                        presentationTimeNanoseconds: presentationTimeNanoseconds
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func start() async throws {
        try await capture.start()
    }

    public func stop() async throws {
        // Before anything else: a still-screen refresh encoding off the actor
        // right now must find this generation changed when it comes back, so
        // it gives its frame up instead of handing it to a stopped pipeline.
        generation += 1
        defer {
            // Nothing may outlive the capture session that vended it.
            lastCapturedFrame.clear()
            // After capture, so no frame can be admitted against a slot this
            // pipeline has already given back. Explicit rather than left to
            // `deinit`: the encoder's callback holds the gate, so ARC may
            // free it long after the session that owned its slots ended.
            // Unconditional so a capture stop that throws still releases
            // every admitted slot rather than leaking them.
            admissionGate.shutDown()
        }
        try await capture.stop()
    }
}

/// What `ScreenCaptureCanvasMedia` needs from a running pipeline. Exists so a
/// test can stand in for `HostMediaPipeline` -- which ScreenCaptureKit will
/// not run outside a granted, on-screen process -- without exercising real
/// capture.
@available(macOS 13.0, *)
@MainActor
public protocol CanvasMediaPipelining: AnyObject {
    func start() async throws
    func stop() async throws
    func apply(framesPerSecond: Int) async throws
    func apply(qualityScale: Double) throws
    func requestKeyFrame()
    @discardableResult
    func refreshStillPicture() async throws -> Int?
}

@available(macOS 13.0, *)
extension HostMediaPipeline: CanvasMediaPipelining {}

/// Carries one capture surface across the hop to the still-refresh queue.
/// `CVImageBuffer` is a Core Foundation type with no `Sendable` conformance of
/// its own; what makes this safe is that the pipeline has already taken the
/// buffer out of `LastCapturedFrame`, so this reference is the only one left
/// and no other thread can be reading it.
@available(macOS 13.0, *)
private final class StillRefreshEncodeInput: @unchecked Sendable {
    let imageBuffer: CVImageBuffer

    init(imageBuffer: CVImageBuffer) {
        self.imageBuffer = imageBuffer
    }
}
