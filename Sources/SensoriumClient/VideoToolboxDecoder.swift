#if canImport(VideoToolbox)
import SensoriumCore
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@available(macOS 13.0, *)
public enum VideoToolboxDecoderError: Error, Equatable {
    case missingCodecConfiguration
    case invalidCodecConfiguration
    /// A presentation time past `Int64.max`, which no `CMTime` can carry.
    case invalidPresentationTime
    case formatDescriptionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case frameSubmissionFailed(OSStatus)
}

@available(macOS 13.0, *)
public enum DecoderSpecification {
    /// The `decoderSpecification` passed to `VTDecompressionSessionCreate`.
    /// Pure so the enable-not-require choice is testable without a real
    /// session: asserts the enable key is present and true, and that the
    /// require key -- which would make hardware decode mandatory -- is absent.
    public static func make() -> [CFString: Bool] {
        [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
    }
}

/// Not main-actor isolated on purpose: VideoToolbox invokes the decompression
/// output callback on its own thread, and a main-actor class traps the moment a
/// frame arrives. Mutable state is guarded by `lock` instead.
@available(macOS 13.0, *)
public final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private final class OutputBox: @unchecked Sendable {
        let handler: @Sendable (DecodedFrame) -> Void
        var receipts: FrameReceiptLedger?

        init(handler: @escaping @Sendable (DecodedFrame) -> Void) {
            self.handler = handler
        }
    }

    private let outputBox: OutputBox
    private let receipts: FrameReceiptLedger?
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var formatConfiguration: Data?
    private var hardwareAccelerationStatus: DecoderHardwareAccelerationStatus?

    /// Which decoder VideoToolbox selected, or `nil` before a decompression
    /// session exists. Kept rather than only logged, so the session HUD can
    /// show it.
    public var hardwareAcceleration: DecoderHardwareAccelerationStatus? {
        lock.lock()
        defer { lock.unlock() }
        return hardwareAccelerationStatus
    }

    public init(
        receipts: FrameReceiptLedger? = nil,
        outputHandler: @escaping @Sendable (DecodedFrame) -> Void
    ) {
        self.receipts = receipts
        outputBox = OutputBox(handler: outputHandler)
        outputBox.receipts = receipts
    }

    public func decode(_ packet: EncodedVideoFramePacket) throws {
        lock.lock()
        defer { lock.unlock() }
        // Checked before anything else this frame could change, and checked
        // here as well as at the codec: a packet reaches a decoder by more
        // than one path, and converting this field without checking it ends
        // the viewer rather than the frame.
        guard let presentationTimeNanoseconds = Int64(exactly: packet.presentationTimeNanoseconds) else {
            throw VideoToolboxDecoderError.invalidPresentationTime
        }
        if let configuration = packet.codecConfiguration, configuration != formatConfiguration {
            try configureDecoder(with: configuration)
        }
        guard let session, let formatDescription else {
            throw VideoToolboxDecoderError.missingCodecConfiguration
        }
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoToolboxDecoderError.blockBufferCreationFailed(blockStatus)
        }
        let copyStatus = packet.payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw VideoToolboxDecoderError.blockBufferCreationFailed(copyStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationTimeNanoseconds, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoToolboxDecoderError.sampleBufferCreationFailed(sampleStatus)
        }
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard decodeStatus == noErr else {
            throw VideoToolboxDecoderError.frameSubmissionFailed(decodeStatus)
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        formatConfiguration = nil
        // The next session makes its own choice; carrying this one's answer
        // over would report a decoder that is not running.
        hardwareAccelerationStatus = nil
        receipts?.reset()
    }

    private func configureDecoder(with encodedConfiguration: Data) throws {
        let configuration: H264CodecConfiguration
        do {
            configuration = try H264CodecConfigurationCodec.decode(encodedConfiguration)
        } catch {
            throw VideoToolboxDecoderError.invalidCodecConfiguration
        }
        let formatDescription = try makeFormatDescription(configuration)
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, presentationTime, _ in
                guard status == noErr, let refcon, let imageBuffer else { return }
                let box = Unmanaged<OutputBox>.fromOpaque(refcon).takeUnretainedValue()
                let scaled = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
                var timing: FrameTiming?
                if scaled.isValid,
                   let receivedAt = box.receipts?.takeReceipt(
                       forPresentationTimeNanoseconds: scaled.value
                   ) {
                    timing = FrameTiming(
                        hostCapturedAtNanoseconds: scaled.value,
                        receivedAtNanoseconds: receivedAt,
                        decodedAtNanoseconds: MonotonicClock.nowNanoseconds()
                    )
                }
                box.handler(DecodedFrame(pixelBuffer: imageBuffer, timing: timing))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(outputBox).toOpaque()
        )
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: DecoderSpecification.make() as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw VideoToolboxDecoderError.sessionCreationFailed(status)
        }
        session = newSession
        self.formatDescription = formatDescription
        formatConfiguration = encodedConfiguration
        logHardwareDecodeStatus(for: newSession)
    }

    /// Reads back whether VideoToolbox actually selected a hardware
    /// decoder -- the enable key only requests it, it never guarantees it --
    /// and logs the outcome once per session so a software fallback is
    /// visible instead of silently burning CPU on the viewer.
    private func logHardwareDecodeStatus(for session: VTDecompressionSession) {
        // `VTSessionCopyProperty` disables implicit CF/ObjC bridging for this
        // out-parameter (see `CF_IMPLICIT_BRIDGING_DISABLED` in VTSession.h),
        // so the retrieved value must be released explicitly via `Unmanaged`
        // rather than treated as an ARC-managed `CFTypeRef?`.
        var value: Unmanaged<CFTypeRef>?
        let copyStatus = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )
        let readBack: Bool? = copyStatus == noErr ? (value?.takeRetainedValue() as? Bool) : nil
        let status = DecoderHardwareAccelerationStatus(reportedHardwareAccelerated: readBack)
        hardwareAccelerationStatus = status
        print(status.logLine)
    }

    private func makeFormatDescription(_ configuration: H264CodecConfiguration) throws -> CMFormatDescription {
        var description: CMFormatDescription?
        let status = configuration.sequenceParameterSet.withUnsafeBytes { spsBytes in
            configuration.pictureParameterSet.withUnsafeBytes { ppsBytes in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                var sizes = [configuration.sequenceParameterSet.count, configuration.pictureParameterSet.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw VideoToolboxDecoderError.formatDescriptionCreationFailed(status)
        }
        return description
    }
}

@available(macOS 13.0, *)
extension VideoToolboxDecoder {
    /// The decoder a viewer running on macOS builds for every window.
    public static let factory: VideoDecoderFactory = { receipts, outputHandler in
        VideoToolboxDecoder(receipts: receipts, outputHandler: outputHandler)
    }
}
#endif
