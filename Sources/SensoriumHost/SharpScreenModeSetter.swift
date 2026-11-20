import Foundation

/// One display mode macOS reports for the sharp screen. `id` names it only
/// to the `SharpScreenModeSetting` that listed it.
public struct SharpScreenMode: Equatable, Sendable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(id: Int, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The sharp screen's display modes, and the one change made to them: its
/// mode is set once, right after it is created. Nothing is put back, since
/// the display itself is destroyed when it is released. A seam rather than
/// direct CoreGraphics calls so that is verified against a fake.
@MainActor
public protocol SharpScreenModeSetting: AnyObject {
    /// Every mode macOS reports for this display, low-resolution duplicates
    /// included, that the desktop can use.
    func modes(for displayID: UInt32) -> [SharpScreenMode]
    /// Sets the display to `modeID`, which must be one the last
    /// `modes(for:)` for this display returned. `false` means it was not set.
    func set(modeID: Int, on displayID: UInt32) -> Bool
}
