import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@available(macOS 13.0, *)
public enum StillFrameEncoderError: Error, Equatable {
    case sessionCreationFailed(OSStatus)
    case propertyUpdateFailed(OSStatus)
    case frameSubmissionFailed(OSStatus)
    /// VideoToolbox accepted the frame, finished, and produced nothing. Named
    /// rather than reported as a submission failure: there is a picture to
    /// send and no frame carrying it, which is a different thing from the
    /// encoder having refused it.
    case noEncodedFrame
    /// Every quality this picture was allowed to try still produced more bytes
    /// than the wire format accepts. Reported rather than returned: the write
    /// would refuse it, and by then the frame has already been counted and
    /// logged as the picture that went out.
    case frameExceedsTransportLimit(bytes: Int)
}

/// A session of its own because `kVTCompressionPropertyKey_Quality` is
/// ignored once a bit rate is set, and average-bitrate control spends only
/// a fraction of a second's budget on any one frame however large that
/// budget is. The stream's session is left untouched. This frame carries
/// its own parameter sets, so the viewer's decoder keeps no reference
/// pictures from the stream's session and the stream's next frame must be
/// a key frame, which `HostMediaPipeline` asks for.
@available(macOS 13.0, *)
public enum StillFrameEncoder {
    /// Encodes `imageBuffer` whole, at `VideoEncoderConfiguration.stillRefreshQuality`.
    ///
    /// A frame larger than the configuration's still-refresh ceiling is encoded
    /// again, more softly, down the ladder in
    /// `VideoEncoderConfiguration.stillRefreshFallbackQualities`: quality mode
    /// has no upper bound of its own, and content with nothing to predict -- a
    /// photograph, a paused video -- costs many times at the same quality what
    /// a screen of text does, sometimes by more than one step's worth.
    ///
    /// What comes out of the last attempt is sent even if it is still over the
    /// bitrate half of the ceiling, because a screen that has stopped changing
    /// has to be resent with something. The transport's half of that ceiling is
    /// different: a frame past
    /// `VideoEncoderConfiguration.stillRefreshTransportCeilingBytes` cannot be
    /// written at all, so it is refused here with
    /// `frameExceedsTransportLimit` rather than handed on to fail at the write.
    ///
    /// Every attempt is given the same `presentationTimeNanoseconds`, on a
    /// session of its own, so the frame that goes out carries the timestamp its
    /// caller already recorded capture and encode stages against. Sharing one
    /// session would forbid that: VideoToolbox requires each frame's timestamp
    /// to be later than the last one that session was given.
    ///
    /// Synchronous: it returns with the frame encoded, so a caller can report
    /// the size of what it is about to send.
    public static func encodeKeyFrame(
        imageBuffer: CVImageBuffer,
        configuration: VideoEncoderConfiguration,
        presentationTimeNanoseconds: Int64
    ) throws -> CMSampleBuffer {
        var quality = VideoEncoderConfiguration.stillRefreshQuality
        var attemptsMade = 0
        while true {
            let frame = try encodeOnce(
                imageBuffer: imageBuffer,
                configuration: configuration,
                presentationTimeNanoseconds: presentationTimeNanoseconds,
                quality: quality
            )
            attemptsMade += 1
            let frameBytes = CMSampleBufferGetTotalSampleSize(frame)
            guard let softer = VideoEncoderConfiguration.stillRefreshRetryQuality(
                frameBytes: frameBytes,
                ceilingBytes: configuration.stillRefreshCeilingBytes,
                attemptsMade: attemptsMade
            ) else {
                guard frameBytes <= VideoEncoderConfiguration.stillRefreshTransportCeilingBytes else {
                    throw StillFrameEncoderError.frameExceedsTransportLimit(bytes: frameBytes)
                }
                return frame
            }
            quality = softer
        }
    }

    /// One attempt, on a session of its own.
    private static func encodeOnce(
        imageBuffer: CVImageBuffer,
        configuration: VideoEncoderConfiguration,
        presentationTimeNanoseconds: Int64,
        quality: Double
    ) throws -> CMSampleBuffer {
        let output = EncodedFrameBox()
        let session = try makeSession(configuration: configuration, output: output)
        defer {
            VTCompressionSessionInvalidate(session)
        }
        try setQuality(quality, on: session)
        return try encodeOne(
            imageBuffer: imageBuffer,
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            framesPerSecond: configuration.framesPerSecond,
            session: session,
            output: output
        )
    }

    private static func makeSession(
        configuration: VideoEncoderConfiguration,
        output: EncodedFrameBox
    ) throws -> VTCompressionSession {
        var encoderSpecificationEntries: [CFString: Any] = [:]
        if configuration.requiresHardwareAcceleration {
            encoderSpecificationEntries[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
            encoderSpecificationEntries[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = kCFBooleanTrue
        }
        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.encodeWidth),
            height: Int32(configuration.encodeHeight),
            codecType: configuration.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecificationEntries.isEmpty ? nil : encoderSpecificationEntries as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard let refcon else { return }
                let box = Unmanaged<EncodedFrameBox>.fromOpaque(refcon).takeUnretainedValue()
                box.record(status: status, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(output).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw StillFrameEncoderError.sessionCreationFailed(status)
        }
        // No AverageBitRate and no DataRateLimits on purpose: either one puts
        // this session back under rate control and the quality target below
        // stops meaning anything.
        VTSessionSetProperty(createdSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(createdSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(createdSession, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: profileLevelKey(codec: configuration.codec, profileLevel: configuration.profileLevel)
        )
        VTCompressionSessionPrepareToEncodeFrames(createdSession)
        return createdSession
    }

    private static func setQuality(_ quality: Double, on session: VTCompressionSession) throws {
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_Quality,
            value: quality as CFNumber
        )
        guard status == noErr else {
            throw StillFrameEncoderError.propertyUpdateFailed(status)
        }
    }

    private static func encodeOne(
        imageBuffer: CVImageBuffer,
        presentationTimeNanoseconds: Int64,
        framesPerSecond: Int,
        session: VTCompressionSession,
        output: EncodedFrameBox
    ) throws -> CMSampleBuffer {
        output.reset()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: CMTime(value: presentationTimeNanoseconds, timescale: 1_000_000_000),
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond))),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw StillFrameEncoderError.frameSubmissionFailed(status)
        }
        // Blocks until the encoder has finished with this frame, which is what
        // makes the size of what is about to be sent knowable here.
        let completionStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard completionStatus == noErr else {
            throw StillFrameEncoderError.frameSubmissionFailed(completionStatus)
        }
        if let failure = output.failureStatus {
            throw StillFrameEncoderError.frameSubmissionFailed(failure)
        }
        guard let frame = output.frame else {
            throw StillFrameEncoderError.noEncodedFrame
        }
        return frame
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
}

/// The one frame a still-refresh encode produces, handed from VideoToolbox's
/// callback thread back to the caller that is waiting on it.
@available(macOS 13.0, *)
private final class EncodedFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var encoded: CMSampleBuffer?
    private var failure: OSStatus?

    func record(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        if status != noErr {
            failure = status
            return
        }
        encoded = sampleBuffer
    }

    var frame: CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return encoded
    }

    var failureStatus: OSStatus? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        encoded = nil
        failure = nil
    }
}
