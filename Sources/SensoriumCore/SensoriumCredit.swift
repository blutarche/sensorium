import Foundation

/// The author and license credited in each shipped app's About panel, kept
/// in one place so the viewer and the host show the identical line.
public enum SensoriumCredit {
    public static let author = "blutarche"
    public static let license = "GPL-3.0"
    public static let copyrightLine = "\u{00A9} 2026 blutarche \u{00B7} GPL-3.0"
}

#if canImport(AppKit)
import AppKit

public extension SensoriumCredit {
    /// Options for `NSApplication.orderFrontStandardAboutPanel(options:)` --
    /// built here rather than left to Info.plist alone, so the credit shows
    /// even when the running binary is unbundled and has no Info.plist to
    /// read it from.
    static var standardAboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [.credits: NSAttributedString(string: copyrightLine)]
    }
}
#endif
