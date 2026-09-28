#if canImport(CCairo)
import CCairo
import CGtk4
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
    /// Between one diagnostics group (a titled block, or a pair of columns)
    /// and the next.
    private static let groupGap = Double(ViewerChromeMetrics.Diagnostics.groupGap)
    /// Between a section's own title and its first row, between one row and
    /// the next, and around a note -- the tighter spacing inside a group.
    private static let rowGap = Double(ViewerChromeMetrics.Diagnostics.rowGap)
    /// Between the diagnostics panel's two side-by-side columns.
    private static let columnGutter = Double(ViewerChromeMetrics.Space.md)

    /// Shared by the status panel's own eyebrow and every diagnostics
    /// eyebrow: `SessionHUDEyebrow` on macOS draws all of them at the same
    /// size, 12, mono, medium.
    private static let eyebrowSize: Double = 12
    /// The latency columns' own headers, one size under the block eyebrow
    /// above them, as `SessionHUDEyebrow.columnSize` sets them on macOS.
    private static let columnHeaderSize: Double = 11
    private static let headlineSize: Double = 16
    private static let detailSize: Double = 12
    /// The status panel's own buttons -- `ViewerActionButton.titleFont` on
    /// macOS is 13, medium.
    private static let statusButtonTitleSize: Double = 13
    /// The shortcut strip's confirm/cancel buttons -- `ShortcutStripButton`
    /// on macOS is 12, regular.
    private static let buttonTitleSize: Double = 12
    private static let rowSize: Double = 11
    private static let eyebrowWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.eyebrow)
    private static let headlineWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.headline)
    private static let detailWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.detail)
    private static let buttonWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.button)
    private static let hudLabelWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.hudLabel)
    private static let hudValueWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.hudValue)
    private static let hudNoteWeight = CairoFontWeight(ViewerChromeMetrics.TextWeight.hudNote)
    private static let dotSize: Double = Double(ViewerChromeMetrics.StatusDot.size)
    private static let dotRadius: Double = Double(ViewerChromeMetrics.StatusDot.radius)

    // MARK: - Status panel

    /// How far the eyebrow's own text reaches below `top`, once the square
    /// tone dot beside it -- 2pt down from `top`, the way `toneDot` sits
    /// `inset + 2` from the panel's top on macOS -- has centred it vertically.
    /// Shared between the measurement pass and the drawing pass so the two
    /// cannot disagree about where the eyebrow row ends.
    private static func eyebrowRowHeight(eyebrowHeight: Double) -> Double {
        2 + dotSize / 2 + eyebrowHeight / 2
    }

    private static var eyebrowTracking: Double {
        Double(ViewerChromeMetrics.Tracking.widest) * eyebrowSize
    }

    private static func sectionTitleSize(isNarrow: Bool) -> Double {
        isNarrow ? columnHeaderSize : eyebrowSize
    }

    /// Fills the whole window behind the status panel -- the one overlay with
    /// nothing to measure, since `WaylandOverlayLayout.canvasScrim` always
    /// sizes it to the window itself. Opaque before a first frame exists,
    /// since there is no picture underneath yet; translucent once there is,
    /// marking that frozen picture as stale.
    static func drawScrim(in context: OpaquePointer, bounds: ViewerChromeRect, opaque: Bool) {
        CairoChromeText.fill(context, bounds, radius: 0, color: opaque ? ViewerPalette.chromeBg : ViewerPalette.scrim)
    }

    /// The panel's width comes from the shared measurement rule, so it is the
    /// same width on both platforms for the same button rows; its height is
    /// whatever this state's own text needs.
    static func statusPanelSize(status: ViewerSessionStatus) -> (width: Double, height: Double) {
        let width = ViewerStatusPanelMetrics.sessionPanelWidth { measureButtonTitle($0) }
        let textWidth = width - inset * 2
        let eyebrowHeight = CairoChromeText.measure(
            status.eyebrow, pointSize: eyebrowSize, mono: true, weight: eyebrowWeight, tracking: eyebrowTracking
        ).height
        var height = inset + eyebrowRowHeight(eyebrowHeight: eyebrowHeight)
        height += ViewerStatusPanelMetrics.eyebrowToTitleGap
        height += CairoChromeText.measure(
            status.headline, pointSize: headlineSize, weight: headlineWeight, maxWidth: textWidth
        ).height
        if !status.detail.isEmpty {
            height += ViewerStatusPanelMetrics.titleToDetailGap
            height += CairoChromeText.measure(
                status.detail, pointSize: detailSize, weight: detailWeight, maxWidth: textWidth
            ).height
        }
        if !status.buttons.isEmpty {
            height += ViewerStatusPanelMetrics.detailToButtonsGap + ViewerStatusPanelMetrics.buttonHeight
        }
        return (width, height + inset)
    }

    static func drawStatusPanel(status: ViewerSessionStatus, in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg2)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.chromeBorder2)

        let tone = ViewerPalette.color(for: status.tone)
        let textWidth = bounds.width - inset * 2
        var y = bounds.y + inset
        let eyebrowHeight = CairoChromeText.measure(
            status.eyebrow, pointSize: eyebrowSize, mono: true, weight: eyebrowWeight, tracking: eyebrowTracking
        ).height
        let dotTop = y + 2
        let dotCentreY = dotTop + dotSize / 2
        let eyebrowY = dotCentreY - eyebrowHeight / 2
        CairoChromeText.fill(
            context,
            ViewerChromeRect(x: bounds.x + inset, y: dotTop, width: dotSize, height: dotSize),
            radius: dotRadius,
            color: tone
        )
        CairoChromeText.draw(
            status.eyebrow,
            in: context,
            x: bounds.x + inset + dotSize + tightGap,
            y: eyebrowY,
            pointSize: eyebrowSize,
            color: ViewerPalette.muted2,
            mono: true,
            weight: eyebrowWeight,
            tracking: eyebrowTracking
        )
        y += eyebrowRowHeight(eyebrowHeight: eyebrowHeight) + ViewerStatusPanelMetrics.eyebrowToTitleGap
        y += CairoChromeText.draw(
            status.headline,
            in: context,
            x: bounds.x + inset,
            y: y,
            pointSize: headlineSize,
            color: ViewerPalette.ink,
            weight: headlineWeight,
            maxWidth: textWidth
        )
        if !status.detail.isEmpty {
            y += ViewerStatusPanelMetrics.titleToDetailGap
            _ = CairoChromeText.draw(
                status.detail,
                in: context,
                x: bounds.x + inset,
                y: y,
                pointSize: detailSize,
                color: ViewerPalette.muted,
                weight: detailWeight,
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
        CairoChromeText.measure(title, pointSize: statusButtonTitleSize, weight: buttonWeight).width
    }

    /// Matches `ViewerActionButton` on macOS: flat, `Radius.base`-cornered,
    /// the primary action filled with the accent and every other one filled
    /// with `bg4` and no border of its own.
    private static func drawActionButton(
        title: String,
        isPrimary: Bool,
        in context: OpaquePointer,
        rect: ViewerChromeRect
    ) {
        CairoChromeText.fill(
            context,
            rect,
            radius: Double(ViewerChromeMetrics.Radius.base),
            color: isPrimary ? ViewerPalette.accent : ViewerPalette.bg4
        )
        let size = CairoChromeText.measure(title, pointSize: statusButtonTitleSize, weight: buttonWeight)
        CairoChromeText.draw(
            title,
            in: context,
            x: rect.x + (rect.width - size.width) / 2,
            y: rect.y + (rect.height - size.height) / 2,
            pointSize: statusButtonTitleSize,
            color: isPrimary ? ViewerPalette.chromeBg : ViewerPalette.ink,
            weight: buttonWeight
        )
    }

    // MARK: - Transient notice

    /// The label wraps at this width, the same as `ViewerTransientNoticeView`
    /// on macOS -- not a fixed panel width, so a short refusal draws a small
    /// banner rather than one padded out to 420 regardless of what it says.
    static let noticeMaxTextWidth: Double = Double(ViewerChromeMetrics.Notice.maxTextWidth)
    static let noticeDismissSize: Double = Double(ViewerChromeMetrics.Notice.dismissHitSize)

    static func noticeSize(line: String) -> (width: Double, height: Double) {
        let text = CairoChromeText.measure(line, pointSize: detailSize, weight: detailWeight, maxWidth: noticeMaxTextWidth)
        let width = gap + text.width + tightGap + noticeDismissSize + gap
        let height = max(text.height, noticeDismissSize) + gap * 2
        return (width, height)
    }

    /// The dismiss button's own rect, in the notice's local coordinates --
    /// shared between drawing and the click that dismisses it.
    static func noticeDismissRect(in bounds: ViewerChromeRect) -> ViewerChromeRect {
        ViewerChromeRect(
            x: bounds.x + bounds.width - gap - noticeDismissSize,
            y: bounds.y + (bounds.height - noticeDismissSize) / 2,
            width: noticeDismissSize,
            height: noticeDismissSize
        )
    }

    static func drawNotice(line: String, in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg2)
        CairoChromeText.stroke(context, bounds, radius: radius, color: ViewerPalette.warn)
        let dismissRect = noticeDismissRect(in: bounds)
        let textMaxWidth = max(0, dismissRect.x - tightGap - (bounds.x + gap))
        _ = CairoChromeText.draw(
            line,
            in: context,
            x: bounds.x + gap,
            y: bounds.y + gap,
            pointSize: detailSize,
            color: ViewerPalette.ink,
            weight: detailWeight,
            maxWidth: textMaxWidth
        )
        // Two 1.5pt strokes rather than a "✕" character: a fallback face
        // substituting a box or a bare "X" for that glyph never reaches this
        // notice.
        CairoChromeText.strokeCross(
            context,
            centreX: dismissRect.x + dismissRect.width / 2,
            centreY: dismissRect.y + dismissRect.height / 2,
            size: 8,
            color: ViewerPalette.muted
        )
    }

    // MARK: - Diagnostics

    static let diagnosticsWidth: Double = Double(ViewerChromeMetrics.Diagnostics.width)

    static func diagnosticsSize(blocks: [SessionHUDBlock]) -> (width: Double, height: Double) {
        var height = gap
        for block in blocks {
            if let title = block.title {
                height += CairoChromeText.measure(
                    title, pointSize: eyebrowSize, mono: true, weight: eyebrowWeight, tracking: eyebrowTracking
                ).height
                height += rowGap
            }
            switch block {
            case let .section(section):
                height += sectionHeight(section, width: diagnosticsWidth - gap * 2, isNarrow: false)
            case let .columns(_, left, right):
                // The same halved, gutter-short column `drawDiagnostics`
                // actually draws into -- a note here still measured against
                // the full panel width would wrap to fewer lines than the
                // narrower column really holds, undersizing the panel below.
                let columnWidth = (diagnosticsWidth - gap * 2 - columnGutter) / 2
                height += max(
                    sectionHeight(left, width: columnWidth, isNarrow: true),
                    sectionHeight(right, width: columnWidth, isNarrow: true)
                )
            }
            height += groupGap
        }
        return (diagnosticsWidth, blocks.isEmpty ? height + gap : height - groupGap + gap)
    }

    /// `width` is the section's own drawn width -- the full panel width for a
    /// lone section, or one narrow column's share for one half of a
    /// `.columns` block -- so a note's wrap is measured at the same width
    /// `drawSection` actually wraps it at.
    private static func sectionHeight(_ section: SessionHUDSection, width: Double, isNarrow: Bool) -> Double {
        let titleSize = sectionTitleSize(isNarrow: isNarrow)
        var height = CairoChromeText.measure(
            section.title, pointSize: titleSize, mono: true, weight: eyebrowWeight,
            tracking: Double(ViewerChromeMetrics.Tracking.widest) * titleSize
        ).height + rowGap
        for row in section.rows {
            height += rowLineHeight(row, width: width, isNarrow: isNarrow)
            if let note = row.note {
                let layout = rowLayout(row, width: width, isNarrow: isNarrow)
                height += rowGap + CairoChromeText.measure(
                    note, pointSize: rowSize, weight: hudNoteWeight, maxWidth: layout.noteWidth
                ).height
            }
            height += rowGap
        }
        if let note = section.note {
            height += CairoChromeText.measure(note, pointSize: rowSize, weight: hudNoteWeight, maxWidth: width).height + rowGap
        }
        // The row gap stands between lines, not after the last one.
        return height - rowGap
    }

    private static func rowLayout(_ row: SessionHUDRow, width: Double, isNarrow: Bool) -> SessionHUDRowLayout.Row {
        SessionHUDRowLayout.layout(
            valueWidth: CairoChromeText.measure(
                row.value, pointSize: rowSize, mono: true, weight: hudValueWeight, tabularFigures: true
            ).width,
            columnWidth: width,
            isNarrow: isNarrow,
            showsSparkline: (row.trend?.count ?? 0) >= 2
        )
    }

    /// One line, label and value alike: a value too wide for its column is
    /// cut with an ellipsis, as on macOS.
    private static func rowLineHeight(_ row: SessionHUDRow, width: Double, isNarrow: Bool) -> Double {
        let layout = rowLayout(row, width: width, isNarrow: isNarrow)
        return max(
            CairoChromeText.measure(
                row.label, pointSize: rowSize, mono: true, weight: hudLabelWeight,
                maxWidth: layout.label.width, ellipsize: true
            ).height,
            CairoChromeText.measure(
                row.value, pointSize: rowSize, mono: true, weight: hudValueWeight,
                maxWidth: max(1, layout.value.width), tabularFigures: true, ellipsize: true
            ).height
        )
    }

    /// `isFlagged` is `SessionHUDSnapshot.isAttentionWorthy`: the same flag
    /// that turns the macOS `SessionHUDView`'s own border to its warn colour.
    static func drawDiagnostics(
        blocks: [SessionHUDBlock],
        in context: OpaquePointer,
        bounds: ViewerChromeRect,
        isFlagged: Bool
    ) {
        CairoChromeText.fill(context, bounds, radius: radius, color: ViewerPalette.chromeBg2)
        CairoChromeText.stroke(
            context, bounds, radius: radius,
            color: isFlagged ? ViewerPalette.warn : ViewerPalette.chromeBorder2
        )
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
                    weight: eyebrowWeight,
                    tracking: eyebrowTracking
                ) + rowGap
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
                let columnWidth = (bounds.width - gap * 2 - columnGutter) / 2
                let leftBottom = drawSection(
                    left, in: context, x: bounds.x + gap, y: y, width: columnWidth, isNarrow: true
                )
                let rightBottom = drawSection(
                    right, in: context, x: bounds.x + gap + columnWidth + columnGutter, y: y,
                    width: columnWidth, isNarrow: true
                )
                y = max(leftBottom, rightBottom)
            }
            y += groupGap
        }
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
        let titleSize = sectionTitleSize(isNarrow: isNarrow)
        cursor += CairoChromeText.draw(
            section.title,
            in: context,
            x: x,
            y: cursor,
            pointSize: titleSize,
            color: ViewerPalette.muted2,
            mono: true,
            weight: eyebrowWeight,
            tracking: Double(ViewerChromeMetrics.Tracking.widest) * titleSize
        ) + rowGap
        for row in section.rows {
            let layout = rowLayout(row, width: width, isNarrow: isNarrow)
            let lineHeight = rowLineHeight(row, width: width, isNarrow: isNarrow)
            CairoChromeText.draw(
                row.label,
                in: context,
                x: x + layout.label.x,
                y: cursor,
                pointSize: rowSize,
                color: ViewerPalette.muted,
                mono: true,
                weight: hudLabelWeight,
                maxWidth: layout.label.width,
                ellipsize: true
            )
            let valueColor = row.tone.map(ViewerPalette.color(for:))
                ?? (row.isStale ? ViewerPalette.muted : ViewerPalette.ink)
            CairoChromeText.draw(
                row.value,
                in: context,
                x: x + layout.value.x,
                y: cursor,
                pointSize: rowSize,
                color: valueColor,
                mono: true,
                weight: hudValueWeight,
                maxWidth: max(1, layout.value.width),
                tabularFigures: true,
                ellipsize: true
            )
            if let sparkline = layout.sparkline, let trend = row.trend {
                drawSparkline(
                    trend,
                    in: context,
                    bounds: ViewerChromeRect(
                        x: x + sparkline.x,
                        y: cursor + (lineHeight - sparkline.height) / 2,
                        width: sparkline.width,
                        height: sparkline.height
                    )
                )
            }
            cursor += lineHeight
            if let note = row.note {
                cursor += rowGap + CairoChromeText.draw(
                    note,
                    in: context,
                    x: x + layout.noteIndent,
                    y: cursor + rowGap,
                    pointSize: rowSize,
                    color: ViewerPalette.muted2,
                    weight: hudNoteWeight,
                    maxWidth: layout.noteWidth
                )
            }
            cursor += rowGap
        }
        if let note = section.note {
            cursor += CairoChromeText.draw(
                note,
                in: context,
                x: x,
                y: cursor,
                pointSize: rowSize,
                color: ViewerPalette.muted2,
                weight: hudNoteWeight,
                maxWidth: width
            ) + rowGap
        }
        return cursor - rowGap
    }

    /// `SessionHUDSparklineView`: a 1pt baseline across the middle, the trend
    /// as a 1.5pt polyline inset 1pt top and bottom, and a dot of radius 1 on
    /// its last point.
    private static func drawSparkline(_ samples: [Double], in context: OpaquePointer, bounds: ViewerChromeRect) {
        CairoChromeText.setSource(context, ViewerPalette.line)
        cairo_set_line_width(context, 1)
        cairo_move_to(context, bounds.x, bounds.y + bounds.height / 2)
        cairo_line_to(context, bounds.x + bounds.width, bounds.y + bounds.height / 2)
        cairo_stroke(context)

        let plot = CGRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2)
        // The layout's y grows upward, as AppKit's does; cairo's grows down.
        let points = SessionHUDSparklineLayout.points(for: samples, in: plot).map {
            (x: bounds.x + Double($0.x), y: bounds.y + bounds.height - Double($0.y))
        }
        guard let first = points.first, let last = points.last, points.count >= 2 else { return }
        CairoChromeText.setSource(context, ViewerPalette.accent2)
        cairo_set_line_width(context, 1.5)
        cairo_move_to(context, first.x, first.y)
        for point in points.dropFirst() {
            cairo_line_to(context, point.x, point.y)
        }
        cairo_stroke(context)
        cairo_new_sub_path(context)
        cairo_arc(context, last.x, last.y, 1, 0, 2 * Double.pi)
        cairo_fill(context)
    }

    // MARK: - Shortcut strip

    static let stripHeight: Double = Double(ViewerChromeMetrics.Strip.barHeight)
    static let handleWidth: Double = Double(ViewerChromeMetrics.Strip.handleWidth)
    static let handleHeight: Double = Double(ViewerChromeMetrics.Strip.handleHeight)
    /// Every icon-only button's own square, and every pill's own height --
    /// `ShortcutStripIconButton.size` and `ShortcutStripView.clusterHeight`
    /// on macOS.
    private static let stripButtonHeight: Double = Double(ViewerChromeMetrics.Strip.actionButtonHeight)
    /// Confirm and cancel are always this tall and never accented, whichever
    /// of the two proceeds -- `ShortcutStripButton` on macOS draws both the
    /// same way.
    private static let confirmButtonHeight: Double = Double(ViewerChromeMetrics.Strip.confirmButtonHeight)
    private static let stripButtonMinimumWidth: Double = 56
    /// The question's own face -- `ShortcutStripView.question` is 12, regular.
    private static let stripTextSize: Double = 12
    /// The host name label at the bar's leading edge -- `hostNameLabel` on
    /// macOS is 12, regular.
    private static let hostNameTextSize: Double = 12
    /// `ShortcutStripView.makeCluster`'s own pill: half its height, so the
    /// pill is always a stadium rather than a rounded rectangle.
    private static let clusterRadius: Double = stripButtonHeight / 2
    /// `row.leading == pill.leading + Space.xxs` on macOS, on every side.
    private static let clusterInnerPadding = Double(ViewerChromeMetrics.Space.xxs)
    /// The 2pt `NSStackView.spacing` between two buttons inside one pill.
    private static let clusterButtonSpacing: Double = 2
    /// `clusterRow.spacing` between one pill and the next.
    private static let clusterGroupSpacing = Double(ViewerChromeMetrics.Space.sm)
    /// `ShortcutStripView.actionClusters`: which actions share a pill, and in
    /// what order.
    private static let actionClusterGroups: [[ShortcutStripAction]] = [
        [.missionControl, .applicationWindows, .showDesktop],
        [.desktopLeft, .desktopRight],
        [.spotlight, .launchpad, .switchApp],
        [.lockScreen, .quitApp]
    ]
    /// One button's hit region and the title its tests and tooltip name it by.
    private struct StripButtonSpec {
        let hit: ShortcutStripHit
        let title: String
    }

    private struct StripButtonEntry {
        let hit: ShortcutStripHit
        let rect: ViewerChromeRect
        let title: String
    }

    /// One pill: its own background rect and the buttons drawn inside it.
    private struct StripCluster {
        let pill: ViewerChromeRect
        let buttons: [StripButtonEntry]
    }

    private struct StripClusterLayout {
        let hostNameOrigin: (x: Double, y: Double)
        /// The room between the host name's own origin and the trailing
        /// pin's pill -- what a long host name is truncated to rather
        /// than drawn under the pill.
        let hostNameMaxWidth: Double
        let clusters: [StripCluster]
        /// The width this layout was actually laid out at -- the real bar
        /// width when one was given, or the width the layout invented to
        /// hold its own content when it was not (`stripSize`, sizing an
        /// isolated screenshot).
        let width: Double
    }

    static func stripSize(visibility: ShortcutStripVisibility, hostName: String) -> (width: Double, height: Double) {
        let clustersWidth = stripClusters(hostName: hostName, originX: 0, originY: 0, width: nil).width
        if case .confirming = visibility {
            let confirmRight = stripLayout(visibility: visibility, hostName: hostName, originX: 0, originY: 0)
                .filter { $0.hit != .pin }
                .map { $0.rect.x + $0.rect.width }
                .max() ?? stripButtonMinimumWidth
            return (max(clustersWidth, confirmRight + gap), stripHeight)
        }
        return (clustersWidth, stripHeight)
    }

    private static func confirmButtonWidth(_ title: String) -> Double {
        let text = CairoChromeText.measure(title, pointSize: buttonTitleSize).width
        return max(stripButtonMinimumWidth, text + tightGap * 2)
    }

    /// The confirm row's own left edge -- question, then confirm, then
    /// cancel -- centred as one group across `width` when the real bar width
    /// is known, the way `confirmRow` is centred on `bar` on macOS; held to
    /// the strip's own leading edge, as every other row on it is, when only
    /// the row's natural width is being measured (`stripSize`, sizing an
    /// isolated screenshot to its own content rather than a real bar).
    private static func confirmRowLeft(questionWidth: Double, confirmWidth: Double, cancelWidth: Double, width: Double?) -> Double {
        let totalWidth = questionWidth + tightGap + confirmWidth + tightGap + cancelWidth
        return width.map { max(tightGap, ($0 - totalWidth) / 2) } ?? tightGap
    }

    private static func actionSpec(_ action: ShortcutStripAction) -> StripButtonSpec {
        StripButtonSpec(hit: .action(action), title: action.title)
    }

    private static let pinSpec = StripButtonSpec(hit: .pin, title: "Pin")

    /// Lays out one pill's buttons left to right from `x`, and answers the
    /// pill rect they sit inside -- `clusterInnerPadding` on every side.
    private static func layoutCluster(_ specs: [StripButtonSpec], x: Double, y: Double) -> StripCluster {
        var cursor = x + clusterInnerPadding
        var buttons: [StripButtonEntry] = []
        for spec in specs {
            buttons.append(StripButtonEntry(
                hit: spec.hit,
                rect: ViewerChromeRect(x: cursor, y: y, width: stripButtonHeight, height: stripButtonHeight),
                title: spec.title
            ))
            cursor += stripButtonHeight + clusterButtonSpacing
        }
        let right = specs.isEmpty ? x + clusterInnerPadding : cursor - clusterButtonSpacing + clusterInnerPadding
        return StripCluster(pill: ViewerChromeRect(x: x, y: y, width: right - x, height: stripButtonHeight), buttons: buttons)
    }

    /// The whole non-confirming strip: a host name label at the leading
    /// edge, the four action clusters centred as one group, and a trailing
    /// pill holding the pin -- `ShortcutStripView.init`'s own
    /// layout, translated to cairo.
    ///
    /// When `width` is the real bar width, the cluster row is centred across
    /// it, clamped so it never crosses the strip's own leading edge -- the
    /// same `clusterRow.centerXAnchor` and `leadingAnchor >=` constraints
    /// macOS solves. When `width` is `nil` (`stripSize`, measuring an
    /// isolated screenshot's own content) the same centred math runs against
    /// a width this synthesises to hold the host name and trailing pill
    /// symmetrically, so a caller that lays out at that width reproduces
    /// exactly what was measured.
    private static func clustersWidth(_ clusters: [StripCluster]) -> Double {
        clusters.reduce(0) { $0 + $1.pill.width } + clusterGroupSpacing * Double(max(0, clusters.count - 1))
    }

    private static func stripClusters(hostName: String, originX: Double, originY: Double, width: Double?) -> StripClusterLayout {
        let buttonY = originY + (stripHeight - stripButtonHeight) / 2

        let hostNameSize = CairoChromeText.measure(hostName, pointSize: hostNameTextSize)
        let hostZoneWidth = gap + hostNameSize.width + gap

        let trailingSpecs = [pinSpec]
        let unplacedTrailing = layoutCluster(trailingSpecs, x: 0, y: buttonY)
        let trailingZoneWidth = gap + unplacedTrailing.pill.width + gap

        // Every action cluster's own pill, measured before anything is
        // placed -- both to size an isolated screenshot (`width == nil`) and
        // to know, once the host name and trailing pill have each reserved
        // their own room, how many of these actually fit.
        let actionSpecGroups = actionClusterGroups.map { $0.map(actionSpec) }
        let unplacedActionClusters = actionSpecGroups.map { layoutCluster($0, x: 0, y: buttonY) }

        let barWidth = width ?? (2 * max(hostZoneWidth, trailingZoneWidth) + clustersWidth(unplacedActionClusters))

        // A toolbar's own overflow rule: the host name and the pin's pill
        // are never dropped, so whatever room the action row
        // does not fit in, whole clusters drop off its own right end --
        // Lock Screen and Quit App first -- until what is left fits between
        // them. An isolated screenshot (`width == nil`, `stripSize`) never
        // drops anything, so measuring the strip's own content still sees
        // every cluster.
        var keptGroupCount = actionSpecGroups.count
        if width != nil {
            let available = max(0, barWidth - hostZoneWidth - trailingZoneWidth)
            while keptGroupCount > 0
                && clustersWidth(Array(unplacedActionClusters.prefix(keptGroupCount))) > available {
                keptGroupCount -= 1
            }
        }
        let keptSpecGroups = Array(actionSpecGroups.prefix(keptGroupCount))
        let actionsWidth = clustersWidth(Array(unplacedActionClusters.prefix(keptGroupCount)))

        // Centred across the whole bar, then held clear of both the host
        // name on the left and the trailing pill on the right -- the same
        // `clusterRow.centerXAnchor` plus `leadingAnchor >=` and
        // `trailingAnchor <=` constraints macOS solves, so the row can
        // never slide into either fixed zone even off-centre.
        let leftBound = originX + max(Double(ViewerChromeMetrics.Space.xs), hostZoneWidth)
        let rightBound = originX + barWidth - trailingZoneWidth - actionsWidth
        let centered = originX + (barWidth - actionsWidth) / 2
        let clusterRowLeft = min(max(leftBound, centered), max(leftBound, rightBound))

        var cursorX = clusterRowLeft
        var placedActionClusters: [StripCluster] = []
        for specs in keptSpecGroups {
            let cluster = layoutCluster(specs, x: cursorX, y: buttonY)
            placedActionClusters.append(cluster)
            cursorX += cluster.pill.width + clusterGroupSpacing
        }

        let trailingX = originX + barWidth - gap - unplacedTrailing.pill.width
        let placedTrailing = layoutCluster(trailingSpecs, x: trailingX, y: buttonY)

        let hostNameOriginX = originX + gap
        return StripClusterLayout(
            hostNameOrigin: (x: hostNameOriginX, y: originY + (stripHeight - hostNameSize.height) / 2),
            hostNameMaxWidth: max(0, trailingX - hostNameOriginX - gap),
            clusters: placedActionClusters + [placedTrailing],
            width: barWidth
        )
    }

    /// Every pressable thing on the strip, in the order it is drawn. Built
    /// once and used for both the drawing and the hit test, so the two cannot
    /// disagree about where a button is. The confirm row keeps the pin where
    /// it was, as macOS does.
    static func stripLayout(
        visibility: ShortcutStripVisibility,
        hostName: String,
        originX: Double,
        originY: Double,
        width: Double? = nil
    ) -> [(hit: ShortcutStripHit, rect: ViewerChromeRect, title: String)] {
        let clusters = stripClusters(hostName: hostName, originX: originX, originY: originY, width: width).clusters
        if case let .confirming(action) = visibility, let question = action.confirmation(hostName: hostName) {
            let questionWidth = CairoChromeText.measure(question.question, pointSize: stripTextSize).width
            let confirmWidth = confirmButtonWidth(question.confirmTitle)
            let cancelWidth = confirmButtonWidth(question.cancelTitle)
            let groupLeft = originX + confirmRowLeft(
                questionWidth: questionWidth, confirmWidth: confirmWidth, cancelWidth: cancelWidth, width: width
            )
            let top = originY + (stripHeight - confirmButtonHeight) / 2
            // `ShortcutStripView.confirmRow.spacing` -- `ViewerDesign.Space.xs`,
            // the same 8 this row already carries as `tightGap` -- between
            // every one of the row's three pieces, question included.
            let confirmX = groupLeft + questionWidth + tightGap
            let cancelX = confirmX + confirmWidth + tightGap
            let pin: [(hit: ShortcutStripHit, rect: ViewerChromeRect, title: String)] =
                (clusters.last?.buttons ?? []).map { ($0.hit, $0.rect, $0.title) }
            return [
                (
                    .confirm,
                    ViewerChromeRect(x: confirmX, y: top, width: confirmWidth, height: confirmButtonHeight),
                    question.confirmTitle
                ),
                (
                    .cancel,
                    ViewerChromeRect(x: cancelX, y: top, width: cancelWidth, height: confirmButtonHeight),
                    question.cancelTitle
                )
            ] + pin
        }
        return clusters.flatMap { cluster in cluster.buttons.map { ($0.hit, $0.rect, $0.title) } }
    }

    static func drawStrip(
        visibility: ShortcutStripVisibility,
        hostName: String,
        isPinned: Bool,
        in context: OpaquePointer,
        bounds: ViewerChromeRect
    ) {
        // Flat and full-width, only as translucent as `bar`'s own 0.88-alpha
        // fill -- never the boxed, bordered card the rest of this system's
        // panels are -- with a hairline at the bottom rather than a stroke
        // running the whole way round, the way `separator` sits under `bar`.
        CairoChromeText.fill(context, bounds, radius: 0, color: ViewerPalette.chromeBg2.withAlpha(0.88))
        CairoChromeText.fill(
            context,
            ViewerChromeRect(x: bounds.x, y: bounds.y + bounds.height - 1, width: bounds.width, height: 1),
            radius: 0,
            color: ViewerPalette.chromeBorder2
        )
        let layout = stripClusters(hostName: hostName, originX: bounds.x, originY: bounds.y, width: bounds.width)
        CairoChromeText.draw(
            hostName,
            in: context,
            x: layout.hostNameOrigin.x,
            y: layout.hostNameOrigin.y,
            pointSize: hostNameTextSize,
            color: ViewerPalette.muted,
            maxWidth: layout.hostNameMaxWidth,
            ellipsize: true
        )
        let confirmation: ShortcutStripConfirmation? = if case let .confirming(action) = visibility {
            action.confirmation(hostName: hostName)
        } else {
            nil
        }
        // The confirm row replaces the action clusters only; the pin's pill
        // stays, as it does on macOS.
        let clusters = confirmation == nil ? layout.clusters : Array(layout.clusters.suffix(1))
        for cluster in clusters {
            CairoChromeText.fill(context, cluster.pill, radius: clusterRadius, color: ViewerPalette.chromeBg.withAlpha(0.55))
            for entry in cluster.buttons {
                guard let glyph = stripGlyph(for: entry.hit, isPinned: isPinned) else { continue }
                let box = ShortcutStripGlyph.box
                drawStripGlyph(
                    glyph,
                    in: context,
                    x: entry.rect.x + (entry.rect.width - box) / 2,
                    y: entry.rect.y + (entry.rect.height - box) / 2,
                    color: ViewerPalette.ink
                )
            }
        }
        guard let question = confirmation else { return }
        let size = CairoChromeText.measure(question.question, pointSize: stripTextSize)
        let confirmWidth = confirmButtonWidth(question.confirmTitle)
        let cancelWidth = confirmButtonWidth(question.cancelTitle)
        let left = bounds.x + confirmRowLeft(
            questionWidth: size.width, confirmWidth: confirmWidth, cancelWidth: cancelWidth, width: bounds.width
        )
        CairoChromeText.draw(
            question.question,
            in: context,
            x: left,
            y: bounds.y + (stripHeight - size.height) / 2,
            pointSize: stripTextSize,
            color: ViewerPalette.ink
        )
        for entry in stripLayout(
            visibility: visibility, hostName: hostName, originX: bounds.x, originY: bounds.y, width: bounds.width
        ) where entry.hit == .confirm || entry.hit == .cancel {
            // Never accented, whichever of the two proceeds.
            CairoChromeText.fill(
                context, entry.rect, radius: Double(ViewerChromeMetrics.Radius.base), color: ViewerPalette.bg4
            )
            let titleSize = CairoChromeText.measure(entry.title, pointSize: buttonTitleSize)
            CairoChromeText.draw(
                entry.title,
                in: context,
                x: entry.rect.x + (entry.rect.width - titleSize.width) / 2,
                y: entry.rect.y + (entry.rect.height - titleSize.height) / 2,
                pointSize: buttonTitleSize,
                color: ViewerPalette.ink
            )
        }
    }

    /// macOS swaps `pin` for `pin.fill` while pinned, and fills nothing
    /// behind it.
    private static func stripGlyph(for hit: ShortcutStripHit, isPinned: Bool) -> ShortcutStripGlyph? {
        switch hit {
        case let .action(action): action.glyph
        case .pin: ShortcutStripGlyph.pin(filled: isPinned)
        case .confirm, .cancel: nil
        }
    }

    /// `glyph` drawn in device pixels from the device pixel nearest `x`, `y`,
    /// so its strokes and edges stay crisp at a fractional scale.
    private static func drawStripGlyph(
        _ glyph: ShortcutStripGlyph, in context: OpaquePointer, x: Double, y: Double, color: ViewerColor
    ) {
        var originX = x
        var originY = y
        cairo_user_to_device(context, &originX, &originY)
        var matrix = cairo_matrix_t()
        cairo_get_matrix(context, &matrix)
        let scale = matrix.xx > 0 ? matrix.xx : 1
        cairo_save(context)
        cairo_identity_matrix(context)
        cairo_translate(context, originX.rounded(), originY.rounded())
        CairoChromeText.setSource(context, color)
        cairo_set_line_width(context, glyph.deviceLineWidth(scale: scale))
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)
        for shape in glyph.deviceShapes(scale: scale) {
            cairo_new_path(context)
            switch shape {
            case let .path(points, closed, filled):
                for (index, point) in points.enumerated() {
                    if index == 0 {
                        cairo_move_to(context, point.x, point.y)
                    } else {
                        cairo_line_to(context, point.x, point.y)
                    }
                }
                if closed { cairo_close_path(context) }
                if filled { cairo_fill_preserve(context) }
                cairo_stroke(context)
            case let .rect(rect, radius, filled):
                CairoChromeText.addRoundedRect(context, rect, radius: radius)
                if filled {
                    cairo_fill(context)
                } else {
                    cairo_stroke(context)
                }
            case let .circle(center, radius):
                cairo_arc(context, center.x, center.y, radius, 0, 2 * Double.pi)
                cairo_stroke(context)
            case let .arch(center, radius, legLength):
                cairo_move_to(context, center.x - radius, center.y + legLength)
                cairo_line_to(context, center.x - radius, center.y)
                cairo_arc(context, center.x, center.y, radius, Double.pi, 2 * Double.pi)
                cairo_line_to(context, center.x + radius, center.y + legLength)
                cairo_stroke(context)
            }
        }
        cairo_restore(context)
    }

    /// A pill the height of its own bounds, filled and outlined the way
    /// `ShortcutStripHandle`'s layer is on macOS -- never the square-cornered
    /// `.tight` radius the rest of this system's small shapes use.
    static func drawHandle(in context: OpaquePointer, bounds: ViewerChromeRect) {
        let pillRadius = bounds.height / 2
        CairoChromeText.fill(context, bounds, radius: pillRadius, color: ViewerPalette.ink.withAlpha(0.3))
        CairoChromeText.stroke(context, bounds, radius: pillRadius, color: ViewerPalette.chromeBg.withAlpha(0.35))
    }
}
#endif
