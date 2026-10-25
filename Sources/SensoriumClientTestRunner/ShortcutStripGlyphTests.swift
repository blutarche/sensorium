import Foundation
import SensoriumClient

/// Every strip action and the pin have their own glyph, no two alike, each
/// inside its own square, and the last one is a circled cross, as Quit App's
/// is on macOS.
func testShortcutStripGlyphSetTests() {
    let glyphs = ShortcutStripAction.allCases.map(\.glyph)
    expect(
        glyphs.indices.allSatisfy { i in glyphs.indices.allSatisfy { j in i == j || glyphs[i] != glyphs[j] } },
        "no two strip actions share a glyph"
    )
    expect(ShortcutStripGlyph.pin(filled: false) != ShortcutStripGlyph.pin(filled: true), "the pin has an outline and a filled form")
    expect(!glyphs.contains(ShortcutStripGlyph.pin(filled: false)), "the pin's glyph is its own")

    let quit = ShortcutStripAction.quitApp.glyph.shapes
    let circles = quit.filter { if case .circle = $0 { true } else { false } }
    let diagonals = quit.filter {
        if case let .path(points, _, _) = $0, points.count == 2 {
            return points[0].x != points[1].x && points[0].y != points[1].y
        }
        return false
    }
    expect(circles.count == 1 && diagonals.count == 2 && quit.count == 3, "Quit App is a circle crossed by two diagonals")

    expect(ShortcutStripAction.lockScreen.symbolName == "lock", "Lock Screen is the outlined padlock, not the solid one")
    expect(
        !ShortcutStripAction.lockScreen.glyph.shapes.contains(where: \.isFilled),
        "and Linux draws its body as an outline too"
    )

    let outline = ShortcutStripGlyph.pin(filled: false).shapes
    expect(!outline.contains(where: \.isFilled), "the unpinned pin is an outline")
    expect(ShortcutStripGlyph.pin(filled: true).shapes.contains(where: \.isFilled), "the pinned pin is filled")

    for glyph in glyphs + [ShortcutStripGlyph.pin(filled: false), ShortcutStripGlyph.pin(filled: true)] {
        for shape in glyph.shapes {
            let bounds = shape.bounds(lineWidth: glyph.lineWidth)
            expect(
                bounds.x >= 0 && bounds.y >= 0
                    && bounds.x + bounds.width <= ShortcutStripGlyph.box && bounds.y + bounds.height <= ShortcutStripGlyph.box,
                "every shape stays inside its \(ShortcutStripGlyph.box)-point square, got \(bounds)"
            )
        }
    }
    print("PASS: every strip action and the pin draw their own glyph, and Quit App's is a circled cross")
}

/// At 1x, 1.5x and 2x every straight outer edge falls on a pixel boundary:
/// both outer edges of an outlined rectangle or circle, both edges of a
/// filled rectangle, and the leading edge of every stroked point. A stroke is
/// never thinner than one device pixel.
func testShortcutStripGlyphPixelSnapTests() {
    func whole(_ value: Double) -> Bool { abs(value - value.rounded()) < 0.0001 }
    let all = ShortcutStripAction.allCases.map(\.glyph) + [ShortcutStripGlyph.pin(filled: false), ShortcutStripGlyph.pin(filled: true)]
    for scale in [1.0, 1.5, 2.0] {
        for glyph in all {
            let lineWidth = glyph.deviceLineWidth(scale: scale)
            expect(lineWidth >= 1, "a stroke is at least one device pixel at \(scale)x, got \(lineWidth)")
            for shape in glyph.deviceShapes(scale: scale) {
                switch shape {
                case let .path(points, _, _):
                    for point in points {
                        expect(whole(point.x - lineWidth / 2) && whole(point.y - lineWidth / 2),
                               "a stroked point's leading edges sit on pixels at \(scale)x, got \(point)")
                    }
                case let .rect(rect, _, filled):
                    let outset = filled ? 0 : lineWidth / 2
                    expect(whole(rect.x - outset) && whole(rect.y - outset)
                           && whole(rect.x + rect.width + outset) && whole(rect.y + rect.height + outset),
                           "a rectangle's outer edges sit on pixels at \(scale)x, got \(rect)")
                case let .circle(center, radius):
                    let reach = radius + lineWidth / 2
                    expect(whole(center.x - reach) && whole(center.x + reach) && whole(center.y - reach) && whole(center.y + reach),
                           "a circle's outer edges sit on pixels at \(scale)x, got \(center) r \(radius)")
                case let .arch(center, radius, _):
                    let reach = radius + lineWidth / 2
                    expect(whole(center.x - reach) && whole(center.x + reach) && whole(center.y - reach),
                           "a shackle's outer edges sit on pixels at \(scale)x, got \(center) r \(radius)")
                }
            }
        }
    }
    print("PASS: the strip glyphs' outer edges snap to device pixels at 1x, 1.5x and 2x")
}

/// At 1x, 1.25x, 1.5x and 2x every glyph's snapped ink stays at least half a
/// device pixel inside its square, so no edge is clipped at any scale.
func testShortcutStripGlyphInkMarginTests() {
    let all = ShortcutStripAction.allCases.map { ($0.title, $0.glyph) }
        + [("Pin", ShortcutStripGlyph.pin(filled: false)), ("Pinned", ShortcutStripGlyph.pin(filled: true))]
    for scale in [1.0, 1.25, 1.5, 2.0] {
        let limit = ShortcutStripGlyph.box * scale - 0.5
        for (title, glyph) in all {
            let lineWidth = glyph.deviceLineWidth(scale: scale)
            for shape in glyph.deviceShapes(scale: scale) {
                let ink = shape.bounds(lineWidth: lineWidth)
                expect(
                    ink.x >= 0.5 && ink.y >= 0.5 && ink.x + ink.width <= limit && ink.y + ink.height <= limit,
                    "\(title)'s ink stays half a pixel inside its \(limit + 0.5)-pixel square at \(scale)x, got \(ink)"
                )
            }
        }
    }
    print("PASS: every strip glyph keeps half a device pixel of margin at 1x, 1.25x, 1.5x and 2x")
}

func testShortcutStripPinCapAndBaseTests() {
    for filled in [false, true] {
        let glyph = ShortcutStripGlyph.pin(filled: filled)
        let outlines = glyph.shapes.compactMap { shape -> [ShortcutStripGlyph.Point]? in
            if case let .path(points, closed, _) = shape, closed { return points }
            return nil
        }
        guard let body = outlines.first else { expect(false, "a pin has a closed body"); return }
        let top = body.map(\.y).min()!
        let cap = body.filter { $0.y == top }
        let capWidth = (cap.map(\.x).max() ?? 0) - (cap.map(\.x).min() ?? 0)
        expect(capWidth >= 8, "both pin forms have a broad horizontal crossbar")
        let lowerCap = body.filter { $0.y > top && $0.y <= top + 1.1 }
        let lowerCapWidth = (lowerCap.map(\.x).max() ?? 0) - (lowerCap.map(\.x).min() ?? 0)
        expect(lowerCapWidth >= 8, "the crossbar has a broad lower edge before the neck narrows")
        let neck = body.filter { $0.y >= 3.8 && $0.y <= 7.3 }
        let neckWidth = (neck.map(\.x).max() ?? 0) - (neck.map(\.x).min() ?? 0)
        let base = body.filter { $0.y >= 10 }
        let baseWidth = (base.map(\.x).max() ?? 0) - (base.map(\.x).min() ?? 0)
        expect(baseWidth > neckWidth * 2, "the domed base spreads wider than the neck")
    }
    print("PASS: outline and filled pins have a broad crossbar, narrow neck and domed base")
}
