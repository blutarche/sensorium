import CoreMedia
import Foundation
import SensoriumCore

extension VideoEncoderConfiguration {
    /// How many pixels a moving picture is encoded at, whatever size the
    /// settled picture is. Encode time grows with the pixel count, and this is
    /// a size the hardware encoder keeps well inside a 60 Hz frame while the
    /// screen is changing everywhere at once.
    public static let motionPixelBudget = 1920 * 1080

    /// How much smaller than the settled picture the moving one has to be for
    /// a stream to have a motion size at all. Every change of size costs the
    /// viewer a key frame, and a stream only a little above the budget would
    /// pay two of them per scroll for a saving nobody could see.
    public static let motionMinimumReduction = 1.5

    /// The configuration a moving picture is encoded with: the same canvas,
    /// frame rate, quality, key frame interval, codec and profile, at the
    /// stream scale that gives `motionPixelBudget` pixels, so the shape stays
    /// the shape the viewer asked for. The bitrate follows the pixel count,
    /// as it does for any other stream scale. Capture is the settled
    /// picture's: the motion encoder scales the frames capture delivers
    /// rather than asking capture for another size, which would rebuild it.
    ///
    /// `nil` when this stream is under `motionMinimumReduction` times the
    /// budget, and is encoded at one size whether it moves or not.
    public var motionConfiguration: VideoEncoderConfiguration? {
        let pixels = Double(encodeWidth * encodeHeight)
        guard pixels >= Double(Self.motionPixelBudget) * Self.motionMinimumReduction else {
            return nil
        }
        let moving = scaled(toStreamScale: streamScale * (Double(Self.motionPixelBudget) / pixels).squareRoot())
        return Self(
            width: moving.width,
            height: moving.height,
            framesPerSecond: moving.framesPerSecond,
            codec: moving.codec,
            maxQueueDepth: moving.maxQueueDepth,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            encodeWidth: moving.encodeWidth,
            encodeHeight: moving.encodeHeight,
            averageBitRate: moving.averageBitRate,
            dataRateLimitBytes: moving.dataRateLimitBytes,
            dataRateLimitSeconds: moving.dataRateLimitSeconds,
            maxFrameDelayCount: moving.maxFrameDelayCount,
            profileLevel: moving.profileLevel,
            requiresHardwareAcceleration: moving.requiresHardwareAcceleration,
            qualityScale: moving.qualityScale,
            keyFrameIntervalSeconds: moving.keyFrameIntervalSeconds
        )
    }
}

/// What `StreamMotionEncoder` needs from each of the encoders behind it: the
/// stream's frame path, and the hold a still-screen refresh puts on it.
@available(macOS 13.0, *)
package protocol MotionRoutableEncoder: VideoFrameEncoding {
    func holdFramesAndFlush()
    func resumeHeldFramesWithKeyFrame()
}

@available(macOS 13.0, *)
extension VideoToolboxEncoder: MotionRoutableEncoder {}

/// One stream, sent from two encoders: one at the size the viewer asked for,
/// for a settled picture, and one at `motionConfiguration`, for a moving one.
/// Both sessions stay open for the whole stream, so a change of size is a key
/// frame from an encoder that is already running, never a rebuild.
///
/// Each frame goes to the encoder for the mode `StreamMotionDetector` is in
/// when the frame is encoded. The first frame either encoder sends after the
/// other one sent is a key frame: the viewer rebuilds its decoder for the
/// other size, and holds none of this encoder's references.
///
/// `EncodeAdmissionGate` keeps one frame in the encoders at a time, and gives
/// the next one in only once the last one's outcome is in. That is what keeps
/// the two encoders' frames in order on the wire with no lock across them.
///
/// Settling has to send a picture of its own. The screen has stopped, so
/// capture delivers nothing, and the last frame the viewer has is the moving
/// one. `settled` is called once each time the stream settles, and is
/// expected to send the last captured frame again, which this encoder then
/// sends from the settled encoder as a key frame.
@available(macOS 13.0, *)
package final class StreamMotionEncoder: VideoFrameEncoding, @unchecked Sendable {
    package enum Role: Equatable, Sendable {
        case settled
        case moving
    }

    private let lock = NSLock()
    private var detector = StreamMotionDetector()
    private var settledEncoder: (any MotionRoutableEncoder)?
    private var movingEncoder: (any MotionRoutableEncoder)?
    /// Which encoder sent the last frame.
    private var lastRole = Role.settled
    /// The encoder whose key frame for a switch has not come out yet. A
    /// switch frame VideoToolbox drops leaves the viewer with no picture it
    /// can decode the next delta against, so it asks again.
    private var awaitingSwitchKeyFrame: Role?
    private var isPriming = false
    private var isSettleCheckPending = false
    private var isStopped = false

    private let clock: @Sendable () -> Double
    private let scheduleSettleCheck: @Sendable (_ afterSeconds: Double, _ check: @escaping @Sendable () -> Void) -> Void
    private let settled: @Sendable () -> Void
    private let frameFinished: @Sendable (VideoEncodeOutcome) -> Void

    /// `clock` is in seconds. `scheduleSettleCheck` runs `check` once, after
    /// at least `afterSeconds`, on any thread. `frameFinished` is where every
    /// outcome of a stream frame goes: the admission gate that let it in.
    package init(
        clock: @escaping @Sendable () -> Double,
        scheduleSettleCheck: @escaping @Sendable (_ afterSeconds: Double, _ check: @escaping @Sendable () -> Void) -> Void,
        settled: @escaping @Sendable () -> Void,
        frameFinished: @escaping @Sendable (VideoEncodeOutcome) -> Void
    ) {
        self.clock = clock
        self.scheduleSettleCheck = scheduleSettleCheck
        self.settled = settled
        self.frameFinished = frameFinished
    }

    /// Set once, after the encoders exist: each one's output callback is
    /// `outcomeHandler(for:)`, which has to be made before the encoder it
    /// belongs to. `moving` is `nil` for a stream with no motion size, which
    /// then sends every frame from `settled` and never changes mode.
    package func attach(settled: any MotionRoutableEncoder, moving: (any MotionRoutableEncoder)?) {
        lock.lock()
        settledEncoder = settled
        movingEncoder = moving
        lock.unlock()
    }

    /// The output callback for the encoder in `role`. Holds this object
    /// weakly: an encoder's last outcomes can come out of its flush after the
    /// stream that owned it has gone, and they still release their slots.
    package func outcomeHandler(for role: Role) -> @Sendable (VideoEncodeOutcome) -> Void {
        let frameFinished = frameFinished
        return { [weak self] outcome in
            guard let self else {
                frameFinished(outcome)
                return
            }
            self.finished(outcome, from: role)
        }
    }

    private func finished(_ outcome: VideoEncodeOutcome, from role: Role) {
        lock.lock()
        if isPriming, role == .moving {
            lock.unlock()
            return
        }
        var askAgain: (any MotionRoutableEncoder)?
        if awaitingSwitchKeyFrame == role {
            if case .encoded = outcome {
                awaitingSwitchKeyFrame = nil
            } else {
                askAgain = encoder(for: role)
            }
        }
        lock.unlock()
        askAgain?.requestKeyFrame()
        frameFinished(outcome)
    }

    private func encoder(for role: Role) -> (any MotionRoutableEncoder)? {
        role == .moving ? movingEncoder : settledEncoder
    }

    /// Which encoder sent the last frame, so what the host reports as the
    /// scale in force is the scale of the picture the viewer has.
    package var encodingRole: Role {
        lock.lock()
        defer { lock.unlock() }
        return lastRole
    }

    /// Capture delivered a change covering `changedFraction` of the frame, or
    /// an unknown part of it. Call for every change, before it is admitted, so
    /// the change that shows motion is itself encoded moving.
    package func screenChanged(changedFraction: Double?) {
        lock.lock()
        guard movingEncoder != nil, !isStopped else {
            lock.unlock()
            return
        }
        let now = clock()
        detector.screenChanged(atSeconds: now, changedFraction: changedFraction)
        let schedule = detector.mode == .moving && !isSettleCheckPending
        if schedule {
            isSettleCheckPending = true
        }
        let delay = (detector.settleDeadlineSeconds ?? now) - now
        lock.unlock()
        if schedule {
            scheduleCheck(after: delay)
        }
    }

    /// The viewer scrolled or dragged; see `StreamMotionInput`.
    package func viewerInteracted() {
        lock.lock()
        detector.viewerInteracted(atSeconds: clock())
        lock.unlock()
    }

    private func scheduleCheck(after delay: Double) {
        scheduleSettleCheck(max(delay, 0)) { [weak self] in
            self?.checkSettle()
        }
    }

    /// One check at a time, rescheduled for the time still to go when a later
    /// change has pushed the deadline back: a check per captured change would
    /// queue sixty a second while the screen moves.
    private func checkSettle() {
        lock.lock()
        guard !isStopped else {
            isSettleCheckPending = false
            lock.unlock()
            return
        }
        let now = clock()
        let didSettle = detector.settleIfDue(atSeconds: now)
        let remaining = detector.settleDeadlineSeconds.map { $0 - now }
        isSettleCheckPending = remaining != nil
        lock.unlock()
        if let remaining {
            scheduleCheck(after: remaining)
        }
        if didSettle {
            settled()
        }
    }

    /// Encodes `frame` on the moving encoder and throws the result away, so
    /// the first moving frame of the stream is not also the first frame that
    /// encoder's session has ever made. Returns once it is out; call before
    /// any stream frame and off the main actor, since the flush waits on
    /// VideoToolbox. The first real frame after it is a key frame.
    package func prime(with frame: CMSampleBuffer) {
        lock.lock()
        guard let moving = movingEncoder else {
            lock.unlock()
            return
        }
        isPriming = true
        lock.unlock()
        try? moving.encode(frame)
        moving.holdFramesAndFlush()
        lock.lock()
        isPriming = false
        lock.unlock()
        moving.resumeHeldFramesWithKeyFrame()
    }

    /// No settle after this: the stream has gone, and a settle would send a
    /// frame through a pipeline that is shutting down.
    package func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }

    package func encode(_ sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        let role: Role = movingEncoder != nil && detector.mode == .moving ? .moving : .settled
        guard let target = encoder(for: role) else {
            lock.unlock()
            throw VideoEncoderError.frameSubmissionFailed(-1)
        }
        let switched = role != lastRole
        lastRole = role
        if switched {
            awaitingSwitchKeyFrame = role
        }
        lock.unlock()
        // Outside the lock: an encoder may call its output callback, and so
        // `finished`, from inside `encode`.
        if switched {
            target.requestKeyFrame()
        }
        try target.encode(sampleBuffer)
    }

    package func requestKeyFrame() {
        for encoder in encoders() {
            encoder.requestKeyFrame()
        }
    }

    /// Both encoders, so a still-screen refresh comes out behind whatever
    /// either one has in flight, and the frame after it is a key frame from
    /// whichever sends it.
    package func holdFramesAndFlush() {
        for encoder in encoders() {
            encoder.holdFramesAndFlush()
        }
    }

    package func resumeHeldFramesWithKeyFrame() {
        for encoder in encoders() {
            encoder.resumeHeldFramesWithKeyFrame()
        }
    }

    /// How much of a `frameWidth` by `frameHeight` frame its dirty rects
    /// cover. ScreenCaptureKit gives them in the frame's pixels. They are
    /// summed rather than united, so rects that overlap count twice, up to
    /// the whole frame: a change can read as larger than it was, never as
    /// smaller. `nil` when there is no list to read.
    package static func changedFraction(dirtyRects: [CGRect]?, frameWidth: Int, frameHeight: Int) -> Double? {
        guard let dirtyRects, frameWidth > 0, frameHeight > 0 else {
            return nil
        }
        let frame = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let area = dirtyRects.reduce(0.0) { total, rect in
            let inside = rect.intersection(frame)
            return inside.isNull ? total : total + Double(inside.width * inside.height)
        }
        return min(area / Double(frameWidth * frameHeight), 1)
    }

    /// The same for a captured frame, read from its own attachments.
    static func changedFraction(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return changedFraction(
            dirtyRects: ScreenCaptureFrameAdmission.dirtyRects(of: sampleBuffer),
            frameWidth: CVPixelBufferGetWidth(imageBuffer),
            frameHeight: CVPixelBufferGetHeight(imageBuffer)
        )
    }

    private func encoders() -> [any MotionRoutableEncoder] {
        lock.lock()
        defer { lock.unlock() }
        return [settledEncoder, movingEncoder].compactMap { $0 }
    }
}
