import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore

/// The real capture-and-encode path for host-screen mode: one existing
/// physical display, captured and encoded exactly as
/// `ScreenCaptureCanvasMedia` already does for the session canvas, but
/// through `HostScreenCapture` instead of `SessionCanvasCapture` and never
/// releasing anything the target display owns -- there is no display
/// handle here to release in the first place; ScreenCaptureKit's own
/// stream stop touches nothing about display configuration.
///
/// Resolving the filter requires Screen Recording approval, so nothing in
/// this repository runs it; the decision of when to start and stop lives in
/// `HostSessionCoordinator`, which is verified against a fake, the same
/// discipline `ScreenCaptureCanvasMedia` already follows.
@available(macOS 13.0, *)
@MainActor
public final class HostScreenCaptureMedia: CanvasMediaStreaming {
    /// Host-screen mode has no `CanvasSurfaceID` of its own, so its frames
    /// are attributed to surface 0 in the telemetry and admission
    /// bookkeeping shared with the canvas path. A canvas on surface 0 live
    /// on the same connection would have its bookkeeping conflated with
    /// this one; mixed sessions are not yet refused.
    private static let telemetrySurface = CanvasSurfaceID.allCases[0]

    private var configuration: VideoEncoderConfiguration
    private let latencyRecorder: HostMediaLatencyRecorder?
    private let focus: CanvasFocusTracker
    private let admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>
    private let sendFeedback: VideoSendFeedback
    private var pipeline: (any CanvasMediaPipelining)?
    private let pipelineFactory: HostMediaPipelineFactory
    private let contentFilterProvider: (UInt32) async throws -> SCContentFilter
    private let packetizer: H264SampleBufferPacketizer
    private var displayID: UInt32?
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?
    /// Resolved once per `displayID`, discarded and re-resolved once on a
    /// start failure.
    private var cachedContentFilter: SCContentFilter?
    /// Where this pipeline's own troubles reach the person reading the host
    /// log -- the same reasoning `ScreenCaptureCanvasMedia.log` documents.
    private let log: (@Sendable (String) -> Void)?
    /// Told when `SCStreamDelegate`'s own stop signal fires -- capture
    /// stopping on its own, never a stop this object was asked for. `nil`
    /// until `setCaptureStoppedHandler` is called, which
    /// `HostSessionCoordinator` does before this pipeline is ever started.
    private var captureStoppedHandler: (@Sendable () -> Void)?
    /// Bumped for every pipeline built and at `stop`. Building a pipeline
    /// waits on the encoder service, for minutes when the hardware encoder
    /// is stuck, and a stop or a newer build that comes in meanwhile wins:
    /// the pipeline that arrives late is discarded, never installed.
    private var pipelineGeneration = 0

    /// `configuration` is the caller's own, already sized for the real
    /// target display -- see `HostScreenEncoderSizing`. This type never
    /// derives dimensions on its own; deriving them twice, in two places,
    /// is exactly how the two could drift apart.
    ///
    /// `sequencer` defaults to a fresh one, but `HostScreenAccountableMedia`
    /// -- the one object that spans every capture a host-screen session
    /// replaces -- injects the same instance into every `HostScreenCaptureMedia`
    /// it builds for that session, so a display-mode change that discards
    /// this object and builds another keeps one packet sequence across both.
    public convenience init(
        configuration: VideoEncoderConfiguration,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        sequencer: VideoPacketSequencer = VideoPacketSequencer(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.init(
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            focus: focus,
            admissionGate: admissionGate,
            sendFeedback: sendFeedback,
            sequencer: sequencer,
            log: log,
            contentFilterProvider: { displayID in
                try await HostScreenCapture.contentFilter(displayID: displayID)
            },
            pipelineFactory: { contentFilter, surface, configuration, latencyRecorder, sessionAdmissionGate, focus, sendFeedback, captureTarget, packetizer, streamStoppedHandler, encodedPacketHandler in
                try await HostMediaPipeline(
                    contentFilter: contentFilter,
                    surface: surface,
                    configuration: configuration,
                    latencyRecorder: latencyRecorder,
                    sessionAdmissionGate: sessionAdmissionGate,
                    focus: focus,
                    sendFeedback: sendFeedback,
                    captureTarget: captureTarget,
                    packetizer: packetizer,
                    streamStoppedHandler: streamStoppedHandler,
                    encodedPacketHandler: encodedPacketHandler
                )
            }
        )
    }

    /// The same, resolving the display's content filter through
    /// `contentFilterProvider` and building each pipeline through
    /// `pipelineFactory`. For this package's tests, which cannot run
    /// ScreenCaptureKit.
    package init(
        configuration: VideoEncoderConfiguration,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        sendFeedback: VideoSendFeedback = VideoSendFeedback(),
        sequencer: VideoPacketSequencer = VideoPacketSequencer(),
        log: (@Sendable (String) -> Void)? = nil,
        contentFilterProvider: @escaping (UInt32) async throws -> SCContentFilter,
        pipelineFactory: @escaping HostMediaPipelineFactory
    ) {
        self.configuration = configuration
        self.latencyRecorder = latencyRecorder
        self.focus = focus
        self.admissionGate = admissionGate
        self.sendFeedback = sendFeedback
        self.packetizer = H264SampleBufferPacketizer(sequencer: sequencer)
        self.log = log
        self.contentFilterProvider = contentFilterProvider
        self.pipelineFactory = pipelineFactory
    }

    public func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {
        captureStoppedHandler = handler
    }

    public var currentStreamScale: Double { configuration.streamScale }

    public var currentFramesPerSecond: Int { configuration.framesPerSecond }

    public var currentQualityScale: Double { configuration.qualityScale }

    /// The same ordering `ScreenCaptureCanvasMedia.apply(framesPerSecond:)`
    /// documents: the configuration records what the live stream actually
    /// took, so a later rebuild carries no fidelity that was never applied.
    public func apply(framesPerSecond: Int) async throws {
        try await pipeline?.apply(framesPerSecond: framesPerSecond)
        configuration = configuration.with(framesPerSecond: framesPerSecond)
    }

    public func apply(qualityScale: Double) async throws {
        try await pipeline?.apply(qualityScale: qualityScale)
        configuration = configuration.with(qualityScale: qualityScale)
    }

    public func apply(keyFrameIntervalSeconds: Double) async throws {
        try await pipeline?.apply(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
        configuration = configuration.with(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
    }

    public func requestKeyFrame() async {
        pipeline?.requestKeyFrame()
    }

    public func viewerInteracted() {
        pipeline?.viewerInteracted()
    }

    public var encodingStreamScale: Double? { pipeline?.encodingStreamScale }

    /// The same still-screen refresh the canvas path sends, on a real
    /// display's own pipeline: a screen nobody is at stops changing exactly
    /// as a canvas does.
    public func refreshStillPicture() async throws -> Int? {
        guard let pipeline else {
            return nil
        }
        return try await pipeline.refreshStillPicture()
    }

    /// All zero without a recorder to count into: nothing measured, rather
    /// than nothing dropped.
    public var frameCounts: HostFrameCounts {
        latencyRecorder?.frameCounts(for: Self.telemetrySurface)
            ?? HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
    }

    public func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        displayID = canvasDisplayID
        packetHandler = onPacket
        try await startPipeline(configuration: configuration)
    }

    public func stop() async {
        // A pipeline that will not stop has no other trace, so the failure
        // is logged.
        if let displayID {
            await stopPipeline(displayID: displayID)
        }
        pipeline = nil
        pipelineGeneration += 1
        displayID = nil
        packetHandler = nil
        cachedContentFilter = nil
    }

    public func reconfigure(streamScale: Double) async throws {
        guard let displayID else {
            return
        }
        let previous = configuration
        let target = configuration.scaled(toStreamScale: streamScale)
        await stopPipeline(displayID: displayID)
        pipeline = nil
        packetizer.beginNewEncoderGeneration()
        do {
            try await startPipeline(configuration: target)
            // A fidelity change applied while the new pipeline was built
            // went into `configuration`, not `target`, and that pipeline
            // already runs it.
            configuration = target.withFidelity(of: configuration)
        } catch {
            await stopPipeline(displayID: displayID)
            pipeline = nil
            packetizer.beginNewEncoderGeneration()
            try await startPipeline(configuration: previous)
            configuration = previous.withFidelity(of: configuration)
            throw CanvasMediaReconfigurationError.recoveredToPreviousScale(previous.streamScale)
        }
    }

    /// Stops the live pipeline and says so if it would not stop -- the same
    /// discipline `ScreenCaptureCanvasMedia.stopPipeline` follows, for the
    /// same reason: a capture stream that survives the pipeline it belonged
    /// to keeps delivering into a stopped encoder, and silence here is the
    /// one thing that must not happen.
    private func stopPipeline(displayID: UInt32) async {
        guard let pipeline else {
            return
        }
        do {
            try await pipeline.stop()
        } catch {
            log?(ScreenCaptureStopReport.stopFailed(displayID: displayID, error: error))
        }
    }

    private func startPipeline(configuration: VideoEncoderConfiguration) async throws {
        guard let displayID, packetHandler != nil else {
            return
        }
        do {
            try await bringUpPipeline(configuration: configuration)
        } catch {
            log?(ScreenCaptureStopReport.startFailed(displayID: displayID, error: error))
            // The attempt that failed is stopped and discarded before the
            // next one is built. `bringUpPipeline` installs the pipeline
            // before starting it, so a start that failed part-way leaves a
            // stream this host still owns, and overwriting it would leave
            // that stream running against the display the retry is about to
            // capture.
            await stopPipeline(displayID: displayID)
            pipeline = nil
            cachedContentFilter = nil
            try await bringUpPipeline(configuration: configuration)
        }
    }

    private func bringUpPipeline(configuration: VideoEncoderConfiguration) async throws {
        guard let displayID, let packetHandler else {
            return
        }
        pipelineGeneration += 1
        let generation = pipelineGeneration
        let filter: SCContentFilter
        if let cachedContentFilter {
            filter = cachedContentFilter
        } else {
            filter = try await contentFilterProvider(displayID)
            cachedContentFilter = filter
        }
        let pipeline: any CanvasMediaPipelining
        do {
            pipeline = try await pipelineFactory(
                filter,
                Self.telemetrySurface,
                configuration,
                latencyRecorder,
                admissionGate,
                focus,
                sendFeedback,
                .hostScreen,
                packetizer,
                { [log, captureStoppedHandler] error in
                    log?(ScreenCaptureStopReport.streamStopped(displayID: displayID, error: error))
                    captureStoppedHandler?()
                },
                packetHandler
            )
        } catch {
            // A build the caller has already moved on from failing is not
            // the live capture failing to start.
            guard generation == pipelineGeneration else {
                return
            }
            throw error
        }
        guard generation == pipelineGeneration else {
            // A stop or a newer build came in while this one waited on the
            // encoder service. Stopping a pipeline that was never started
            // shuts its encoder down and leaves capture alone.
            try? await pipeline.stop()
            return
        }
        self.pipeline = pipeline
        latencyRecorder?.resetEncodeCheckpoint(for: Self.telemetrySurface)
        try await pipeline.start()
        await catchUpFidelity(of: pipeline, builtWith: configuration)
    }

    /// Brings `pipeline` to the fidelity this media records now. It was
    /// built from `built`, and building it waits on the encoder service: a
    /// change applied during that wait found no pipeline to take it, so it
    /// was only recorded. A change in resolution is not one of these; it
    /// rebuilds the pipeline instead. A lever the pipeline refuses keeps the
    /// value it was built with, and the configuration goes back to saying
    /// so. Nothing is thrown: the pipeline is already streaming, as built.
    private func catchUpFidelity(
        of pipeline: any CanvasMediaPipelining,
        builtWith built: VideoEncoderConfiguration
    ) async {
        guard self.pipeline === pipeline else {
            return
        }
        let wanted = configuration
        var kept = wanted
        if wanted.framesPerSecond != built.framesPerSecond {
            do {
                try await pipeline.apply(framesPerSecond: wanted.framesPerSecond)
            } catch {
                kept = kept.with(framesPerSecond: built.framesPerSecond)
                log?("frame rate \(wanted.framesPerSecond) fps did not apply to the new capture; it stays at \(built.framesPerSecond) fps: \(error)")
            }
        }
        if wanted.qualityScale != built.qualityScale {
            do {
                try await pipeline.apply(qualityScale: wanted.qualityScale)
            } catch {
                kept = kept.with(qualityScale: built.qualityScale)
                log?("quality \(wanted.qualityScale) did not apply to the new capture; it stays at \(built.qualityScale): \(error)")
            }
        }
        if wanted.keyFrameIntervalSeconds != built.keyFrameIntervalSeconds {
            do {
                try await pipeline.apply(keyFrameIntervalSeconds: wanted.keyFrameIntervalSeconds)
            } catch {
                kept = kept.with(keyFrameIntervalSeconds: built.keyFrameIntervalSeconds)
                log?("key frames every \(wanted.keyFrameIntervalSeconds) s did not apply to the new capture; they stay every \(built.keyFrameIntervalSeconds) s: \(error)")
            }
        }
        // A stop, a newer build, or a change applied straight to this
        // pipeline while it caught up owns the configuration from then on.
        guard kept != wanted, self.pipeline === pipeline, configuration == wanted else {
            return
        }
        configuration = kept
    }
}
