import Foundation

/// Where one HUD row's label, value, sparkline and note sit: the geometry
/// `SessionHUDRowView` gets from its fixed-width label column and stack views
/// on macOS, stated as numbers a cairo row can draw to.
public enum SessionHUDRowLayout {
    public struct Span: Equatable, Sendable {
        public let x: Double
        public let width: Double
    }

    public struct Row: Equatable, Sendable {
        public let label: Span
        /// Left-aligned after the label column. A value wider than `width` is
        /// cut with an ellipsis, as a truncating-tail `NSTextField` cuts it.
        public let value: Span
        /// Only on a full-width row whose trend has a line to draw. Its `y` is
        /// 0: it is centred on the label and value line wherever that sits.
        public let sparkline: ViewerChromeRect?
        public let noteIndent: Double
        public let noteWidth: Double
    }

    public static func layout(
        valueWidth: Double,
        columnWidth: Double,
        isNarrow: Bool,
        showsSparkline: Bool
    ) -> Row {
        let metrics = ViewerChromeMetrics.Diagnostics.self
        let gap = Double(ViewerChromeMetrics.Space.xs)
        let labelWidth = Double(isNarrow ? metrics.narrowLabelColumnWidth : metrics.labelColumnWidth)
        let valueX = labelWidth + gap
        let sparkline: ViewerChromeRect? = showsSparkline && !isNarrow
            ? ViewerChromeRect(
                x: columnWidth - Double(metrics.sparklineWidth),
                y: 0,
                width: Double(metrics.sparklineWidth),
                height: Double(metrics.sparklineHeight)
            )
            : nil
        let reserve = sparkline.map { $0.width + gap } ?? 0
        let valueRoom = max(0, columnWidth - valueX - reserve)
        return Row(
            label: Span(x: 0, width: labelWidth),
            value: Span(x: valueX, width: min(valueWidth, valueRoom)),
            sparkline: sparkline,
            noteIndent: gap,
            noteWidth: columnWidth - gap
        )
    }
}

/// Keeps the session status panel off the diagnostics panel, which is pinned
/// to the canvas's leading edge. The status panel's buttons are what ends an
/// outage, and the readings behind a lost session are still worth reading, so
/// neither covers the other when the canvas has room for both.
public enum SessionHUDClearance {
    /// How much of the canvas's leading edge the diagnostics panel holds: its
    /// inset, its width, and one more inset as the gap beside it.
    public static let keepClear = Double(
        ViewerChromeMetrics.Diagnostics.edgeInset * 2 + ViewerChromeMetrics.Diagnostics.width
    )

    /// The x of the status panel's leading edge on a canvas `canvasWidth`
    /// wide: centred, unless that puts it over the leading `keepClear` points
    /// and the canvas has room to the right of them -- then centred in that
    /// room. With no room to move into it stays centred and the panel,
    /// drawn above, covers what it must.
    public static func statusPanelOriginX(canvasWidth: Double, panelWidth: Double, keepClear: Double) -> Double {
        let centred = (canvasWidth - panelWidth) / 2
        guard centred < keepClear, canvasWidth - keepClear >= panelWidth else { return centred }
        return keepClear + (canvasWidth - keepClear - panelWidth) / 2
    }
}
