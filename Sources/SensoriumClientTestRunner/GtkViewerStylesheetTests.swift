import Foundation
import SensoriumClient

/// The GTK stylesheet's exact values, checked as text -- the string itself
/// builds on every platform (see `GtkViewerStylesheet.swift`), even though
/// only a GTK display can load it. Each expectation names one number from
/// the real macOS reference the same rule is meant to match: `TailnetDeviceRow`,
/// `SavedMachineRowButton`, `ViewerFormControls` and `ViewerDesignTokens`.
func testGtkViewerStylesheetTests() {
    let css = GtkViewerStyle.stylesheet

    expect(css.contains("font-family: Inter, sans-serif"), "body text asks for Inter before falling back, matching ViewerDesignTokens.font")
    expect(
        css.contains("\"JetBrains Mono\", monospace"),
        "mono text asks for JetBrains Mono before falling back, the same as the mono case of ViewerDesignTokens.font"
    )

    expect(
        css.contains("font-size: 14px; font-weight: 600"),
        "a row's own name is 14pt medium, drawn SemiBold, matching TailnetDeviceRow's and SavedMachineRowButton's own title font"
    )
    expect(
        css.contains("padding: 12px 16px"),
        "a row's own padding is 12 vertical, 16 horizontal, matching TailnetDeviceRow's own Space.sm/Space.md inset"
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
        ".\(Class.rowAction)", ".\(Class.link)", ".\(Class.settingsRow)",
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
        eyebrow.contains("font-size: 12px") && eyebrow.contains("font-weight: 600")
            && eyebrow.contains("color: \(palette.muted2.hexString)") && eyebrow.contains("letter-spacing: 2.64px"),
        "the eyebrow is mono 12 medium muted2 at Tracking.widest, as ViewerMessageWindowController draws it"
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
    // Noto Sans Medium, the sans most Linux desktops resolve to, is barely
    // heavier than its Regular, so macOS's medium reads as regular there.
    check(
        !css.contains("font-weight: 500") && css.contains("font-weight: 600"),
        "text macOS draws medium is drawn SemiBold, the nearest face visibly heavier than regular"
    )

    // A bare `.code` would lose to `window.sensorium entry` on specificity.
    let code = cssRule("window.sensorium entry.\(Class.code)", in: css)
    check(
        code.contains("font-size: 20px") && code.contains("monospace") && !code.contains("letter-spacing"),
        "the code field is 20 mono with no added tracking, as YourMachinesWindow.codeField draws it, in a rule that outranks the plain field's"
    )
    check(
        !css.contains("entry:focus"),
        "a focused field draws no ring or border of its own, as ViewerFormControls.textField sets focusRingType none"
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
    // Pango reads a bare number as a multiple of the font's own line height,
    // which varies by font; only a length pins it.
    for match in css.matches(of: /font-size: (\d+)px/) {
        let size = Double(match.1)!
        let expected = "line-height: \(String(format: "%g", size * 1.2))px; \(match.0)"
        let everyOne = css.components(separatedBy: expected).count == css.components(separatedBy: String(match.0)).count
        check(everyOne, "\(match.0) text is set on lines 1.2 times its size, the system font's own spacing on macOS")
    }

    check(
        cssRule(".\(Class.row):focus-visible", in: css).contains("outline"),
        "a row shows a focus ring when it has keyboard focus"
    )

    expect(failures.isEmpty, failures.joined(separator: "\nFAIL: "))
    print("PASS: every GTK surface the viewer draws sets each property the desktop theme would otherwise draw")
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
