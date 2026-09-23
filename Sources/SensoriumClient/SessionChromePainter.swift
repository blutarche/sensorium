#if canImport(CCairo)
import CCairo
import Foundation
import SensoriumCore

/// What one press on the shortcut strip landed on.
enum ShortcutStripHit: Equatable {
    case action(ShortcutStripAction)
    case pin
    case confirm
    case cancel
}

/// Draws the session window's chrome with cairo, and measures it first.
///
/// Every word, every colour and every enablement arrives already decided --
/// from `ViewerSessionStateMachine`, `SessionHUDPanel`, `ShortcutStripModel`
/// and `ViewerPalette`. This decides only where the ink goes.
@MainActor
enum SessionChromePainter {
    private static let inset = Double(ViewerChromeMetrics.Space.lg)
    private static let gap = Double(ViewerChromeMetrics.Space.sm)
    private static let tightGap = Double(ViewerChromeMetrics.Space.xs)
    private static let radius = Double(ViewerChromeMetrics.Radius.base)

    private static let eyebrowSize: Double = 10
    private static let headlineSize: Double = 15
    private static let detailSize: Double = 12
    private static let buttonTitleSize: Double = 12
    private static let rowSize: Double = 11
    private static let dotRadius: Double = 4

    /// The row label's own column, so a value that does not fit beside it
    /// truncates instead of running into it -- the same fixed columns
    /// `SessionHUDRowView.labelColumnWidth` and `.narrowLabelColumnWidth`
    /// reserve on macOS. Narrow applies only inside a `.columns` block's two
    /// side-by-side sections.
    private static let rowLabelWidth: Double = 96
    private static let rowNarrowLabelWidth: Double = 70

    // MARK: - Status panel

    /// The panel's width comes from the shared measurement rule, so it is the
    /// same width on both platforms for the same button rows; its height is
    /// whatever this state's own text needs.
    static func statusPanelSize(status: ViewerSessionStatus) -> (width: Double, height: Double) {
        let width = ViewerStatusPanelMetrics.sessionPanelWidth { measureButtonTitle($0) }
        let textWidth = width - inset * 2
        var height = inset
        height += CairoChromeText.measure(
            status.eyebrow, pointSize: eyebrowSize, mono: true, tracking: 2
        ).height
        height += tightGap
        height += CairoChromeText.measure(
            status.headline, pointSize: headlineSize, maxWidth: textWidth
        ).height
        if !status.detail.isEmpty {
            height += tightGap
            height += CairoChromeText.measure(
                status.detail, pointSize: detailSize, maxWidth: textWidth
            ).height
        }
        if !status.buttons.isEmpty {
            height += gap + ViewerStatusPanelMetrics.buttonHeight
        }
        return (width, height + inset)
    }

    static func drawStatusPanel(status: ViewerSessionStatus, in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.chromeBorder2)

        let tone = ViewerPalette.color(for: status.tone)
        let textWidth = bounds.width - inset * 2
        var y = bounds.y + inset
        let eyebrowHeight = CairoChromeText.measure(
            status.eyebrow, pointSize: eyebrowSize, mono: true, tracking: 2
        ).height
        CairoChromeText.fillDot(
            context,
            centreX: bounds.x + inset + dotRadius,
            centreY: y + eyebrowHeight / 2,
            radius: dotRadius,
            color: tone
        )
        CairoChromeText.draw(
            status.eyebrow,
            in: context,
            x: bounds.x + inset + dotRadius * 2 + tightGap,
            y: y,
            pointSize: eyebrowSize,
            color: ViewerPalette.muted,
            mono: true,
            tracking: 2
        )
        y += eyebrowHeight + tightGap
        y += CairoChromeText.draw(
            status.headline,
            in: context,
            x: bounds.x + inset,
            y: y,
            pointSize: headlineSize,
            color: ViewerPalette.ink,
            maxWidth: textWidth
        )
        if !status.detail.isEmpty {
            y += tightGap
            _ = CairoChromeText.draw(
                status.detail,
                in: context,
                x: bounds.x + inset,
                y: y,
                pointSize: detailSize,
                color: ViewerPalette.muted,
                maxWidth: textWidth
            )
        }
        for (index, layout) in statusButtonLayouts(status: status, panel: bounds).enumerated() {
            drawActionButton(
                title: status.buttons[index].title,
                isPrimary: status.buttons[index].isPrimary,
                in: context,
                rect: layout.rect
            )
        }
    }

    /// Where each of this status's buttons sits, in the same coordinates the
    /// panel was drawn in. The shared hit-test decides the row; this only
    /// supplies the measurement it needs.
    static func statusButtonLayouts(
        status: ViewerSessionStatus,
        panel: ViewerChromeRect
    ) -> [ViewerStatusPanelButtonLayout] {
        ViewerStatusPanelHitTest.buttonRow(buttons: status.buttons, panel: panel) { measureButtonTitle($0) }
    }

    private static func measureButtonTitle(_ title: String) -> Double {
        CairoChromeText.measure(title, pointSize: buttonTitleSize).width
    }

    private static func drawActionButton(
        title: String,
        isPrimary: Bool,
        in context: OpaquePointer,
        rect: ViewerChromeRect
    ) {
        CairoChromeText.fill(
            context,
            rect,
            radius: Double(ViewerChromeMetrics.Radius.tight),
            color: isPrimary ? ViewerPalette.accent : ViewerPalette.chromeBg2
        )
        if !isPrimary {
            CairoChromeText.stroke(
                context, rect, radius: Double(ViewerChromeMetrics.Radius.tight), color: ViewerPalette.line
            )
        }
        let size = CairoChromeText.measure(title, pointSize: buttonTitleSize)
        CairoChromeText.draw(
            title,
            in: context,
            x: rect.x + (rect.width - size.width) / 2,
            y: rect.y + (rect.height - size.height) / 2,
            pointSize: buttonTitleSize,
            color: isPrimary ? ViewerPalette.chromeBg : ViewerPalette.ink
        )
    }

    // MARK: - Transient notice

    static let noticeMaximumWidth: Double = 420

    static func noticeSize(line: String) -> (width: Double, height: Double) {
        let textWidth = noticeMaximumWidth - gap * 2
        let text = CairoChromeText.measure(line, pointSize: detailSize, maxWidth: textWidth)
        return (noticeMaximumWidth, text.height + gap * 2)
    }

    static func drawNotice(line: String, in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg2)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.warn)
        CairoChromeText.draw(
            line,
            in: context,
            x: bounds.x + gap,
            y: bounds.y + gap,
            pointSize: detailSize,
            color: ViewerPalette.ink,
            maxWidth: bounds.width - gap * 2
        )
    }

    // MARK: - Diagnostics

    static let diagnosticsWidth: Double = 340

    static func diagnosticsSize(blocks: [SessionHUDBlock]) -> (width: Double, height: Double) {
        var height = gap
        for block in blocks {
            if let title = block.title {
                height += CairoChromeText.measure(title, pointSize: eyebrowSize, mono: true, tracking: 2).height
                height += tightGap
            }
            switch block {
            case let .section(section):
                height += sectionHeight(section, width: diagnosticsWidth - gap * 2)
            case let .columns(_, left, right):
                // The same halved, gutter-short column `drawDiagnostics`
                // actually draws into -- a note here still measured against
                // the full panel width would wrap to fewer lines than the
                // narrower column really holds, undersizing the panel below.
                let columnWidth = (diagnosticsWidth - gap * 3) / 2
                height += max(sectionHeight(left, width: columnWidth), sectionHeight(right, width: columnWidth))
            }
            height += tightGap
        }
        // One line naming the chord that opens the session controls, which is
        // the only place a desktop with no menu bar says where they are.
        height += CairoChromeText.measure(helpLine, pointSize: rowSize, maxWidth: diagnosticsWidth - gap * 2).height
        return (diagnosticsWidth, height + gap)
    }

    static var helpLine: String {
        "Session controls: \(ViewerKeyNames.sessionControls)  \u{00B7}  "
            + "Shortcut strip: \(ViewerKeyNames.shortcutStrip)  \u{00B7}  "
            + "Back to this machine: \(ViewerKeyNames.escapeGesture)"
    }

    /// `width` is the section's own drawn width -- the full panel width for a
    /// lone section, or one narrow column's share for one half of a
    /// `.columns` block -- so a note's wrap is measured at the same width
    /// `drawSection` actually wraps it at.
    private static func sectionHeight(_ section: SessionHUDSection, width: Double) -> Double {
        var height = CairoChromeText.measure(
            section.title, pointSize: eyebrowSize, mono: true, tracking: 2
        ).height + tightGap
        for row in section.rows {
            height += CairoChromeText.measure(row.label, pointSize: rowSize, mono: true).height
            if let note = row.note {
                height += CairoChromeText.measure(note, pointSize: rowSize, maxWidth: width).height
            }
        }
        if let note = section.note {
            height += CairoChromeText.measure(note, pointSize: rowSize, maxWidth: width).height
        }
        return height + tightGap
    }

    static func drawDiagnostics(blocks: [SessionHUDBlock], in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.chromeBorder2)
        var y = bounds.y + gap
        for block in blocks {
            if let title = block.title {
                y += CairoChromeText.draw(
                    title,
                    in: context,
                    x: bounds.x + gap,
                    y: y,
                    pointSize: eyebrowSize,
                    color: ViewerPalette.muted2,
                    mono: true,
                    tracking: 2
                ) + tightGap
            }
            switch block {
            case let .section(section):
                y = drawSection(
                    section,
                    in: context,
                    x: bounds.x + gap,
                    y: y,
                    width: bounds.width - gap * 2,
                    isNarrow: false
                )
            case let .columns(_, left, right):
                let columnWidth = (bounds.width - gap * 3) / 2
                let leftBottom = drawSection(
                    left, in: context, x: bounds.x + gap, y: y, width: columnWidth, isNarrow: true
                )
                let rightBottom = drawSection(
                    right, in: context, x: bounds.x + gap * 2 + columnWidth, y: y, width: columnWidth, isNarrow: true
                )
                y = max(leftBottom, rightBottom)
            }
            y += tightGap
        }
        CairoChromeText.draw(
            helpLine,
            in: context,
            x: bounds.x + gap,
            y: y,
            pointSize: rowSize,
            color: ViewerPalette.muted2,
            maxWidth: bounds.width - gap * 2
        )
    }

    private static func drawSection(
        _ section: SessionHUDSection,
        in context: OpaquePointer,
        x: Double,
        y: Double,
        width: Double,
        isNarrow: Bool
    ) -> Double {
        var cursor = y
        cursor += CairoChromeText.draw(
            section.title,
            in: context,
            x: x,
            y: cursor,
            pointSize: eyebrowSize,
            color: ViewerPalette.muted,
            mono: true,
            tracking: 2
        ) + tightGap
        // The value's own column is whatever the label's reserved width
        // leaves behind, truncated to one line with an ellipsis rather than
        // left to run into the label -- see `SessionHUDRowView.update(_:)`'s
        // `byTruncatingTail` value.
        let labelWidth = isNarrow ? rowNarrowLabelWidth : rowLabelWidth
        let valueWidth = max(0, width - labelWidth - tightGap)
        for row in section.rows {
            let height = CairoChromeText.draw(
                row.label,
                in: context,
                x: x,
                y: cursor,
                pointSize: rowSize,
                color: row.isStale ? ViewerPalette.muted2 : ViewerPalette.muted,
                mono: true
            )
            CairoChromeText.drawRightAligned(
                row.value,
                in: context,
                rightX: x + width,
                y: cursor,
                pointSize: rowSize,
                color: row.tone.map(ViewerPalette.color(for:))
                    ?? (row.isStale ? ViewerPalette.muted2 : ViewerPalette.ink),
                mono: true,
                maxWidth: valueWidth,
                ellipsize: true
            )
            cursor += height
            if let note = row.note {
                cursor += CairoChromeText.draw(
                    note,
                    in: context,
                    x: x,
                    y: cursor,
                    pointSize: rowSize,
                    color: ViewerPalette.muted2,
                    maxWidth: width
                )
            }
        }
        if let note = section.note {
            cursor += CairoChromeText.draw(
                note,
                in: context,
                x: x,
                y: cursor,
                pointSize: rowSize,
                color: ViewerPalette.muted2,
                maxWidth: width
            )
        }
        return cursor + tightGap
    }

    // MARK: - Shortcut strip

    static let stripHeight: Double = 44
    static let handleWidth: Double = 72
    static let handleHeight: Double = 6
    private static let stripButtonHeight: Double = 30
    private static let stripButtonMinimumWidth: Double = 56
    private static let iconSize: Double = 16

    static func stripSize(visibility: ShortcutStripVisibility, hostName: String) -> (width: Double, height: Double) {
        let width = stripLayout(visibility: visibility, hostName: hostName, originX: 0, originY: 0)
            .map { $0.rect.x + $0.rect.width }
            .max() ?? stripButtonMinimumWidth
        return (width + tightGap, stripHeight)
    }

    /// Every pressable thing on the strip, in the order it is drawn. Built
    /// once and used for both the drawing and the hit test, so the two cannot
    /// disagree about where a button is.
    static func stripLayout(
        visibility: ShortcutStripVisibility,
        hostName: String,
        originX: Double,
        originY: Double
    ) -> [(hit: ShortcutStripHit, rect: ViewerChromeRect, title: String, isPrimary: Bool)] {
        var cursor = originX + tightGap
        let top = originY + (stripHeight - stripButtonHeight) / 2
        var result: [(ShortcutStripHit, ViewerChromeRect, String, Bool)] = []

        func place(_ hit: ShortcutStripHit, _ title: String, isPrimary: Bool, hasIcon: Bool) {
            let text = CairoChromeText.measure(title, pointSize: rowSize).width
            let width = max(stripButtonMinimumWidth, text + tightGap * 2 + (hasIcon ? iconSize + tightGap : 0))
            result.append((
                hit,
                ViewerChromeRect(x: cursor, y: top, width: width, height: stripButtonHeight),
                title,
                isPrimary
            ))
            cursor += width + tightGap / 2
        }

        if case let .confirming(action) = visibility, let question = action.confirmation(hostName: hostName) {
            // The question replaces the label area, with the buttons beside
            // it -- the same row `ShortcutStripView`'s `confirmRow` lays out
            // on macOS, in the same order. Reserving its measured width in
            // the cursor here is what keeps the buttons from starting under
            // it, and what widens `stripSize()`'s own measured width so the
            // strip's background never draws the question past its own edge.
            cursor += CairoChromeText.measure(question.question, pointSize: rowSize).width + gap
            place(.confirm, question.confirmTitle, isPrimary: true, hasIcon: false)
            place(.cancel, question.cancelTitle, isPrimary: false, hasIcon: false)
            return result
        }
        for action in ShortcutStripAction.allCases {
            place(
                .action(action),
                action.title,
                isPrimary: false,
                hasIcon: FreedesktopIconLookup.pngPath(named: action.freedesktopIconName) != nil
            )
        }
        place(.pin, "Pin", isPrimary: false, hasIcon: false)
        return result
    }

    static func drawStrip(
        visibility: ShortcutStripVisibility,
        hostName: String,
        isPinned: Bool,
        in context: OpaquePointer,
        bounds: ViewerChromeRect
    ) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.chromeBorder2)
        if case let .confirming(action) = visibility, let question = action.confirmation(hostName: hostName) {
            let size = CairoChromeText.measure(question.question, pointSize: rowSize)
            CairoChromeText.draw(
                question.question,
                in: context,
                x: bounds.x + tightGap,
                y: bounds.y + (stripHeight - size.height) / 2,
                pointSize: rowSize,
                color: ViewerPalette.ink
            )
        }
        for entry in stripLayout(
            visibility: visibility,
            hostName: hostName,
            originX: bounds.x,
            originY: bounds.y
        ) {
            let isOn = entry.hit == .pin && isPinned
            CairoChromeText.fill(
                context,
                entry.rect,
                radius: Double(ViewerChromeMetrics.Radius.tight),
                color: entry.isPrimary || isOn ? ViewerPalette.accent : ViewerPalette.chromeBg2
            )
            var textX = entry.rect.x + tightGap
            if case let .action(action) = entry.hit,
               let path = FreedesktopIconLookup.pngPath(named: action.freedesktopIconName) {
                drawIcon(path: path, in: context, x: textX, y: entry.rect.y + (entry.rect.height - iconSize) / 2)
                textX += iconSize + tightGap
            }
            let size = CairoChromeText.measure(entry.title, pointSize: rowSize)
            CairoChromeText.draw(
                entry.title,
                in: context,
                x: textX,
                y: entry.rect.y + (entry.rect.height - size.height) / 2,
                pointSize: rowSize,
                color: entry.isPrimary || isOn ? ViewerPalette.chromeBg : ViewerPalette.ink
            )
        }
    }

    static func drawHandle(in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(
            context,
            bounds,
            radius: Double(ViewerChromeMetrics.Radius.tight),
            color: ViewerPalette.muted2
        )
    }

    /// Every icon this window draws, decoded once and kept.
    ///
    /// Decoding a PNG on every frame of a strip that is open is work the
    /// picture's own frame budget pays for, and the decoded surface is at
    /// the icon's own pixel size: the scale a chrome overlay is drawn at
    /// lives in the cairo context, not in the image, so one decode serves
    /// every scale. A path that failed to decode is remembered as a failure
    /// rather than retried each frame.
    private static var iconCache: [String: OpaquePointer?] = [:]

    private static func icon(path: String) -> OpaquePointer? {
        if let cached = iconCache[path] { return cached }
        let image = cairo_image_surface_create_from_png(path)
        if let image, cairo_surface_status(image) == CAIRO_STATUS_SUCCESS {
            iconCache[path] = image
            return image
        }
        if let image { cairo_surface_destroy(image) }
        iconCache[path] = OpaquePointer?.none
        return nil
    }

    private static func drawIcon(path: String, in context: OpaquePointer, x: Double, y: Double) {
        guard let image = icon(path: path) else { return }
        let width = Double(cairo_image_surface_get_width(image))
        let height = Double(cairo_image_surface_get_height(image))
        guard width > 0, height > 0 else { return }
        cairo_save(context)
        cairo_translate(context, x, y)
        cairo_scale(context, iconSize / width, iconSize / height)
        cairo_set_source_surface(context, image, 0, 0)
        cairo_paint(context)
        cairo_restore(context)
    }
}
#endif
