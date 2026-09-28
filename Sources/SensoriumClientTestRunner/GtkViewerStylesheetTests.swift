import Foundation
import SensoriumClient

/// The GTK stylesheet's exact values, checked as text -- the string itself
/// builds on every platform (see `GtkViewerStylesheet.swift`), even though
/// only a GTK display can load it. Each expectation names one number from
/// the real macOS reference the same rule is meant to match: `TailnetDeviceRow`,
/// `SavedMachineRowButton`, `ViewerFormControls` and `ViewerDesignTokens`.
func testGtkViewerStylesheetTests() {
    let css = GtkViewerStyle.stylesheet

    expect(!css.contains("Inter"), "body text names no font of its own: the system sans GTK resolves is the one it draws in")
    expect(
        !cssRule("window.sensorium", in: css).contains("font-family"),
        "the window leaves its font family to GTK's own setting"
    )
    expect(
        css.contains("font-family: monospace;") && css.matches(of: /font-family: [^;]*[A-Z"]/).isEmpty,
        "mono text asks for the system monospace family and names no font"
    )

    expect(
        cssRule(".\(GtkViewerStyle.Class.rowName)", in: css).contains("font-size: 14px"),
        "a row's own name is 14pt, matching TailnetDeviceRow's and SavedMachineRowButton's own title font"
    )
    expect(
        !css.contains(".\(GtkViewerStyle.Class.row):hover"),
        "a row highlights on selection, not on hover -- SavedMachineRowButton's border colour follows isSelected, not the pointer"
    )
    expect(
        css.contains(".\(GtkViewerStyle.Class.row).\(GtkViewerStyle.Class.rowSelected)"),
        "a selected row is told apart by its own class, not a pseudo-class no model here drives"
    )

    expect(
        cssRule(".\(GtkViewerStyle.Class.primary)", in: css).contains("border-radius: 4px")
            && cssRule(".\(GtkViewerStyle.Class.secondary)", in: css).contains("border-radius: 4px"),
        "a form button's own corner radius is Radius.base, 4"
    )

    expect(
        css.contains("min-width: 6px") && css.contains("min-height: 6px") && css.contains("border-radius: 3px"),
        "a row's own online/offline/activity dot is a 6x6, radius-3 circle, the same fixed square SavedMachineRowButton.dot draws on macOS"
    )

    print("PASS: the GTK stylesheet's exact values match the metrics macOS itself draws from")
}

/// Each text role takes the token macOS draws it in: ink for primary text,
/// `muted` for secondary, `muted2` for tertiary, and the dimmed colours an
/// offline device's name and address take in `TailnetDeviceRow`.
func testGtkTextRoleColoursMatchMacOSTests() {
    let css = GtkViewerStyle.stylesheet
    typealias Class = GtkViewerStyle.Class
    let palette = ViewerPalette.self
    let roles: [(String, ViewerColor, String)] = [
        (".\(Class.heading)", palette.ink, "primary: a window's heading"),
        (".\(Class.sentence)", palette.ink, "primary: a sentence"),
        (".\(Class.rowName)", palette.ink, "primary: a row's name"),
        (".\(Class.muted)", palette.muted, "secondary: body text, a field's label and hint"),
        (".\(Class.detail)", palette.muted, "secondary: the line under a headline"),
        (".\(Class.rowDetail)", palette.muted, "secondary: a saved machine's address"),
        (".\(Class.deviceSubtitle)", palette.muted, "secondary: a device's mono address"),
        (".\(Class.eyebrow)", palette.muted2, "tertiary: an eyebrow"),
        ("window.sensorium entry > text > placeholder", palette.muted2, "tertiary: a placeholder"),
        (".\(Class.rowName).\(Class.offline)", palette.muted, "dimmed: an offline device's name"),
        (".\(Class.deviceSubtitle).\(Class.offline)", palette.muted2, "dimmed: an offline device's address")
    ]
    for (selector, token, role) in roles {
        let colour = cssValue("color", in: cssRule(selector, in: css))
        expect(colour == token.hexString, "\(role) is \(token.hexString), as on macOS -- got \(colour ?? "none")")
    }

    print("PASS: every text role is drawn in the colour token macOS draws it in")
}

/// A link's icon on Linux is drawn from shapes held in this source, never
/// looked up in an icon theme, so its size and stroke are the ones set here.
/// Each expectation is measured on the macOS previews at 2x, in points from
/// where the GTK link's box starts: where the title starts, and the box the
/// SF Symbol's ink fills.
func testGtkLinkIconMatchesMacOSGlyphBoxTests() {
    typealias Box = (minX: Double, minY: Double, maxX: Double, maxY: Double)
    let macOS: [(GtkViewerStyle.LinkIcon, String, titleOffset: Double, ink: Box)] = [
        (.lookAgain, "arrow.clockwise", 19, (3.0, 2.67, 12.0, 13.67)),
        (.enterManually, "keyboard", 24, (3.5, 4.17, 16.25, 12.17)),
        (.back, "chevron.left", 16, (2.5, 3.67, 7.5, 12.67))
    ]
    expect(
        GtkViewerStyle.LinkIcon.allCases == macOS.map(\.0),
        "every link icon is checked here"
    )
    for (icon, symbol, titleOffset, box) in macOS {
        expect(
            icon.titleOffset == titleOffset,
            "the title after the icon standing in for \(symbol) starts \(titleOffset)pt in -- got \(icon.titleOffset)"
        )
        expect(!icon.shapes.isEmpty, "\(symbol)'s stand-in draws something of its own")
        let ink = icon.inkBounds
        let tolerance = 0.25
        expect(
            abs(ink.minX - box.minX) <= tolerance && abs(ink.minY - box.minY) <= tolerance
                && abs(ink.maxX - box.maxX) <= tolerance && abs(ink.maxY - box.maxY) <= tolerance,
            "\(symbol)'s stand-in fills the box macOS inks, \(box) -- got \(ink)"
        )
        expect(ink.maxX < titleOffset, "\(symbol)'s stand-in ends before its title starts")
    }

    print("PASS: each link's embedded icon fills the box its SF Symbol inks on macOS and puts the title where macOS does")
}

/// A saved machine's "\u{2026}" is three dots drawn from this source, where
/// macOS draws the glyph. Measured on the macOS preview at 2x, relative to
/// the row: the middle dot's centre 20.225pt in from the row's right edge and
/// 4.815pt below its centre, 4.865pt between centres, 2.68pt across. Each
/// placement is whole device pixels at the window's own scale, so the three
/// rasterise alike at any scale, fractional ones included.
func testGtkMoreDotsMatchMacOSTests() {
    typealias Dots = GtkViewerStyle.MoreDots
    let size = Dots.buttonSize
    expect(size == 24, "the button is 24pt square, as on macOS -- got \(size)")
    let fromRight = size + ViewerChromeMetrics.Space.xs - Dots.middle.x
    expect(abs(fromRight - 20.225) < 0.01, "the middle dot is 20.225pt in from the row's right edge -- got \(fromRight)")
    expect(abs(Dots.middle.y - size / 2 - 4.815) < 0.01, "and 4.815pt below the row's centre -- got \(Dots.middle.y - size / 2)")
    expect(Dots.pitch == 4.865 && Dots.diameter == 2.68, "4.865pt apart and 2.68pt across -- got \(Dots.pitch), \(Dots.diameter)")

    for scale in [1.0, 1.25, 1.5, 2.0] {
        for origin in [(x: 0.0, y: 0.0), (x: 19.5, y: 97.5), (x: 0.25, y: 0.75), (x: 13.3, y: 7.7)] {
            let dots = Dots.placement(scale: scale, origin: origin)
            let label = "at \(scale)x from \(origin)"
            let d = dots.diameter
            expect(d >= 1 && d == d.rounded(), "each dot is whole device pixels across \(label) -- got \(d)")
            expect(abs(d - Dots.diameter * scale) <= 0.5, "and as wide as macOS draws it \(label) -- got \(d)")
            expect(dots.centres.count == 3, "three dots \(label)")
            guard dots.centres.count == 3 else { continue }
            let (left, middle, right) = (dots.centres[0], dots.centres[1], dots.centres[2])
            expect(left.y == middle.y && right.y == middle.y, "the dots share one line \(label)")
            let pitch = middle.x - left.x
            expect(
                right.x - middle.x == pitch && pitch == pitch.rounded() && abs(pitch - Dots.pitch * scale) <= 0.5,
                "the dots are evenly spaced whole device pixels apart \(label) -- got \(dots.centres)"
            )
            for centre in dots.centres {
                let edge = (x: centre.x - d / 2, y: centre.y - d / 2)
                expect(
                    edge.x == edge.x.rounded() && edge.y == edge.y.rounded(),
                    "each dot's box starts on a device pixel \(label) -- got \(centre), \(d) across"
                )
            }
            let ideal = (x: origin.x + Dots.middle.x * scale, y: origin.y + Dots.middle.y * scale)
            expect(
                abs(middle.x - ideal.x) <= 0.5 && abs(middle.y - ideal.y) <= 0.5,
                "the middle dot is within half a device pixel of where macOS draws it \(label) -- got \(middle), not \(ideal)"
            )
        }
    }

    print("PASS: a row's \u{2026} is three even, whole-pixel dots where macOS draws the glyph, at every scale")
}

/// A desktop theme styles every `button`, `entry` and `menubutton > button`
/// it finds, and a property this stylesheet leaves unset is one the theme
/// still draws, whatever this stylesheet's priority. Each check names the
/// macOS surface the rule stands for; every failing one is reported at once.
func testGtkViewerStylesheetOverridesTheThemeTests() {
    let css = GtkViewerStyle.stylesheet
    let palette = ViewerPalette.self
    typealias Class = GtkViewerStyle.Class
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    let buttonSelectors = [
        ".\(Class.row)", ".\(Class.primary)", ".\(Class.secondary)", ".\(Class.messageSecondary)",
        ".\(Class.rowAction)", ".\(Class.link)",
        "menubutton.\(Class.iconButton) > button"
    ]
    for selector in buttonSelectors {
        let body = cssRule(selector, in: css)
        for reset in ["background-image: none", "box-shadow: none", "text-shadow: none", "min-height: 0", "min-width: 0"] {
            check(body.contains(reset), "\(selector) resets the theme's \(reset.split(separator: ":")[0])")
        }
    }
    check(
        cssRule("menubutton.\(Class.iconButton) > button", in: css).contains("background-color: transparent"),
        "the row's \u{2026} is drawn with no fill of its own, like SavedMachineRowButton.moreButton; the theme styles the menubutton's inner button, not the menubutton"
    )
    check(
        cssRule(".\(Class.row)", in: css).contains("background-color: \(palette.chromeBg2.hexString)"),
        "a row is the chromeBg2 surface SavedMachineRowButton draws"
    )
    check(
        cssRule(".\(Class.rowAction)", in: css).contains("background-color: transparent")
            && cssRule(".\(Class.rowAction)", in: css).contains("border: none"),
        "a row's Cancel is bare text, as SavedMachineRowButton.cancelButton draws it"
    )
    check(
        cssRule(".\(Class.primary):disabled", in: css).contains("background-color: \(palette.chromeBg2.hexString)")
            && cssRule(".\(Class.primary):disabled", in: css).contains("color: \(palette.muted2.hexString)"),
        "a disabled primary button is outlined with muted2 text, as ViewerFormControls.style draws isEnabled false"
    )
    check(
        cssRule(".\(Class.messageSecondary)", in: css).contains("background-color: \(palette.bg4.hexString)"),
        "a message window's outlined button is filled bg4, as ViewerMessageWindowController draws it"
    )

    let eyebrow = cssRule(".\(Class.eyebrow)", in: css)
    check(
        eyebrow.contains("font-size: 12px")
            && eyebrow.contains("color: \(palette.muted2.hexString)") && eyebrow.contains("letter-spacing: 2.64px"),
        "the eyebrow is mono 12 muted2 at Tracking.widest, as ViewerMessageWindowController draws it"
    )
    check(cssRule(".\(Class.detail)", in: css).contains("font-size: 12px"), "a message's detail is 12, as ViewerMessageWindowController draws it")
    check(cssRule(".\(Class.hint)", in: css).contains("font-size: 12px"), "a field's hint is 12, as ViewerFormControls.hintLabel draws it")
    let subtitle = cssRule(".\(Class.deviceSubtitle)", in: css)
    check(
        subtitle.contains("monospace") && subtitle.contains("font-size: 11px"),
        "a tailnet device's subtitle is mono 11, as TailnetDeviceRowButton draws it"
    )
    check(
        cssRule(".\(Class.dotOffline)", in: css).contains("background-color: \(palette.bad.hexString)"),
        "an offline dot is the bad colour, as SavedMachineRowButton.dot draws it"
    )

    let entry = cssRule("window.sensorium entry", in: css)
    for value in ["border-radius: 4px", "padding: 0 12px", "box-shadow: none", "background-image: none", "outline: none"] {
        check(entry.contains(value), "a text field has \(value), as ViewerFormControls.textField draws it")
    }
    check(
        cssRule("window.sensorium entry > text > placeholder", in: css).contains("color: \(palette.muted2.hexString)"),
        "a placeholder is muted2, as ViewerFormControls.placeholder draws it"
    )
    // A bare `.code` would lose to `window.sensorium entry` on specificity.
    let code = cssRule("window.sensorium entry.\(Class.code)", in: css)
    check(
        code.contains("font-size: 20px") && code.contains("monospace") && !code.contains("letter-spacing"),
        "the code field is 20 mono with no added tracking, as YourMachinesWindow.codeField draws it, in a rule that outranks the plain field's"
    )
    // GTK centres a field's text on the Linux face's own ascent and descent,
    // which sets a sans or code field's text a point below the macOS field's;
    // a 14pt mono field's already sits on it.
    check(
        cssValue("margin-bottom", in: cssRule("window.sensorium entry > text", in: css)) == "2px"
            && cssValue("margin-bottom", in: cssRule("window.sensorium entry.\(Class.monoField) > text", in: css)) == "0",
        "a sans or code field's text sits a point above centre, a mono field's on it, as on macOS"
    )
    check(
        !css.contains("entry:focus"),
        "a focused field draws no ring or border of its own, as ViewerFormControls.textField sets focusRingType none"
    )
    let selection = cssRule("window.sensorium entry > text > selection", in: css)
    check(
        cssValue("background-color", in: selection) == "rgba(124, 112, 245, 0.32)"
            && cssValue("color", in: selection) == palette.ink.hexString,
        "selected text is ink on the selection token, as the macOS field editor draws it; got \(selection)"
    )
    check(
        cssValue("caret-color", in: cssRule("window.sensorium entry", in: css)) == palette.accentHi.hexString,
        "the caret is accentHi, as the macOS field editor's insertion point"
    )

    // GTK's min-width and min-height size the content box, inside the border
    // and padding; macOS states each control's size as its outer frame.
    func outer(_ selectors: [String]) -> (width: Double, height: Double) {
        let body = selectors.map { cssRule($0, in: css) }.joined(separator: ";")
        let border = cssPixels("border", in: body)
        let padding = cssValue("padding", in: body)?.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "px", with: "")) } ?? [0]
        let vertical = padding[0], horizontal = padding.count > 1 ? padding[1] : padding[0]
        return (
            cssPixels("min-width", in: body) + 2 * border + 2 * horizontal,
            cssPixels("min-height", in: body) + 2 * border + 2 * vertical
        )
    }
    for (name, selectors) in [
        ("primary", [".\(Class.primary)"]),
        ("disabled primary", [".\(Class.primary)", ".\(Class.primary):disabled"]),
        ("secondary", [".\(Class.secondary)"]),
        ("message window outlined", [".\(Class.messageSecondary)"])
    ] {
        let size = outer(selectors)
        check(
            size.width == 96 && size.height == 32,
            "a \(name) button's frame is at least 96 wide and 32 tall, as ViewerFormControls.actionButton sizes it; got \(size)"
        )
    }
    check(outer(["window.sensorium entry"]).height == 32, "a text field's frame is 32 tall; got \(outer(["window.sensorium entry"]).height)")
    let codeHeight = outer(["window.sensorium entry", "window.sensorium entry.\(Class.code)"]).height
    check(codeHeight == 44, "the code field's frame is 44 tall; got \(codeHeight)")
    let rowInset = outer([".\(Class.row)"])
    check(
        rowInset.width == 2 * 16 && rowInset.height == 2 * 12,
        "a row's text sits 16 from its outer left edge and 12 from its top, border included, as a layer border draws inside SavedMachineRowButton's frame; got \(rowInset)"
    )
    // Pango reads a bare number as a multiple of the font's own line height,
    // which varies by font; only a length pins it. A row's name is the one
    // exception: `GtkWidgets.onTextLine` places it, since Pango drops the
    // line height from the ellipsis it cuts a long name with.
    let rowName = cssRule(".\(Class.rowName)", in: css)
    check(
        rowName.contains("font-size: 14px") && !rowName.contains("line-height"),
        "a row's name has its size but no line height of its own"
    )
    let sized = css.matches(of: /(font-family: monospace; )?line-height: ([\d.]+)px; font-size: (\d+)px/)
    check(
        sized.count == css.matches(of: /font-size:/).count - 1,
        "every other font size comes with a line height in pixels"
    )
    // An AppKit label's line in Inter and in JetBrains Mono, the fonts the
    // macOS viewer asks for, measured from NSTextField at each size used.
    let appKitLine: [Double: Double] = [11: 14, 12: 15, 13: 16, 14: 17, 16: 20, 20: 24]
    let appKitMonoLine: [Double: Double] = [11: 14, 12: 16, 13: 17, 14: 18, 16: 21, 20: 26]
    for match in sized {
        let size = Double(match.3)!, lineHeight = Double(match.2)!
        let expected = (match.1 == nil ? appKitLine : appKitMonoLine)[size]
        check(
            lineHeight == expected,
            "\(match.3)px\(match.1 == nil ? "" : " mono") text is set on \(expected.map { "\($0)" } ?? "?")px lines, as AppKit sets a label's; got \(lineHeight)"
        )
    }

    // macOS draws no focus ring and no hover on any of these controls: the
    // form buttons and the row's "\u{2026}" never take keyboard focus there,
    // and a row shows focus only as its selected border.
    let outlines = css.matches(of: /outline: ([^;]+);/).map { String($0.1) }
    check(outlines.allSatisfy { $0 == "none" }, "no rule draws an outline, got \(outlines)")
    check(!css.contains(":hover"), "nothing changes under the pointer, as on macOS")
    let focusSelectors = css.matches(of: /([^\s,{}]+):focus-visible/).map { String($0.1) }
    check(
        focusSelectors == [".\(Class.row)"],
        "only a row changes with keyboard focus, got \(focusSelectors)"
    )
    let rowFocus = cssRule(".\(Class.row):focus-visible", in: css)
        .split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    check(
        rowFocus == ["border-color: \(palette.accent.hexString)"],
        "a focused row draws the selected row's accent border and nothing else, got \(rowFocus)"
    )

    expect(failures.isEmpty, failures.joined(separator: "\nFAIL: "))
    print("PASS: every GTK surface the viewer draws sets each property the desktop theme would otherwise draw")
}

/// Each text role's weight, measured as the one whose stem width in Noto
/// Sans or Noto Sans Mono comes nearest the macOS preview's for the same
/// string, size and scale, and the GTK rule for that role drawing it.
func testTextWeightTokensTests() {
    typealias Weight = ViewerChromeMetrics.TextWeight
    typealias Class = GtkViewerStyle.Class
    let pinned: [(String, Int, Int)] = [
        ("headline", Weight.headline, 700),
        ("eyebrow", Weight.eyebrow, 700),
        ("detail", Weight.detail, 600),
        ("body", Weight.body, 600),
        ("button", Weight.button, 700),
        ("windowHeading", Weight.windowHeading, 600),
        ("rowName", Weight.rowName, 700),
        ("rowDetail", Weight.rowDetail, 600),
        ("deviceSubtitle", Weight.deviceSubtitle, 600),
        ("field", Weight.field, 500),
        ("code", Weight.code, 500),
        ("hint", Weight.hint, 600),
        ("link", Weight.link, 600),
        ("hudLabel", Weight.hudLabel, 600),
        ("hudValue", Weight.hudValue, 800),
        ("hudNote", Weight.hudNote, 500),
    ]
    for (role, token, measured) in pinned {
        expect(token == measured, "the \(role) role is drawn at \(measured), got \(token)")
    }

    let css = GtkViewerStyle.stylesheet
    let rules: [(String, Int)] = [
        (".\(Class.heading)", Weight.windowHeading),
        (".\(Class.eyebrow)", Weight.eyebrow),
        (".\(Class.headline)", Weight.headline),
        (".\(Class.sentence)", Weight.body),
        (".\(Class.muted)", Weight.body),
        (".\(Class.bad)", Weight.body),
        (".\(Class.detail)", Weight.detail),
        (".\(Class.hint)", Weight.hint),
        (".\(Class.rowName)", Weight.rowName),
        (".\(Class.rowDetail)", Weight.rowDetail),
        (".\(Class.deviceSubtitle)", Weight.deviceSubtitle),
        (".\(Class.primary)", Weight.button),
        (".\(Class.secondary)", Weight.button),
        (".\(Class.messageSecondary)", Weight.button),
        (".\(Class.rowAction)", Weight.button),
        (".\(Class.link)", Weight.link),
        ("window.sensorium entry", Weight.field),
        ("window.sensorium entry.\(Class.code)", Weight.code),
    ]
    for (selector, weight) in rules {
        expect(
            cssRule(selector, in: css).contains("font-weight: \(weight);"),
            "\(selector) is drawn at \(weight)"
        )
    }
    // A headline turned bad keeps its own weight: the later rule wins a tie.
    expect(
        css.range(of: ".\(Class.headline) {")!.lowerBound > css.range(of: ".\(Class.bad) {")!.lowerBound
            && css.range(of: ".\(Class.hint) {")!.lowerBound > css.range(of: ".\(Class.muted) {")!.lowerBound,
        "the headline and hint rules come after the body rules they share a label with"
    )
    print("PASS: every text role is drawn at the weight measured nearest macOS")
}

/// The bodies of every rule in `css` whose selector list names `selector`
/// exactly, joined, or an empty string when none does.
func cssRule(_ selector: String, in css: String) -> String {
    var bodies: [String] = []
    var remainder = Substring(css)
    while let open = remainder.firstIndex(of: "{"), let close = remainder[open...].firstIndex(of: "}") {
        let head = remainder[..<open]
        let selectors = head.split(separator: ",").map { part in
            part.split(whereSeparator: \.isNewline).last.map { String($0) }?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        if selectors.contains(selector) {
            bodies.append(String(remainder[remainder.index(after: open)..<close]))
        }
        remainder = remainder[remainder.index(after: close)...]
    }
    return bodies.joined(separator: ";")
}

/// The last value `body` gives `property`, the one that wins the cascade.
func cssValue(_ property: String, in body: String) -> String? {
    body.split(separator: ";").reversed().lazy.compactMap { declaration -> String? in
        let parts = declaration.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == property else { return nil }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }.first
}

/// The pixel length that leads `property`'s value in `body`, or 0 when it is
/// unset or not a length (`border: none`).
func cssPixels(_ property: String, in body: String) -> Double {
    guard let first = cssValue(property, in: body)?.split(separator: " ").first,
          first.hasSuffix("px") || first == "0" else { return 0 }
    return Double(first.replacingOccurrences(of: "px", with: "")) ?? 0
}

/// The Your Machines menu bar is styled to look like the one the session
/// window paints: same height, padding, colours, font size, highlight and
/// checkmark.
@MainActor
func testGtkMenuBarMatchesPaintedBarTests() {
    let css = GtkViewerStyle.stylesheet
    typealias Metrics = ViewerChromeMetrics.MenuBar
    let bar = cssRule("window.sensorium menubar", in: css)
    expect(
        bar.contains("min-height: \(Int(Metrics.height))px") && bar.contains("background-color: \(ViewerPalette.chromeBg2.hexString)")
            && bar.contains("border: none") && bar.contains("padding: 0 \(Int(Metrics.barPaddingX))px"),
        "the bar is the painted bar's height, surface and padding, with no border: \(bar)"
    )
    let item = cssRule("window.sensorium menubar > item", in: css)
    expect(
        item.contains("font-size: \(Int(Metrics.fontSize))px") && item.contains("padding: 0 \(Int(Metrics.itemPaddingX))px")
            && item.contains("margin: \(Int(Metrics.titleInsetY))px 0"),
        "a title is the painted size and padding: \(item)"
    )
    expect(cssRule("window.sensorium menubar > item:first-child", in: css).contains("font-weight: bold"), "the app menu's title is bold")
    expect(
        cssRule("window.sensorium menubar > item:selected", in: css).contains("background-color: \(ViewerPalette.bg4.hexString)"),
        "the open title sits on the painted pill"
    )
    let contents = cssRule("window.sensorium popover.menu > contents", in: css)
    expect(
        contents.contains("background-color: \(ViewerPalette.chromeBg2.hexString)")
            && contents.contains("border-radius: \(Int(Metrics.popupRadius))px")
            && contents.contains("border: 1px solid \(ViewerPalette.chromeBorder2.hexString)")
            && contents.contains("padding: \(Int(Metrics.popupPaddingY) - 1)px 0"),
        "a menu is the painted surface, radius and padding: \(contents)"
    )
    expect(
        cssRule("window.sensorium menubar > item > popover.menu > contents", in: css)
            .contains("margin-top: \(Int(Metrics.titleInsetY))px"),
        "a menu opens from the bar's bottom edge, not its title's pill, as the painted one does"
    )
    let row = cssRule("window.sensorium popover.menu modelbutton", in: css)
    expect(
        row.contains("min-height: \(Int(Metrics.rowHeight))px") && row.contains("font-size: \(Int(Metrics.fontSize))px"),
        "a row is the painted height and size: \(row)"
    )
    expect(
        cssRule("window.sensorium popover.menu modelbutton:selected", in: css).contains("background-color: \(ViewerPalette.accent.hexString)"),
        "the highlighted row is the accent"
    )
    expect(
        cssRule("window.sensorium popover.menu modelbutton:disabled", in: css).contains("color: \(ViewerPalette.muted2.hexString)"),
        "a disabled row is dimmed as painted"
    )
    let checked = cssRule("window.sensorium popover.menu modelbutton check:checked", in: css)
    let encoded = SessionMenuGlyph.checkmark.svg(color: ViewerPalette.ink)
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    expect(checked.contains(encoded), "the checkmark is the painted one: \(checked)")
    print("PASS: the Your Machines menu bar is styled like the painted session bar")
}
