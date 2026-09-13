/// Holds non-control packets a control wait stepped over, in arrival order,
/// until the media loop drains them.
///
/// The host is already streaming the first surface while it answers the
/// second surface's `canvasRequest`, so video reaches the client between two
/// control replies while it is still handshaking. Discarding those packets is
/// not safe: the first
/// frame of a surface is the recovery keyframe, and `VideoFrameIngress` admits
/// nothing until one arrives, so losing it leaves that surface undecodable
/// until the encoder's next keyframe. Holding them hands the media loop exactly
/// the sequence the socket would have.
public actor DeferredPacketQueue {
    /// Two seconds of two 60 fps surfaces. The handshake it covers is already
    /// bounded by `connect`'s deadline, so this exists for the peer that
    /// streams and never answers rather than for any healthy session.
    public static let capacity = 240

    private var packets: [SensoriumTransportPacket] = []
    /// Packets the queue had to drop because compaction could not free a slot.
    /// Non-zero means some surface lost frames it needed; nothing here can
    /// recover them, so it is reported rather than hidden.
    public private(set) var droppedPacketCount = 0

    public init() {}

    public var count: Int { packets.count }

    public func hold(_ packet: SensoriumTransportPacket) {
        packets.append(packet)
        guard packets.count > Self.capacity else {
            return
        }
        compact()
        if packets.count > Self.capacity {
            packets.removeFirst()
            droppedPacketCount += 1
        }
    }

    public func take() -> SensoriumTransportPacket? {
        packets.isEmpty ? nil : packets.removeFirst()
    }

    /// Frames a later keyframe for the same surface supersedes are dead weight:
    /// the decoder recovers from that keyframe alone, so dropping what precedes
    /// it costs the surface nothing. Only a queue holding no keyframe at all has
    /// nothing spare to give up.
    private func compact() {
        var newestKeyFrameIndex: [UInt32: Int] = [:]
        for (index, packet) in packets.enumerated() {
            guard let video = Self.videoFrame(packet), video.frame.isKeyFrame else {
                continue
            }
            newestKeyFrameIndex[video.surfaceID] = index
        }
        guard !newestKeyFrameIndex.isEmpty else {
            return
        }
        packets = packets.enumerated().filter { index, packet in
            guard let video = Self.videoFrame(packet),
                  let keyFrameIndex = newestKeyFrameIndex[video.surfaceID] else {
                return true
            }
            return index >= keyFrameIndex
        }.map(\.element)
    }

    /// Tag 1 carries no surfaceID; it is surface 0, exactly as the media loop
    /// treats it.
    private static func videoFrame(
        _ packet: SensoriumTransportPacket
    ) -> (surfaceID: UInt32, frame: EncodedVideoFramePacket)? {
        switch packet {
        case let .video(frame):
            return (0, frame)
        case let .videoForSurface(surfaceID, frame):
            return (surfaceID, frame)
        case .control, .clipboard, .unrecognized:
            return nil
        }
    }
}
