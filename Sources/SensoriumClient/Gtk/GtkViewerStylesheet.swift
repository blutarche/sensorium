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
        /// A message window's outlined button, filled `bg4` where a form's
        /// `secondary` is filled `chromeBg2` -- the two fills
        /// `ViewerMessageWindowController` and `ViewerFormControls.style`
        /// each draw on macOS.
        public static let messageSecondary = "sensorium-message-secondary"
        /// One choice in the session settings window: flat, like a menu item.
        public static let settingsRow = "sensorium-settings-row"
        /// A one-line message's own headline: ink, or `bad` beside it.
        public static let headline = "sensorium-headline"
        /// The smaller muted line under a headline.
        public static let detail = "sensorium-detail"
        /// Added beside `muted` or `bad` on the line under a field, which is
        /// smaller than a sentence.
        public static let hint = "sensorium-hint"
        public static let deviceSubtitle = "sensorium-device-subtitle"
        /// A tailnet device that is not online, drawn dimmer.
        public static let offline = "sensorium-offline"
        /// A field whose text cannot be edited while a pairing is out.
        public static let readOnly = "sensorium-read-only"
        public static let monoField = "sensorium-mono-field"
    }

    public static var stylesheet: String {
        let palette = ViewerPalette.self
        let space = ViewerChromeMetrics.Space.self
        let radius = Int(ViewerChromeMetrics.Radius.base)
        let ink = palette.ink.hexString
        let muted = palette.muted.hexString
        let muted2 = palette.muted2.hexString
        let accent = palette.accent.hexString
        let line = palette.line.hexString
        let chromeBg = palette.chromeBg.hexString
        let chromeBg2 = palette.chromeBg2.hexString
        let bg4 = palette.bg4.hexString
        let mono = "font-family: \"JetBrains Mono\", monospace"
        // Lines 1.2 times the size apart, the system font's own spacing on
        // macOS. Pango reads a bare number as a multiple of the font's own
        // line height, which most Linux UI fonts set wider, so it is a length.
        func text(_ size: Int) -> String {
            "line-height: \(String(format: "%g", Double(size) * 1.2))px; font-size: \(size)px"
        }
        // What macOS draws medium. Noto Sans Medium, the sans most Linux
        // desktops resolve to, is barely heavier than its Regular, so medium
        // text is drawn SemiBold, the nearest face visibly heavier.
        let medium = 600
        func tracking(_ size: Double) -> String {
            String(format: "%g", Double(ViewerChromeMetrics.Tracking.widest) * size)
        }
        // A row's own online/offline/activity dot: 6x6, radius 3, the same
        // fixed square `SavedMachineRowButton.dot` draws on macOS. Not
        // `ViewerChromeMetrics.StatusDot` -- that is the status panel's own
        // tone indicator, a different dot at a different size.
        let rowDotSize = 6
        let rowDotRadius = 3
        // GTK's min-width and min-height size the content box, inside border
        // and padding; macOS gives each control's outer frame. A form button
        // is 96x32 outside, a field 32 tall and the code field 44, each with
        // a 1px border.
        let border = 1
        let buttonPadding = Int(space.md)
        let buttonMinWidth = 96 - 2 * buttonPadding - 2 * border
        let buttonMinHeight = 32 - 2 * border
        let fieldMinHeight = 32 - 2 * border
        let codeMinHeight = 44 - 2 * border
        // Every button this viewer draws, including the inner button a
        // `menubutton` wraps. A desktop theme styles each of these nodes, and
        // this provider's priority wins only for the properties it sets --
        // whatever it leaves unset, in any state, the theme still draws.
        let buttons = [
            ".\(Class.row)", ".\(Class.primary)", ".\(Class.secondary)", ".\(Class.messageSecondary)",
            ".\(Class.rowAction)", ".\(Class.link)", ".\(Class.settingsRow)",
            "menubutton.\(Class.iconButton) > button"
        ]
        return """
        window.sensorium, window.sensorium > * {
            background-color: \(chromeBg);
            color: \(ink);
            font-family: Inter, sans-serif;
        }
        \(buttons.joined(separator: ",\n"))
        {
            background-image: none;
            background-color: transparent;
            border: none;
            border-radius: \(radius)px;
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
            color: \(ink);
        }
        \(buttons.map { $0 + ":focus-visible" }.joined(separator: ",\n"))
        {
            outline: 3px solid alpha(\(accent), 0.5);
            outline-offset: 1px;
        }
        .\(Class.heading) { \(text(20)); font-weight: \(medium); color: \(ink); }
        .\(Class.eyebrow) { \(mono); \(text(12)); font-weight: \(medium); letter-spacing: \(tracking(12))px; color: \(muted2); }
        .\(Class.sentence) { \(text(13)); color: \(ink); }
        .\(Class.headline) { \(text(13)); font-weight: \(medium); }
        .\(Class.muted) { \(text(13)); color: \(muted); }
        .\(Class.bad) { \(text(13)); color: \(palette.bad.hexString); }
        .\(Class.detail) { \(text(12)); color: \(muted); }
        .\(Class.hint) { \(text(12)); }
        .\(Class.rowName) { \(text(14)); font-weight: \(medium); color: \(ink); }
        .\(Class.rowName).\(Class.offline) { color: \(muted); }
        .\(Class.rowDetail) { \(text(12)); color: \(muted); }
        .\(Class.deviceSubtitle) { \(mono); \(text(11)); color: \(muted); }
        .\(Class.deviceSubtitle).\(Class.offline) { color: \(muted2); }
        .\(Class.row) {
            background-color: \(chromeBg2);
            border: 1px solid \(palette.chromeBorder2.hexString);
            padding: \(Int(space.sm))px \(Int(space.md))px;
        }
        .\(Class.row).\(Class.rowSelected) { border-color: \(accent); }
        .\(Class.dotOnline), .\(Class.dotOffline), .\(Class.dotActivity) {
            border-radius: \(rowDotRadius)px;
            min-width: \(rowDotSize)px;
            min-height: \(rowDotSize)px;
        }
        .\(Class.dotOnline) { background-color: \(palette.ok.hexString); }
        .\(Class.dotOffline) { background-color: \(palette.bad.hexString); }
        .\(Class.dotActivity) { background-color: \(palette.warn.hexString); animation: sensorium-pulse 0.7s ease-in-out infinite alternate; }
        @keyframes sensorium-pulse { from { opacity: 1; } to { opacity: 0.35; } }
        .\(Class.primary), .\(Class.secondary), .\(Class.messageSecondary) {
            min-height: \(buttonMinHeight)px;
            min-width: \(buttonMinWidth)px;
            padding: 0 \(buttonPadding)px;
            border-radius: \(radius)px;
            \(text(13));
            font-weight: \(medium);
        }
        .\(Class.primary) { background-color: \(accent); border: \(border)px solid \(accent); color: \(chromeBg); }
        .\(Class.primary):disabled { background-color: \(chromeBg2); border: \(border)px solid \(line); color: \(muted2); }
        .\(Class.secondary) { background-color: \(chromeBg2); border: \(border)px solid \(line); }
        .\(Class.messageSecondary) { background-color: \(bg4); border: \(border)px solid \(line); }
        .\(Class.rowAction) {
            background-color: transparent;
            border: none;
            min-height: 24px;
            min-width: 64px;
            \(text(13));
            font-weight: \(medium);
        }
        menubutton.\(Class.iconButton) > button {
            background-color: transparent;
            min-width: 24px;
            min-height: 24px;
            \(text(16));
            font-weight: \(medium);
            color: \(muted);
        }
        .\(Class.link) { \(text(13)); color: \(accent); }
        .\(Class.settingsRow) {
            min-height: 28px;
            padding: 0 \(Int(space.xs))px;
            \(text(13));
        }
        .\(Class.settingsRow):hover { background-color: \(bg4); }
        .\(Class.settingsRow):disabled { color: \(muted2); }
        window.sensorium entry {
            background-image: none;
            background-color: \(bg4);
            color: \(ink);
            border: \(border)px solid \(line);
            border-radius: \(radius)px;
            box-shadow: none;
            outline: none;
            min-height: \(fieldMinHeight)px;
            padding: 0 \(Int(space.sm))px;
            \(text(14));
            caret-color: \(ink);
        }
        window.sensorium entry > text > placeholder { color: \(muted2); }
        window.sensorium entry > text > selection { background-color: alpha(\(accent), 0.4); color: \(ink); }
        window.sensorium entry.\(Class.readOnly) { color: \(muted); }
        .\(Class.monoField) { \(mono); }
        window.sensorium entry.\(Class.code) { \(mono); \(text(20)); min-height: \(codeMinHeight)px; }
        """
    }
}
