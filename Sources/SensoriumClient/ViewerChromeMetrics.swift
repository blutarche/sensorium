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
}
