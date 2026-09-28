/// One strip button's icon where there are no SF Symbols: drawn from lines,
/// rectangles and circles on an 18-point square, each shaped after the
/// symbol macOS draws for the same action.
public struct ShortcutStripGlyph: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Shape: Equatable, Sendable {
        /// Stroked through `points`; a filled path is stroked as well, so it
        /// is the same size as its outline.
        case path([Point], closed: Bool, filled: Bool)
        case rect(ViewerChromeRect, radius: Double, filled: Bool)
        case circle(center: Point, radius: Double)
        /// A padlock's shackle: the top half of a circle with straight legs
        /// running `legLength` down from both ends.
        case arch(center: Point, radius: Double, legLength: Double)

        public var isFilled: Bool {
            switch self {
            case let .path(_, _, filled), let .rect(_, _, filled): filled
            case .circle, .arch: false
            }
        }

        public func bounds(lineWidth: Double) -> ViewerChromeRect {
            let half = lineWidth / 2
            switch self {
            case let .path(points, _, _):
                let xs = points.map(\.x)
                let ys = points.map(\.y)
                let minX = (xs.min() ?? 0) - half
                let minY = (ys.min() ?? 0) - half
                return ViewerChromeRect(
                    x: minX, y: minY, width: (xs.max() ?? 0) + half - minX, height: (ys.max() ?? 0) + half - minY
                )
            case let .rect(rect, _, filled):
                let outset = filled ? 0 : half
                return ViewerChromeRect(
                    x: rect.x - outset, y: rect.y - outset, width: rect.width + outset * 2, height: rect.height + outset * 2
                )
            case let .circle(center, radius):
                let reach = radius + half
                return ViewerChromeRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
            case let .arch(center, radius, legLength):
                let reach = radius + half
                return ViewerChromeRect(
                    x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach + legLength + half
                )
            }
        }
    }

    public static let box: Double = 18

    /// The stroke of the symbol this glyph stands for, in points, as the
    /// macOS strip draws it: 18 points at medium weight, fitted to its square.
    public let lineWidth: Double
    public let shapes: [Shape]

    public init(lineWidth: Double, shapes: [Shape]) {
        self.lineWidth = lineWidth
        self.shapes = shapes
    }

    public func deviceLineWidth(scale: Double) -> Double {
        max(1, lineWidth * scale)
    }

    /// `shapes` in device pixels at `scale`, from a square whose corner is on
    /// a device pixel. A rectangle's or circle's outer edges, a filled
    /// rectangle's edges, and the leading edge of every stroked point fall on
    /// pixel boundaries; a stroke that is not a whole number of pixels wide
    /// shades its inner edge, as the symbol's own does.
    public func deviceShapes(scale: Double) -> [Shape] {
        let width = deviceLineWidth(scale: scale)
        func stroked(_ value: Double) -> Double { (value * scale - width / 2).rounded() + width / 2 }
        func strokedPoint(_ point: Point) -> Point { Point(stroked(point.x), stroked(point.y)) }
        func edge(_ value: Double) -> Double { (value * scale).rounded() }
        return shapes.map { shape in
            switch shape {
            case let .path(points, closed, filled):
                return .path(points.map(strokedPoint), closed: closed, filled: filled)
            case let .rect(rect, radius, true):
                let left = edge(rect.x)
                let top = edge(rect.y)
                return .rect(
                    ViewerChromeRect(x: left, y: top, width: edge(rect.x + rect.width) - left, height: edge(rect.y + rect.height) - top),
                    radius: radius * scale,
                    filled: true
                )
            case let .rect(rect, radius, false):
                let left = (rect.x * scale - width / 2).rounded()
                let top = (rect.y * scale - width / 2).rounded()
                let right = ((rect.x + rect.width) * scale + width / 2).rounded()
                let bottom = ((rect.y + rect.height) * scale + width / 2).rounded()
                return .rect(
                    ViewerChromeRect(
                        x: left + width / 2, y: top + width / 2, width: right - left - width, height: bottom - top - width
                    ),
                    radius: radius * scale,
                    filled: false
                )
            case let .circle(center, radius):
                let outer = Self.outerRange(center.x, radius, scale: scale, width: width)
                let top = ((center.y - radius) * scale - width / 2).rounded()
                let reach = (outer.upper - outer.lower) / 2
                return .circle(center: Point(outer.lower + reach, top + reach), radius: reach - width / 2)
            case let .arch(center, radius, legLength):
                let outer = Self.outerRange(center.x, radius, scale: scale, width: width)
                let top = ((center.y - radius) * scale - width / 2).rounded()
                let reach = (outer.upper - outer.lower) / 2
                let middle = top + reach
                return .arch(
                    center: Point(outer.lower + reach, middle),
                    radius: reach - width / 2,
                    legLength: ((center.y + legLength) * scale).rounded() - middle
                )
            }
        }
    }

    /// A circle's left and right outer edges, each on a device pixel.
    private static func outerRange(
        _ centerX: Double, _ radius: Double, scale: Double, width: Double
    ) -> (lower: Double, upper: Double) {
        (((centerX - radius) * scale - width / 2).rounded(), ((centerX + radius) * scale + width / 2).rounded())
    }

    /// Unpinned is an outline; pinned is filled, as `pin` and `pin.fill` are.
    public static func pin(filled: Bool) -> ShortcutStripGlyph {
        let left = [
            Point(4.5, 1.2), Point(7, 3.9), Point(6.95, 7.2), Point(5.5, 8.2),
            Point(4.4, 9.2), Point(3.8, 10.3), Point(3.55, 11.7)
        ]
        let right = left.map { Point(17.7 - $0.x, $0.y) }
        return ShortcutStripGlyph(lineWidth: 1.3, shapes: [
            .path(left.reversed() + right, closed: true, filled: filled),
            .path([Point(8.85, 11.7), Point(8.85, 16.75)], closed: false, filled: false)
        ])
    }
}

extension ShortcutStripAction {
    /// The glyph Linux draws for `symbolName`.
    public var glyph: ShortcutStripGlyph {
        typealias Point = ShortcutStripGlyph.Point
        func line(_ points: Point...) -> ShortcutStripGlyph.Shape { .path(points, closed: false, filled: false) }
        func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double, radius: Double) -> ShortcutStripGlyph.Shape {
            .rect(ViewerChromeRect(x: x, y: y, width: width, height: height), radius: radius, filled: false)
        }
        func block(_ x: Double, _ y: Double, _ width: Double, _ height: Double, radius: Double) -> ShortcutStripGlyph.Shape {
            .rect(ViewerChromeRect(x: x, y: y, width: width, height: height), radius: radius, filled: true)
        }
        switch self {
        case .missionControl:
            return ShortcutStripGlyph(lineWidth: 1, shapes: [
                frame(2.08, 4.7, 6.42, 3.81, radius: 0.65),
                frame(3.25, 10.58, 5.51, 3.12, radius: 0.65),
                frame(11.06, 5.51, 4.82, 7.5, radius: 0.65)
            ])
        case .applicationWindows:
            return ShortcutStripGlyph(lineWidth: 1.25, shapes: [
                block(4.64, 1.7, 8.25, 0.88, radius: 0.44),
                block(3.33, 3.57, 10.88, 1.12, radius: 0.56),
                frame(2.35, 6.35, 12.82, 9.95, radius: 1.55),
                block(4.07, 8.07, 1, 1, radius: 0.5),
                block(5.83, 8.07, 1, 1, radius: 0.5),
                block(7.57, 8.07, 1, 1, radius: 0.5)
            ])
        case .showDesktop:
            return ShortcutStripGlyph(lineWidth: 1.2, shapes: [
                frame(2.21, 4.34, 13.18, 10.48, radius: 1.9),
                line(Point(2.21, 6.45), Point(15.39, 6.45)),
                block(4.3, 11.25, 9, 1.9, radius: 0.8)
            ])
        case .desktopLeft:
            return ShortcutStripGlyph(lineWidth: 1.4, shapes: [
                frame(2.5, 2.45, 12.91, 13.04, radius: 1.5),
                line(Point(5.88, 8.97), Point(12.09, 8.97)),
                line(Point(8.39, 6.46), Point(5.88, 8.97), Point(8.39, 11.48))
            ])
        case .desktopRight:
            return ShortcutStripGlyph(lineWidth: 1.4, shapes: [
                frame(2.5, 2.45, 12.91, 13.04, radius: 1.5),
                line(Point(5.82, 8.97), Point(12.03, 8.97)),
                line(Point(9.52, 6.46), Point(12.03, 8.97), Point(9.52, 11.48))
            ])
        case .spotlight:
            return ShortcutStripGlyph(lineWidth: 1.45, shapes: [
                .circle(center: Point(7.67, 7.65), radius: 5.2),
                .path(
                    [Point(11.26, 11.54), Point(14.91, 15.19), Point(15.19, 14.91), Point(11.54, 11.26)],
                    closed: true, filled: true
                )
            ])
        case .launchpad:
            return ShortcutStripGlyph(lineWidth: 1, shapes: [2, 7.05, 12.1].flatMap { y in
                [1.95, 6.95, 11.95].map { x in block(x, y, 4.05, 4.2, radius: 0.9) }
            })
        case .switchApp:
            return ShortcutStripGlyph(lineWidth: 1.3, shapes: [
                frame(2.6, 2.55, 12.91, 13.04, radius: 1.5),
                line(Point(6.1, 6.82), Point(12, 6.82)),
                line(Point(7.74, 5.18), Point(6.1, 6.82), Point(7.74, 8.46)),
                line(Point(6.1, 11.35), Point(12, 11.35)),
                line(Point(10.33, 9.68), Point(12, 11.35), Point(10.33, 13.02))
            ])
        case .lockScreen:
            return ShortcutStripGlyph(lineWidth: 1.75, shapes: [
                .arch(center: Point(8.85, 5.4), radius: 3.95, legLength: 1.5),
                block(2.45, 6.9, 12.7, 10.5, radius: 2.6)
            ])
        case .quitApp:
            return ShortcutStripGlyph(lineWidth: 1.35, shapes: [
                .circle(center: Point(8.65, 8.66), radius: 6.95),
                line(Point(6.46, 6.37), Point(10.95, 11)),
                line(Point(10.95, 6.37), Point(6.46, 11))
            ])
        }
    }
}
