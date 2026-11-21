#if os(Linux)

/// How the granted monitor's coordinates relate to the frames captured from it.
///
/// The portal reports a monitor's `size` in compositor coordinates, which are
/// logical: on a scaled monitor the frames have more pixels than that. Pointer
/// positions are sent back in the same logical space, so a fractional scale
/// maps exactly and needs no rounding here. The scale is the frame's pixel
/// width over the logical width.
public struct PortalCaptureGeometry: Equatable, Sendable {
    /// The PipeWire node absolute pointer motion names.
    public let streamNodeID: UInt32
    public let logicalWidth: Double
    public let logicalHeight: Double
    /// What `displayIdentity` hashes: the stream's `id` when the portal gave
    /// one, and otherwise the monitor's position and size.
    public let identitySeed: String

    public init(streamNodeID: UInt32, logicalWidth: Double, logicalHeight: Double, identitySeed: String) {
        self.streamNodeID = streamNodeID
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.identitySeed = identitySeed
    }

    /// Nil when the portal gave the stream no `size`.
    public init?(stream: PortalStream) {
        guard let size = stream.size, size.width > 0, size.height > 0 else { return nil }
        self.init(
            streamNodeID: stream.nodeID,
            logicalWidth: Double(size.width),
            logicalHeight: Double(size.height),
            identitySeed: Self.identitySeed(for: stream, size: size)
        )
    }

    /// For a stream the portal gave no size: the first frame's pixel size
    /// stands in for the logical size, which is right at scale 1 and the best
    /// available otherwise.
    public init(stream: PortalStream, firstFrameWidth: Int, firstFrameHeight: Int) {
        let size = PortalSize(width: Int32(clamping: firstFrameWidth), height: Int32(clamping: firstFrameHeight))
        self.init(
            streamNodeID: stream.nodeID,
            logicalWidth: Double(firstFrameWidth),
            logicalHeight: Double(firstFrameHeight),
            identitySeed: Self.identitySeed(for: stream, size: size)
        )
    }

    private static func identitySeed(for stream: PortalStream, size: PortalSize) -> String {
        if let id = stream.id, !id.isEmpty {
            return id
        }
        let position = stream.position ?? PortalPoint(x: 0, y: 0)
        return "\(position.x),\(position.y),\(size.width)x\(size.height)"
    }

    /// Frame pixels per logical point, along x.
    public func backingScale(bufferWidth: Int) -> Double {
        Double(bufferWidth) / logicalWidth
    }

    /// A stable non-zero 32-bit identity for `hostScreenList`: FNV-1a of
    /// `identitySeed`.
    public var displayIdentity: UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in identitySeed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }

    /// `(x, y)` pulled inside the monitor. The right and bottom edges belong
    /// to the next monitor, so the far limit is a hair inside them; 1/64 is
    /// exact in binary.
    public func clamped(x: Double, y: Double) -> (x: Double, y: Double) {
        let inset = 1.0 / 64
        return (
            min(max(x, 0), logicalWidth - inset),
            min(max(y, 0), logicalHeight - inset)
        )
    }
}

#endif
