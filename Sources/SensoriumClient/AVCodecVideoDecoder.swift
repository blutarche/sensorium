#if canImport(CAVCodec)
import CAVCodec
import Foundation
import SensoriumCore

public enum AVCodecVideoDecoderError: Error, Equatable {
    /// A packet arrived before any parameter set did, so there is no decoder
    /// open to feed it to.
    case decoderNotOpened
    /// The parameter sets the host sent are not a pair this decoder can be
    /// configured from.
    case invalidCodecConfiguration
    /// A presentation time past `Int64.max`, which no packet timestamp can
    /// carry.
    case invalidPresentationTime
    /// libavcodec refused to open a decoder. Carries its own error code.
    case decoderOpenFailed(Int32)
    case packetSubmissionFailed(Int32)
    case frameReceiveFailed(Int32)
    /// A decoder was asked for hardware decode and neither the hardware nor
    /// the software path could be opened.
    case hardwareUnavailable
}

/// One decoded frame, owning its own reference to the picture and, for a
/// hardware surface, to the device that holds it.
///
/// A frame outlives the decode call that produced it: the presenter may still
/// be drawing it when the next packet arrives, and it may still be holding it
/// when the decoder is reset. Everything the presenter needs to draw a
/// hardware surface -- the surface identifier and the VA display it belongs
/// to -- is reachable from here, so the presenter never has to reach back
/// into the decoder, and the device stays alive for exactly as long as any
/// frame from it does.
public final class AVFrameBox {
    private static let countLock = NSLock()
    nonisolated(unsafe) private static var live = 0

    /// How many frames are currently wrapped. A decoder that keeps its
    /// references is a leak of whole pictures, so the count is observable.
    public static var liveCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return live
    }

    private var owned: UnsafeMutablePointer<AVFrame>?
    private var deviceReference: UnsafeMutablePointer<AVBufferRef>?

    /// The picture itself, for a presenter that reads its planes or its
    /// hardware surface directly.
    public var frame: UnsafeMutablePointer<AVFrame>? { owned }
    public let width: Int
    public let height: Int
    public let pixelFormat: AVPixelFormat
    /// The VA display the surface below belongs to, absent for a frame
    /// decoded in software.
    public let vaDisplay: VADisplay?

    /// The VA-API surface this frame lives in, for a presenter exporting it
    /// for display. Absent for a frame decoded in software, and absent unless
    /// `vaDisplay` is there too: a surface identifier means nothing without
    /// the display it belongs to, so the two never travel apart.
    public var vaSurfaceID: VASurfaceID? {
        guard pixelFormat == AV_PIX_FMT_VAAPI, vaDisplay != nil,
              let owned, let surface = owned.pointee.data.3 else {
            return nil
        }
        return VASurfaceID(UInt(bitPattern: surface))
    }

    init?(
        referencing source: UnsafeMutablePointer<AVFrame>,
        deviceReference sourceDevice: UnsafeMutablePointer<AVBufferRef>?,
        vaDisplay: VADisplay?
    ) {
        guard let copy = av_frame_alloc() else { return nil }
        guard av_frame_ref(copy, source) == 0 else {
            var toFree: UnsafeMutablePointer<AVFrame>? = copy
            av_frame_free(&toFree)
            return nil
        }
        owned = copy
        width = Int(copy.pointee.width)
        height = Int(copy.pointee.height)
        pixelFormat = AVPixelFormat(rawValue: copy.pointee.format)
        if let sourceDevice {
            deviceReference = av_buffer_ref(sourceDevice)
            self.vaDisplay = deviceReference == nil ? nil : vaDisplay
        } else {
            deviceReference = nil
            self.vaDisplay = nil
        }
        Self.countLock.lock()
        Self.live += 1
        Self.countLock.unlock()
    }

    deinit {
        av_frame_free(&owned)
        av_buffer_unref(&deviceReference)
        Self.countLock.lock()
        Self.live -= 1
        Self.countLock.unlock()
    }
}

/// The viewer's H.264 decoder where libavcodec is the platform decoder.
///
/// Hardware decode is enabled, never required: a VA-API device is opened when
/// one is there, and a machine without a usable one decodes in software
/// rather than refusing the picture.
///
/// Not isolated to an actor: frames are produced on whichever thread called
/// `decode`, and `reset` arrives from the session's own thread. Mutable state
/// is guarded by `lock`.
public final class AVCodecVideoDecoder: VideoDecoding, @unchecked Sendable {
    /// The render node a Linux viewer decodes through unless told otherwise.
    public static let defaultRenderNodePath = "/dev/dri/renderD128"

    private let lock = NSRecursiveLock()
    private let receipts: FrameReceiptLedger?
    private let outputHandler: @Sendable (DecodedFrame) -> Void
    private let renderNodePath: String?

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var deviceReference: UnsafeMutablePointer<AVBufferRef>?
    private var vaDisplay: VADisplay?
    private var codecConfiguration: Data?
    private var status: DecoderHardwareAccelerationStatus?
    /// Set once a frame has come back. Until then a decode failure on the
    /// hardware path is still recoverable by reopening in software; after it,
    /// the stream was decoding and the failure is the session's.
    private var hasDecodedAFrame = false

    /// Which decoder implementation is running, or `nil` before one is open.
    /// Shown on the session HUD.
    public var hardwareAcceleration: DecoderHardwareAccelerationStatus? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// `renderNodePath` is the DRM render node hardware decode is attempted
    /// through; `nil` asks for software decode outright.
    public init(
        receipts: FrameReceiptLedger? = nil,
        renderNodePath: String? = defaultRenderNodePath,
        outputHandler: @escaping @Sendable (DecodedFrame) -> Void
    ) {
        self.receipts = receipts
        self.renderNodePath = renderNodePath
        self.outputHandler = outputHandler
    }

    deinit {
        closeDecoder()
    }

    /// Decodes under the lock, then hands the frames over without it. The
    /// handler reaches the presenter and the coalescer, which is work this
    /// decoder must not be holding a lock through. A `reset` arriving in
    /// between still lets this batch through: the frames were already decoded
    /// when it arrived, and the presenter drops what it cannot use.
    public func decode(_ packet: EncodedVideoFramePacket) throws {
        var frames: [DecodedFrame] = []
        defer {
            for frame in frames {
                outputHandler(frame)
            }
        }
        try decodeUnderLock(packet, into: &frames)
    }

    private func decodeUnderLock(
        _ packet: EncodedVideoFramePacket,
        into frames: inout [DecodedFrame]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        // Checked here as well as where the packet was parsed: a packet
        // reaches a decoder by more than one path, and converting this field
        // without checking it ends the viewer rather than the frame.
        guard let presentationTime = Int64(exactly: packet.presentationTimeNanoseconds) else {
            throw AVCodecVideoDecoderError.invalidPresentationTime
        }
        if let configuration = packet.codecConfiguration, configuration != codecConfiguration {
            try openDecoder(with: configuration, into: &frames)
        }
        guard context != nil else {
            throw AVCodecVideoDecoderError.decoderNotOpened
        }
        do {
            try submit(payload: packet.payload, presentationTime: presentationTime, into: &frames)
        } catch {
            // The hardware path can only be ruled out by trying it: a device
            // that opens can still refuse the first picture it is given, and
            // a viewer that gave up there would show nothing at all.
            guard deviceReference != nil, !hasDecodedAFrame, let configuration = codecConfiguration else {
                throw error
            }
            try reopenInSoftware(with: configuration)
            try submit(payload: packet.payload, presentationTime: presentationTime, into: &frames)
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            avcodec_flush_buffers(context)
        }
        closeDecoder()
        codecConfiguration = nil
        // The next decoder makes its own choice; carrying this one's answer
        // over would report an implementation that is not running.
        status = nil
        hasDecodedAFrame = false
        receipts?.reset()
    }

    private func submit(
        payload: Data,
        presentationTime: Int64,
        into frames: inout [DecodedFrame]
    ) throws {
        guard let context else {
            throw AVCodecVideoDecoderError.decoderNotOpened
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else {
            throw AVCodecVideoDecoderError.packetSubmissionFailed(0)
        }
        let allocation = av_new_packet(packet, Int32(payload.count))
        guard allocation == 0 else {
            throw AVCodecVideoDecoderError.packetSubmissionFailed(allocation)
        }
        payload.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                packet.pointee.data.update(
                    from: source.assumingMemoryBound(to: UInt8.self),
                    count: payload.count
                )
            }
        }
        packet.pointee.pts = presentationTime
        packet.pointee.dts = presentationTime
        let sent = avcodec_send_packet(context, packet)
        guard sent == 0 else {
            throw AVCodecVideoDecoderError.packetSubmissionFailed(sent)
        }
        try drainFrames(into: &frames)
    }

    /// Takes every frame the decoder has ready. `EAGAIN` and end of stream
    /// are how it says there are none left, not failures.
    private func drainFrames(into frames: inout [DecodedFrame]) throws {
        guard let context else { return }
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frame else {
            throw AVCodecVideoDecoderError.frameReceiveFailed(0)
        }
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == sensorium_averror_again() || received == sensorium_averror_eof() {
                return
            }
            guard received == 0 else {
                throw AVCodecVideoDecoderError.frameReceiveFailed(received)
            }
            if let decoded = wrap(frame) {
                frames.append(decoded)
            }
            av_frame_unref(frame)
        }
    }

    private func wrap(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        guard let box = AVFrameBox(
            referencing: frame,
            deviceReference: deviceReference,
            vaDisplay: vaDisplay
        ) else {
            return nil
        }
        if !hasDecodedAFrame {
            hasDecodedAFrame = true
            let resolved = DecoderHardwareAccelerationStatus(
                reportedHardwareAccelerated: box.pixelFormat == AV_PIX_FMT_VAAPI
            )
            status = resolved
            print(resolved.logLine)
        }
        let presentationTime = frame.pointee.pts == Int64.min
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        var timing: FrameTiming?
        if presentationTime != Int64.min,
           let receivedAt = receipts?.takeReceipt(forPresentationTimeNanoseconds: presentationTime) {
            timing = FrameTiming(
                hostCapturedAtNanoseconds: presentationTime,
                receivedAtNanoseconds: receivedAt,
                decodedAtNanoseconds: MonotonicClock.nowNanoseconds()
            )
        }
        return DecodedFrame(
            payload: box,
            width: box.width,
            height: box.height,
            timing: timing
        )
    }

    /// Opens a decoder for these parameter sets, trying the render node first
    /// where one was asked for. A stream whose parameter sets change mid-way
    /// arrives here again: the frames the old decoder still holds are taken
    /// out of it before it is closed, so none of them are lost.
    private func openDecoder(with configuration: Data, into frames: inout [DecodedFrame]) throws {
        let parameterSets: H264CodecConfiguration
        do {
            parameterSets = try H264CodecConfigurationCodec.decode(configuration)
        } catch {
            throw AVCodecVideoDecoderError.invalidCodecConfiguration
        }
        let extradata = try Self.avcConfigurationRecord(from: parameterSets)
        if context != nil {
            drainToEndOfStream(into: &frames)
            closeDecoder()
        }
        status = nil
        hasDecodedAFrame = false
        if let renderNodePath {
            do {
                try openContext(extradata: extradata, renderNodePath: renderNodePath)
                codecConfiguration = configuration
                return
            } catch {
                // Hardware decode is enabled, never required. The software
                // attempt below is what this machine gets instead.
            }
        }
        try openContext(extradata: extradata, renderNodePath: nil)
        codecConfiguration = configuration
    }

    private func reopenInSoftware(with configuration: Data) throws {
        let parameterSets: H264CodecConfiguration
        do {
            parameterSets = try H264CodecConfigurationCodec.decode(configuration)
        } catch {
            throw AVCodecVideoDecoderError.invalidCodecConfiguration
        }
        let extradata = try Self.avcConfigurationRecord(from: parameterSets)
        closeDecoder()
        try openContext(extradata: extradata, renderNodePath: nil)
        codecConfiguration = configuration
    }

    private func openContext(extradata: Data, renderNodePath: String?) throws {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264) else {
            throw AVCodecVideoDecoderError.decoderOpenFailed(0)
        }
        guard let newContext = avcodec_alloc_context3(codec) else {
            throw AVCodecVideoDecoderError.decoderOpenFailed(0)
        }
        context = newContext
        do {
            // Presentation times travel in nanoseconds, so a frame comes back
            // keyed by the same number the packet carried in.
            newContext.pointee.pkt_timebase = AVRational(num: 1, den: 1_000_000_000)
            try attachExtradata(extradata, to: newContext)
            if let renderNodePath {
                try attachHardwareDevice(at: renderNodePath, to: newContext)
            }
            let opened = avcodec_open2(newContext, codec, nil)
            guard opened == 0 else {
                throw AVCodecVideoDecoderError.decoderOpenFailed(opened)
            }
        } catch {
            // A context that never opened is not one a later packet may be
            // fed to, so it is given up here rather than left behind.
            closeDecoder()
            throw error
        }
    }

    private func attachExtradata(
        _ extradata: Data,
        to context: UnsafeMutablePointer<AVCodecContext>
    ) throws {
        // The spare bytes past the declared size are libavcodec's own
        // requirement: its bitstream readers are allowed to read past the end
        // of what they were given, and must stay inside the allocation when
        // they do.
        let padding = Int(sensorium_av_input_buffer_padding_size())
        guard let allocation = av_mallocz(extradata.count + padding) else {
            throw AVCodecVideoDecoderError.decoderOpenFailed(0)
        }
        extradata.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                allocation.copyMemory(from: source, byteCount: extradata.count)
            }
        }
        context.pointee.extradata = allocation.assumingMemoryBound(to: UInt8.self)
        context.pointee.extradata_size = Int32(extradata.count)
    }

    private func attachHardwareDevice(
        at renderNodePath: String,
        to context: UnsafeMutablePointer<AVCodecContext>
    ) throws {
        var device: UnsafeMutablePointer<AVBufferRef>?
        let created = renderNodePath.withCString { path in
            av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VAAPI, path, nil, 0)
        }
        guard created == 0, let device else {
            throw AVCodecVideoDecoderError.hardwareUnavailable
        }
        deviceReference = device
        vaDisplay = Self.display(of: device)
        context.pointee.hw_device_ctx = av_buffer_ref(device)
        context.pointee.get_format = { _, formats in
            guard let formats else { return AV_PIX_FMT_NONE }
            var candidate = formats
            while candidate.pointee != AV_PIX_FMT_NONE {
                if candidate.pointee == AV_PIX_FMT_VAAPI {
                    return AV_PIX_FMT_VAAPI
                }
                candidate += 1
            }
            return formats.pointee
        }
    }

    private static func display(of device: UnsafeMutablePointer<AVBufferRef>) -> VADisplay? {
        guard let data = device.pointee.data else { return nil }
        let deviceContext = UnsafeMutableRawPointer(data)
            .assumingMemoryBound(to: AVHWDeviceContext.self)
        guard let hardwareContext = deviceContext.pointee.hwctx else { return nil }
        return hardwareContext
            .assumingMemoryBound(to: AVVAAPIDeviceContext.self)
            .pointee.display
    }

    /// Asks the decoder for whatever it is still holding, and hands those
    /// frames on. Used only before the decoder is closed, so a failure here
    /// has nothing left to report to.
    private func drainToEndOfStream(into frames: inout [DecodedFrame]) {
        guard let context else { return }
        guard avcodec_send_packet(context, nil) == 0 else { return }
        try? drainFrames(into: &frames)
    }

    private func closeDecoder() {
        if context != nil {
            avcodec_free_context(&context)
        }
        if deviceReference != nil {
            av_buffer_unref(&deviceReference)
        }
        vaDisplay = nil
    }

    /// Builds the AVC decoder configuration record libavcodec reads parameter
    /// sets from. Its leading `1` is also what tells the decoder the access
    /// units that follow are length prefixed rather than start-code
    /// delimited, which is the framing the host sends.
    static func avcConfigurationRecord(from configuration: H264CodecConfiguration) throws -> Data {
        let sps = configuration.sequenceParameterSet
        let pps = configuration.pictureParameterSet
        guard sps.count >= 4, !pps.isEmpty,
              sps.count <= Int(UInt16.max), pps.count <= Int(UInt16.max) else {
            throw AVCodecVideoDecoderError.invalidCodecConfiguration
        }
        var record = Data([1, sps[sps.startIndex + 1], sps[sps.startIndex + 2], sps[sps.startIndex + 3]])
        // Four-byte NAL unit lengths, then one sequence parameter set.
        record.append(0xFF)
        record.append(0xE1)
        record.append(UInt8(sps.count >> 8))
        record.append(UInt8(sps.count & 0xFF))
        record.append(sps)
        record.append(1)
        record.append(UInt8(pps.count >> 8))
        record.append(UInt8(pps.count & 0xFF))
        record.append(pps)
        return record
    }
}

extension AVCodecVideoDecoder {
    /// The decoder a viewer running where libavcodec is the platform decoder
    /// builds for every window.
    public static let factory: VideoDecoderFactory = { receipts, outputHandler in
        AVCodecVideoDecoder(receipts: receipts, outputHandler: outputHandler)
    }
}
#endif
