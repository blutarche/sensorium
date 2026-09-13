import Foundation
import SensoriumCore

/// Everything one arriving video packet costs the thread that read it:
/// deciding which surface it belongs to, counting its bytes, and handing it to
/// that surface's decoder.
///
/// A type of its own, holding no socket and no window, for two reasons. The
/// receive loop it was taken out of cannot be verified at all — it owns a live
/// connection — and every step here must stay off the main actor, which is a
/// property a test can only check by blocking the main actor and watching a
/// packet arrive anyway.
public struct ReceivedVideoDispatch: Sendable {
    private let statistics: ClientStreamStatistics
    private let router: SurfaceFrameRouter

    public init(statistics: ClientStreamStatistics, router: SurfaceFrameRouter) {
        self.statistics = statistics
        self.router = router
    }

    /// Which surface a video packet belongs to. Tag 1 carries no surfaceID at
    /// all and is surface 0, which is what keeps a single-canvas stream on the
    /// wire shape a host that never heard of `surfaceID` sends; tag 2 carries
    /// its own. Anything that is not video has no routing here.
    public static func routing(
        for packet: SensoriumTransportPacket
    ) -> (surfaceID: UInt32, frame: EncodedVideoFramePacket)? {
        switch packet {
        case let .video(frame):
            return (surfaceID: 0, frame: frame)
        case let .videoForSurface(surfaceID, frame):
            return (surfaceID: surfaceID, frame: frame)
        case .control, .clipboard, .unrecognized:
            return nil
        }
    }

    /// Takes one packet off the read path. Returns whether it was video this
    /// dispatch had somewhere to send; a control or clipboard packet is not
    /// this type's business and is reported as untaken so the caller handles
    /// it itself.
    @discardableResult
    public func dispatch(
        _ packet: SensoriumTransportPacket,
        receivedAtNanoseconds: Int64
    ) async throws -> Bool {
        guard let routing = Self.routing(for: packet) else {
            return false
        }
        statistics.recordReceivedVideo(
            surfaceID: routing.surfaceID,
            byteCount: routing.frame.payload.count + (routing.frame.codecConfiguration?.count ?? 0),
            atNanoseconds: receivedAtNanoseconds
        )
        try await router.route(
            surfaceID: routing.surfaceID,
            frame: routing.frame,
            receivedAtNanoseconds: receivedAtNanoseconds
        )
        return true
    }
}
