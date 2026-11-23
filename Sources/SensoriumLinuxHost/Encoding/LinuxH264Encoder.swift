#if os(Linux)
import CAVCodec
import Foundation
import SensoriumCore
import SensoriumHost

/// The Linux host's H.264 encoder, producing the packets the macOS host's
/// `VideoToolboxEncoder` does, so a viewer decodes either unchanged:
///
/// - the payload is length-prefixed NAL units with no parameter sets in it;
/// - a key frame (an IDR picture) carries the SPS and PPS in
///   `codecConfiguration`, encoded by `H264CodecConfigurationCodec`;
/// - there are no B-frames, so presentation order is output order;
/// - presentation times pass through in nanoseconds.
///
/// libavcodec's `h264_vaapi` runs when a VA-API device can encode H.264, and
/// `libopenh264` runs otherwise. Both are set up for latency: one frame in,
/// one packet out, in the same `encode` call.
///
/// The outcome handler is called exactly once for every frame `encode`
/// accepts, after the encoder's own lock is released, so the handler may call
/// `encode` again.
public final class LinuxH264Encoder: LinuxVideoFrameEncoding, @unchecked Sendable {
    public let configuration: LinuxEncoderConfiguration
    /// The encoder that actually opened.
    public private(set) var backend: LinuxEncoderBackend = .openH264

    private let outcomeHandler: @Sendable (LinuxVideoEncodeOutcome) -> Void
    private let sequencer: VideoPacketSequencer
    private let lock = NSLock()

    private var context: UnsafeMutablePointer<AVCodecContext>?
    /// The picture in the layout the encoder is fed: planar for OpenH264,
    /// NV12 for VA-API.
    private var softwareFrame: UnsafeMutablePointer<AVFrame>?
    private var surfaceFrame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var deviceReference: UnsafeMutablePointer<AVBufferRef>?
    private var framesReference: UnsafeMutablePointer<AVBufferRef>?

    private var keyFrameRequested = false
    /// The encoder is given the index of each frame as its timestamp, in
    /// units of one frame, so its rate control sees `framesPerSecond` however
    /// irregular capture is. The real time is kept here until the packet
    /// comes back.
    private var nextFrameIndex: Int64 = 0
    private var presentationTimes: [Int64: UInt64] = [:]
    private var unreportedFrames = 0
    private var lastKeyFrameTime: UInt64?
    private var lastSequenceParameterSet: Data?
    private var lastPictureParameterSet: Data?
    private var isShutDown = false
    private var timings = LinuxEncodeTimings()

    /// How long the stages of the most recent frame took.
    public var lastTimings: LinuxEncodeTimings {
        lock.lock()
        defer { lock.unlock() }
        return timings
    }

    /// `sequencer` is shared by every encoder a session builds in turn, so a
    /// rebuild at a new size does not send the viewer's sequence numbers
    /// backwards.
    public init(
        configuration: LinuxEncoderConfiguration,
        sequencer: VideoPacketSequencer = VideoPacketSequencer(),
        outcomeHandler: @escaping @Sendable (LinuxVideoEncodeOutcome) -> Void
    ) throws {
        guard configuration.isEncodable else {
            throw LinuxVideoEncoderError.invalidConfiguration
        }
        self.configuration = configuration
        self.sequencer = sequencer
        self.outcomeHandler = outcomeHandler

        var opened = false
        var failure: LinuxVideoEncoderError = .noEncoderAvailable
        let candidates: [LinuxEncoderBackend]
        switch configuration.backendPreference {
        case .automatic: candidates = [.vaapi, .openH264]
        case .vaapi: candidates = [.vaapi]
        case .openH264: candidates = [.openH264]
        }
        for candidate in candidates {
            backend = candidate
            do {
                try openEncoder(candidate)
                opened = true
                break
            } catch let error as LinuxVideoEncoderError {
                failure = error
                releaseResources()
            }
        }
        guard opened else {
            throw failure
        }
    }

    deinit {
        releaseResources()
    }

    public func requestKeyFrame() {
        lock.lock()
        keyFrameRequested = true
        lock.unlock()
    }

    public func encode(_ frame: LinuxVideoFrame) throws {
        let outcomes = try submit(frame)
        for outcome in outcomes {
            outcomeHandler(outcome)
        }
    }

    /// The entry point for frames that arrive as DMA-BUF file descriptors,
    /// for the zero-copy path that imports them as GPU surfaces instead of
    /// copying them through the CPU. Not built yet.
    public func encode(dmaBuf frame: LinuxDMABufFrame) throws {
        throw LinuxVideoEncoderError.dmaBufInputNotSupported
    }

    /// Emits every frame still held and frees the encoder. Every later call
    /// to `encode` throws.
    public func shutDown() {
        lock.lock()
        var outcomes: [LinuxVideoEncodeOutcome] = []
        // FFmpeg's VA-API encoder crashes when drained before its first frame.
        if !isShutDown, nextFrameIndex > 0, let context {
            isShutDown = true
            if avcodec_send_frame(context, nil) >= 0 {
                outcomes = receivePackets(lastPresentationTime: lastKeyFrameTime ?? 0)
            }
        }
        isShutDown = true
        releaseResources()
        lock.unlock()
        for outcome in outcomes {
            outcomeHandler(outcome)
        }
    }

    // MARK: Submission

    private func submit(_ frame: LinuxVideoFrame) throws -> [LinuxVideoEncodeOutcome] {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown, context != nil, let softwareFrame else {
            throw LinuxVideoEncoderError.shutDown
        }
        guard frame.isConsistent, frame.width == configuration.width, frame.height == configuration.height else {
            throw LinuxVideoEncoderError.invalidFrame
        }
        // One request is taken by exactly one frame, and put back below if
        // that frame never reaches the encoder.
        let intervalElapsed = lastKeyFrameTime.map {
            frame.presentationTimeNanoseconds >= $0
                && Double(frame.presentationTimeNanoseconds - $0) / 1e9 >= configuration.keyFrameIntervalSeconds
        } ?? false
        let forcesKeyFrame = keyFrameRequested || intervalElapsed
        keyFrameRequested = false

        var stageStart = Self.nowNanoseconds()
        var stages = LinuxEncodeTimings()
        guard av_frame_make_writable(softwareFrame) >= 0 else {
            keyFrameRequested = keyFrameRequested || forcesKeyFrame
            throw LinuxVideoEncoderError.frameSubmissionFailed(sensorium_averror_invalid_data())
        }
        convert(frame, into: softwareFrame)
        var now = Self.nowNanoseconds()
        stages.conversion = now - stageStart
        stageStart = now

        var toSend = softwareFrame
        if backend == .vaapi {
            guard let surfaceFrame, let framesReference else {
                throw LinuxVideoEncoderError.shutDown
            }
            let acquired = av_hwframe_get_buffer(framesReference, surfaceFrame, 0)
            guard acquired >= 0 else {
                keyFrameRequested = keyFrameRequested || forcesKeyFrame
                throw LinuxVideoEncoderError.frameSubmissionFailed(acquired)
            }
            let uploaded = av_hwframe_transfer_data(surfaceFrame, softwareFrame, 0)
            guard uploaded >= 0 else {
                av_frame_unref(surfaceFrame)
                keyFrameRequested = keyFrameRequested || forcesKeyFrame
                throw LinuxVideoEncoderError.frameSubmissionFailed(uploaded)
            }
            toSend = surfaceFrame
            now = Self.nowNanoseconds()
            stages.upload = now - stageStart
            stageStart = now
        }

        let index = nextFrameIndex
        toSend.pointee.pts = index
        // The frame is reused, so the picture type is set on every frame:
        // left at "intra" it would make every later frame a key frame.
        toSend.pointee.pict_type = forcesKeyFrame ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE
        let sent = avcodec_send_frame(self.context, toSend)
        toSend.pointee.pict_type = AV_PICTURE_TYPE_NONE
        if backend == .vaapi, let surfaceFrame {
            av_frame_unref(surfaceFrame)
        }
        guard sent >= 0 else {
            keyFrameRequested = keyFrameRequested || forcesKeyFrame
            throw LinuxVideoEncoderError.frameSubmissionFailed(sent)
        }
        nextFrameIndex += 1
        presentationTimes[index] = frame.presentationTimeNanoseconds
        unreportedFrames += 1
        if forcesKeyFrame {
            lastKeyFrameTime = frame.presentationTimeNanoseconds
        }

        var outcomes = receivePackets(lastPresentationTime: frame.presentationTimeNanoseconds)
        // OpenH264 answers a frame it chose to skip with nothing at all, in
        // the same call. VA-API, with no frame delay, never does.
        if backend == .openH264, unreportedFrames > 0 {
            outcomes.append(contentsOf: Array(repeating: .dropped, count: unreportedFrames))
            unreportedFrames = 0
            presentationTimes.removeAll()
        }
        stages.encode = Self.nowNanoseconds() - stageStart
        timings = stages
        return outcomes
    }

    private func convert(_ frame: LinuxVideoFrame, into target: UnsafeMutablePointer<AVFrame>) {
        guard let luma = target.pointee.data.0, let chroma = target.pointee.data.1 else { return }
        let layout: YUV420Layout = backend == .vaapi ? .nv12 : .i420
        frame.pixels.withUnsafeBytes { source in
            YUV420Converter.convert(
                source: source.baseAddress!,
                sourceBytesPerRow: frame.bytesPerRow,
                width: frame.width,
                height: frame.height,
                layout: layout,
                luma: luma,
                lumaBytesPerRow: Int(target.pointee.linesize.0),
                chroma: chroma,
                chromaBytesPerRow: Int(target.pointee.linesize.1),
                redChroma: target.pointee.data.2,
                redChromaBytesPerRow: Int(target.pointee.linesize.2)
            )
        }
    }

    // MARK: Output

    /// Takes every packet the encoder has ready. Call with `lock` held.
    private func receivePackets(lastPresentationTime: UInt64) -> [LinuxVideoEncodeOutcome] {
        guard let context, let packet else { return [] }
        var outcomes: [LinuxVideoEncodeOutcome] = []
        while true {
            let received = avcodec_receive_packet(context, packet)
            if received == sensorium_averror_again() || received == sensorium_averror_eof() {
                break
            }
            guard received >= 0 else {
                outcomes.append(.failed(received))
                unreportedFrames = max(unreportedFrames - 1, 0)
                break
            }
            unreportedFrames = max(unreportedFrames - 1, 0)
            let time = presentationTimes.removeValue(forKey: packet.pointee.pts) ?? lastPresentationTime
            let annexB = Data(bytes: packet.pointee.data, count: Int(packet.pointee.size))
            av_packet_unref(packet)
            outcomes.append(outcome(forAnnexB: annexB, presentationTime: time))
        }
        return outcomes
    }

    private func outcome(forAnnexB annexB: Data, presentationTime: UInt64) -> LinuxVideoEncodeOutcome {
        let unit = H264AnnexB.reframe(annexB)
        guard !unit.payload.isEmpty else {
            return .failed(sensorium_averror_invalid_data())
        }
        if let sps = unit.sequenceParameterSet { lastSequenceParameterSet = sps }
        if let pps = unit.pictureParameterSet { lastPictureParameterSet = pps }
        var codecConfiguration: Data?
        if unit.containsIDR {
            // A key frame without parameter sets in it takes the last ones
            // the encoder sent. With none ever seen the viewer could not
            // decode it, so it is not sent.
            guard let sps = lastSequenceParameterSet, let pps = lastPictureParameterSet,
                  let encoded = try? H264CodecConfigurationCodec.encode(
                      H264CodecConfiguration(sequenceParameterSet: sps, pictureParameterSet: pps)
                  ) else {
                return .failed(sensorium_averror_invalid_data())
            }
            codecConfiguration = encoded
            lastKeyFrameTime = presentationTime
        }
        return .encoded(sequencer.packet(
            presentationTimeNanoseconds: presentationTime,
            isKeyFrame: unit.containsIDR,
            codecConfiguration: codecConfiguration,
            payload: unit.payload
        ))
    }

    // MARK: Setup

    private func openEncoder(_ candidate: LinuxEncoderBackend) throws {
        let name = candidate == .vaapi ? "h264_vaapi" : "libopenh264"
        guard let codec = avcodec_find_encoder_by_name(name) else {
            throw LinuxVideoEncoderError.noEncoderAvailable
        }
        guard let newContext = avcodec_alloc_context3(codec) else {
            throw LinuxVideoEncoderError.sessionCreationFailed(0)
        }
        context = newContext
        configureCommon(newContext, backend: candidate)
        switch candidate {
        case .vaapi:
            try configureVAAPI(newContext)
        case .openH264:
            try configureOpenH264(newContext)
        }
        let opened = avcodec_open2(newContext, codec, nil)
        guard opened >= 0 else {
            throw LinuxVideoEncoderError.sessionCreationFailed(opened)
        }
        guard let frame = av_frame_alloc(), let packet = av_packet_alloc() else {
            throw LinuxVideoEncoderError.sessionCreationFailed(0)
        }
        softwareFrame = frame
        self.packet = packet
        frame.pointee.width = Int32(configuration.width)
        frame.pointee.height = Int32(configuration.height)
        frame.pointee.format = (candidate == .vaapi ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P).rawValue
        frame.pointee.color_range = AVCOL_RANGE_MPEG
        frame.pointee.colorspace = AVCOL_SPC_BT709
        frame.pointee.color_primaries = AVCOL_PRI_BT709
        frame.pointee.color_trc = AVCOL_TRC_BT709
        let allocated = av_frame_get_buffer(frame, 0)
        guard allocated >= 0 else {
            throw LinuxVideoEncoderError.sessionCreationFailed(allocated)
        }
        if candidate == .vaapi {
            guard let surface = av_frame_alloc() else {
                throw LinuxVideoEncoderError.sessionCreationFailed(0)
            }
            surfaceFrame = surface
            surface.pointee.color_range = AVCOL_RANGE_MPEG
            surface.pointee.colorspace = AVCOL_SPC_BT709
            surface.pointee.color_primaries = AVCOL_PRI_BT709
            surface.pointee.color_trc = AVCOL_TRC_BT709
        }
    }

    /// Everything both encoders are told: size, frame rate, no B-frames,
    /// bit-rate envelope, and the colour the picture is coded in.
    private func configureCommon(_ context: UnsafeMutablePointer<AVCodecContext>, backend: LinuxEncoderBackend) {
        let fps = Int32(configuration.framesPerSecond)
        context.pointee.width = Int32(configuration.width)
        context.pointee.height = Int32(configuration.height)
        context.pointee.time_base = AVRational(num: 1, den: fps)
        context.pointee.framerate = AVRational(num: fps, den: 1)
        context.pointee.gop_size = Int32(configuration.maxKeyFrameIntervalFrames)
        context.pointee.max_b_frames = 0
        context.pointee.bit_rate = Int64(configuration.averageBitRate)
        context.pointee.rc_max_rate = Int64(configuration.peakBitRate)
        // One second of the average rate: room for the one large key frame a
        // scene change costs, no more.
        context.pointee.rc_buffer_size = Int32(clamping: configuration.averageBitRate)
        context.pointee.flags |= Int32(AV_CODEC_FLAG_LOW_DELAY)
        context.pointee.color_range = AVCOL_RANGE_MPEG
        context.pointee.colorspace = AVCOL_SPC_BT709
        context.pointee.color_primaries = AVCOL_PRI_BT709
        context.pointee.color_trc = AVCOL_TRC_BT709
    }

    private func configureOpenH264(_ context: UnsafeMutablePointer<AVCodecContext>) throws {
        context.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        try setOption(context, "profile", configuration.profile.libavName)
        try setOption(context, "rc_mode", "bitrate")
        // A skipped frame would leave the viewer waiting on a picture that
        // never comes.
        try setOption(context, "allow_skip_frames", "0")
        try setOption(context, "coder", configuration.profile == .constrainedBaseline ? "cavlc" : "cabac", required: false)
    }

    private func configureVAAPI(_ context: UnsafeMutablePointer<AVCodecContext>) throws {
        var device: UnsafeMutablePointer<AVBufferRef>?
        let created = configuration.renderNodePath.withCString { path in
            av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VAAPI, path, nil, 0)
        }
        guard created >= 0, let device else {
            throw LinuxVideoEncoderError.sessionCreationFailed(created)
        }
        deviceReference = device
        guard let frames = av_hwframe_ctx_alloc(device) else {
            throw LinuxVideoEncoderError.sessionCreationFailed(0)
        }
        framesReference = frames
        let framesContext = UnsafeMutableRawPointer(frames.pointee.data)
            .assumingMemoryBound(to: AVHWFramesContext.self)
        framesContext.pointee.format = AV_PIX_FMT_VAAPI
        framesContext.pointee.sw_format = AV_PIX_FMT_NV12
        framesContext.pointee.width = Int32(configuration.width)
        framesContext.pointee.height = Int32(configuration.height)
        framesContext.pointee.initial_pool_size = 4
        let initialised = av_hwframe_ctx_init(frames)
        guard initialised >= 0 else {
            throw LinuxVideoEncoderError.sessionCreationFailed(initialised)
        }
        context.pointee.pix_fmt = AV_PIX_FMT_VAAPI
        context.pointee.hw_frames_ctx = av_buffer_ref(frames)
        try setOption(context, "profile", configuration.profile.libavName)
        try setOption(context, "rc_mode", "VBR")
        // One frame in flight: a packet is ready as soon as its frame is.
        try setOption(context, "async_depth", "1")
        try setOption(context, "coder", configuration.profile == .constrainedBaseline ? "cavlc" : "cabac", required: false)
        // Every I frame the GOP asks for is an IDR, so a key frame is always
        // a point a viewer can start decoding from.
        try setOption(context, "idr_interval", "0", required: false)
        try setOption(context, "sei", "0", required: false)
    }

    private func setOption(
        _ context: UnsafeMutablePointer<AVCodecContext>,
        _ name: String,
        _ value: String,
        required: Bool = true
    ) throws {
        let result = av_opt_set(context.pointee.priv_data, name, value, 0)
        if result < 0, required {
            throw LinuxVideoEncoderError.optionRejected(name)
        }
    }

    private func releaseResources() {
        if surfaceFrame != nil { av_frame_free(&surfaceFrame) }
        if softwareFrame != nil { av_frame_free(&softwareFrame) }
        if packet != nil { av_packet_free(&packet) }
        if context != nil { avcodec_free_context(&context) }
        if framesReference != nil { av_buffer_unref(&framesReference) }
        if deviceReference != nil { av_buffer_unref(&deviceReference) }
    }

    private static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
#endif
