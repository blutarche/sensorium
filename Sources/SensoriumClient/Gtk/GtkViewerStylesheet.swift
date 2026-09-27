import Foundation

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

    /// The icon a link draws ahead of its title, where macOS draws an SF
    /// Symbol: plain strokes and fills held here, in points from the top
    /// left of the space before the title, so no icon theme decides its
    /// shape, size or weight. Drawn in the link's own text colour.
    public enum LinkIcon: Int, CaseIterable, Sendable {
        case lookAgain = 1
        case enterManually
        case back

        public enum Shape: Sendable {
            case polyline([(x: Double, y: Double)], width: Double)
            /// Clockwise from `from` to `to`, in radians, 0 pointing right.
            case arc(x: Double, y: Double, radius: Double, from: Double, to: Double, width: Double)
            case roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double, lineWidth: Double)
            case fill(x: Double, y: Double, width: Double, height: Double)
        }

        /// Points from the link's leading edge to where its title starts.
        public var titleOffset: Double {
            switch self {
            case .lookAgain: 19
            case .enterManually: 24
            case .back: 16
            }
        }

        // Strokes as heavy as a small SF Symbol's beside 13pt text.
        private static let stroke = 1.1
        private static let outline = 1.0
        private static let key = 0.9

        public var shapes: [Shape] {
            switch self {
            case .lookAgain:
                // A circle open at the top right, with an open head at its
                // end pointing on round, clockwise.
                let centre = (x: 7.5, y: 9.17)
                let radius = 3.95
                let top = centre.y - radius
                return [
                    .arc(x: centre.x, y: centre.y, radius: radius, from: 0, to: 1.5 * .pi, width: Self.stroke),
                    .polyline([(centre.x, top), (9.6, top)], width: Self.stroke),
                    .polyline([(7.6, top - 2), (9.6, top), (7.6, top + 2)], width: Self.stroke)
                ]
            case .enterManually:
                // A keyboard: an outline, two rows of keys, and a row with a
                // space bar between two keys.
                let columns = (0..<6).map { 5.875 + 1.6 * Double($0) }
                let half = Self.key / 2
                func keys(_ y: Double, _ indices: [Int]) -> [Shape] {
                    indices.map { .fill(x: columns[$0] - half, y: y - half, width: Self.key, height: Self.key) }
                }
                return [.roundedRect(x: 4.0, y: 4.67, width: 11.75, height: 6.9, radius: 1.5, lineWidth: Self.outline)]
                    + keys(6.4, Array(0..<6))
                    + keys(8.0, Array(0..<6))
                    + keys(9.6, [0, 5])
                    + [.fill(x: columns[1] - half, y: 9.6 - half, width: columns[4] - columns[1] + Self.key, height: Self.key)]
            case .back:
                let tip = (x: 3.05, y: 8.17)
                let reach = 3.95
                return [.polyline([(tip.x + reach, tip.y - reach), tip, (tip.x + reach, tip.y + reach)], width: Self.stroke)]
            }
        }

        /// The box the shapes ink, strokes included.
        public var inkBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
            var box = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
            func add(_ x: Double, _ y: Double, _ pad: Double) {
                box = (min(box.minX, x - pad), min(box.minY, y - pad), max(box.maxX, x + pad), max(box.maxY, y + pad))
            }
            for shape in shapes {
                switch shape {
                case let .polyline(points, width):
                    for point in points { add(point.x, point.y, width / 2) }
                case let .arc(x, y, radius, from, to, width):
                    for step in 0...64 {
                        let angle = from + (to - from) * Double(step) / 64
                        add(x + radius * cos(angle), y + radius * sin(angle), width / 2)
                    }
                case let .roundedRect(x, y, width, height, _, lineWidth):
                    add(x, y, lineWidth / 2)
                    add(x + width, y + height, lineWidth / 2)
                case let .fill(x, y, width, height):
                    add(x, y, 0)
                    add(x + width, y + height, 0)
                }
            }
            return box
        }
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
        let selection = palette.selection
        let selectionBg = String(
            format: "rgba(%d, %d, %d, %g)",
            Int((selection.red * 255).rounded()), Int((selection.green * 255).rounded()),
            Int((selection.blue * 255).rounded()), selection.alpha
        )
        // Lines as tall as AppKit sets a label's: the font's ascent and its
        // descent, each rounded to a whole point, in Inter and JetBrains
        // Mono, the fonts the macOS viewer asks for. Pango reads a bare
        // number as a multiple of the font's own line height, which most
        // Linux UI fonts set wider, so it is a length.
        func lineHeight(_ size: Int, ascent: Double, descent: Double) -> Int {
            Int((ascent * Double(size)).rounded() + (descent * Double(size)).rounded())
        }
        func text(_ size: Int) -> String {
            "line-height: \(lineHeight(size, ascent: 1984.0 / 2048, descent: 494.0 / 2048))px; font-size: \(size)px"
        }
        func monoText(_ size: Int) -> String {
            "\(mono); line-height: \(lineHeight(size, ascent: 1.02, descent: 0.3))px; font-size: \(size)px"
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
        // a 1px border. A row's text sits 12 and 16 in from its outer edge,
        // border included: a layer border on macOS draws inside the frame.
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
        .\(Class.heading) { \(text(20)); font-weight: \(medium); color: \(ink); }
        .\(Class.eyebrow) { \(monoText(12)); font-weight: \(medium); letter-spacing: \(tracking(12))px; color: \(muted2); }
        .\(Class.sentence) { \(text(13)); color: \(ink); }
        .\(Class.headline) { \(text(13)); font-weight: \(medium); }
        .\(Class.muted) { \(text(13)); color: \(muted); }
        .\(Class.bad) { \(text(13)); color: \(palette.bad.hexString); }
        .\(Class.detail) { \(text(12)); color: \(muted); }
        .\(Class.hint) { \(text(12)); }
        .\(Class.rowName) { \(text(14)); font-weight: \(medium); color: \(ink); }
        .\(Class.rowName).\(Class.offline) { color: \(muted); }
        .\(Class.rowDetail) { \(text(12)); color: \(muted); }
        .\(Class.deviceSubtitle) { \(monoText(11)); color: \(muted); }
        .\(Class.deviceSubtitle).\(Class.offline) { color: \(muted2); }
        .\(Class.row) {
            background-color: \(chromeBg2);
            border: \(border)px solid \(palette.chromeBorder2.hexString);
            padding: \(Int(space.sm) - border)px \(Int(space.md) - border)px;
        }
        .\(Class.row).\(Class.rowSelected) { border-color: \(accent); }
        .\(Class.row):focus-visible { border-color: \(accent); }
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
            caret-color: \(palette.accentHi.hexString);
        }
        window.sensorium entry > text > placeholder { color: \(muted2); }
        window.sensorium entry > text > selection { background-color: \(selectionBg); color: \(ink); }
        window.sensorium entry.\(Class.readOnly) { color: \(muted); }
        .\(Class.monoField) { \(mono); }
        window.sensorium entry.\(Class.code) { \(monoText(20)); min-height: \(codeMinHeight)px; }
        """
    }
}
