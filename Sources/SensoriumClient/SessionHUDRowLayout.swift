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
