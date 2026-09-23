import Foundation

public protocol SensoriumControlTransport: Sendable {
    func send(_ message: SensoriumMessage) async throws
    /// The next packet exactly as it came off the wire, control or media, with
    /// nothing skipped. This is the only read a conformer implements: the
    /// control-message and media views of the stream are both derived from it,
    /// so a fake transport can script an interleaving the real socket produces.
    func receiveWirePacket() async throws -> SensoriumTransportPacket
    /// Non-control packets a control wait stepped over. Shared with the media
    /// loop, which is what makes stepping over them lossless.
    var deferredPackets: DeferredPacketQueue { get }
    /// The SHA-256 of the TLS certificate this link is pinned to, which the
    /// authenticated hello sent over it names and signs. It is the channel
    /// this session is actually on, read from the transport rather than
    /// passed in alongside it, so a hello can never be signed for one host
    /// and sent to another. `nil` is a link with no certificate: the
    /// one-time pairing dial, and a plain TCP connection.
    var pinnedHostCertificateHash: Data? { get }
    func close() async
}

public extension SensoriumControlTransport {
    /// Most transports -- every in-memory and scripted one -- have no
    /// certificate to bind to.
    var pinnedHostCertificateHash: Data? { nil }

    /// The next packet the media loop should process: whatever a control wait
    /// held first, then the wire. Draining the hold first is what keeps the
    /// media loop's view of the stream in the order the peer sent it.
    func receivePacket() async throws -> SensoriumTransportPacket {
        if let held = await deferredPackets.take() {
            return held
        }
        return try await receiveWirePacket()
    }

    /// The next control message, stepping over any media that arrived ahead of
    /// it. One socket carries both, and the host is already streaming a surface
    /// before it answers the next `canvasRequest`, so video between two control
    /// replies is ordinary traffic rather than a peer failure. What is stepped
    /// over is held for the media loop, never dropped: the first frame of a
    /// surface is its recovery keyframe, and losing that leaves the surface
    /// undecodable until the encoder produces another.
    ///
    /// Only the packet kind is tolerated. A control message that is not the
    /// expected reply, a malformed frame, and a stream that ended all still
    /// reach the caller as errors.
    func receive() async throws -> SensoriumMessage {
        while true {
            let packet = try await receiveWirePacket()
            if case let .control(message) = packet {
                return message
            }
            await deferredPackets.hold(packet)
        }
    }
}
