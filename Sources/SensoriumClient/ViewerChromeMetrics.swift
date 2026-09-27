import Foundation

/// The metrics the viewer's own chrome is laid out on, as
/// `docs/design-system.md` records them. Held here rather than beside the
/// colours in `ViewerDesign`, which is AppKit-only: a Wayland overlay drawn
/// with cairo needs the same numbers, and two lists of them would drift.
public enum ViewerChromeMetrics {
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
    }
}
