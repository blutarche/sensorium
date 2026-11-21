#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

extension CanvasKeyConfinement {
    /// Turns `CGWindowListCopyWindowInfo`'s dictionaries into the scan's own
    /// terms. Separate from the call that produces them so the parsing -- in
    /// particular that nothing here filters by `kCGWindowLayer` -- is
    /// assertable without asking WindowServer for anything.
    ///
    /// Every entry is kept. A floating panel sits above layer 0, so a
    /// layer-0-only scan would not see a keyed panel standing on a physical
    /// display as outside the canvas; it would not see it at all, the scan
    /// would pass, and the key would be posted onto a real monitor.
    ///
    /// An entry whose bounds or owner cannot be read is kept too, as a null
    /// rectangle no canvas contains, so a malformed entry refuses the key
    /// rather than disappearing from the check.
    public nonisolated static func windows(from info: [[String: Any]]) -> [ScannedWindow] {
        info.map { entry in
            ScannedWindow(
                processIdentifier: (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1,
                bounds: bounds(from: entry[kCGWindowBounds as String])
            )
        }
    }

    private nonisolated static func bounds(from value: Any?) -> CGRect {
        guard let dictionary = value as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
            return .null
        }
        return rect
    }
}

/// The real scan: `NSWorkspace`'s frontmost application, and WindowServer's
/// on-screen window list.
///
/// Needs no Accessibility grant. `CGWindowListCopyWindowInfo` is a WindowServer
/// query, so revoking Accessibility breaks the launcher's ability to *move* a
/// window onto the canvas, and must not break typing into a window already
/// standing there. The two are deliberately not coupled.
///
/// `.optionOnScreenOnly` omits windows on other Spaces. `.optionAll` would
/// close that hole and was rejected on measurement: it enumerates every app's
/// off-screen windows, so every application tested -- ten of them -- had at
/// least one window outside the canvas and would have been permanently
/// untypeable.
@MainActor
public final class CoreGraphicsFrontmostWindowScan: FrontmostWindowScanning {
    public init() {}

    public func scan() -> FrontmostWindowScan {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        return FrontmostWindowScan(
            frontmostProcessIdentifier: frontmost,
            onScreenWindows: CanvasKeyConfinement.windows(from: info ?? [])
        )
    }
}
#endif
