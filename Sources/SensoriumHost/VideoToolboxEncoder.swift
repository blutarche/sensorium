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

/// The submission half of an encoder, named separately so the frame path can
/// be driven without a live `VTCompressionSession`.
@available(macOS 13.0, *)
public protocol VideoFrameEncoding: AnyObject {
    func encode(_ sampleBuffer: CMSampleBuffer) throws
}

@available(macOS 13.0, *)
public final class VideoToolboxEncoder: VideoFrameEncoding, @unchecked Sendable {
    private var session: VTCompressionSession?
    /// What this session was created with. Its dimensions are fixed for the
    /// session's whole life; its frame rate and quality are only the opening
    /// ones, and `applied` below is what is actually in force now.
    public let configuration: VideoEncoderConfiguration
    private let callbackBox: CallbackBox
    /// `encode` runs on the capture queue, and both the key-frame request and
    /// a fidelity change arrive from whichever thread decided them, so the
    /// state between them is held under this lock.
    private let stateLock = NSLock()
    private var keyFrameRequested = false
    /// The fidelity actually in force, updated only when VideoToolbox has
    /// accepted it. Each lever derives its new bitrate from this rather than
    /// from `configuration`: bits per second is now a product of frame rate
    /// and quality, so deriving from the opening values would make either
    /// lever silently undo the other.
    private var applied: VideoEncoderConfiguration

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
            value: configuration.framesPerSecond as CFNumber
        )
        // `MaxKeyFrameInterval` alone counts frames, and capture is
        // change-driven: a screen producing far fewer than `framesPerSecond`
        // real frames stretches the intended one-IDR-per-second recovery
        // point out to minutes on a quiet screen -- exactly backwards, since
        // that is also when a viewer reconnect or an ingress reset is most
        // likely to land on a viewer with nothing to recover with (see
        // `VideoFrameIngress.reset()`). Setting the duration bound alongside
        // the frame-count bound enforces the interval this was always meant
        // to be, regardless of how many frames actually arrived within it.
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 1.0 as CFNumber
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
        case (.h264, .mainAutoLevel):
            return kVTProfileLevel_H264_Main_AutoLevel
        case (.h264, .highAutoLevel):
            return kVTProfileLevel_H264_High_AutoLevel
        case (.hevc, _):
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Changes how many bits this resolution is allowed, on the running
    /// session, with no rebuild: `AverageBitRate` and `DataRateLimits` are
    /// both settable on a live `VTCompressionSession`, unlike the frame
    /// dimensions, which are fixed for the session's whole life.
    public func apply(qualityScale: Double) throws {
        guard let session else {
            throw VideoEncoderError.propertyUpdateFailed(-1)
        }
        try applyRate(currentlyApplied().with(qualityScale: qualityScale), to: session)
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
        let bitRateStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: averageBitRate as CFNumber
        )
        guard bitRateStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(bitRateStatus)
        }
        let dataRateLimits: [CFNumber] = [
            dataRateLimitBytes as CFNumber,
            dataRateLimitSeconds as CFNumber
        ]
        let limitsStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )
        guard limitsStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(limitsStatus)
        }
    }

    /// Tells the running session how many frames per second to expect, with
    /// no rebuild. `ExpectedFrameRate` is what the rate controller spends its
    /// bit budget against, so leaving it at the old rate makes every frame at
    /// a lower one look starved. `MaxKeyFrameInterval` counts frames, so it
    /// moves with the rate to stay one second's worth;
    /// `MaxKeyFrameIntervalDuration` is deliberately not touched, because the
    /// one-second recovery point it enforces is exactly what must not change
    /// when the frame rate does.
    public func apply(framesPerSecond: Int) throws {
        guard let session else {
            throw VideoEncoderError.propertyUpdateFailed(-1)
        }
        let expectedRateStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: framesPerSecond as CFNumber
        )
        guard expectedRateStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(expectedRateStatus)
        }
        let keyFrameIntervalStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: framesPerSecond as CFNumber
        )
        guard keyFrameIntervalStatus == noErr else {
            throw VideoEncoderError.propertyUpdateFailed(keyFrameIntervalStatus)
        }
        try applyRate(currentlyApplied().with(framesPerSecond: framesPerSecond), to: session)
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

    /// Flushes the encoder and makes the next frame a key frame,
    /// indivisibly, for a still-screen refresh. The refresh is encoded on
    /// its own session with its own parameter sets, so the viewer rebuilds
    /// its decoder and any delta emitted behind the refresh would reference
    /// pictures it no longer holds. `encode` holds the same lock across its
    /// submission, so nothing can slip between the flush and the request.
    public func completeFramesRequestingKeyFrame() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
        keyFrameRequested = true
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw VideoEncoderError.frameSubmissionFailed(-1)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        // Held across the submission, not merely across reading the flag:
        // `completeFramesRequestingKeyFrame` takes the same lock, and what it
        // promises is that nothing reaches VideoToolbox between its flush and
        // its request.
        stateLock.lock()
        defer { stateLock.unlock() }
        let forcesKeyFrame = keyFrameRequested
        keyFrameRequested = false
        let frameProperties: CFDictionary? = forcesKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            if forcesKeyFrame {
                // The frame carrying the request never reached the encoder, so
                // the request has not been served: re-arm it rather than let a
                // failed submission swallow it silently.
                keyFrameRequested = true
            }
            throw VideoEncoderError.frameSubmissionFailed(status)
        }
    }
}
