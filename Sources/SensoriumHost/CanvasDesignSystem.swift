import AppKit
import CoreGraphics
import Foundation

/// One colour of the Blutarche Studio design system, stored as the sRGB
/// components of the `#RRGGBB` literal `docs/design-system.md` records.
///
/// Deliberately not an `NSColor`: AppKit's semantic colours resolve against
/// this machine's own appearance, and a palette that moves with the machine
/// is not a palette. Everything the host draws on the session canvas comes
/// from here.
public struct DesignColor: Equatable, Sendable {
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

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The same colour at a different alpha. The system writes `accent-soft`,
    /// `accent-bd` and `selection` as `rgba` on the accent's own channels;
    /// typing that hex out four times is four chances to mistype one of them.
    public func withAlpha(_ alpha: Double) -> DesignColor {
        DesignColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        nsColor.cgColor
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
/// bind them — dark only, borders instead of shadows, sharp radii.
public enum CanvasDesign {
    // MARK: - Workspace surfaces

    public static let bg = DesignColor(hex: 0x0A0A0C)
    public static let bg2 = DesignColor(hex: 0x121216)
    public static let bg3 = DesignColor(hex: 0x1A1A20)
    public static let bg4 = DesignColor(hex: 0x24242C)

    // MARK: - Chrome

    /// The shell's housing, deliberately a shade apart from the workspace
    /// surfaces above.
    public static let chromeBg = DesignColor(hex: 0x07070A)
    public static let chromeBg2 = DesignColor(hex: 0x0E0E14)
    public static let chromeBgHover = DesignColor(hex: 0x14141A)
    public static let chromeBorder = DesignColor(hex: 0x18181E)
    public static let chromeBorder2 = DesignColor(hex: 0x1F1F26)
    public static let chromeInk = DesignColor(hex: 0xE8E5DE)
    public static let chromeInk2 = DesignColor(hex: 0xC8C5BD)
    public static let chromeMuted = DesignColor(hex: 0x8A8A92)
    public static let chromeMuted2 = DesignColor(hex: 0x5A5A63)

    // MARK: - Lines

    public static let line = DesignColor(hex: 0x24242C)
    public static let line2 = DesignColor(hex: 0x34343F)
    public static let lineHi = DesignColor(hex: 0x43434F)

    // MARK: - Text

    public static let ink = DesignColor(hex: 0xF2EFEA)
    public static let ink2 = DesignColor(hex: 0xC8C5BD)
    public static let muted = DesignColor(hex: 0x8C8C94)
    public static let muted2 = DesignColor(hex: 0x5A5A63)
    public static let muted3 = DesignColor(hex: 0x3A3A44)

    // MARK: - Accent

    /// Selection, focus and active state only. Anywhere else it is decoration.
    public static let accent = DesignColor(hex: 0x7C70F5)
    public static let accentHi = DesignColor(hex: 0x9088F8)
    public static let accentDeep = DesignColor(hex: 0x5A4FC0)
    public static let accentSoft = accent.withAlpha(0.10)
    public static let accentBorder = accent.withAlpha(0.30)
    public static let selection = accent.withAlpha(0.32)

    /// Secondary accent, soft pink: data-viz highlights and the badge border
    /// gradient; never competes with the primary accent for actions.
    public static let accent2 = DesignColor(hex: 0xF0A8D0)
    public static let accent2Hi = DesignColor(hex: 0xF5BFE0)
    public static let accent2Deep = DesignColor(hex: 0xC87AAA)
    public static let accent2Soft = accent2.withAlpha(0.10)
    public static let accent2Border = accent2.withAlpha(0.30)

    // MARK: - Status

    public static let ok = DesignColor(hex: 0x6FBE83)
    public static let bad = DesignColor(hex: 0xE26F5C)
    public static let info = DesignColor(hex: 0x8EE0E8)
    public static let warn = DesignColor(hex: 0xE0B85D)

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
    public static func eyebrow(_ text: String, color: DesignColor = CanvasDesign.muted2, size: CGFloat = 12) -> NSAttributedString {
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
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
        layer?.borderWidth = border == nil ? 0 : 1
        layer?.borderColor = border?.cgColor
    }
}
