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
        css.contains("font-size: 14px; font-weight: 500"),
        "a row's own name is 14pt medium, matching TailnetDeviceRow's and SavedMachineRowButton's own title font"
    )
    expect(
        css.contains("padding: 12px 16px"),
        "a row's own padding is 12 vertical, 16 horizontal, matching TailnetDeviceRow's own Space.sm/Space.md inset"
    )
    expect(
        !css.contains(":hover"),
        "a row highlights on selection, not on hover -- SavedMachineRowButton's border colour follows isSelected, not the pointer"
    )
    expect(
        css.contains(".\(GtkViewerStyle.Class.row).\(GtkViewerStyle.Class.rowSelected)"),
        "a selected row is told apart by its own class, not a pseudo-class no model here drives"
    )

    expect(
        css.contains("min-height: 32px") && css.contains("min-width: 96px"),
        "a form button is 32 tall and at least 96 wide, matching ViewerFormControls.actionButton"
    )
    expect(
        css.range(
            of: #"\.sensorium-primary,\s*\.sensorium-secondary\s*\{[^}]*border-radius: 4px"#,
            options: String.CompareOptions.regularExpression
        ) != nil,
        "a form button's own corner radius is Radius.base, 4"
    )

    expect(
        css.contains("min-width: 6px") && css.contains("min-height: 6px") && css.contains("border-radius: 3px"),
        "a row's own online/offline/activity dot is a 6x6, radius-3 circle, the same fixed square SavedMachineRowButton.dot draws on macOS"
    )

    print("PASS: the GTK stylesheet's exact values match the metrics macOS itself draws from")
}
