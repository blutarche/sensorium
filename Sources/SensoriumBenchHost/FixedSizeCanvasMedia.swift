import Foundation
import SensoriumCore
import SensoriumHost

/// A canvas stream whose picture size is the one it was built with, for a
/// stand-in started with `--canvas`.
///
/// A real session follows the viewer's window: each change of its size is
/// asked of the host as a new stream scale, and the host rebuilds the encoder
/// at it. A run that has to hold one settled size, and the one smaller size
/// motion switches to, cannot have the size follow a window it does not
/// control. Every size request is answered as the host answers one it cannot
/// bring up: the stream keeps the size it has, and says so.
@MainActor
final class FixedSizeCanvasMedia: CanvasMediaStreaming {
    private let media: ScreenCaptureCanvasMedia

    init(_ media: ScreenCaptureCanvasMedia) {
        self.media = media
    }

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        try await media.start(canvasDisplayID: canvasDisplayID, onPacket: onPacket)
    }

    func stop() async {
        await media.stop()
    }

    var currentStreamScale: Double { media.currentStreamScale }

    func reconfigure(streamScale: Double) async throws {
        throw CanvasMediaReconfigurationError.recoveredToPreviousScale(media.currentStreamScale)
    }

    func apply(framesPerSecond: Int) async throws {
        try await media.apply(framesPerSecond: framesPerSecond)
    }

    func apply(qualityScale: Double) async throws {
        try await media.apply(qualityScale: qualityScale)
    }

    func requestKeyFrame() async {
        await media.requestKeyFrame()
    }

    func refreshStillPicture() async throws -> Int? {
        try await media.refreshStillPicture()
    }

    var currentFramesPerSecond: Int {
        get async { media.currentFramesPerSecond }
    }

    var currentQualityScale: Double {
        get async { media.currentQualityScale }
    }

    var frameCounts: HostFrameCounts {
        get async { media.frameCounts }
    }

    func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {
        media.setCaptureStoppedHandler(handler)
    }

    func use(profileLevel: VideoEncoderProfileLevel) {
        media.use(profileLevel: profileLevel)
    }

    func apply(keyFrameIntervalSeconds: Double) async throws {
        try await media.apply(keyFrameIntervalSeconds: keyFrameIntervalSeconds)
    }

    func viewerInteracted() {
        media.viewerInteracted()
    }

    var encodingStreamScale: Double? { media.encodingStreamScale }
}
