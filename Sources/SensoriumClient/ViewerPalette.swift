import Foundation
import SensoriumCore

/// One colour in the viewer's own chrome, as `docs/design-system.md` records
/// it, with the value it takes in each appearance. Held as plain components
/// rather than a platform colour: the window layer chooses the appearance, not
/// whatever the machine happens to be set to. Each platform's window layer
/// turns these into whatever it draws with -- an `NSColor` on macOS, a CSS
/// declaration under GTK.
///
/// `red`, `green`, `blue`, `alpha` and `hexString` read the dark value, the
/// one every existing caller draws. `resolved(for:)` and `hexString(for:)`
/// read a named appearance.
public struct ViewerColor: Equatable, Sendable {
    private struct Channels: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        init(hex: UInt32, alpha: Double) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
            self.alpha = alpha
        }
    }

    private let darkChannels: Channels
    private let lightChannels: Channels

    public var red: Double { darkChannels.red }
    public var green: Double { darkChannels.green }
    public var blue: Double { darkChannels.blue }
    public var alpha: Double { darkChannels.alpha }

    /// A colour that reads the same in both appearances.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(dark: hex, light: hex, alpha: alpha)
    }

    public init(dark: UInt32, light: UInt32, alpha: Double = 1) {
        darkChannels = Channels(hex: dark, alpha: alpha)
        lightChannels = Channels(hex: light, alpha: alpha)
    }

    private init(darkChannels: Channels, lightChannels: Channels) {
        self.darkChannels = darkChannels
        self.lightChannels = lightChannels
    }

    private func channels(for appearance: ResolvedAppearance) -> Channels {
        switch appearance {
        case .dark: return darkChannels
        case .light: return lightChannels
        }
    }

    /// The colour as one appearance draws it: its own `red`, `green`, `blue`,
    /// `alpha` and `hexString` are that appearance's, which is what a platform
    /// layer that already knows its appearance passes on to its drawing code.
    public func resolved(for appearance: ResolvedAppearance) -> ViewerColor {
        let chosen = channels(for: appearance)
        return ViewerColor(darkChannels: chosen, lightChannels: chosen)
    }

    /// `#rrggbb`, which every stylesheet language this viewer feeds accepts.
    /// Alpha is left out: it is carried by the one caller that needs it, in
    /// whatever form that caller's own syntax takes.
    public var hexString: String {
        hexString(for: .dark)
    }

    public func hexString(for appearance: ResolvedAppearance) -> String {
        func channel(_ value: Double) -> String {
            String(format: "%02X", Int((value * 255).rounded()))
        }
        let chosen = channels(for: appearance)
        return "#" + channel(chosen.red) + channel(chosen.green) + channel(chosen.blue)
    }

    /// The same colour at a different opacity -- a scrim, a translucent bar,
    /// a dimmed handle -- without a caller reaching for the raw channels.
    /// Each appearance keeps its own colour.
    public func withAlpha(_ alpha: Double) -> ViewerColor {
        var dark = darkChannels
        var light = lightChannels
        dark.alpha = alpha
        light.alpha = alpha
        return ViewerColor(darkChannels: dark, lightChannels: light)
    }
}

/// Every colour the viewer's chrome uses, stated once for both platforms. The
/// host's `CanvasDesignSystem.swift` states the same system for what the host
/// draws on the canvas; this target cannot import `SensoriumHost`.
public enum ViewerPalette {
    public static let chromeBg = ViewerColor(dark: 0x07070A, light: 0xECE9E2)
    public static let chromeBg2 = ViewerColor(dark: 0x0E0E14, light: 0xF3F1EB)
    public static let chromeBorder2 = ViewerColor(dark: 0x1F1F26, light: 0xCCC8BE)
    /// The workspace input fill, `bg-4`. The one surface a text field sits on.
    public static let bg4 = ViewerColor(dark: 0x24242C, light: 0xE0DDD5)
    public static let line = ViewerColor(dark: 0x24242C, light: 0xDAD6CD)
    public static let ink = ViewerColor(dark: 0xF2EFEA, light: 0x1A1917)
    public static let muted = ViewerColor(dark: 0x8C8C94, light: 0x626068)
    public static let muted2 = ViewerColor(dark: 0x5A5A63, light: 0x7C7A82)

    /// Sparingly: selection, focus, active. In the viewer's own chrome that is
    /// the focused field's border and the one button that commits.
    public static let accent = ViewerColor(dark: 0x7C70F5, light: 0x5B4FDB)
    public static let accentHi = ViewerColor(dark: 0x9088F8, light: 0x6A5EEA)
    public static let accent2 = ViewerColor(dark: 0xF0A8D0, light: 0xB8437F)
    /// Behind selected text, under `ink`; the caret is `accentHi`.
    public static let selection = accent.withAlpha(0.32)

    /// Behind the status panel once a picture exists to mark as stale --
    /// the same colour and opacity `ViewerSessionStatusOverlay` fills its own
    /// full-window background with on macOS, `NSColor(srgbRed: 0, green: 0,
    /// blue: 0, alpha: 0.66)`. Black dims either appearance's picture.
    public static let scrim = ViewerColor(hex: 0x000000, alpha: 0.66)

    public static let ok = ViewerColor(dark: 0x6FBE83, light: 0x267340)
    public static let bad = ViewerColor(dark: 0xE26F5C, light: 0xB93A26)
    public static let info = ViewerColor(dark: 0x8EE0E8, light: 0x157383)
    public static let warn = ViewerColor(dark: 0xE0B85D, light: 0x8F6000)

    public static func color(for tone: ViewerStatusTone) -> ViewerColor {
        switch tone {
        case .ok: return ok
        case .info: return info
        case .warn: return warn
        case .bad: return bad
        }
    }
}
