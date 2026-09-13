/// Guards the packet stream across an encoder rebuild.
///
/// A resolution change replaces the `VTCompressionSession`, and with it the
/// H.264 SPS/PPS that describe the picture size. The viewer's decoder only
/// learns the new parameter sets from a keyframe — `EncodedVideoFramePacket`
/// carries `codecConfiguration` on keyframes alone — so a delta that reached
/// it first would be decoded against the previous resolution's format
/// description and come out as garbage, or fail outright.
///
/// A new compression session emits an IDR first, so this rarely fires; the
/// failure it prevents is a corrupted picture rather than a clean error.
public struct EncoderGenerationGate: Sendable {
    private var awaitsKeyFrame = true

    public init() {}

    /// Call the moment the encoder is replaced, before any of its output can
    /// be packetized.
    public mutating func beginNewGeneration() {
        awaitsKeyFrame = true
    }

    /// `false` for a delta the viewer could not decode yet. Such a frame must
    /// be dropped, not sent.
    public mutating func admits(keyFrame: Bool) -> Bool {
        guard awaitsKeyFrame else {
            return true
        }
        guard keyFrame else {
            return false
        }
        awaitsKeyFrame = false
        return true
    }
}
