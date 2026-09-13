import Foundation

/// The EDID-style identity a session canvas presents to macOS.
///
/// macOS keys arrangement, per-display settings and colour profiles on this
/// triple, so two live canvases sharing one identity gives it nothing to tell
/// them apart. Only `serialNumber` varies: the canvases really are one model
/// from one vendor, and claiming otherwise through `productID` would be a lie
/// about the hardware rather than a distinction between two units of it.
///
/// The serial is a pure function of the surface index and nothing else — not
/// the connection, not the session, not the process. A serial that changed per
/// session would make macOS meet a brand-new display on every reconnect and
/// forget where the user had put the last one; deriving it from the index
/// keeps surface 0 recognisably surface 0 across a disconnect, a reconnect and
/// a host restart, which is what a workstation the user returns to all day
/// needs.
public struct CanvasDisplayIdentity: Equatable, Sendable {
    /// Unregistered, and deliberately so: Sensorium is not a display vendor,
    /// and borrowing a real vendor's ID would misattribute these canvases to
    /// hardware that does not exist. macOS only needs the triple to be
    /// distinct, never registered.
    public static let vendorID: UInt32 = 0x434C
    public static let productID: UInt32 = 1

    /// Alternative serials are a whole stride apart, so no surface's
    /// alternative can ever be another surface's serial -- there are two
    /// surfaces and the stride is far wider than that.
    public static let attemptStride: UInt32 = 16

    /// The last attempt whose serial still fits the field macOS reads it from.
    /// Far beyond any sequence `CanvasIdentityFallback` produces, and here so
    /// that an identity exists for every attempt a caller can name rather than
    /// the arithmetic ending the process on one it cannot represent.
    public static let maximumAttempt =
        Int((UInt32.max - UInt32(CanvasSurfaceID.capacity)) / attemptStride)

    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    /// Which identity in this surface's fallback sequence this is, counting
    /// from 0 -- `CanvasIdentityFallback` is what produces them. Never
    /// negative and never past `maximumAttempt`, whatever was asked for.
    public let attempt: Int

    /// Serial 1 is surface 0, which is the serial the single-canvas host has
    /// always presented; the second canvas takes the next one.
    ///
    /// `attempt` defaults to 0 because that is the stable identity described
    /// above, and the only one used when nothing is wrong. A later attempt is
    /// asked for only after macOS has refused the ones before it, which
    /// happens when a canvas an earlier host left behind still holds the
    /// stable identity; see `CanvasIdentityFallback`.
    ///
    /// `attempt` is clamped into `0...maximumAttempt`, so an out-of-range
    /// caller gets an identity rather than a trapped host.
    public init(surface: CanvasSurfaceID, attempt: Int = 0) {
        let bounded = min(UInt32(clamping: attempt), UInt32(Self.maximumAttempt))
        vendorID = Self.vendorID
        productID = Self.productID
        serialNumber = UInt32(surface.index) + 1 + bounded * Self.attemptStride
        self.attempt = Int(bounded)
    }
}
