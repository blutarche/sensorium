#if canImport(AppKit)
import AppKit

/// The design tokens the viewer's own chrome draws with, as recorded
/// in `docs/design-system.md`. A second statement of the same values: the
/// host's `CanvasDesignSystem.swift` states them for what the host draws on the
/// canvas, and this target cannot import `SensoriumHost`.
///
/// Never an AppKit semantic colour. Those resolve against this machine's own
/// appearance, and a palette that moves with the machine is not a palette.
public struct ViewerColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        nsColor.cgColor
    }
}

public enum ViewerDesign {
    public static let chromeBg = ViewerColor(hex: 0x07070A)
    public static let chromeBg2 = ViewerColor(hex: 0x0E0E14)
    public static let chromeBorder2 = ViewerColor(hex: 0x1F1F26)
    /// The workspace input fill, `bg-4`. The one surface a text field sits on.
    public static let bg4 = ViewerColor(hex: 0x24242C)
    public static let line = ViewerColor(hex: 0x24242C)
    public static let ink = ViewerColor(hex: 0xF2EFEA)
    public static let muted = ViewerColor(hex: 0x8C8C94)
    public static let muted2 = ViewerColor(hex: 0x5A5A63)

    /// Sparingly: selection, focus, active. In the viewer's own chrome that is
    /// the focused field's border and the one button that commits.
    public static let accent = ViewerColor(hex: 0x7C70F5)
    public static let accent2 = ViewerColor(hex: 0xF0A8D0)

    public static let ok = ViewerColor(hex: 0x6FBE83)
    public static let bad = ViewerColor(hex: 0xE26F5C)
    public static let info = ViewerColor(hex: 0x8EE0E8)
    public static let warn = ViewerColor(hex: 0xE0B85D)

    /// Intentionally sharp; nothing in this system is rounder than 6.
    public enum Radius {
        public static let tight: CGFloat = 2
        public static let base: CGFloat = 4
    }

    /// The 4px grid.
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
    }

    public enum Tracking {
        public static let snug: CGFloat = -0.015
        public static let widest: CGFloat = 0.22
    }

    public static func kern(_ tracking: CGFloat, size: CGFloat) -> CGFloat {
        tracking * size
    }

    public static func color(for tone: ViewerStatusTone) -> ViewerColor {
        switch tone {
        case .ok: return ok
        case .info: return info
        case .warn: return warn
        case .bad: return bad
        }
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
