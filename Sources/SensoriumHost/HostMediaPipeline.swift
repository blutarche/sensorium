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

/// Where a `HostMediaPipeline` gets its frames: ScreenCaptureKit in the host,
/// or anything else that can deliver sample buffers carrying an image buffer.
/// The surface it covers is exactly the part of `ScreenCaptureSession` the
/// pipeline drives.
@available(macOS 13.0, *)
@MainActor
public protocol HostFrameSource: AnyObject {
    func start() async throws
    func stop() async throws
    func apply(framesPerSecond: Int) async throws
}

@available(macOS 13.0, *)
extension ScreenCaptureSession: HostFrameSource {}

/// Builds the frame source for one pipeline, given the encoder configuration
/// the pipeline was built with and the closures the pipeline listens on: what
/// each delivery turned out to be, the stream ending by itself, and every
/// frame that should be encoded.
@available(macOS 13.0, *)
public typealias HostFrameSourceFactory = @MainActor (
    _ configuration: VideoEncoderConfiguration,
    _ deliveryHandler: @escaping @Sendable (ScreenCaptureDelivery) -> Void,
    _ streamStoppedHandler: (@Sendable (Error) -> Void)?,
    _ frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void
) throws -> any HostFrameSource

@available(macOS 13.0, *)
@MainActor
public final class HostMediaPipeline {
    private let capture: any HostFrameSource
    private let encoder: VideoToolboxEncoder
    /// The encoder a moving picture is sent from, at `movingConfiguration`.
    /// `nil` for a stream too small to have a motion size.
    private let movingEncoder: VideoToolboxEncoder?
    private let movingConfiguration: VideoEncoderConfiguration?
    /// What the admission gate submits to: `encoder` and `movingEncoder`
    /// behind one frame path. Held here because the gate holds it weakly.
    private let motion: StreamMotionEncoder
    private let admissionGate: EncodeAdmissionGate
    private let lastCapturedFrame: LastCapturedFrame
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
    /// Where a still-screen refresh is encoded, and where the stream's encoder
    /// is flushed and held before it and resumed after it. Off the main actor
    /// because a whole key frame of a large screen takes tens of milliseconds
    /// -- 57 ms measured at 2880x1800 -- and input injection runs on that
    /// actor, so encoding there is a visible stall on every key the person is
    /// pressing. The flush waits on VideoToolbox, and the main actor must not
    /// wait with it.
    /// Serial: two refreshes of the same surface have no reason to run at once.
    private let stillRefreshQueue = DispatchQueue(label: "sensorium.still-refresh-encode")
    /// Bumped by `stop`. A refresh encoded off the actor comes back to an
    /// actor that may have torn this pipeline down while it was away, and a
    /// frame belonging to a pipeline that has stopped is not sent.
    private var generation = 0
    /// Whether `start` has asked capture to start.
    private var hasStartedCapture = false

    /// Frames dropped before they ever reached the encoder because capture
    /// outran it, or outran the link: captures wait while this surface's send
    /// slot is full, newest wins. Distinct from `HostMediaLatencyRecorder`'s
    /// `encodeSubmissionFailures`, which counts frames VideoToolbox itself
    /// refused. Counted per pipeline, so a resolution change restarts it. The
    /// counts that span a whole session are the recorder's
    /// `encoderInputDropped`, for captures the encoder was too busy for, and
    /// the transport's `droppedVideoFrameCount`, for captures held for the
    /// link.
    public var droppedCaptureFrameCount: Int { admissionGate.droppedFrameCount }

    /// The stream's own encoder, for this package's tests.
    package var streamEncoder: VideoToolboxEncoder { encoder }

    /// The screen-capture pipeline: frames come from a ScreenCaptureKit
    /// stream over `contentFilter`.
    public convenience init(
        contentFilter: SCContentFilter,
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        captureTarget: CaptureCursorPolicy.Target,
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Bool
    ) async throws {
        try await self.init(
            surface: surface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: sessionAdmissionGate,
            focus: focus,
            sendFeedback: sendFeedback,
            streamStoppedHandler: streamStoppedHandler,
            frameSourceFactory: Self.screenCapture(of: contentFilter, captureTarget: captureTarget),
            encodedFrameHandler: encodedFrameHandler
        )
    }

    /// `frameSourceFactory` is called once, with the closures that feed this
    /// pipeline's capture bookkeeping and encoder admission.
    ///
    /// Returns once the encoder's session is ready. It is created off the
    /// main actor -- see `VideoToolboxEncoder.make` -- so the actor is free
    /// while this waits.
    public convenience init(
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        frameSourceFactory: HostFrameSourceFactory,
        encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Bool
    ) async throws {
        try await self.init(
            surface: surface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: sessionAdmissionGate,
            focus: focus,
            sendFeedback: sendFeedback,
            streamStoppedHandler: streamStoppedHandler,
            frameSourceFactory: frameSourceFactory,
            encoderSessionCalls: .live,
            encodedFrameHandler: encodedFrameHandler
        )
    }

    /// The same, with `encoderSessionCalls` in place in the encoder from its
    /// session's creation on. For this package's tests.
    package init(
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        frameSourceFactory: HostFrameSourceFactory,
        encoderSessionCalls: VideoToolboxSessionCalls,
        encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Bool
    ) async throws {
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
            sendFeedback: sendFeedback,
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
        let lastCapturedFrame = LastCapturedFrame()
        let settleQueue = DispatchQueue(label: "sensorium.stream-motion-settle")
        let motion = StreamMotionEncoder(
            clock: { Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000 },
            scheduleSettleCheck: { afterSeconds, check in
                settleQueue.asyncAfter(deadline: .now() + afterSeconds, execute: check)
            },
            settled: {
                Self.resendSettledPicture(
                    lastCapturedFrame: lastCapturedFrame,
                    admissionGate: admissionGate,
                    latencyRecorder: latencyRecorder,
                    surface: surface
                )
            },
            // Every outcome releases the frame's slot; only the successful
            // ones go onward.
            frameFinished: { outcome in
                admissionGate.frameFinished(outcome)
            }
        )
        let encoder = try await VideoToolboxEncoder.make(
            configuration: configuration,
            sessionCalls: encoderSessionCalls,
            frameOutcomeHandler: motion.outcomeHandler(for: .settled)
        )
        // A stream that cannot have its motion encoder is still a stream: it
        // is sent at one size, as one that is too small for a motion size is.
        let movingConfiguration = configuration.motionConfiguration
        var movingEncoder: VideoToolboxEncoder?
        if let movingConfiguration {
            do {
                movingEncoder = try await VideoToolboxEncoder.make(
                    configuration: movingConfiguration,
                    sessionCalls: encoderSessionCalls,
                    frameOutcomeHandler: motion.outcomeHandler(for: .moving)
                )
            } catch {
                print("Sensorium host: motion encoder unavailable, sending one size: \(error)")
            }
        }
        motion.attach(settled: encoder, moving: movingEncoder)
        if movingEncoder != nil {
            await Self.prime(motion, width: configuration.captureWidth, height: configuration.captureHeight)
        }
        self.encoder = encoder
        self.movingEncoder = movingEncoder
        self.movingConfiguration = movingEncoder == nil ? nil : movingConfiguration
        self.motion = motion
        self.lastCapturedFrame = lastCapturedFrame
        deliverEncodedFrame = encodedFrameHandler
        admissionGate.encoder = motion
        self.admissionGate = admissionGate
        self.configuration = configuration
        self.surface = surface
        self.latencyRecorder = latencyRecorder
        capture = try frameSourceFactory(
            configuration,
            { delivery in
                latencyRecorder?.recordCaptureDelivery(delivery, surface: surface)
            },
            streamStoppedHandler
        ) { sampleBuffer in
            lastCapturedFrame.record(sampleBuffer)
            // Before admission, so the change that shows motion is itself
            // encoded as the moving picture.
            motion.screenChanged(changedFraction: StreamMotionEncoder.changedFraction(of: sampleBuffer))
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
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        captureTarget: CaptureCursorPolicy.Target,
        packetizer: H264SampleBufferPacketizer = H264SampleBufferPacketizer(),
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        encodedPacketHandler: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        try await self.init(
            surface: surface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: sessionAdmissionGate,
            focus: focus,
            sendFeedback: sendFeedback,
            packetizer: packetizer,
            streamStoppedHandler: streamStoppedHandler,
            frameSourceFactory: Self.screenCapture(of: contentFilter, captureTarget: captureTarget),
            encodedPacketHandler: encodedPacketHandler
        )
    }

    /// The same as the packetizing initializer above, with the frames
    /// coming from `frameSourceFactory`.
    public convenience init(
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        packetizer: H264SampleBufferPacketizer = H264SampleBufferPacketizer(),
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        frameSourceFactory: HostFrameSourceFactory,
        encodedPacketHandler: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        try await self.init(
            surface: surface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: sessionAdmissionGate,
            focus: focus,
            sendFeedback: sendFeedback,
            streamStoppedHandler: streamStoppedHandler,
            frameSourceFactory: frameSourceFactory,
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

    /// Sends the picture the screen settled on again, through the stream's
    /// own path, so it goes out from the settled encoder at full size.
    /// Capture is change-driven and the screen has stopped, so nothing else
    /// would send it. The frame is left held for a still-screen refresh,
    /// which still comes later and sends it sharp.
    ///
    /// Counted as the host's own frame: it is a deliberate key frame, not the
    /// screen changing, and not evidence of what the frame rate in force
    /// costs.
    nonisolated private static func resendSettledPicture(
        lastCapturedFrame: LastCapturedFrame,
        admissionGate: EncodeAdmissionGate,
        latencyRecorder: HostMediaLatencyRecorder?,
        surface: CanvasSurfaceID
    ) {
        guard let captured = lastCapturedFrame.peek() else {
            return
        }
        // A timestamp of its own: the encoder needs every frame later than the
        // last, and the latency recorder tells frames apart by it.
        let presentationTime = MonotonicClock.nowNanoseconds()
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(captured),
            presentationTimeStamp: CMTime(value: presentationTime, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var resent: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: captured,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &resent
        ) == noErr, let resent else {
            return
        }
        latencyRecorder?.recordHostRequestedFrame(
            surface: surface,
            presentationTimeNanoseconds: presentationTime,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        admissionGate.admit(resent)
    }

    /// `StreamMotionEncoder.prime`, with a blank frame the size capture
    /// delivers, so the scaling in front of the moving encoder runs too. Off
    /// the main actor, since priming waits on VideoToolbox.
    nonisolated private static func prime(_ motion: StreamMotionEncoder, width: Int, height: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if let frame = blankFrame(width: width, height: height) {
                    motion.prime(with: frame)
                }
                continuation.resume()
            }
        }
    }

    nonisolated private static func blankFrame(width: Int, height: Int) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: MonotonicClock.nowNanoseconds(), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func screenCapture(
        of contentFilter: SCContentFilter,
        captureTarget: CaptureCursorPolicy.Target
    ) -> HostFrameSourceFactory {
        { configuration, deliveryHandler, streamStoppedHandler, frameHandler in
            try ScreenCaptureSession(
                contentFilter: contentFilter,
                configuration: configuration,
                captureTarget: captureTarget,
                deliveryHandler: deliveryHandler,
                streamStoppedHandler: streamStoppedHandler,
                frameHandler: frameHandler
            )
        }
    }

    /// The encoder is told first: it must already expect the new rate when
    /// the first frame captured at that rate arrives, not one frame later.
    ///
    /// If capture then refuses the change, the encoder is put back. Left
    /// alone it would budget bits for a rate capture is not delivering, and
    /// a step that failed is exactly when the two halves must still agree.
    ///
    /// Every lever reaches the moving encoder too, so a picture that starts
    /// moving keeps the fidelity in force.
    public func apply(framesPerSecond: Int) async throws {
        let previousFramesPerSecond = encoder.appliedFramesPerSecond
        try await encoder.apply(framesPerSecond: framesPerSecond)
        do {
            try await movingEncoder?.apply(framesPerSecond: framesPerSecond)
            try await capture.apply(framesPerSecond: framesPerSecond)
        } catch {
            // Best effort: if putting the encoders back also fails, the
            // original refusal is still what the caller needs to hear, and
            // the media above has not recorded the new rate either, so the
            // next attempt re-applies every half from the rate still in
            // force.
            try? await encoder.apply(framesPerSecond: previousFramesPerSecond)
            try? await movingEncoder?.apply(framesPerSecond: previousFramesPerSecond)
            throw error
        }
    }

    /// Quality is an encoder-side lever only: capture delivers the same
    /// pixels either way, and how many bits they are worth is decided after.
    /// A refusal from either encoder is the caller's to hear: the media above
    /// then has not recorded the new quality, and its next attempt applies it
    /// to both again.
    public func apply(qualityScale: Double) async throws {
        try await encoder.apply(qualityScale: qualityScale)
        try await movingEncoder?.apply(qualityScale: qualityScale)
    }

    /// An encoder-side lever only, like quality: capture delivers the same
    /// frames whatever the encoder makes of them.
    public func apply(keyFrameIntervalSeconds: Double) async throws {
        try await encoder.apply(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
        try await movingEncoder?.apply(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
    }

    public func requestKeyFrame() {
        motion.requestKeyFrame()
    }

    /// The viewer scrolled or dragged on this surface, so the change it causes
    /// is sent as a moving picture from its first frame.
    public func viewerInteracted() {
        motion.viewerInteracted()
    }

    /// The stream scale of the picture the viewer has now, while it is the
    /// moving one. `nil` while it is the settled one, which is encoded at the
    /// stream scale this pipeline was built with.
    public var encodingStreamScale: Double? {
        guard motion.encodingRole == .moving, let movingConfiguration else {
            return nil
        }
        return movingConfiguration.streamScale
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
    /// arrive at a decoder that no longer holds them. So the stream reaches
    /// the transport in this order: the frames already in its encoder, then
    /// this one, then a key frame, then deltas. Right after the still encode
    /// the stream's encoder is flushed, and every stream frame it accepts from
    /// then on is held. Only once this frame has been handed on, or given up,
    /// are the held frames submitted, the first of them as that key frame.
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
        let (refreshed, encodedAt) = try await encodeStillFrameHoldingStream(
            imageBuffer: imageBuffer,
            configuration: configuration,
            presentationTimeNanoseconds: presentationTime
        )
        // The stream's encoder is holding from here, and every exit below
        // must end that hold exactly once, or the frames it holds never get
        // an outcome and their admission slots are never given back. At scope
        // exit, so the refresh has already been handed on when they go in;
        // on the queue, so their submission stays off the main actor.
        let queue = stillRefreshQueue
        let motion = motion
        defer {
            queue.async {
                motion.resumeHeldFramesWithKeyFrame()
            }
        }
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
            atNanoseconds: encodedAt
        )
        latencyRecorder?.recordHostRequestedFrameHandOff(
            surface: surface,
            presentationTimeNanoseconds: presentationTime,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        guard deliverEncodedFrame(refreshed) else {
            throw HostMediaPipelineError.stillRefreshNotDelivered
        }
        return CMSampleBufferGetTotalSampleSize(refreshed)
    }

    /// `StillFrameEncoder`, then the stream encoder's flush and hold, both
    /// off the main actor on this pipeline's own serial queue. The flush
    /// waits on VideoToolbox's output callbacks, and the main actor must not
    /// wait with it: input injection runs there, and so does the host's
    /// handling of every message the viewer sends. The picture and the
    /// configuration are read on the actor and handed across, so nothing here
    /// reads pipeline state that the actor could be changing meanwhile.
    ///
    /// The hold begins only after a still encode that succeeded, so a
    /// refresh that failed leaves the stream as it was. A frame returned here
    /// means the hold is in force, and the caller must resume it.
    /// `encodedAt` is taken between the encode and the flush, so the encode
    /// stage measures the still encode alone.
    private func encodeStillFrameHoldingStream(
        imageBuffer: CVImageBuffer,
        configuration: VideoEncoderConfiguration,
        presentationTimeNanoseconds: Int64
    ) async throws -> (frame: CMSampleBuffer, encodedAt: Int64) {
        let queue = stillRefreshQueue
        let box = StillRefreshEncodeInput(imageBuffer: imageBuffer)
        // Both of the stream's encoders: the frame after the refresh is a key
        // frame from whichever one sends it.
        let encoder = motion
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let frame = try StillFrameEncoder.encodeKeyFrame(
                        imageBuffer: box.imageBuffer,
                        configuration: configuration,
                        presentationTimeNanoseconds: presentationTimeNanoseconds
                    )
                    let encodedAt = MonotonicClock.nowNanoseconds()
                    encoder.holdFramesAndFlush()
                    continuation.resume(returning: (frame, encodedAt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func start() async throws {
        // Before the await, so a stop that arrives while capture is still
        // coming up, or after it failed to, still stops it.
        hasStartedCapture = true
        try await capture.start()
    }

    /// Also how a pipeline that was built and never started is discarded:
    /// its capture is left alone, since there is none to stop, and its
    /// encoder is shut down.
    public func stop() async throws {
        // Before anything else: a still-screen refresh encoding off the actor
        // right now must find this generation changed when it comes back, so
        // it gives its frame up instead of handing it to a stopped pipeline.
        generation += 1
        // As early: a settle due now would send a picture into the teardown.
        motion.stop()
        var captureStopError: (any Error)?
        if hasStartedCapture {
            do {
                try await capture.stop()
            } catch {
                captureStopError = error
            }
        }
        // Nothing may outlive the capture session that vended it.
        lastCapturedFrame.clear()
        // After capture, so no frame can be admitted against a slot this
        // pipeline has already given back. Explicit rather than left to
        // `deinit`: the encoder's callback holds the gate, so ARC may free it
        // long after the session that owned its slots ended. Whether or not
        // capture stopped cleanly, so a capture stop that throws still
        // releases every admitted slot rather than leaking them.
        admissionGate.shutDown()
        // After the gate, so the flush's last outcomes admit nothing new.
        // Awaited, so the session is gone before a caller rebuilding at
        // another resolution stands the next one up; off the main actor,
        // because the flush waits on the encoder service.
        await encoder.shutDown()
        await movingEncoder?.shutDown()
        if let captureStopError {
            throw captureStopError
        }
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
    func apply(qualityScale: Double) async throws
    func apply(keyFrameIntervalSeconds: Double) async throws
    func requestKeyFrame()
    @discardableResult
    func refreshStillPicture() async throws -> Int?
    func viewerInteracted()
    var encodingStreamScale: Double? { get }
}

/// For a stand-in that sends one size.
@available(macOS 13.0, *)
public extension CanvasMediaPipelining {
    func viewerInteracted() {}
    var encodingStreamScale: Double? { nil }
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
