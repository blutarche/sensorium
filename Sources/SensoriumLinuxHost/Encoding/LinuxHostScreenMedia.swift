#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumHost

/// The Linux host-screen capture-and-encode path the shared coordinator
/// drives: frames from the granted monitor's screen feed, scaled to the
/// encode size, through `LinuxH264Encoder`, to the session's video sender.
///
/// It keeps the macOS host's packet path where it applies: one sequencer
/// across every encoder the session builds, key frames on request and when
/// the send queue lost a frame, the viewer's profile, stream-scale
/// rebuilds, the frame rate and quality levers, and the same capture and
/// encode counters on surface 0.
///
/// Where it differs:
/// - The frame rate is applied by pacing frames into the encoder. The bit
///   rate rule keeps bits per frame constant across frame rates, so the
///   encoder needs no rebuild for it.
/// - Quality and the key-frame interval rebuild the encoder, which has no
///   live bit-rate change; the next frame is then a key frame.
/// - A still refresh sends the last frame again as a key frame from the
///   stream's own encoder, at the quality in force.
/// - An encode size with an odd side is encoded one pixel smaller on that
///   side, because 4:2:0 video cannot be odd.
/// - PipeWire sends nothing while the screen is still, so while the stream
///   is live a no-change notice is counted every `heartbeatInterval`, as
///   ScreenCaptureKit's idle frames are on macOS. A capture that stopped
///   delivering stops counting them.
@MainActor
public final class LinuxHostScreenMedia: CanvasMediaStreaming {
    private var configuration: VideoEncoderConfiguration
    private let feed: LinuxScreenFeed
    private let engine: LinuxScreenEncodeEngine
    private let latencyRecorder: HostMediaLatencyRecorder?
    private var subscription: LinuxScreenFeed.Subscription?
    private var captureStoppedHandler: (@Sendable () -> Void)?
    private var isStarted = false

    public init(
        configuration: VideoEncoderConfiguration,
        sequencer: VideoPacketSequencer,
        feed: LinuxScreenFeed,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        backendPreference: LinuxEncoderBackendPreference = .automatic,
        heartbeatInterval: TimeInterval = 0.5,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.feed = feed
        self.latencyRecorder = latencyRecorder
        engine = LinuxScreenEncodeEngine(
            sequencer: sequencer,
            latencyRecorder: latencyRecorder,
            sendFeedback: sendFeedback,
            backendPreference: backendPreference,
            heartbeatInterval: heartbeatInterval,
            log: log
        )
    }

    /// The encoder settings for `configuration`: its encode size rounded
    /// down to even, its rate, profile, quality and key-frame interval.
    public static func encoderConfiguration(
        for configuration: VideoEncoderConfiguration,
        backendPreference: LinuxEncoderBackendPreference
    ) -> LinuxEncoderConfiguration {
        LinuxEncoderConfiguration(
            width: max(16, configuration.encodeWidth & ~1),
            height: max(16, configuration.encodeHeight & ~1),
            framesPerSecond: configuration.framesPerSecond,
            profile: profile(for: configuration.profileLevel),
            qualityScale: configuration.qualityScale,
            keyFrameIntervalSeconds: configuration.keyFrameIntervalSeconds,
            backendPreference: backendPreference
        )
    }

    private static func profile(for level: VideoEncoderProfileLevel) -> LinuxEncoderProfile {
        switch level {
        case .baselineAutoLevel, .constrainedBaselineAutoLevel: .constrainedBaseline
        case .mainAutoLevel: .main
        case .highAutoLevel: .high
        }
    }

    public func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {
        captureStoppedHandler = handler
        engine.setCaptureStoppedHandler(handler)
    }

    public func use(profileLevel: VideoEncoderProfileLevel) {
        configuration = configuration.with(profileLevel: profileLevel)
    }

    public var currentStreamScale: Double { configuration.streamScale }

    public var currentFramesPerSecond: Int { configuration.framesPerSecond }

    public var currentQualityScale: Double { configuration.qualityScale }

    public var frameCounts: HostFrameCounts {
        latencyRecorder?.frameCounts(for: LinuxScreenEncodeEngine.surface)
            ?? HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
    }

    public func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        if case let .failed(reason) = feed.currentState {
            throw LinuxHostScreenMediaError.captureUnavailable(reason)
        }
        engine.setPacketHandler(onPacket)
        engine.setFramesPerSecond(configuration.framesPerSecond)
        try await engine.configure(Self.encoderConfiguration(for: configuration, backendPreference: engine.backendPreference))
        isStarted = true
        engine.startHeartbeat()
        let engine = engine
        subscription = feed.subscribe(
            onFrame: { frame in engine.admit(frame) },
            onState: { state in engine.streamStateChanged(state) }
        )
    }

    public func stop() async {
        subscription?.cancel()
        subscription = nil
        isStarted = false
        await engine.shutDown()
    }

    public func reconfigure(streamScale: Double) async throws {
        guard isStarted else { return }
        let previous = configuration
        let target = configuration.scaled(toStreamScale: streamScale)
        do {
            try await engine.configure(Self.encoderConfiguration(for: target, backendPreference: engine.backendPreference))
            configuration = target
        } catch {
            try await engine.configure(Self.encoderConfiguration(for: previous, backendPreference: engine.backendPreference))
            throw CanvasMediaReconfigurationError.recoveredToPreviousScale(previous.streamScale)
        }
        engine.encodeLatestAgain()
    }

    public func apply(framesPerSecond: Int) async throws {
        configuration = configuration.with(framesPerSecond: framesPerSecond)
        engine.setFramesPerSecond(framesPerSecond)
    }

    public func apply(qualityScale: Double) async throws {
        let target = configuration.with(qualityScale: qualityScale)
        if isStarted {
            try await engine.configure(Self.encoderConfiguration(for: target, backendPreference: engine.backendPreference))
        }
        configuration = target
    }

    public func apply(keyFrameIntervalSeconds: Double) async throws {
        let target = configuration.with(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
        if isStarted {
            try await engine.configure(Self.encoderConfiguration(for: target, backendPreference: engine.backendPreference))
        }
        configuration = target
    }

    public func requestKeyFrame() async {
        engine.requestKeyFrame()
    }

    public func refreshStillPicture() async throws -> Int? {
        try await engine.refreshStillPicture()
    }
}

public enum LinuxHostScreenMediaError: Error, Equatable {
    /// The screen feed has stopped, so there is nothing to capture.
    case captureUnavailable(String)
    /// A still refresh was encoded but the transport did not take it.
    case refreshRefused
    /// A still refresh's encode produced no picture.
    case refreshNotEncoded
}

/// The encoder side of `LinuxHostScreenMedia`, on a serial queue of its own
/// so encoding never runs on the main actor or a PipeWire thread.
///
/// Admission is latest-frame-wins: a frame that arrives while one is being
/// encoded, while the send queue's waiting slot is full, or before the frame
/// rate allows the next one, waits in a single slot that a newer frame
/// replaces. The frame in that slot always goes in once the reason it waits
/// clears, so the last frame of a burst is never lost.
final class LinuxScreenEncodeEngine: VideoSendFeedbackListener, @unchecked Sendable {
    /// Host-screen frames are counted on surface 0, as on macOS.
    static let surface = CanvasSurfaceID.allCases[0]

    let backendPreference: LinuxEncoderBackendPreference
    private let sequencer: VideoPacketSequencer
    private let latencyRecorder: HostMediaLatencyRecorder?
    private let sendFeedback: VideoSendFeedback
    private let heartbeatInterval: TimeInterval
    private let log: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "sensorium.linux-host-screen-encode")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?
    private var captureStoppedHandler: (@Sendable () -> Void)?
    private var didReportCaptureStopped = false
    private var pending: ScreenFeedFrame?
    private var latest: ScreenFeedFrame?
    private var isDrainScheduled = false
    private var isShutDown = false
    private var isStreaming = false
    private var framesSinceHeartbeat = 0
    private var minimumFrameInterval: Int64 = 0
    private var lastEncodeAt: Int64?
    private var heartbeat: DispatchSourceTimer?

    // Touched only on `queue`.
    private var encoder: LinuxH264Encoder?
    private var lastResult: (packet: EncodedVideoFramePacket, accepted: Bool)?

    init(
        sequencer: VideoPacketSequencer,
        latencyRecorder: HostMediaLatencyRecorder?,
        sendFeedback: VideoSendFeedback,
        backendPreference: LinuxEncoderBackendPreference,
        heartbeatInterval: TimeInterval,
        log: (@Sendable (String) -> Void)?
    ) {
        self.sequencer = sequencer
        self.latencyRecorder = latencyRecorder
        self.sendFeedback = sendFeedback
        self.backendPreference = backendPreference
        self.heartbeatInterval = heartbeatInterval
        self.log = log
        sendFeedback.attach(self, on: Self.surface)
    }

    deinit {
        heartbeat?.cancel()
        sendFeedback.detach(self, on: Self.surface)
    }

    func setPacketHandler(_ handler: @escaping @Sendable (EncodedVideoFramePacket) -> Bool) {
        lock.withLock { packetHandler = handler }
    }

    func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { captureStoppedHandler = handler }
    }

    func setFramesPerSecond(_ framesPerSecond: Int) {
        let interval = framesPerSecond > 0 ? 1_000_000_000 / Int64(framesPerSecond) : 0
        lock.withLock { minimumFrameInterval = interval }
    }

    /// Builds the encoder every later frame goes through, replacing any
    /// earlier one. The first frame it encodes is a key frame.
    func configure(_ configuration: LinuxEncoderConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let replacement = try LinuxH264Encoder(
                        configuration: configuration,
                        sequencer: sequencer,
                        outcomeHandler: { [weak self] outcome in self?.handle(outcome) }
                    )
                    encoder?.shutDown()
                    encoder = replacement
                    latencyRecorder?.resetEncodeCheckpoint(for: Self.surface)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        scheduleDrain()
    }

    func startHeartbeat() {
        guard heartbeatInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.beat() }
        let replaced = lock.withLock {
            defer { heartbeat = timer }
            return heartbeat
        }
        replaced?.cancel()
        timer.resume()
    }

    private func beat() {
        let counts = lock.withLock {
            defer { framesSinceHeartbeat = 0 }
            return (isStreaming && !isShutDown, framesSinceHeartbeat)
        }
        if counts.0, counts.1 == 0 {
            latencyRecorder?.recordCaptureDelivery(.noChangeNotice, surface: Self.surface)
        }
    }

    func streamStateChanged(_ state: CaptureState) {
        let stopped: (@Sendable () -> Void)? = lock.withLock {
            isStreaming = state == .streaming
            guard case .failed = state, !didReportCaptureStopped, !isShutDown else { return nil }
            didReportCaptureStopped = true
            return captureStoppedHandler
        }
        if case let .failed(reason) = state {
            log?("Sensorium host: the host screen's capture stopped: \(reason)")
        }
        stopped?()
    }

    func admit(_ frame: ScreenFeedFrame) {
        let replaced: Bool? = lock.withLock {
            guard !isShutDown else { return nil }
            framesSinceHeartbeat += 1
            let replacing = pending != nil
            pending = frame
            latest = frame
            return replacing
        }
        guard let replaced else { return }
        latencyRecorder?.recordCapture(
            surface: Self.surface,
            presentationTimeNanoseconds: frame.presentationTimeNanoseconds,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        if replaced {
            if sendFeedback.isWaitingSlotOccupied(on: Self.surface) {
                sendFeedback.recordCaptureDroppedForTheLink(on: Self.surface)
            } else {
                latencyRecorder?.recordEncoderInputDrop(surface: Self.surface)
            }
        }
        scheduleDrain()
    }

    /// Puts the latest frame through the encoder again, as after a rebuild
    /// at a new size, so a still screen shows the new size at once.
    func encodeLatestAgain() {
        lock.withLock {
            if pending == nil, let latest {
                pending = ScreenFeedFrame(
                    width: latest.width,
                    height: latest.height,
                    bytesPerRow: latest.bytesPerRow,
                    pixels: latest.pixels,
                    presentationTimeNanoseconds: MonotonicClock.nowNanoseconds()
                )
            }
        }
        scheduleDrain()
    }

    func requestKeyFrame() {
        queue.async { [self] in encoder?.requestKeyFrame() }
    }

    func sendWaitingSlotEmptied() {
        scheduleDrain()
    }

    func keyFrameNeeded() {
        requestKeyFrame()
    }

    func refreshStillPicture() async throws -> Int? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int?, any Error>) in
            queue.async { [self] in
                let frame: ScreenFeedFrame? = lock.withLock {
                    guard !isShutDown, let latest else { return nil }
                    return ScreenFeedFrame(
                        width: latest.width,
                        height: latest.height,
                        bytesPerRow: latest.bytesPerRow,
                        pixels: latest.pixels,
                        presentationTimeNanoseconds: MonotonicClock.nowNanoseconds()
                    )
                }
                guard let frame, let encoder else {
                    continuation.resume(returning: nil)
                    return
                }
                latencyRecorder?.recordHostRequestedFrame(
                    surface: Self.surface,
                    presentationTimeNanoseconds: frame.presentationTimeNanoseconds,
                    atNanoseconds: MonotonicClock.nowNanoseconds()
                )
                encoder.requestKeyFrame()
                lastResult = nil
                encode(frame, on: encoder)
                guard let result = lastResult else {
                    continuation.resume(throwing: LinuxHostScreenMediaError.refreshNotEncoded)
                    return
                }
                guard result.accepted else {
                    continuation.resume(throwing: LinuxHostScreenMediaError.refreshRefused)
                    return
                }
                continuation.resume(returning: result.packet.payload.count)
            }
        }
    }

    func shutDown() async {
        let timer: DispatchSourceTimer? = lock.withLock {
            isShutDown = true
            pending = nil
            latest = nil
            packetHandler = nil
            defer { heartbeat = nil }
            return heartbeat
        }
        timer?.cancel()
        sendFeedback.detach(self, on: Self.surface)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                encoder?.shutDown()
                encoder = nil
                continuation.resume()
            }
        }
    }

    private func scheduleDrain(after delay: Int64 = 0) {
        let schedule = lock.withLock {
            guard !isDrainScheduled, !isShutDown else { return false }
            isDrainScheduled = true
            return true
        }
        guard schedule else { return }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in self?.drain() }
        } else {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// On `queue`.
    private func drain() {
        let now = MonotonicClock.nowNanoseconds()
        enum Next { case encode(ScreenFeedFrame, LinuxH264Encoder), wait(Int64), idle }
        let next: Next = lock.withLock {
            isDrainScheduled = false
            guard !isShutDown, let frame = pending, let encoder else { return .idle }
            if sendFeedback.isWaitingSlotOccupied(on: Self.surface) {
                return .idle
            }
            if let lastEncodeAt, minimumFrameInterval > 0, now - lastEncodeAt < minimumFrameInterval {
                return .wait(minimumFrameInterval - (now - lastEncodeAt))
            }
            pending = nil
            lastEncodeAt = now
            return .encode(frame, encoder)
        }
        switch next {
        case .idle:
            return
        case let .wait(delay):
            scheduleDrain(after: delay)
        case let .encode(frame, encoder):
            encode(frame, on: encoder)
            if lock.withLock({ pending != nil }) {
                scheduleDrain()
            }
        }
    }

    /// On `queue`.
    private func encode(_ frame: ScreenFeedFrame, on encoder: LinuxH264Encoder) {
        let size = encoder.configuration
        let scaled = BGRxScaler.scale(
            pixels: frame.pixels,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            toWidth: size.width,
            toHeight: size.height
        )
        latencyRecorder?.recordEncodeSubmit(
            surface: Self.surface,
            presentationTimeNanoseconds: frame.presentationTimeNanoseconds,
            atNanoseconds: MonotonicClock.nowNanoseconds()
        )
        do {
            try encoder.encode(LinuxVideoFrame(
                width: scaled.width,
                height: scaled.height,
                pixelFormat: .bgrx,
                bytesPerRow: scaled.bytesPerRow,
                pixels: scaled.pixels,
                presentationTimeNanoseconds: UInt64(max(0, frame.presentationTimeNanoseconds))
            ))
        } catch let LinuxVideoEncoderError.frameSubmissionFailed(code) {
            latencyRecorder?.recordEncodeSubmissionFailure(status: code, surface: Self.surface)
            log?("Sensorium host: video encode submission failed code=\(code)")
        } catch {
            latencyRecorder?.recordEncoderOutputDrop(surface: Self.surface)
            log?("Sensorium host: video encode failed \(error)")
        }
    }

    /// Called by the encoder during its own `encode`, on `queue`.
    private func handle(_ outcome: LinuxVideoEncodeOutcome) {
        switch outcome {
        case let .encoded(packet):
            latencyRecorder?.recordEncodeOutput(
                surface: Self.surface,
                presentationTimeNanoseconds: Int64(packet.presentationTimeNanoseconds),
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
            let handler = lock.withLock { packetHandler }
            let accepted = handler?(packet) ?? false
            lastResult = (packet, accepted)
        case .dropped:
            latencyRecorder?.recordEncoderOutputDrop(surface: Self.surface)
        case let .failed(code):
            latencyRecorder?.recordEncodeSubmissionFailure(status: code, surface: Self.surface)
            log?("Sensorium host: video encode failed code=\(code)")
        }
    }
}
#endif
