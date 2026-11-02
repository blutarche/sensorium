import AppKit
import CoreGraphics
import Foundation
import SensoriumCore

/// One colour of the Blutarche Studio design system, stored as the sRGB
/// components of the `#RRGGBB` literals `docs/design-system.md` records for
/// the dark and the light appearance.
///
/// Deliberately not a semantic `NSColor`: AppKit's semantic colours follow
/// this machine's own palette, and a palette that moves with the machine is
/// not a palette. The appearance a colour takes is the one the app's setting
/// puts on the window. Everything the host draws comes from here.
///
/// `red`, `green`, `blue` and `alpha` read the dark value, the one every
/// existing caller compares against. `resolved(for:)` reads a named appearance.
public struct DesignColor: Equatable, Sendable {
    fileprivate struct Channels: Hashable, Sendable {
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

        var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
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

    /// The same colour at a different alpha. The system writes `accent-soft`,
    /// `accent-bd` and `selection` as `rgba` on the accent's own channels;
    /// typing that hex out four times is four chances to mistype one of them.
    /// Each appearance keeps its own colour.
    public func withAlpha(_ alpha: Double) -> DesignColor {
        var dark = darkChannels
        var light = lightChannels
        dark.alpha = alpha
        light.alpha = alpha
        return DesignColor(darkChannels: dark, lightChannels: light)
    }

    /// The colour as one appearance draws it: its `red`, `green`, `blue` and
    /// `alpha` are that appearance's.
    public func resolved(for appearance: ResolvedAppearance) -> DesignColor {
        let chosen = appearance == .dark ? darkChannels : lightChannels
        return DesignColor(darkChannels: chosen, lightChannels: chosen)
    }

    /// Picks the dark or light value each time AppKit draws it, so a label
    /// or window background follows an appearance change without being set
    /// again. The same colour always returns the same object: a dynamic
    /// `NSColor` is equal only to itself.
    public var nsColor: NSColor {
        guard darkChannels != lightChannels else { return darkChannels.nsColor }
        return DynamicColorCache.color(dark: darkChannels, light: lightChannels)
    }

    /// A `CGColor` is fixed once made, so this resolves against the drawing
    /// appearance in effect right now. A layer that holds one must set it
    /// again when its view's appearance changes: see
    /// `NSView.resolvingDesignColors(_:)`. `cgColor(in:)` names the appearance.
    public var cgColor: CGColor {
        nsColor.cgColor
    }

    public func cgColor(in appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance { resolved = nsColor.cgColor }
        return resolved ?? nsColor.cgColor
    }
}

/// One dynamic `NSColor` per distinct dark and light pair. The set is as small
/// as the palette: the tokens, and the few opacities derived from them.
private enum DynamicColorCache {
    private struct Key: Hashable {
        let dark: DesignColor.Channels
        let light: DesignColor.Channels
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var colors: [Key: NSColor] = [:]

    static func color(dark: DesignColor.Channels, light: DesignColor.Channels) -> NSColor {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(dark: dark, light: light)
        if let cached = colors[key] { return cached }
        let made = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark.nsColor : light.nsColor
        }
        colors[key] = made
        return made
    }
}

/// The three faces the system names. This repository bundles and installs no
/// fonts, so whether a family is present is a property of the machine; when one
/// is absent `font(_:size:weight:)` resolves a deliberate system fallback at the
/// same size and weight rather than whatever AppKit picks for an unknown family.
public enum DesignTypeface: Sendable {
    /// Inter. Primary UI text.
    case primary
    /// Space Grotesk. The alternate display voice.
    case alternate
    /// JetBrains Mono. Labels, keyboard hints, data, code.
    case mono

    var familyName: String {
        switch self {
        case .primary: return "Inter"
        case .alternate: return "Space Grotesk"
        case .mono: return "JetBrains Mono"
        }
    }
}

/// The design system's tokens, as the host's on-canvas UI uses them.
/// See `docs/design-system.md` for the tokens themselves and the rules that
/// bind them -- a dark and a light appearance, borders instead of shadows,
/// sharp radii.
public enum CanvasDesign {
    // MARK: - Workspace surfaces

    public static let bg = DesignColor(dark: 0x0A0A0C, light: 0xF5F3EE)
    public static let bg2 = DesignColor(dark: 0x121216, light: 0xFBFAF7)
    public static let bg3 = DesignColor(dark: 0x1A1A20, light: 0xEAE7E0)
    public static let bg4 = DesignColor(dark: 0x24242C, light: 0xE0DDD5)

    // MARK: - Chrome

    /// The shell's housing, deliberately a shade apart from the workspace
    /// surfaces above.
    public static let chromeBg = DesignColor(dark: 0x07070A, light: 0xECE9E2)
    public static let chromeBg2 = DesignColor(dark: 0x0E0E14, light: 0xF3F1EB)
    public static let chromeBgHover = DesignColor(dark: 0x14141A, light: 0xE3E0D8)
    public static let chromeBorder = DesignColor(dark: 0x18181E, light: 0xD6D2C9)
    public static let chromeBorder2 = DesignColor(dark: 0x1F1F26, light: 0xCCC8BE)
    public static let chromeInk = DesignColor(dark: 0xE8E5DE, light: 0x1E1D1A)
    public static let chromeInk2 = DesignColor(dark: 0xC8C5BD, light: 0x46433E)
    public static let chromeMuted = DesignColor(dark: 0x8A8A92, light: 0x5F5E64)
    public static let chromeMuted2 = DesignColor(dark: 0x5A5A63, light: 0x777680)

    // MARK: - Lines

    public static let line = DesignColor(dark: 0x24242C, light: 0xDAD6CD)
    public static let line2 = DesignColor(dark: 0x34343F, light: 0xC6C2B8)
    public static let lineHi = DesignColor(dark: 0x43434F, light: 0xAAA69B)

    // MARK: - Text

    public static let ink = DesignColor(dark: 0xF2EFEA, light: 0x1A1917)
    public static let ink2 = DesignColor(dark: 0xC8C5BD, light: 0x433F3A)
    public static let muted = DesignColor(dark: 0x8C8C94, light: 0x626068)
    public static let muted2 = DesignColor(dark: 0x5A5A63, light: 0x7C7A82)
    public static let muted3 = DesignColor(dark: 0x3A3A44, light: 0xB3B0A8)

    // MARK: - Accent

    /// Selection, focus and active state only. Anywhere else it is decoration.
    /// The light accent is already the deep variant, so it reads as text on a
    /// light surface.
    public static let accent = DesignColor(dark: 0x7C70F5, light: 0x5B4FDB)
    public static let accentHi = DesignColor(dark: 0x9088F8, light: 0x6A5EEA)
    public static let accentDeep = DesignColor(dark: 0x5A4FC0, light: 0x4338A8)
    public static let accentSoft = accent.withAlpha(0.10)
    public static let accentBorder = accent.withAlpha(0.30)
    public static let selection = accent.withAlpha(0.32)

    /// Secondary accent, soft pink: data-viz highlights and the badge border
    /// gradient; never competes with the primary accent for actions.
    public static let accent2 = DesignColor(dark: 0xF0A8D0, light: 0xB8437F)
    public static let accent2Hi = DesignColor(dark: 0xF5BFE0, light: 0xC0508C)
    public static let accent2Deep = DesignColor(dark: 0xC87AAA, light: 0x9A3366)
    public static let accent2Soft = accent2.withAlpha(0.10)
    public static let accent2Border = accent2.withAlpha(0.30)

    // MARK: - Status

    public static let ok = DesignColor(dark: 0x6FBE83, light: 0x267340)
    public static let bad = DesignColor(dark: 0xE26F5C, light: 0xB93A26)
    public static let info = DesignColor(dark: 0x8EE0E8, light: 0x157383)
    public static let warn = DesignColor(dark: 0xE0B85D, light: 0x8F6000)

    // MARK: - Metrics

    /// Intentionally sharp. Nothing in this system is rounder than 6.
    public enum Radius {
        public static let none: CGFloat = 0
        public static let tight: CGFloat = 2
        public static let base: CGFloat = 4
        public static let wide: CGFloat = 6
    }

    /// The 4px grid. Every gap and inset in the host UI is one of these.
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 40
        public static let huge: CGFloat = 48
        public static let giant: CGFloat = 64
    }

    // MARK: - Type

    /// Letter-spacing in `em`. AppKit has no relative unit, so `kern` converts.
    public enum Tracking {
        public static let tight: CGFloat = -0.03
        public static let snug: CGFloat = -0.015
        public static let normal: CGFloat = 0
        public static let wide: CGFloat = 0.06
        public static let wider: CGFloat = 0.12
        public static let widest: CGFloat = 0.22
    }

    /// `letter-spacing` is relative to the font size; `NSAttributedString.Key.kern`
    /// is absolute points.
    public static func kern(_ tracking: CGFloat, size: CGFloat) -> CGFloat {
        tracking * size
    }

    /// Families installed on this machine, read once. Absent Inter, Space
    /// Grotesk and JetBrains Mono, `NSFont(descriptor:size:)` would silently
    /// hand back a default face; the membership test is what makes the
    /// fallback below deliberate rather than accidental.
    @MainActor
    private static let installedFamilies = Set(NSFontManager.shared.availableFontFamilies)

    @MainActor
    public static func font(
        _ face: DesignTypeface,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        if installedFamilies.contains(face.familyName) {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: face.familyName,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
            if let resolved = NSFont(descriptor: descriptor, size: size) {
                return resolved
            }
        }
        switch face {
        case .primary, .alternate:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// The system's `h6`: uppercase mono, 12px, `widest` tracking, muted.
    /// `size` departs from 12 only where the surface itself is smaller
    /// than a window, such as the host-screen badge.
    @MainActor
    public static func eyebrow(_ text: String, color: DesignColor = CanvasDesign.muted, size: CGFloat = 12) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: font(.mono, size: size, weight: .medium),
                .foregroundColor: color.nsColor,
                .kern: kern(Tracking.widest, size: size)
            ]
        )
    }

    /// A sentence in the primary face, with each run of digits swapped to a
    /// monospaced-digit font so a changing count (a countdown's seconds, a
    /// pairing code's minutes) never shifts the width of the digits beside
    /// it as they tick over.
    @MainActor
    public static func textWithTabularDigits(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: DesignColor,
        tracking: CGFloat = Tracking.normal,
        alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font(.primary, size: size, weight: weight),
                .foregroundColor: color.nsColor,
                .kern: kern(tracking, size: size),
                .paragraphStyle: paragraph
            ]
        )
        let tabularDigitFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let characters = text as NSString
        var index = 0
        while index < characters.length {
            guard let scalar = Unicode.Scalar(characters.character(at: index)), CharacterSet.decimalDigits.contains(scalar) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.length,
                  let nextScalar = Unicode.Scalar(characters.character(at: end)),
                  CharacterSet.decimalDigits.contains(nextScalar) {
                end += 1
            }
            result.addAttribute(.font, value: tabularDigitFont, range: NSRange(location: index, length: end - index))
            index = end
        }
        return result
    }

    /// The product name, and the only place the alternate face is used -- see
    /// the face assignment note in `docs/design-system.md` before moving it to
    /// the body face.
    @MainActor
    public static func wordmark(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font(.alternate, size: 14, weight: .medium),
                .foregroundColor: ink2.nsColor,
                .kern: kern(Tracking.snug, size: 14)
            ]
        )
    }
}

extension NSView {
    /// Borders and background colour, never elevation — the system forbids
    /// shadows outright, so this is the whole of how a surface is set apart.
    @MainActor
    func applyDesignSurface(fill: DesignColor, border: DesignColor? = nil, radius: CGFloat = CanvasDesign.Radius.base) {
        wantsLayer = true
        resolvingDesignColors {
            layer?.setAppearanceColor(fill.nsColor, for: "backgroundColor")
            layer?.setAppearanceColor(border?.nsColor, for: "borderColor")
        }
        layer?.cornerRadius = radius
        layer?.borderWidth = border == nil ? 0 : 1
    }

    /// Runs `body` with this view's own appearance as the drawing appearance,
    /// so every `DesignColor.cgColor` it reads is the dark or light value this
    /// view shows. A layer colour does not follow an appearance change on its
    /// own: call this from `viewDidChangeEffectiveAppearance()` and set each
    /// layer colour again inside it.
    @MainActor
    public func resolvingDesignColors(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }
}

@MainActor
public extension CanvasDesign {
    static func refreshAppearance() {
        for window in NSApplication.shared.windows {
            if let content = window.contentView { AppearanceLayerColors.refresh(in: content) }
        }
    }
}
