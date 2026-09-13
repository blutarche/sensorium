import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore

/// Builds the pipeline `ScreenCaptureCanvasMedia` streams through. Given the
/// same arguments `HostMediaPipeline`'s own initializer takes, so the
/// default is a direct pass-through to `HostMediaPipeline`.
@available(macOS 13.0, *)
public typealias HostMediaPipelineFactory = @MainActor (
    _ contentFilter: SCContentFilter,
    _ surface: CanvasSurfaceID,
    _ configuration: VideoEncoderConfiguration,
    _ latencyRecorder: HostMediaLatencyRecorder?,
    _ sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
    _ focus: CanvasFocusTracker,
    _ captureTarget: CaptureCursorPolicy.Target,
    _ packetizer: H264SampleBufferPacketizer,
    _ streamStoppedHandler: (@Sendable (Error) -> Void)?,
    _ encodedPacketHandler: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
) throws -> any CanvasMediaPipelining

/// Resolves the content filter for one owned canvas display. Given the same
/// argument `SessionCanvasCapture.contentFilter(ownedHandle:)` takes, so a
/// test can hand back a filter, or fail, without `SCShareableContent`'s
/// system-wide window enumeration.
@available(macOS 13.0, *)
public typealias CanvasContentFilterProvider = (VirtualDisplayHandle) async throws -> SCContentFilter

/// The real capture-and-encode path for the session canvas. Resolving the
/// filter requires Screen Recording approval; when to start and stop is
/// decided by `HostSessionCoordinator`.
@available(macOS 13.0, *)
@MainActor
public final class ScreenCaptureCanvasMedia: CanvasMediaStreaming {
    /// Which session canvas this pipeline serves. Carried so every latency
    /// sample is attributed to the surface it came from: two canvases can
    /// legitimately capture frames sharing one presentation timestamp.
    private let surface: CanvasSurfaceID
    private var configuration: VideoEncoderConfiguration
    private let latencyRecorder: HostMediaLatencyRecorder?
    /// The session's shared focus state, carried into every pipeline this
    /// media rebuilds so a resolution change never drops the preference.
    private let focus: CanvasFocusTracker
    /// This session's encode-admission gate, shared with the other canvas's
    /// media and carried across every pipeline this media rebuilds. Owned by
    /// the session, not by this object: it has to outlive a resolution change,
    /// which throws the pipeline away, and bound both canvases together.
    private let admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>
    /// Where this pipeline's own troubles reach the person reading the host
    /// log. A capture stream that ends by itself, and a stop this host asked
    /// for and did not get, leave no other trace at all.
    private let log: (@Sendable (String) -> Void)?
    private let pipelineFactory: HostMediaPipelineFactory
    private let contentFilterProvider: CanvasContentFilterProvider
    private var pipeline: (any CanvasMediaPipelining)?
    /// Held across a reconfiguration so the packet sequence stays monotonic
    /// and the new resolution's keyframe gate is armed. A second packetizer
    /// would restart the sequence at zero, which the viewer's
    /// `VideoFrameIngress` discards wholesale.
    private let packetizer = H264SampleBufferPacketizer()
    private var canvasDisplayID: UInt32?
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?
    /// Resolved once per `canvasDisplayID`: the filter does not change
    /// between `start` and `stop`, and
    /// `SessionCanvasCapture.contentFilter(ownedHandle:)` runs a
    /// system-wide window enumeration (~30-40 ms, measured on real
    /// hardware). Cleared by `stop`, and by `startPipeline` whenever a
    /// cached filter fails to bring a pipeline up, since ScreenCaptureKit
    /// is the only authority on whether a filter it vended is still good.
    private var cachedContentFilter: SCContentFilter?

    public init(
        surface: CanvasSurfaceID,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        log: (@Sendable (String) -> Void)? = nil,
        pipelineFactory: @escaping HostMediaPipelineFactory = { contentFilter, surface, configuration, latencyRecorder, sessionAdmissionGate, focus, captureTarget, packetizer, streamStoppedHandler, encodedPacketHandler in
            try HostMediaPipeline(
                contentFilter: contentFilter,
                surface: surface,
                configuration: configuration,
                latencyRecorder: latencyRecorder,
                sessionAdmissionGate: sessionAdmissionGate,
                focus: focus,
                captureTarget: captureTarget,
                packetizer: packetizer,
                streamStoppedHandler: streamStoppedHandler,
                encodedPacketHandler: encodedPacketHandler
            )
        },
        contentFilterProvider: @escaping CanvasContentFilterProvider = SessionCanvasCapture.contentFilter(ownedHandle:)
    ) {
        self.surface = surface
        self.configuration = configuration
        self.latencyRecorder = latencyRecorder
        self.focus = focus
        self.admissionGate = admissionGate
        self.log = log
        self.pipelineFactory = pipelineFactory
        self.contentFilterProvider = contentFilterProvider
    }

    public var currentStreamScale: Double { configuration.streamScale }

    public var currentFramesPerSecond: Int { configuration.framesPerSecond }

    public var currentQualityScale: Double { configuration.qualityScale }

    /// The configuration is updated only once the live stream has actually
    /// taken the change, so `currentFramesPerSecond` never reports a rate the
    /// encoder refused -- and so a later resolution rebuild, which reads this
    /// configuration, cannot carry a fidelity that was never applied.
    ///
    /// Before `start`, and after `stop`, there is no stream to update: the
    /// value is simply recorded, and the pipeline is built with it whenever
    /// one is next brought up.
    public func apply(framesPerSecond: Int) async throws {
        try await pipeline?.apply(framesPerSecond: framesPerSecond)
        configuration = configuration.with(framesPerSecond: framesPerSecond)
    }

    public func apply(qualityScale: Double) async throws {
        try pipeline?.apply(qualityScale: qualityScale)
        configuration = configuration.with(qualityScale: qualityScale)
    }

    public func requestKeyFrame() async {
        pipeline?.requestKeyFrame()
    }

    /// `nil` with no pipeline as well as with no frame yet: neither has a
    /// picture to send again.
    public func refreshStillPicture() async throws -> Int? {
        guard let pipeline else {
            return nil
        }
        return try await pipeline.refreshStillPicture()
    }

    /// All zero without a recorder to count into: nothing measured, rather
    /// than nothing dropped.
    public var frameCounts: HostFrameCounts {
        latencyRecorder?.frameCounts(for: surface)
            ?? HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
    }

    public func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        self.canvasDisplayID = canvasDisplayID
        packetHandler = onPacket
        try await startPipeline(configuration: configuration)
    }

    public func stop() async {
        // Routed through `stopPipeline` rather than a bare `try?` so a stop
        // that fails is reported the same way a reconfiguration's stop is:
        // the pipeline going silent here has no other trace at all.
        if let canvasDisplayID {
            await stopPipeline(displayID: canvasDisplayID)
        }
        pipeline = nil
        canvasDisplayID = nil
        packetHandler = nil
        cachedContentFilter = nil
    }

    /// Rebuilds capture and encode at the new resolution. `VTCompressionSession`
    /// dimensions are immutable, so the session is genuinely recreated rather
    /// than reconfigured, and `HostMediaPipeline` rebuilds the ScreenCaptureKit
    /// stream and the encoder-input admission gate with it.
    ///
    /// If the new resolution cannot be brought up, the previous one is
    /// restarted and `CanvasMediaReconfigurationError.recoveredToPreviousScale`
    /// is thrown: the caller must hear about it, but a working stream is worth
    /// more than the requested one. Only if that restart also fails does the
    /// original error escape, and the session is then torn down by the caller.
    public func reconfigure(streamScale: Double) async throws {
        guard let displayID = canvasDisplayID else {
            return
        }
        let previous = configuration
        let target = configuration.scaled(toStreamScale: streamScale)
        await stopPipeline(displayID: displayID)
        pipeline = nil
        // Arms the gate that keeps the new resolution's first delta from
        // reaching a decoder that still holds the old SPS/PPS.
        packetizer.beginNewEncoderGeneration()
        do {
            try await startPipeline(configuration: target)
            configuration = target
        } catch {
            await stopPipeline(displayID: displayID)
            pipeline = nil
            packetizer.beginNewEncoderGeneration()
            try await startPipeline(configuration: previous)
            configuration = previous
            throw CanvasMediaReconfigurationError.recoveredToPreviousScale(previous.streamScale)
        }
    }

    /// Stops the live pipeline and says so if it would not stop. A capture
    /// stream that survives the pipeline it belonged to keeps delivering into
    /// a stopped encoder and keeps the canvas busy, and the caller carries on
    /// either way -- so silence here is the one thing that must not happen.
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
        guard let canvasDisplayID, packetHandler != nil else {
            return
        }
        do {
            try await bringUpPipeline(configuration: configuration)
        } catch {
            log?(ScreenCaptureStopReport.startFailed(displayID: canvasDisplayID, error: error))
            // The attempt that failed is stopped and discarded before the
            // next one is built. `bringUpPipeline` installs the pipeline
            // before starting it, so a start that failed part-way leaves a
            // stream this host still owns, and overwriting it would leave
            // that stream running against the same canvas the retry is
            // about to capture.
            await stopPipeline(displayID: canvasDisplayID)
            pipeline = nil
            cachedContentFilter = nil
            try await bringUpPipeline(configuration: configuration)
        }
    }

    private func bringUpPipeline(configuration: VideoEncoderConfiguration) async throws {
        guard let canvasDisplayID, let packetHandler else {
            return
        }
        let filter: SCContentFilter
        if let cachedContentFilter {
            filter = cachedContentFilter
        } else {
            filter = try await contentFilterProvider(VirtualDisplayHandle(rawValue: canvasDisplayID))
            cachedContentFilter = filter
        }
        let pipeline = try pipelineFactory(
            filter,
            surface,
            configuration,
            latencyRecorder,
            admissionGate,
            focus,
            .sessionCanvas,
            packetizer,
            { [log] error in
                log?(ScreenCaptureStopReport.streamStopped(displayID: canvasDisplayID, error: error))
            },
            packetHandler
        )
        self.pipeline = pipeline
        // Before `start()`, not after: any frame this new pipeline produces
        // from here on belongs to the checkpoint that names its own scale,
        // never folded into whatever the previous scale had already recorded.
        latencyRecorder?.resetEncodeCheckpoint(for: surface)
        try await pipeline.start()
    }
}
