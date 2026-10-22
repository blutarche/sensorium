import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@available(macOS 13.0, *)
public enum VideoEncoderError: Error, Equatable {
    case sessionCreationFailed(OSStatus)
    case frameSubmissionFailed(OSStatus)
    /// A property change on a live compression session was refused. Reported
    /// rather than swallowed: the caller asked for a fidelity change because
    /// something measured could not keep up, so a silent no-op would leave it
    /// believing it had already acted.
    case propertyUpdateFailed(OSStatus)
}

/// One frame's fate as VideoToolbox's compression output callback reports
/// it. All three outcomes are one value so a caller holding a per-frame
/// resource (`EncodeAdmissionGate`'s admission slot) can free it on
/// whichever arrives.
@available(macOS 13.0, *)
public enum VideoEncodeOutcome {
    /// The frame encoded; `CMSampleBuffer` carries its compressed output.
    case encoded(CMSampleBuffer)
    /// VideoToolbox dropped the frame: a successful status, no output.
    case dropped
    /// VideoToolbox failed to encode the frame and reported this status.
    case failed(OSStatus)

    /// Classifies one compression-output callback from its raw arguments.
    /// Split out from the callback itself because the callback needs a live
    /// `VTCompressionSession` to ever run, so this is the only part of that
    /// path a test can reach.
    public static func callbackOutcome(status: OSStatus, sampleBuffer: CMSampleBuffer?) -> VideoEncodeOutcome {
        guard status == noErr else { return .failed(status) }
        guard let sampleBuffer else { return .dropped }
        return .encoded(sampleBuffer)
    }
}

/// The VideoToolbox calls a `VideoToolboxEncoder` makes on a session it has
/// already created: property changes on the live session, and the flush
/// before it is invalidated. Both go through the encoder service and can wait
/// on the hardware encoder for as long as it is stuck. Replaceable so a test
/// can stand in for an encoder service that stops answering; production uses
/// `live` alone.
@available(macOS 13.0, *)
package struct VideoToolboxSessionCalls: Sendable {
    package var setProperty: @Sendable (VTSession, CFString, CFTypeRef?) -> OSStatus
    package var completeFrames: @Sendable (VTCompressionSession) -> Void

    package init(
        setProperty: @escaping @Sendable (VTSession, CFString, CFTypeRef?) -> OSStatus,
        completeFrames: @escaping @Sendable (VTCompressionSession) -> Void
    ) {
        self.setProperty = setProperty
        self.completeFrames = completeFrames
    }

    package static let live = VideoToolboxSessionCalls(
        setProperty: { session, key, value in
            VTSessionSetProperty(session, key: key, value: value)
        },
        completeFrames: { session in
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    )
}

/// The submission half of an encoder, named separately so the frame path can
/// be driven without a live `VTCompressionSession`.
@available(macOS 13.0, *)
public protocol VideoFrameEncoding: AnyObject {
    func encode(_ sampleBuffer: CMSampleBuffer) throws
    /// Makes the next frame submitted a key frame. Safe from any thread.
    func requestKeyFrame()
}

@available(macOS 13.0, *)
public final class VideoToolboxEncoder: VideoFrameEncoding, @unchecked Sendable {
    private var session: VTCompressionSession?
    /// What this session was created with. Its dimensions are fixed for the
    /// session's whole life; its frame rate, quality and key-frame interval
    /// are only the opening ones, and `applied` below is what is actually in
    /// force now.
    public let configuration: VideoEncoderConfiguration
    private let callbackBox: CallbackBox
    /// `encode` runs on the capture queue, and both the key-frame request and
    /// a fidelity change arrive from whichever thread decided them, so the
    /// state between them is held under this lock.
    private let stateLock = NSLock()
    private var keyFrameRequested = false
    /// How many `holdFramesAndFlush` calls are still waiting for their
    /// `resumeHeldFramesWithKeyFrame`. Above 0, every frame `encode` accepts
    /// goes to `heldFrames` instead of the session.
    private var holdDepth = 0
    private var heldFrames: [CMSampleBuffer] = []
    /// The fidelity actually in force, updated only when VideoToolbox has
    /// accepted it. Each lever derives its new bitrate from this rather than
    /// from `configuration`: bits per second is now a product of frame rate
    /// and quality, so deriving from the opening values would make either
    /// lever silently undo the other.
    private var applied: VideoEncoderConfiguration
    private var calls = VideoToolboxSessionCalls.live
    /// Where every change to the live session runs. Each one is a round trip
    /// to the encoder service, which waits on the hardware encoder for as long
    /// as that is stuck -- minutes, on a locked machine. A caller on the main
    /// actor would stall host-screen input injection, session control and
    /// shutdown with it, so no change runs on the caller's thread. Serial, so
    /// changes reach the session, and advance `applied`, in the order they
    /// were asked for.
    private let liveChangeQueue = DispatchQueue(label: "sensorium.encoder-live-changes")
    /// Set once the session has been flushed and invalidated, by `shutDown`.
    private var isFinished = false

    /// The calls this encoder makes on its live session. For this package's
    /// tests, which replace them to stand in for a stalled encoder service.
    package var sessionCalls: VideoToolboxSessionCalls {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return calls
        }
        set {
            stateLock.lock()
            calls = newValue
            stateLock.unlock()
        }
    }

    /// The frame rate currently in force, for a caller that has to put it
    /// back -- `HostMediaPipeline` reverts this encoder when the capture half
    /// of a frame-rate step fails.
    public var appliedFramesPerSecond: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return applied.framesPerSecond
    }

    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable (VideoEncodeOutcome) -> Void

        init(handler: @escaping @Sendable (VideoEncodeOutcome) -> Void) {
            self.handler = handler
        }
    }

    /// `frameOutcomeHandler` is called exactly once for every frame this
    /// encoder accepts, whether the frame encoded, was dropped, or failed —
    /// never only for the ones that produced output. A caller holding a
    /// per-frame resource (`EncodeAdmissionGate` holds an admission slot)
    /// depends on that, so the callback below must not filter any outcome out.
    public init(
        configuration: VideoEncoderConfiguration = .remoteDefault,
        frameOutcomeHandler: @escaping @Sendable (VideoEncodeOutcome) -> Void
    ) throws {
        self.configuration = configuration
        applied = configuration
        callbackBox = CallbackBox(handler: frameOutcomeHandler)
        var createdSession: VTCompressionSession?
        let codecType: CMVideoCodecType = configuration.codec == .h264
            ? kCMVideoCodecType_H264
            : kCMVideoCodecType_HEVC
        var encoderSpecificationEntries: [CFString: Any] = [:]
        if configuration.requiresHardwareAcceleration {
            encoderSpecificationEntries[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
            encoderSpecificationEntries[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.encodeWidth),
            height: Int32(configuration.encodeHeight),
            codecType: codecType,
            encoderSpecification: encoderSpecificationEntries.isEmpty ? nil : encoderSpecificationEntries as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                // `refcon` is the box this initializer passes below, so it is
                // never nil in practice; every other argument combination is a
                // real outcome and must be reported, not filtered out here.
                guard let refcon else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                box.handler(VideoEncodeOutcome.callbackOutcome(status: status, sampleBuffer: sampleBuffer))
            },
            refcon: Unmanaged.passUnretained(callbackBox).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }
        session = createdSession

        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: configuration.maxKeyFrameIntervalFrames as CFNumber
        )
        // `MaxKeyFrameInterval` alone counts frames, and capture is
        // change-driven: a screen producing far fewer than `framesPerSecond`
        // real frames stretches the key-frame interval out to minutes on a
        // quiet screen -- exactly when a viewer that has given a group of
        // frames up is most likely to be left with nothing to recover with.
        // Setting the duration bound alongside the frame-count bound enforces
        // `keyFrameIntervalSeconds` however few frames arrive within it.
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: configuration.keyFrameIntervalSeconds as CFNumber
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: configuration.framesPerSecond as CFNumber
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: configuration.averageBitRate as CFNumber
        )
        let dataRateLimits: [CFNumber] = [
            configuration.dataRateLimitBytes as CFNumber,
            configuration.dataRateLimitSeconds as CFNumber
        ]
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: configuration.maxFrameDelayCount as CFNumber
        )
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: Self.profileLevelKey(codec: configuration.codec, profileLevel: configuration.profileLevel)
        )
        VTCompressionSessionPrepareToEncodeFrames(createdSession)
    }

    private static func profileLevelKey(codec: VideoCodec, profileLevel: VideoEncoderProfileLevel) -> CFString {
        switch (codec, profileLevel) {
        case (.h264, .baselineAutoLevel):
            return kVTProfileLevel_H264_Baseline_AutoLevel
        case (.h264, .constrainedBaselineAutoLevel):
            return kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case (.h264, .mainAutoLevel):
            return kVTProfileLevel_H264_Main_AutoLevel
        case (.h264, .highAutoLevel):
            return kVTProfileLevel_H264_High_AutoLevel
        case (.hevc, _):
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    /// Emits every frame still in flight and invalidates the session, on
    /// `liveChangeQueue`: behind any change still waiting on the encoder
    /// service rather than racing it, and never on the caller's thread, since
    /// the flush waits on that service too. Returns once both are done, so a
    /// caller that builds the next encoder after this has the previous
    /// session's frames out first. Every later call does nothing.
    public func shutDown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            liveChangeQueue.async { [self] in
                finishSessionOnLiveChangeQueue()
                continuation.resume()
            }
        }
    }

    private func finishSessionOnLiveChangeQueue() {
        stateLock.lock()
        let wasFinished = isFinished
        isFinished = true
        let calls = calls
        stateLock.unlock()
        guard !wasFinished, let session else {
            return
        }
        calls.completeFrames(session)
        VTCompressionSessionInvalidate(session)
    }

    /// For an encoder released without `shutDown`. Released wherever its last
    /// reference went, which can be the main actor, so the flush is handed to
    /// `liveChangeQueue` instead of run here.
    deinit {
        guard !isFinished, let session else {
            return
        }
        let finishing = FinishingSession(session: session, calls: calls, callbackBox: callbackBox)
        liveChangeQueue.async {
            finishing.finish()
        }
    }

    /// What finishing a released encoder's session needs, carried to
    /// `liveChangeQueue`. The output callback reaches `callbackBox` through an
    /// unretained pointer, so it is held here until the flush has reported
    /// every frame still in flight. Nothing else holds the session once the
    /// encoder is gone, which is what makes handing it across safe.
    private final class FinishingSession: @unchecked Sendable {
        let session: VTCompressionSession
        let calls: VideoToolboxSessionCalls
        let callbackBox: CallbackBox

        init(session: VTCompressionSession, calls: VideoToolboxSessionCalls, callbackBox: CallbackBox) {
            self.session = session
            self.calls = calls
            self.callbackBox = callbackBox
        }

        func finish() {
            calls.completeFrames(session)
            VTCompressionSessionInvalidate(session)
            withExtendedLifetime(callbackBox) {}
        }
    }

    /// Runs one change to the live session on `liveChangeQueue` and returns
    /// once VideoToolbox has answered it, with whatever it threw.
    private func onLiveChangeQueue(_ change: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            liveChangeQueue.async {
                do {
                    try change()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Changes how many bits this resolution is allowed, on the running
    /// session, with no rebuild: `AverageBitRate` and `DataRateLimits` are
    /// both settable on a live `VTCompressionSession`, unlike the frame
    /// dimensions, which are fixed for the session's whole life.
    ///
    /// Runs on `liveChangeQueue`, never on the caller's thread.
    public func apply(qualityScale: Double) async throws {
        try await onLiveChangeQueue { [self] in
            try applyOnLiveChangeQueue(qualityScale: qualityScale)
        }
    }

    private func applyOnLiveChangeQueue(qualityScale: Double) throws {
        guard let session = unfinishedSession() else {
            throw VideoEncoderError.propertyUpdateFailed(-1)
        }
        try applyRate(currentlyApplied().with(qualityScale: qualityScale), to: session)
    }

    /// The session, unless `shutDown` has already finished it.
    private func unfinishedSession() -> VTCompressionSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isFinished ? nil : session
    }

    private func currentlyApplied() -> VideoEncoderConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return applied
    }

    /// `AverageBitRate` and `DataRateLimits` always move together:
    /// `DataRateLimits` is a hard per-window ceiling, so left at another
    /// fidelity's budget it would either keep clipping bursts the new average
    /// no longer produces, or cap a rise back toward the full picture.
    ///
    /// `applied` is advanced only once both have been accepted, so a refused
    /// change leaves this encoder describing the fidelity it still has.
    private func applyRate(_ target: VideoEncoderConfiguration, to session: VTCompressionSession) throws {
        try setRate(
            averageBitRate: target.averageBitRate,
            dataRateLimitBytes: target.dataRateLimitBytes,
            dataRateLimitSeconds: target.dataRateLimitSeconds,
            to: session
        )
        stateLock.lock()
        applied = target
        stateLock.unlock()
    }

    /// The two properties alone, with no claim about which fidelity they
    /// represent -- that claim is `applied`, and only `applyRate` makes it.
    private func setRate(
        averageBitRate: Int,
        dataRateLimitBytes: Int,
        dataRateLimitSeconds: Double,
        to session: VTCompressionSession
    ) throws {
        let calls = sessionCalls
        let bitRateStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_AverageBitRate,
            averageBitRate as CFNumber
        )
        guard bitRateStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(bitRateStatus)
        }
        let dataRateLimits: [CFNumber] = [
            dataRateLimitBytes as CFNumber,
            dataRateLimitSeconds as CFNumber
        ]
        let limitsStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_DataRateLimits,
            dataRateLimits as CFArray
        )
        guard limitsStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(limitsStatus)
        }
    }

    /// Tells the running session how many frames per second to expect, with
    /// no rebuild. `ExpectedFrameRate` is what the rate controller spends its
    /// bit budget against, so leaving it at the old rate makes every frame at
    /// a lower one look starved. `MaxKeyFrameInterval` counts frames, so it
    /// moves with the rate to stay the frame rate times the key-frame interval
    /// in force; `MaxKeyFrameIntervalDuration` is deliberately not touched,
    /// because the interval it enforces is exactly what must not change when
    /// the frame rate does.
    ///
    /// Runs on `liveChangeQueue`, never on the caller's thread.
    public func apply(framesPerSecond: Int) async throws {
        try await onLiveChangeQueue { [self] in
            try applyOnLiveChangeQueue(framesPerSecond: framesPerSecond)
        }
    }

    private func applyOnLiveChangeQueue(framesPerSecond: Int) throws {
        guard let session = unfinishedSession() else {
            throw VideoEncoderError.propertyUpdateFailed(-1)
        }
        let target = currentlyApplied().with(framesPerSecond: framesPerSecond)
        let calls = sessionCalls
        let expectedRateStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_ExpectedFrameRate,
            framesPerSecond as CFNumber
        )
        guard expectedRateStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(expectedRateStatus)
        }
        let keyFrameIntervalStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            target.maxKeyFrameIntervalFrames as CFNumber
        )
        guard keyFrameIntervalStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(keyFrameIntervalStatus)
        }
        try applyRate(target, to: session)
    }

    /// Changes how long the running session may go without a key frame, with
    /// no rebuild. Both bounds move together, the frame count at the frame
    /// rate in force, so neither one cuts the other's interval short.
    ///
    /// `applied` is advanced only once both have been accepted, so a later
    /// frame-rate change keeps whichever interval the session actually has.
    ///
    /// Runs on `liveChangeQueue`, never on the caller's thread.
    public func apply(keyFrameIntervalSeconds: Double) async throws {
        try await onLiveChangeQueue { [self] in
            try applyOnLiveChangeQueue(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
        }
    }

    private func applyOnLiveChangeQueue(keyFrameIntervalSeconds: Double) throws {
        guard let session = unfinishedSession() else {
            throw VideoEncoderError.propertyUpdateFailed(-1)
        }
        let target = currentlyApplied().with(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
        let calls = sessionCalls
        let framesStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            target.maxKeyFrameIntervalFrames as CFNumber
        )
        guard framesStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(framesStatus)
        }
        let durationStatus = calls.setProperty(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            target.keyFrameIntervalSeconds as CFNumber
        )
        guard durationStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(durationStatus)
        }
        stateLock.lock()
        applied = target
        stateLock.unlock()
    }

    /// The two key-frame bounds the live session holds, read back from
    /// VideoToolbox rather than from what this encoder asked for. `nil` when
    /// there is no session or either property cannot be read. For this
    /// package's tests.
    package func sessionKeyFrameIntervalBounds() -> (frames: Int, seconds: Double)? {
        guard let session else {
            return nil
        }
        var frames: CFTypeRef?
        var seconds: CFTypeRef?
        guard VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            allocator: kCFAllocatorDefault,
            valueOut: &frames
        ) == noErr,
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                allocator: kCFAllocatorDefault,
                valueOut: &seconds
            ) == noErr,
            let frameCount = (frames as? NSNumber)?.intValue,
            let duration = (seconds as? NSNumber)?.doubleValue else {
            return nil
        }
        return (frameCount, duration)
    }

    /// Makes the next frame this encoder accepts a key frame, whatever the
    /// key-frame interval would otherwise have decided. A fidelity change is
    /// worth one: the viewer sees the new picture at once instead of watching
    /// deltas built on the old one until the interval next comes around.
    ///
    /// Safe to call from a different thread than `encode`, which runs on the
    /// capture queue: the request is a flag taken by the next submission
    /// rather than a property change racing a frame already in flight.
    public func requestKeyFrame() {
        stateLock.lock()
        defer { stateLock.unlock() }
        keyFrameRequested = true
    }

    /// Empties the encoder for a still-screen refresh and holds every frame
    /// `encode` accepts from now until the matching
    /// `resumeHeldFramesWithKeyFrame`. The refresh is encoded on its own
    /// session with its own parameter sets, so the viewer rebuilds its decoder
    /// around them, and the stream must reach the transport in this order: the
    /// frames already in flight, then the refresh, then a key frame, then
    /// deltas. The flush puts out the first. The caller hands the refresh on
    /// between this call and the resume. The resume lets the held frames in
    /// behind it, the first of them a key frame. A frame submitted before the
    /// refresh was handed on could come out ahead of it, and the delta after
    /// that frame would reach a decoder that no longer holds its reference.
    ///
    /// `stateLock` is released while VideoToolbox flushes. The flush waits
    /// for the output callback of every frame still in flight, and that
    /// callback is where `EncodeAdmissionGate` submits the next capture,
    /// through `encode`, which needs the same lock. Holding that frame rather
    /// than waiting for the flush is what lets the callback return.
    ///
    /// Every call must be matched by exactly one resume, on every path,
    /// including a refresh that is given up or refused. A frame held with no
    /// resume to come never gets an outcome, and its slots in the session's
    /// and the machine's admission gates are never given back. Holds nest:
    /// frames go in only when the last of them is resumed.
    ///
    /// Blocks until VideoToolbox has emitted every frame that was in flight,
    /// so the caller belongs off the main actor. It requests no key frame;
    /// the resume does.
    public func holdFramesAndFlush() {
        stateLock.lock()
        holdDepth += 1
        let session = session
        stateLock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    /// Ends one `holdFramesAndFlush`. Ending the last one makes the next
    /// frame a key frame and submits every held frame, in the order `encode`
    /// accepted them, so the first of them is that key frame.
    ///
    /// A held frame whose submission fails is reported through
    /// `frameOutcomeHandler` as `.failed`, so it still gets its one outcome.
    /// That report is made with `stateLock` released, because the handler
    /// may call `encode` again.
    public func resumeHeldFramesWithKeyFrame() {
        stateLock.lock()
        // Never below 0: a resume with no hold to end must not leave the next
        // hold holding nothing.
        holdDepth = max(holdDepth - 1, 0)
        guard holdDepth == 0 else {
            stateLock.unlock()
            return
        }
        keyFrameRequested = true
        let held = heldFrames
        heldFrames = []
        var failedStatuses: [OSStatus] = []
        for frame in held {
            let status = submitHoldingStateLock(frame)
            if status != noErr {
                failedStatuses.append(status)
            }
        }
        stateLock.unlock()

        for status in failedStatuses {
            callbackBox.handler(.failed(status))
        }
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) throws {
        guard session != nil, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            throw VideoEncoderError.frameSubmissionFailed(-1)
        }
        // Held across the submission, not merely across reading the flag, so
        // one key-frame request is taken by exactly one frame and frames reach
        // VideoToolbox in the order they took the lock.
        stateLock.lock()
        defer { stateLock.unlock() }
        if holdDepth > 0 {
            // Accepted now and reported on later, once
            // `resumeHeldFramesWithKeyFrame` submits it. Waiting here instead
            // would block the very output callback a flush is waiting on, and
            // submitting now could put this frame out ahead of the refresh.
            heldFrames.append(sampleBuffer)
            return
        }
        let status = submitHoldingStateLock(sampleBuffer)
        guard status == noErr else {
            throw VideoEncoderError.frameSubmissionFailed(status)
        }
    }

    /// Hands one frame to VideoToolbox, taking any pending key-frame request
    /// with it. Call with `stateLock` held. Answers -1 when there is no
    /// session or no picture to submit.
    private func submitHoldingStateLock(_ sampleBuffer: CMSampleBuffer) -> OSStatus {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return -1
        }
        let forcesKeyFrame = keyFrameRequested
        keyFrameRequested = false
        let frameProperties: CFDictionary? = forcesKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr, forcesKeyFrame {
            // The frame carrying the request never reached the encoder, so
            // the request has not been served: re-arm it rather than let a
            // failed submission swallow it silently.
            keyFrameRequested = true
        }
        return status
    }
}
