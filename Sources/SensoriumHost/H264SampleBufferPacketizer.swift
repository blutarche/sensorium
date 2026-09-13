import SensoriumCore
import CoreMedia
import Foundation
import VideoToolbox

@available(macOS 13.0, *)
public enum H264SampleBufferPacketizerError: Error, Equatable {
    case missingDataBuffer
    case dataCopyFailed(OSStatus)
    case invalidPresentationTime
    case missingFormatDescription
    case parameterSetExtractionFailed(OSStatus)
    case invalidParameterSet
    /// The encoder was rebuilt at a new resolution and this frame is not the
    /// keyframe the viewer needs before anything else can be decoded.
    case awaitingKeyFrameAfterReconfiguration
}

/// Converts H.264 VideoToolbox output into a bounded transport packet.
@available(macOS 13.0, *)
public final class H264SampleBufferPacketizer: @unchecked Sendable {
    private let lock = NSLock()
    private let sequencer: VideoPacketSequencer
    private var generation = EncoderGenerationGate()

    /// `sequencer` defaults to a fresh one, but a caller that rebuilds this
    /// packetizer's owning object mid-session -- host-screen mode's
    /// `replaceCapture`, which discards the whole capture object and
    /// everything it owns -- must inject the same `VideoPacketSequencer`
    /// every rebuilt packetizer shares, or the viewer's `VideoFrameIngress`
    /// discards the entire restarted stream as stale (its sequence numbers
    /// start back at zero, below the last one it already admitted).
    public init(sequencer: VideoPacketSequencer = VideoPacketSequencer()) {
        self.sequencer = sequencer
    }

    /// Call when the compression session has been replaced — a resolution
    /// change — so the next packet sent is the keyframe carrying the new
    /// SPS/PPS rather than a delta the viewer cannot decode.
    public func beginNewEncoderGeneration() {
        lock.lock()
        defer { lock.unlock() }
        generation.beginNewGeneration()
    }

    /// Numbers this frame and hands it to `sink` without letting go of the
    /// lock in between, answering whatever `sink` answers.
    ///
    /// One step on purpose. Frames reach this from two threads -- VideoToolbox's
    /// own, for the stream, and the main actor, for a still-screen refresh --
    /// and two callers that each took a number under the lock and then raced to
    /// the transport would arrive in the wrong order. The viewer's
    /// `VideoFrameIngress` discards any frame whose sequence is not newer than
    /// the last one it admitted, so the loser of that race is thrown away
    /// outright, and the still frame is the one that can least afford to lose
    /// it: it is a whole picture, and nothing will replace it until the screen
    /// moves again.
    ///
    /// `sink` runs under the lock, so it must not call back into this
    /// packetizer. Handing a packet to the transport does not: the send queue
    /// has a lock of its own and never reaches back here.
    public func deliver<Delivery>(
        from sampleBuffer: CMSampleBuffer,
        to sink: (EncodedVideoFramePacket) -> Delivery
    ) throws -> Delivery {
        let read = try readFrame(from: sampleBuffer)
        lock.lock()
        defer { lock.unlock() }
        guard generation.admits(keyFrame: read.isKeyFrame) else {
            throw H264SampleBufferPacketizerError.awaitingKeyFrameAfterReconfiguration
        }
        return sink(sequencer.packet(
            presentationTimeNanoseconds: read.presentationTimeNanoseconds,
            isKeyFrame: read.isKeyFrame,
            codecConfiguration: read.codecConfiguration,
            payload: read.payload
        ))
    }

    public func packet(from sampleBuffer: CMSampleBuffer) throws -> EncodedVideoFramePacket {
        try deliver(from: sampleBuffer) { $0 }
    }

    /// Everything about one encoder output that can be read before the lock is
    /// taken: the payload copy and the parameter-set extraction, which are the
    /// expensive part and depend on nothing this packetizer holds.
    private struct ReadFrame {
        let presentationTimeNanoseconds: UInt64
        let isKeyFrame: Bool
        let codecConfiguration: Data?
        let payload: Data
    }

    private func readFrame(from sampleBuffer: CMSampleBuffer) throws -> ReadFrame {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw H264SampleBufferPacketizerError.missingDataBuffer
        }
        let payloadLength = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: payloadLength)
        let copyStatus = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: payloadLength,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw H264SampleBufferPacketizerError.dataCopyFailed(copyStatus)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            throw H264SampleBufferPacketizerError.invalidPresentationTime
        }
        let scaledTime = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        guard scaledTime.value >= 0 else {
            throw H264SampleBufferPacketizerError.invalidPresentationTime
        }
        let isKeyFrame = !isNotSync(sampleBuffer)
        return ReadFrame(
            presentationTimeNanoseconds: UInt64(scaledTime.value),
            isKeyFrame: isKeyFrame,
            codecConfiguration: isKeyFrame ? try h264Configuration(from: sampleBuffer) : nil,
            payload: payload
        )
    }

    private func isNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let attachment = attachments.first else {
            return false
        }
        return (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) == true
    }

    private func h264Configuration(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw H264SampleBufferPacketizerError.missingFormatDescription
        }
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsLength,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard spsStatus == noErr, parameterSetCount >= 2, let spsPointer, spsLength > 0 else {
            throw H264SampleBufferPacketizerError.parameterSetExtractionFailed(spsStatus)
        }
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsLength,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard ppsStatus == noErr, let ppsPointer, ppsLength > 0 else {
            throw H264SampleBufferPacketizerError.parameterSetExtractionFailed(ppsStatus)
        }
        return try H264CodecConfigurationCodec.encode(H264CodecConfiguration(
            sequenceParameterSet: Data(bytes: spsPointer, count: spsLength),
            pictureParameterSet: Data(bytes: ppsPointer, count: ppsLength)
        ))
    }
}
