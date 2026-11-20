#if os(macOS)
import CoreGraphics
import Foundation

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
#endif
