import Foundation

/// A surface's logical size and backing scale — the two numbers that say how
/// big it looks and how many real pixels back it, independent of which
/// `CaptureIntent` produced it. Used wherever a surface's size is meant
/// rather than a canvas this host created; see docs/host-screen-design.md
/// §1.
///
/// `backingScale` is a ratio, not `VirtualCanvasConfiguration`'s fixed
/// integer `1` or `2`: a physical display's backing scale is whatever
/// `DisplayInventory` reports for it (docs/host-screen-design.md §5.1),
/// which host-screen mode must be able to represent exactly, including
/// values a session canvas never has.
public struct SessionSurfaceGeometry: Equatable, Codable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let backingScale: Double

    public init(logicalWidth: Int, logicalHeight: Int, backingScale: Double) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingScale = backingScale
    }

    /// The session canvas's fixed geometry, equal in every field to
    /// `VirtualCanvasConfiguration.remoteDefault`.
    public static let sessionCanvasDefault = Self(
        logicalWidth: 1920, logicalHeight: 1200, backingScale: 2.0
    )
}
