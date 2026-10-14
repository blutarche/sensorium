import CoreGraphics
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

/// The real thing, in public CoreGraphics only: `CGDisplayCopyAllDisplayModes`,
/// and the one configuration transaction `CoreGraphicsHostScreenModeController`
/// sets a mode with, completed `.forSession`.
@MainActor
public final class CoreGraphicsSharpScreenModeSetter: SharpScreenModeSetting {
    /// The modes last listed, by display, so a `modeID` resolves back to the
    /// exact `CGDisplayMode` macOS gave rather than one matched by numbers.
    private var listed: [UInt32: [CGDisplayMode]] = [:]

    public init() {}

    public func modes(for displayID: UInt32) -> [SharpScreenMode] {
        // A mode at 2x is a duplicate of a lower resolution, which macOS
        // omits unless asked.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let raw = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        let usable = raw.filter { $0.isUsableForDesktopGUI() }
        listed[displayID] = usable
        return usable.enumerated().map { index, mode in
            SharpScreenMode(
                id: index,
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight
            )
        }
    }

    public func set(modeID: Int, on displayID: UInt32) -> Bool {
        guard let modes = listed[displayID], modes.indices.contains(modeID) else {
            return false
        }
        return CoreGraphicsHostScreenModeController.set(mode: modes[modeID], on: displayID)
    }
}
