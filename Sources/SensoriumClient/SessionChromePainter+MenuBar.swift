#if canImport(CCairo)
import CCairo
import Foundation

/// The session window's menu bar and the menus it opens, painted to look the
/// same as the GTK menu bar across Your Machines.
extension SessionChromePainter {
    private typealias Metrics = ViewerChromeMetrics.MenuBar

    static let menuBarHeight = Double(Metrics.height)
    private static let menuFontSize = Double(Metrics.fontSize)
    private static let menuHighlightInset = Double(ViewerChromeMetrics.Space.xxs)

    static func menuBarItems(titles: [String]) -> [SessionMenuBarLayout.Item] {
        SessionMenuBarLayout.items(titleWidths: titles.enumerated().map { index, title in
            CairoChromeText.measure(title, pointSize: menuFontSize, weight: menuTitleWeight(index)).width
        })
    }

    /// The app menu's title is bold, as it is in the macOS menu bar.
    private static func menuTitleWeight(_ index: Int) -> CairoFontWeight {
        index == 0 ? .bold : .regular
    }

    static func drawMenuBar(titles: [String], openIndex: Int?, in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: 0, color: ViewerPalette.chromeBg2)
        for (index, item) in menuBarItems(titles: titles).enumerated() {
            if index == openIndex {
                let inset = Double(Metrics.titleInsetY)
                let pill = ViewerChromeRect(
                    x: bounds.x + item.x, y: bounds.y + inset, width: item.width, height: bounds.height - inset * 2
                )
                CairoChromeText.fill(context, pill, radius: Double(ViewerChromeMetrics.Radius.base), color: ViewerPalette.bg4)
            }
            let weight = menuTitleWeight(index)
            let height = CairoChromeText.measure(titles[index], pointSize: menuFontSize, weight: weight).height
            CairoChromeText.draw(
                titles[index],
                in: context,
                x: bounds.x + item.x + Double(Metrics.itemPaddingX),
                y: snapped(context, bounds.y + (bounds.height - height) / 2),
                pointSize: menuFontSize,
                color: ViewerPalette.ink,
                weight: weight
            )
        }
    }

    static func menuChordLabel(for item: ViewerMenuItem) -> String? {
        LinuxViewerMenu.chordLabel(keyEquivalent: item.keyEquivalent, modifiers: item.modifiers, style: .session)
    }

    static func menuPopupLayout(_ menu: ViewerMenu) -> SessionMenuPopupLayout {
        SessionMenuPopupLayout(
            menu: menu,
            titleWidths: menu.items.map { CairoChromeText.measure($0.title, pointSize: menuFontSize).width },
            chordWidths: menu.items.map { item in
                menuChordLabel(for: item).map { CairoChromeText.measure($0, pointSize: menuFontSize).width } ?? 0
            }
        )
    }

    static func drawMenuPopup(_ menu: ViewerMenu, highlighted: Int?, in context: OpaquePointer, bounds: ViewerChromeRect) {
        let radius = Double(Metrics.popupRadius)
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg2)
        // Border and separators are one point wide, as GTK draws the Your
        // Machines menus' own, so the two match at every scale.
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.chromeBorder2)
        let layout = menuPopupLayout(menu)
        let padding = Double(Metrics.rowPaddingX)
        let checkWidth = Double(Metrics.checkColumnWidth)
        for (index, item) in menu.items.enumerated() {
            let row = layout.rect(ofRow: index)
            let top = bounds.y + row.y
            if layout.rows[index].isSeparator {
                CairoChromeText.fill(
                    context,
                    ViewerChromeRect(x: bounds.x + padding, y: top + (row.height - 1) / 2, width: bounds.width - padding * 2, height: 1),
                    radius: 0,
                    color: ViewerPalette.chromeBorder2
                )
                continue
            }
            let isEnabled = item.isEnabled && !menu.autoenablesItems
            if index == highlighted, isEnabled {
                let fill = ViewerChromeRect(
                    x: bounds.x + menuHighlightInset, y: top, width: bounds.width - menuHighlightInset * 2, height: row.height
                )
                CairoChromeText.fill(context, fill, radius: Double(ViewerChromeMetrics.Radius.base), color: ViewerPalette.accent)
            }
            let ink = isEnabled ? ViewerPalette.ink : ViewerPalette.muted2
            let glyph = SessionMenuGlyph.checkmark
            if item.isSelected {
                drawGlyph(glyph, in: context, x: bounds.x + padding + (checkWidth - glyph.box) / 2,
                          y: top + (row.height - glyph.box) / 2, color: ink)
            }
            let textHeight = CairoChromeText.measure(item.title, pointSize: menuFontSize).height
            let textY = snapped(context, top + (row.height - textHeight) / 2)
            CairoChromeText.draw(
                item.title, in: context, x: bounds.x + padding + checkWidth, y: textY, pointSize: menuFontSize, color: ink
            )
            var trailing = bounds.x + bounds.width - padding
            if item.submenu != nil {
                let arrow = SessionMenuGlyph.submenuArrow
                drawGlyph(arrow, in: context, x: trailing - arrow.box, y: top + (row.height - arrow.box) / 2, color: ink)
                trailing -= Double(Metrics.submenuArrowWidth)
            }
            if let chord = menuChordLabel(for: item) {
                let width = CairoChromeText.measure(chord, pointSize: menuFontSize).width
                CairoChromeText.draw(
                    chord, in: context, x: trailing - width, y: textY, pointSize: menuFontSize,
                    color: isEnabled && index != highlighted ? ViewerPalette.muted : ink
                )
            }
        }
    }

    /// `glyph` with its box's top-left corner on the device pixel nearest
    /// `x`, `y`.
    private static func drawGlyph(_ glyph: SessionMenuGlyph, in context: OpaquePointer, x: Double, y: Double, color: ViewerColor) {
        let originX = snapped(context, x, horizontal: true)
        let originY = snapped(context, y)
        cairo_new_path(context)
        for (index, point) in glyph.points.enumerated() {
            if index == 0 {
                cairo_move_to(context, originX + point.x, originY + point.y)
            } else {
                cairo_line_to(context, originX + point.x, originY + point.y)
            }
        }
        CairoChromeText.setSource(context, color)
        cairo_set_line_width(context, glyph.lineWidth)
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)
        cairo_stroke(context)
    }

    /// `value` moved onto the nearest device pixel, so text and rules do
    /// not straddle two rows at a fractional backing scale.
    private static func snapped(_ context: OpaquePointer, _ value: Double, horizontal: Bool = false) -> Double {
        var x = horizontal ? value : 0
        var y = horizontal ? 0 : value
        cairo_user_to_device(context, &x, &y)
        x = x.rounded()
        y = y.rounded()
        cairo_device_to_user(context, &x, &y)
        return horizontal ? x : y
    }
}
#endif
