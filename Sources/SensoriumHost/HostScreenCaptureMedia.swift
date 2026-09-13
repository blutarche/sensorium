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
    private var pipeline: HostMediaPipeline?
    private let packetizer: H264SampleBufferPacketizer
    private var displayID: UInt32?
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?
    /// Resolved once per `displayID`, discarded and re-resolved once on a
    /// start failure.
    private var cachedContentFilter: SCContentFilter?
    /// Where this pipeline's own troubles reach the person reading the host
    /// log -- the same reasoning `ScreenCaptureCanvasMedia.log` documents.
    private let log: (@Sendable (String) -> Void)?

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
    public init(
        configuration: VideoEncoderConfiguration,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        sequencer: VideoPacketSequencer = VideoPacketSequencer(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.latencyRecorder = latencyRecorder
        self.focus = focus
        self.admissionGate = admissionGate
        self.packetizer = H264SampleBufferPacketizer(sequencer: sequencer)
        self.log = log
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
        try pipeline?.apply(qualityScale: qualityScale)
        configuration = configuration.with(qualityScale: qualityScale)
    }

    public func requestKeyFrame() async {
        pipeline?.requestKeyFrame()
    }

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
        guard displayID != nil, packetHandler != nil else {
            return
        }
        do {
            try await bringUpPipeline(configuration: configuration)
        } catch {
            cachedContentFilter = nil
            try await bringUpPipeline(configuration: configuration)
        }
    }

    private func bringUpPipeline(configuration: VideoEncoderConfiguration) async throws {
        guard let displayID, let packetHandler else {
            return
        }
        let filter: SCContentFilter
        if let cachedContentFilter {
            filter = cachedContentFilter
        } else {
            filter = try await HostScreenCapture.contentFilter(displayID: displayID)
            cachedContentFilter = filter
        }
        let pipeline = try HostMediaPipeline(
            contentFilter: filter,
            surface: Self.telemetrySurface,
            configuration: configuration,
            latencyRecorder: latencyRecorder,
            sessionAdmissionGate: admissionGate,
            focus: focus,
            captureTarget: .hostScreen,
            packetizer: packetizer,
            streamStoppedHandler: { [log] error in
                log?(ScreenCaptureStopReport.streamStopped(displayID: displayID, error: error))
            },
            encodedPacketHandler: packetHandler
        )
        self.pipeline = pipeline
        latencyRecorder?.resetEncodeCheckpoint(for: Self.telemetrySurface)
        try await pipeline.start()
    }
}
