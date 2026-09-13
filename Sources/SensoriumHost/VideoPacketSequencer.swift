import SensoriumCore
import Foundation

/// Assigns a monotonic sequence number to host encoder output. Decoder
/// configuration is sent only on keyframes, which form recovery boundaries.
public final class VideoPacketSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0

    public init() {}

    public func packet(
        presentationTimeNanoseconds: UInt64,
        isKeyFrame: Bool,
        codecConfiguration: Data?,
        payload: Data
    ) -> EncodedVideoFramePacket {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence &+= 1
        return EncodedVideoFramePacket(
            sequence: sequence,
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            isKeyFrame: isKeyFrame,
            codecConfiguration: isKeyFrame ? codecConfiguration : nil,
            payload: payload
        )
    }
}
