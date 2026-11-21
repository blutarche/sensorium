#if os(Linux)
import Foundation

/// A colour of the design system with the value it takes in each appearance.
struct HostWindowColor {
    let dark: UInt32
    let light: UInt32

    func hex(_ appearance: IndicatorAppearance) -> UInt32 {
        appearance == .dark ? dark : light
    }

    func css(_ appearance: IndicatorAppearance) -> String {
        String(format: "#%06X", hex(appearance))
    }

    func rgb(_ appearance: IndicatorAppearance) -> (red: Double, green: Double, blue: Double) {
        let value = hex(appearance)
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// The tokens of `docs/design-system.md` the host windows draw with. Windows
/// take the same values as the live-session pill, which states them in the
/// same way, and the same ones the macOS host draws on its cards.
enum HostWindowPalette {
    static let chromeBg = HostWindowColor(dark: 0x07070A, light: 0xEDEDF0)
    /// A card's fill.
    static let bg2 = HostWindowColor(dark: 0x121216, light: 0xFFFFFF)
    static let bg3 = HostWindowColor(dark: 0x1A1A20, light: 0xEAEAED)
    /// An input's fill.
    static let bg4 = HostWindowColor(dark: 0x24242C, light: 0xDCDCE0)
    /// A hairline, and the border of an outlined control.
    static let line2 = HostWindowColor(dark: 0x34343F, light: 0xBFBFC6)
    static let ink = HostWindowColor(dark: 0xF2EFEA, light: 0x0A0A0C)
    static let muted = HostWindowColor(dark: 0x8C8C94, light: 0x4A4A52)
    static let muted2 = HostWindowColor(dark: 0x5A5A63, light: 0x6C6C74)
    static let accent = HostWindowColor(dark: 0x7C70F5, light: 0x5C51D0)
    static let accentHi = HostWindowColor(dark: 0x9088F8, light: 0x5047B8)
    static let warn = HostWindowColor(dark: 0xE0B85D, light: 0x8F6000)
    static let bad = HostWindowColor(dark: 0xE26F5C, light: 0xB93A26)
    /// The title on a filled accent, status or Stop button, and the knob of a
    /// switch.
    static let onFill = chromeBg
}

/// The metrics the host windows are laid out on, in points. These are the
/// macOS host window's own, which sit on the 4px grid of the design system.
enum HostWindowMetrics {
    enum Space {
        static let xxs = 4
        static let xs = 8
        static let sm = 12
        static let md = 16
        static let lg = 20
        static let xl = 24
    }

    static let radius = 4
    static let tightRadius = 2
    static let windowWidth = 360
    static let contentWidth = windowWidth - Space.xl * 2
    static let buttonHeight = 32
    static let rowHeight = 48
    static let switchSize = (width: 38, height: 22)
    static let moreButtonSize = 24
    static let checkboxSize = 16
    static let promptWidth = 360
    static let promptButton = (width: 80, height: 28)
    static let renameWidth = 320

    /// The line a text of `size` points is set on, as the macOS host sets it
    /// in its sans and mono faces: ascent and descent each rounded to a whole
    /// point. Pango reads a bare CSS line-height number as a multiple of the
    /// face's own height, which differs between Linux fonts, so the height is
    /// stated as a length.
    static func lineHeight(size: Int, mono: Bool) -> Int {
        let ascent = mono ? 1.02 : 1984.0 / 2048
        let descent = mono ? 0.3 : 494.0 / 2048
        return Int((ascent * Double(size)).rounded()) + Int((descent * Double(size)).rounded())
    }
}

/// The host windows' stylesheet, for one appearance. A class name here is
/// the one the window layer puts on a widget, and every widget the layer draws
/// is restyled in full, so no desktop theme shows through.
public enum HostWindowStyle {
    enum Class {
        static let window = "sensorium-host"
        static let card = "host-card"
        static let eyebrow = "host-eyebrow"
        static let warn = "host-warn"
        static let headline = "host-headline"
        static let detail = "host-detail"
        static let detailWarn = "host-detail-warn"
        static let sentence = "host-sentence"
        static let sentenceMedium = "host-sentence-medium"
        static let muted = "host-muted"
        static let rowName = "host-row-name"
        static let rowDetail = "host-row-detail"
        static let digits = "host-digits"
        static let countdown = "host-countdown"
        static let countdownUrgent = "host-countdown-urgent"
        static let stop = "host-stop"
        static let grant = "host-grant"
        static let filled = "host-filled"
        static let outlined = "host-outlined"
        static let plain = "host-plain"
        static let promptHeadline = "host-prompt-headline"
        static let promptButton = "host-prompt-button"
        static let promptFilled = "host-prompt-filled"
        static let sheet = "host-sheet"
        static let sheetTitle = "host-sheet-title"
        static let sheetButton = "host-sheet-button"
        static let sheetCancel = "host-sheet-cancel"
        static let separator = "host-separator"
        static let iconButton = "host-icon-button"
        static let check = "host-check"
        static let menu = "host-menu"
        static let menuItem = "host-menu-item"
        static let menuRemove = "host-menu-remove"
        static let menuKey = "host-menu-key"
    }

    /// The weight Linux draws each macOS weight in. macOS smooths text
    /// heavier than Linux draws the same face, so the viewer's chrome takes
    /// the next weight up for the same role.
    enum Weight {
        static let regular = 600
        static let medium = 700
        static let semibold = 700
        static let eyebrow = 700
        static let digits = 600
    }

    public static func stylesheet(for appearance: IndicatorAppearance) -> String {
        typealias P = HostWindowPalette
        typealias M = HostWindowMetrics
        func c(_ color: HostWindowColor) -> String { color.css(appearance) }
        func text(_ size: Int, _ weight: Int, mono: Bool = false) -> String {
            let face = mono ? "font-family: monospace; " : ""
            return "\(face)font-size: \(size)px; line-height: \(M.lineHeight(size: size, mono: mono))px; font-weight: \(weight);"
        }
        func tracking(_ ratio: Double, _ size: Int) -> String {
            "letter-spacing: \(String(format: "%g", ratio * Double(size)))px;"
        }
        let border = 1
        let buttons = [
            ".\(Class.filled)", ".\(Class.outlined)", ".\(Class.plain)", ".\(Class.promptButton)",
            ".\(Class.sheetButton)", "menubutton.\(Class.iconButton) > button", ".\(Class.menuItem)"
        ]
        return """
        window.\(Class.window), window.\(Class.window) > *, window.\(Class.window) scrolledwindow, window.\(Class.window) viewport {
            background-color: \(c(P.chromeBg));
            background-image: none;
            color: \(c(P.ink));
        }
        window.\(Class.window) scrolledwindow undershoot, window.\(Class.window) scrolledwindow overshoot { background: none; }
        \(buttons.joined(separator: ",\n"))
        {
            background-image: none;
            background-color: transparent;
            border: none;
            border-radius: \(M.radius)px;
            box-shadow: none;
            text-shadow: none;
            -gtk-icon-shadow: none;
            outline: none;
            min-height: 0;
            min-width: 0;
            padding: 0;
            margin: 0;
            opacity: 1;
            transition: none;
            color: \(c(P.ink));
        }
        .\(Class.card) { background-color: \(c(P.bg2)); border-radius: \(M.radius)px; }
        .\(Class.eyebrow) { \(text(12, Weight.eyebrow, mono: true)) \(tracking(0.22, 12)) color: \(c(P.muted)); }
        .\(Class.eyebrow).\(Class.warn) { color: \(c(P.warn)); }
        .\(Class.headline) { \(text(14, Weight.medium)) color: \(c(P.ink)); }
        .\(Class.detail) { \(text(12, Weight.regular)) color: \(c(P.muted)); }
        .\(Class.detail).\(Class.detailWarn) { color: \(c(P.warn)); }
        .\(Class.sentence) { \(text(13, Weight.regular)) color: \(c(P.ink)); }
        .\(Class.sentenceMedium) { \(text(13, Weight.medium)) color: \(c(P.ink)); }
        .\(Class.muted) { \(text(13, Weight.regular)) color: \(c(P.muted)); }
        .\(Class.rowName) { \(text(13, Weight.regular)) color: \(c(P.ink)); }
        .\(Class.rowDetail) { \(text(12, Weight.regular)) color: \(c(P.muted)); }
        .\(Class.digits) { \(text(30, Weight.digits, mono: true)) \(tracking(0.06, 30)) color: \(c(P.ink)); }
        .\(Class.countdown) { \(text(12, Weight.regular)) color: \(c(P.muted)); }
        .\(Class.countdown).\(Class.countdownUrgent) { color: \(c(P.warn)); }
        .\(Class.filled) { min-height: \(M.buttonHeight)px; \(text(14, Weight.medium)) color: \(c(P.onFill)); }
        .\(Class.filled).\(Class.stop) { background-color: \(c(P.bad)); \(text(14, Weight.semibold)) }
        .\(Class.filled).\(Class.grant) { background-color: \(c(P.warn)); \(text(13, Weight.medium)) }
        .\(Class.filled):not(.\(Class.stop)):not(.\(Class.grant)) { background-color: \(c(P.accent)); }
        .\(Class.filled):disabled { background-color: \(c(P.bg3)); border: \(border)px solid \(c(P.line2)); color: \(c(P.muted2)); }
        .\(Class.outlined) {
            min-height: \(M.buttonHeight - 2 * border)px;
            border: \(border)px solid \(c(P.line2));
            \(text(14, Weight.medium)) color: \(c(P.ink));
        }
        .\(Class.plain) { color: \(c(P.ink)); \(text(13, Weight.regular)) }
        .\(Class.plain):disabled { color: \(c(P.muted2)); }
        .\(Class.promptHeadline) { \(text(15, Weight.semibold)) color: \(c(P.ink)); }
        .\(Class.promptButton) {
            min-width: \(M.promptButton.width - 2 * border)px;
            min-height: \(M.promptButton.height - 2 * border)px;
            border: \(border)px solid \(c(P.line2));
            border-radius: \(M.tightRadius)px;
            \(text(12, Weight.semibold)) color: \(c(P.ink));
        }
        .\(Class.promptButton).\(Class.promptFilled) { background-color: \(c(P.accent)); border-color: \(c(P.accent)); color: #FFFFFF; }
        .\(Class.sheet) { border: \(border)px solid \(c(P.line2)); border-radius: \(M.radius)px; }
        .\(Class.sheetTitle) { \(text(14, Weight.semibold)) color: \(c(P.ink)); }
        .\(Class.sheetButton) {
            border-radius: \(M.tightRadius)px;
            \(text(13, Weight.medium))
            padding: 0 \(M.Space.md - border)px;
            min-height: \(lineHeightOfSheetButton() - 2 * border)px;
            border: \(border)px solid transparent;
        }
        .\(Class.sheetButton).\(Class.sheetCancel) { background-color: \(c(P.bg3)); border-color: \(c(P.line2)); color: \(c(P.ink)); }
        .\(Class.sheetButton):not(.\(Class.sheetCancel)) { background-color: \(c(P.accent)); color: \(c(P.onFill)); }
        .\(Class.separator) { background-color: \(c(P.line2)); min-height: 1px; min-width: 1px; }
        menubutton.\(Class.iconButton) > button { min-width: \(M.moreButtonSize)px; min-height: \(M.moreButtonSize)px; }
        window.\(Class.window) entry, window.\(Class.window) entry > text {
            background-image: none;
            background-color: \(c(P.bg4));
            color: \(c(P.ink));
            box-shadow: none;
            outline: none;
            border-radius: \(M.radius)px;
        }
        window.\(Class.window) entry {
            border: \(border)px solid \(c(P.line2));
            min-height: \(32 - 2 * border)px;
            padding: 0 \(M.Space.xs)px;
            \(text(13, Weight.regular))
            caret-color: \(c(P.accentHi));
        }
        window.\(Class.window) entry > text { border: none; background: none; padding: 0; margin: 0; min-height: 0; }
        window.\(Class.window) entry:focus-within { border-color: \(c(P.accent)); }
        window.\(Class.window) entry > text > selection { background-color: \(c(P.accent)); color: #FFFFFF; }
        popover.\(Class.menu) > contents {
            background-color: \(c(P.bg2));
            background-image: none;
            border: \(border)px solid \(c(P.line2));
            border-radius: \(M.radius)px;
            box-shadow: none;
            padding: \(M.Space.xxs - border)px 0;
        }
        popover.\(Class.menu) > arrow { background: none; border: none; min-height: 0; min-width: 0; }
        .\(Class.menuItem) { min-height: 28px; padding: 0 \(M.Space.sm)px; \(text(13, Weight.regular)) }
        .\(Class.menuItem):hover { background-color: \(c(P.bg4)); }
        .\(Class.menuItem):disabled { color: \(c(P.muted2)); }
        .\(Class.menuItem).\(Class.menuRemove) { color: \(c(P.bad)); }
        .\(Class.menuKey) { min-height: 28px; padding: 0 \(M.Space.sm)px; \(text(13, Weight.regular)) color: \(c(P.muted2)); }
        """
    }

    private static func lineHeightOfSheetButton() -> Int {
        // 13pt text plus the macOS button's own vertical inset of 8 above and below.
        HostWindowMetrics.lineHeight(size: 13, mono: false) + HostWindowMetrics.Space.xs * 2
    }
}
#endif
