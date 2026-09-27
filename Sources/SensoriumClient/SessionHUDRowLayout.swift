import Foundation

/// Where one HUD row's label and its value sit, so neither ever draws over
/// the other -- the same guarantee a fixed-width `NSTextField` column next
/// to an adjacent stack view gives `SessionHUDRowView` on macOS for free,
/// and which a cairo row has to be told to keep instead.
///
/// Every `measure...` closure answers a string's own drawn width at
/// whatever face, size and weight the row actually draws it in -- pango on
/// Linux, nothing here -- so this is pure geometry, verified without a font
/// engine.
public enum SessionHUDRowLayout {
    /// How wide a section's own label column should be: just wide enough for
    /// the widest of `labels`, never so wide it pushes the value beside it
    /// under the smaller of that section's own widest `values` and
    /// `valueWidthCap`.
    ///
    /// The cap, not a flat reservation, is what lets a section of short
    /// values (a latency reading like "18.5 ms") give its label column more
    /// room than a fixed floor ever would, while a section with one
    /// outlying long value (`DROPPED HERE`'s own
    /// "4 before decode, 1 before present") still reserves `valueWidthCap`
    /// for it to wrap into, rather than losing that room to the label.
    public static func sectionLabelColumnWidth(
        labels: [String],
        values: [String],
        rowWidth: Double,
        columnGap: Double,
        valueWidthCap: Double,
        measureLabel: (String) -> Double,
        measureValue: (String) -> Double
    ) -> Double {
        let widestLabel = labels.reduce(0.0) { max($0, measureLabel($1)) }
        let widestValue = values.reduce(0.0) { max($0, measureValue($1)) }
        let reservedValueWidth = min(widestValue, valueWidthCap)
        return min(widestLabel, max(0, rowWidth - columnGap - reservedValueWidth))
    }

    public static func layout(
        label: String,
        value: String,
        rowWidth: Double,
        labelColumnWidth: Double,
        columnGap: Double,
        measureLabel: (String) -> Double,
        measureValue: (String) -> Double
    ) -> (label: (x: Double, width: Double), value: (x: Double, width: Double)) {
        // Capped to its own column, exactly as a label's own fixed-width
        // AppKit column caps it: a label longer than the column it is given
        // never reaches past it, whatever the actual font measures it at.
        let labelWidth = min(measureLabel(label), labelColumnWidth)
        let valueColumnWidth = max(0, rowWidth - labelColumnWidth - columnGap)
        let valueWidth = min(measureValue(value), valueColumnWidth)
        return (
            label: (x: 0, width: labelWidth),
            // Right-aligned to the row's own trailing edge, and never wider
            // than the column left over once the label's own column and the
            // gap between them are taken out.
            value: (x: rowWidth - valueWidth, width: valueWidth)
        )
    }
}
