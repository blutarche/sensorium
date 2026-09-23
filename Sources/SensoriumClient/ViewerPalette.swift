import Foundation

/// One colour in the viewer's own chrome, as `docs/design-system.md` records
/// it. Held as plain components rather than a platform colour: a palette that
/// resolves against whatever appearance the machine is set to is not a
/// palette. Each platform's window layer turns these into whatever it draws
/// with -- an `NSColor` on macOS, a CSS declaration under GTK.
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

    /// `#rrggbb`, which every stylesheet language this viewer feeds accepts.
    /// Alpha is left out: it is carried by the one caller that needs it, in
    /// whatever form that caller's own syntax takes.
    public var hexString: String {
        func channel(_ value: Double) -> String {
            String(format: "%02X", Int((value * 255).rounded()))
        }
        return "#" + channel(red) + channel(green) + channel(blue)
    }
}

/// Every colour the viewer's chrome uses, stated once for both platforms. The
/// host's `CanvasDesignSystem.swift` states the same system for what the host
/// draws on the canvas; this target cannot import `SensoriumHost`.
public enum ViewerPalette {
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

    public static func color(for tone: ViewerStatusTone) -> ViewerColor {
        switch tone {
        case .ok: return ok
        case .info: return info
        case .warn: return warn
        case .bad: return bad
        }
    }
}
