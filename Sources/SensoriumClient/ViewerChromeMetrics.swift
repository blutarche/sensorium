import Foundation

/// The metrics the viewer's own chrome is laid out on, as
/// `docs/design-system.md` records them. Held here rather than beside the
/// colours in `ViewerDesign`, which is AppKit-only: a Wayland overlay drawn
/// with cairo needs the same numbers, and two lists of them would drift.
public enum ViewerChromeMetrics {
    /// The weight Linux draws each text role in, 100 to 900. macOS smooths
    /// text heavier than Linux draws the same face, so each role takes the
    /// weight whose stems, in the sans and mono most Linux desktops resolve
    /// to, come nearest the macOS viewer's in width for the same string and
    /// size.
    public enum TextWeight {
        public static let headline = 700
        public static let eyebrow = 700
        public static let detail = 600
        public static let body = 600
        public static let button = 700
        public static let windowHeading = 600
        public static let rowName = 700
        public static let rowDetail = 600
        public static let deviceSubtitle = 600
        public static let field = 500
        public static let code = 500
        public static let hint = 600
        public static let link = 600
        public static let hudLabel = 600
        public static let hudValue = 800
        public static let hudNote = 500
    }

    /// The lines text sits on, as AppKit sets a label's in the macOS
    /// viewer's sans and mono faces: a line as tall as the face's ascent and
    /// descent, each rounded to a whole point, with its baseline the rounded
    /// ascent below its top. Linux draws on the same lines whatever its own
    /// face's metrics.
    public enum TextLine {
        private static func ascent(mono: Bool) -> Double { mono ? 1.02 : 1984.0 / 2048 }
        private static func descent(mono: Bool) -> Double { mono ? 0.3 : 494.0 / 2048 }

        public static func height(size: Double, mono: Bool) -> Double {
            baseline(size: size, mono: mono) + (descent(mono: mono) * size).rounded()
        }

        public static func baseline(size: Double, mono: Bool) -> Double {
            (ascent(mono: mono) * size).rounded()
        }
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

    /// Intentionally sharp; nothing in this system is rounder than 6.
    public enum Radius {
        public static let tight: CGFloat = 2
        public static let base: CGFloat = 4
    }

    /// Letter-spacing ratios, applied as `ratio * pointSize`. Portable, unlike
    /// AppKit's `.kern` attribute, so the cairo painter can compute the same
    /// tracking `ViewerDesign.kern(_:size:)` gives an `NSAttributedString`.
    public enum Tracking {
        public static let snug: CGFloat = -0.015
        public static let widest: CGFloat = 0.22
    }

    /// The status panel's own tone dot: a small square, not a circle, shared
    /// so macOS and Linux draw the same shape.
    public enum StatusDot {
        public static let size: CGFloat = 8
        public static let radius: CGFloat = 2
    }

    /// The shortcut strip's shared numbers -- `ShortcutStripView` on macOS,
    /// `SessionChromePainter`'s strip drawing on Linux.
    public enum Strip {
        public static let topClearance: CGFloat = 6
        public static let barHeight: CGFloat = 40
        public static let handleWidth: CGFloat = 36
        public static let handleHeight: CGFloat = 8
        public static let actionButtonHeight: CGFloat = 28
        public static let actionIconSize: CGFloat = 18
        public static let confirmButtonHeight: CGFloat = 24
    }

    /// The transient notice's own numbers -- `ViewerTransientNoticeView` on
    /// macOS, `SessionChromePainter.drawNotice` on Linux.
    public enum Notice {
        public static let maxTextWidth: CGFloat = 360
        public static let dismissHitSize: CGFloat = 24
    }

    /// The diagnostics HUD's own numbers -- `SessionHUDView` on macOS,
    /// `SessionChromePainter`'s diagnostics drawing on Linux.
    public enum Diagnostics {
        public static let width: CGFloat = 320
        public static let edgeInset: CGFloat = 8
        public static let groupGap: CGFloat = 16
        public static let rowGap: CGFloat = 4
        public static let labelColumnWidth: CGFloat = 96
        /// A column is half the panel less the gutter, so its labels get
        /// only what "END-TO-END", the longest of them, needs.
        public static let narrowLabelColumnWidth: CGFloat = 70
        public static let sparklineWidth: CGFloat = 64
        public static let sparklineHeight: CGFloat = 14
    }

    /// The Linux menu bar: the one GTK draws across Your Machines and the one
    /// the session window paints, which must look the same.
    public enum MenuBar {
        public static let height: CGFloat = 26
        public static let barPaddingX: CGFloat = 4
        public static let itemPaddingX: CGFloat = 5
        /// How far the open title's pill sits in from the bar's top and
        /// bottom: a whole pixel at 1x, 1.5x and 2x.
        public static let titleInsetY: CGFloat = 4
        public static let fontSize: CGFloat = 13
        public static let popupPaddingY: CGFloat = 4
        public static let rowHeight: CGFloat = 24
        public static let rowPaddingX: CGFloat = 8
        public static let separatorHeight: CGFloat = 9
        public static let checkColumnWidth: CGFloat = 20
        public static let chordGap: CGFloat = 24
        public static let submenuArrowWidth: CGFloat = 16
        public static let minimumPopupWidth: CGFloat = 160
        public static let popupRadius: CGFloat = 6
    }
}
