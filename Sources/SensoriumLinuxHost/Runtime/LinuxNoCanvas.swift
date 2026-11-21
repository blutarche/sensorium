#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumHost

/// The Linux host offers no session canvas, so no virtual display is ever
/// made. The shared controller refuses a canvas request before it reaches
/// this, because the host reports that it offers none; this only makes the
/// refusal certain.
struct NoCanvasDisplayAdapter: VirtualDisplayAdapter {
    struct Unavailable: Error {}

    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        throw Unavailable()
    }

    func release(_ handle: VirtualDisplayHandle) {}
}

/// Media for something that cannot be streamed: a session canvas, which the
/// Linux host never offers, or a host screen whose grant ended between the
/// request and the start. Starting it fails, so nothing is sent.
@MainActor
final class UnavailableMedia: CanvasMediaStreaming {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func start(canvasDisplayID: UInt32, onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool) async throws {
        throw Unavailable(description: reason)
    }

    func stop() async {}
    var currentStreamScale: Double { 1 }
    func reconfigure(streamScale: Double) async throws {}
    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) async throws {}
    func requestKeyFrame() async {}
    func refreshStillPicture() async throws -> Int? { nil }
    var currentFramesPerSecond: Int { 0 }
    var currentQualityScale: Double { 1 }
    var frameCounts: HostFrameCounts { HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0) }
}
#endif
