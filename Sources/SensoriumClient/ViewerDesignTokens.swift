#if canImport(AppKit)
import AppKit

/// What a `ViewerColor` is to AppKit. The values themselves are
/// `ViewerPalette`'s, stated once for every platform this viewer runs on.
///
/// Never an AppKit semantic colour. Those resolve against this machine's own
/// appearance, and a palette that moves with the machine is not a palette.
public extension ViewerColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        nsColor.cgColor
    }
}

/// The design tokens the viewer's own chrome draws with, as recorded in
/// `docs/design-system.md`: `ViewerPalette`'s colours, plus the metrics and
/// faces only an AppKit window needs.
public enum ViewerDesign {
    public static let chromeBg = ViewerPalette.chromeBg
    public static let chromeBg2 = ViewerPalette.chromeBg2
    public static let chromeBorder2 = ViewerPalette.chromeBorder2
    public static let bg4 = ViewerPalette.bg4
    public static let line = ViewerPalette.line
    public static let ink = ViewerPalette.ink
    public static let muted = ViewerPalette.muted
    public static let muted2 = ViewerPalette.muted2

    public static let accent = ViewerPalette.accent
    public static let accent2 = ViewerPalette.accent2

    public static let ok = ViewerPalette.ok
    public static let bad = ViewerPalette.bad
    public static let info = ViewerPalette.info
    public static let warn = ViewerPalette.warn

    public typealias Radius = ViewerChromeMetrics.Radius
    public typealias Space = ViewerChromeMetrics.Space

    public enum Tracking {
        public static let snug: CGFloat = -0.015
        public static let widest: CGFloat = 0.22
    }

    public static func kern(_ tracking: CGFloat, size: CGFloat) -> CGFloat {
        tracking * size
    }

    public static func color(for tone: ViewerStatusTone) -> ViewerColor {
        ViewerPalette.color(for: tone)
    }

    /// Read once. Without the membership test `NSFont(descriptor:size:)` hands
    /// back a default face for an unknown family, which would make the
    /// fallback accidental instead of deliberate.
    @MainActor
    private static let installedFamilies = Set(NSFontManager.shared.availableFontFamilies)

    /// Inter for content, JetBrains Mono for labels and data — the two faces
    /// this window needs; the alternate face is reserved for the wordmark.
    @MainActor
    public static func font(mono: Bool, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let family = mono ? "JetBrains Mono" : "Inter"
        if installedFamilies.contains(family) {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
            if let resolved = NSFont(descriptor: descriptor, size: size) {
                return resolved
            }
        }
        return mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
    }
}
#endif
