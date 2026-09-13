import SensoriumCore

/// Admits encoded video frames only after a recovery keyframe and retains
/// the newest usable frame for decoding, never a growing backlog.
public actor VideoFrameIngress {
    private let frames = LatestFrameBuffer<EncodedVideoFramePacket>()
    private var hasRecoveryKeyFrame = false
    private var newestSequence: UInt64?

    public init() {}

    public func receive(_ frame: EncodedVideoFramePacket) async {
        if let newestSequence, frame.sequence <= newestSequence {
            return
        }
        guard hasRecoveryKeyFrame || frame.isKeyFrame else {
            return
        }
        if frame.isKeyFrame {
            hasRecoveryKeyFrame = true
        }
        newestSequence = frame.sequence
        await frames.push(frame)
    }

    public func takeNewest() async -> EncodedVideoFramePacket? {
        await frames.takeNewest()
    }

    public func reset() {
        hasRecoveryKeyFrame = false
        newestSequence = nil
    }
}

/// One `VideoFrameIngress` per surface. Each host-side surface packetizes
/// independently and starts its own sequence at 0, so sharing a single
/// ingress across surfaces would make one surface's frames look stale
/// against the other's; sharing `hasRecoveryKeyFrame` would let one
/// surface's keyframe wrongly unblock the other's undecodable deltas.
///
/// Fixed at two slots, matching the `{0, 1}` surfaceID cap: a surfaceID
/// outside that range is dropped rather than used to grow storage.
public actor SurfaceVideoIngress {
    private let ingresses: [VideoFrameIngress] = [VideoFrameIngress(), VideoFrameIngress()]

    public init() {}

    public func receive(surfaceID: UInt32, frame: EncodedVideoFramePacket) async {
        guard let index = Self.index(for: surfaceID) else { return }
        await ingresses[index].receive(frame)
    }

    public func takeNewest(surfaceID: UInt32) async -> EncodedVideoFramePacket? {
        guard let index = Self.index(for: surfaceID) else { return nil }
        return await ingresses[index].takeNewest()
    }

    public func reset() async {
        for ingress in ingresses {
            await ingress.reset()
        }
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}
