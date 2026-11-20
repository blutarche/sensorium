#if os(Linux)
import Foundation

/// The numbers the corner pill is built from, in logical points.
///
/// These are the macOS host's collapsed corner pill, reduced to what a
/// layer-shell surface needs: a status dot, the device name, and Stop, on one
/// row. They come from the same 4px design grid, so the two hosts' pills look
/// like one product.
public enum IndicatorPillMetrics {
    /// Space between the pill's edge and its row.
    public static let inset = 5.0
    /// Space between the dot, the name and Stop.
    public static let gap = 12.0
    public static let dotDiameter = 8.0
    public static let stopSize = (width: 34.0, height: 18.0)
    public static let nameFontSize = 12.0
    public static let stopFontSize = 10.0
    /// The widest the device name may be before it ends in an ellipsis.
    public static let nameMaximumWidth = 160.0
    public static let minimumWidth = 90.0
    public static let maximumWidth = 260.0
    public static let cornerRadius = 4.0
    public static let stopCornerRadius = 2.0
    public static let borderWidth = 1.5
    /// Distance between the pill and the corner of the output it sits in.
    public static let cornerMargin = 12.0
}

/// A rectangle in the pill's own coordinates: origin at its top-left corner,
/// y growing downward, measured in logical points.
public struct IndicatorRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < x + width && pointY >= y && pointY < y + height
    }
}

/// Where everything in the pill sits, decided from how wide the device name
/// measured. Pure arithmetic, so the pill's shape is testable without a
/// compositor or a font.
public struct IndicatorPillLayout: Equatable, Sendable {
    public let size: (width: Double, height: Double)
    public let dotRect: IndicatorRect
    public let nameRect: IndicatorRect
    public let stopRect: IndicatorRect
    public let nameIsTruncated: Bool

    /// `measuredNameWidth` is the width the whole name would take on one
    /// line. `nameLineHeight` is the height of that line.
    public init(measuredNameWidth: Double, nameLineHeight: Double = 15) {
        typealias M = IndicatorPillMetrics
        let nameWidth = min(measuredNameWidth, M.nameMaximumWidth)
        nameIsTruncated = measuredNameWidth > M.nameMaximumWidth

        let rowHeight = max(M.stopSize.height, nameLineHeight, M.dotDiameter)
        let contentWidth = M.dotDiameter + M.gap + nameWidth + M.gap + M.stopSize.width
        let width = min(max(contentWidth + 2 * M.inset, M.minimumWidth), M.maximumWidth)
        let height = rowHeight + 2 * M.inset
        size = (width, height)

        let centre = height / 2
        dotRect = IndicatorRect(x: M.inset, y: centre - M.dotDiameter / 2, width: M.dotDiameter, height: M.dotDiameter)
        // Stop is pinned to the right edge, so a short name leaves the extra
        // minimum width between the name and Stop rather than after Stop.
        stopRect = IndicatorRect(
            x: width - M.inset - M.stopSize.width,
            y: centre - M.stopSize.height / 2,
            width: M.stopSize.width,
            height: M.stopSize.height
        )
        let nameX = M.inset + M.dotDiameter + M.gap
        nameRect = IndicatorRect(x: nameX, y: centre - nameLineHeight / 2, width: nameWidth, height: nameLineHeight)
    }

    /// Whether a press at `x`, `y` in the pill's own coordinates lands on Stop.
    public func hitsStop(x: Double, y: Double) -> Bool {
        stopRect.contains(x: x, y: y)
    }

    /// The part of the surface that takes pointer input: the pill itself,
    /// which is the whole surface, so nothing around it is ever clickable.
    public var inputRegion: IndicatorRect {
        IndicatorRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    public static func == (lhs: IndicatorPillLayout, rhs: IndicatorPillLayout) -> Bool {
        lhs.size == rhs.size && lhs.dotRect == rhs.dotRect && lhs.nameRect == rhs.nameRect
            && lhs.stopRect == rhs.stopRect && lhs.nameIsTruncated == rhs.nameIsTruncated
    }
}
#endif
