/// The viewer's own palette and metrics, as one GTK stylesheet. Generated
/// from `ViewerPalette` and `ViewerChromeMetrics`, which every platform
/// reads, so the colours and sizes in a GTK window and an AppKit one are the
/// same values and not two lists that drift.
///
/// Kept free of any GTK import: the string this builds is exact text, and a
/// typo in it is worth catching on whichever machine builds this file, not
/// only on the one with a display to run it on. `GtkChrome.swift` adds the
/// half of this type that actually talks to GTK, in its own gated file.
public enum GtkViewerStyle {
    /// Class names the window layer puts on widgets. Named here so a rule and
    /// the widget it styles cannot disagree about spelling.
    public enum Class {
        public static let heading = "sensorium-heading"
        public static let sentence = "sensorium-sentence"
        public static let muted = "sensorium-muted"
        public static let bad = "sensorium-bad"
        public static let rowName = "sensorium-row-name"
        public static let rowDetail = "sensorium-row-detail"
        public static let row = "sensorium-row"
        /// Added to a row alongside `row` for the one that is currently
        /// selected -- the same rule `SavedMachineRowButton` uses on macOS,
        /// an explicit selected/not-selected state rather than a hover
        /// effect. `GtkYourMachinesWindow` adds it when a row's own host key
        /// matches `selectedHostPublicKey`.
        public static let rowSelected = "sensorium-row-selected"
        public static let dotOnline = "sensorium-dot-online"
        public static let dotOffline = "sensorium-dot-offline"
        public static let dotActivity = "sensorium-dot-activity"
        public static let primary = "sensorium-primary"
        /// The outlined counterpart to `primary`: `ViewerFormControls.style`'s
        /// `isPrimary: false` case on macOS, same size and radius.
        public static let secondary = "sensorium-secondary"
        /// A row's own compact action -- `SavedMachineRowButton.cancelButton`
        /// on macOS: half `primary`'s height, tight horizontal padding.
        public static let rowAction = "sensorium-row-action"
        /// A bare square icon button with no fill of its own -- the row menu's
        /// "…", `SavedMachineRowButton.moreButton` on macOS.
        public static let iconButton = "sensorium-icon-button"
        public static let link = "sensorium-link"
        public static let code = "sensorium-code"
        public static let eyebrow = "sensorium-eyebrow"
    }

    public static var stylesheet: String {
        let palette = ViewerPalette.self
        let space = ViewerChromeMetrics.Space.self
        let radius = ViewerChromeMetrics.Radius.self
        // A row's own online/offline/activity dot: 6x6, radius 3, the same
        // fixed square `SavedMachineRowButton.dot` draws on macOS. Not
        // `ViewerChromeMetrics.StatusDot` -- that is the status panel's own
        // tone indicator, a different dot at a different size.
        let rowDotSize = 6
        let rowDotRadius = 3
        return """
        window.sensorium, window.sensorium > * {
            background-color: \(palette.chromeBg.hexString);
            font-family: Inter, sans-serif;
        }
        window.sensorium label { color: \(palette.ink.hexString); }
        .\(Class.heading) { font-size: 20px; font-weight: 500; color: \(palette.ink.hexString); }
        .\(Class.eyebrow) { font-family: "JetBrains Mono", monospace; font-size: 11px; letter-spacing: 2px; color: \(palette.muted.hexString); }
        .\(Class.sentence) { font-size: 13px; color: \(palette.ink.hexString); }
        .\(Class.muted) { font-size: 13px; color: \(palette.muted.hexString); }
        .\(Class.bad) { font-size: 13px; color: \(palette.bad.hexString); }
        .\(Class.rowName) { font-size: 14px; font-weight: 500; color: \(palette.ink.hexString); }
        .\(Class.rowDetail) { font-size: 12px; color: \(palette.muted.hexString); }
        .\(Class.row) {
            background-color: \(palette.chromeBg2.hexString);
            border: 1px solid \(palette.chromeBorder2.hexString);
            border-radius: \(Int(radius.base))px;
            padding: \(Int(space.sm))px \(Int(space.md))px;
        }
        .\(Class.row).\(Class.rowSelected) { border-color: \(palette.accent.hexString); }
        .\(Class.dotOnline), .\(Class.dotOffline), .\(Class.dotActivity) {
            border-radius: \(rowDotRadius)px;
            min-width: \(rowDotSize)px;
            min-height: \(rowDotSize)px;
        }
        .\(Class.dotOnline) { background-color: \(palette.ok.hexString); }
        .\(Class.dotOffline) { background-color: \(palette.muted2.hexString); }
        .\(Class.dotActivity) { background-color: \(palette.warn.hexString); }
        .\(Class.primary), .\(Class.secondary) {
            min-height: 32px;
            min-width: 96px;
            padding: 0 \(Int(space.md))px;
            border-radius: \(Int(radius.base))px;
            font-size: 13px;
            font-weight: 500;
        }
        .\(Class.primary) { background-image: none; background-color: \(palette.accent.hexString); color: \(palette.chromeBg.hexString); border: none; }
        .\(Class.secondary) { background-image: none; background-color: \(palette.chromeBg2.hexString); color: \(palette.ink.hexString); border: 1px solid \(palette.line.hexString); }
        .\(Class.rowAction) {
            background-image: none;
            background-color: \(palette.chromeBg2.hexString);
            color: \(palette.ink.hexString);
            border: 1px solid \(palette.line.hexString);
            border-radius: \(Int(radius.base))px;
            min-height: 24px;
            min-width: 64px;
            padding: 0 \(Int(space.xs))px;
            font-size: 13px;
            font-weight: 500;
        }
        .\(Class.iconButton) {
            background-image: none;
            background: none;
            border: none;
            color: \(palette.muted.hexString);
            min-width: 24px;
            min-height: 24px;
            padding: 0;
        }
        .\(Class.link) { background: none; border: none; color: \(palette.accent.hexString); font-size: 13px; padding: 2px 0; }
        entry { background-image: none; background-color: \(palette.bg4.hexString); color: \(palette.ink.hexString); border: 1px solid \(palette.line.hexString); border-radius: 2px; }
        entry:focus-within { border-color: \(palette.accent.hexString); }
        .\(Class.code) { font-family: "JetBrains Mono", monospace; font-size: 20px; letter-spacing: 4px; }
        """
    }
}
