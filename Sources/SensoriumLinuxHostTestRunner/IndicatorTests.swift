#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// The long sample name from the design notes: far wider than a pill allows.
let longDeviceName = "workstation-west-annex-render-node-07"

@MainActor
enum IndicatorTests {
    static let all: [(String, () async -> Void)] = [
        ("a long device name truncates inside the pill's width bounds", testLongNameTruncatesInsideTheWidthBounds),
        ("a measured long name truncates and a short one does not", testMeasuredNamesTruncateOnlyWhenTooWide),
        ("the pill's rows sit inside it and never overlap", testRowsSitInsideThePillAndNeverOverlap),
        ("only the Stop rectangle hits Stop", testOnlyTheStopRectangleHitsStop),
        ("the drawn pill follows the output scale and paints Stop", testDrawnPillFollowsTheScaleAndPaintsStop)
    ]

    static func testLongNameTruncatesInsideTheWidthBounds() async {
        let long = IndicatorPillLayout(measuredNameWidth: 400)
        expect(long.nameIsTruncated, "a name wider than its column is truncated")
        expect(long.nameRect.width == IndicatorPillMetrics.nameMaximumWidth, "a truncated name fills exactly its column")
        expect(long.size.width <= IndicatorPillMetrics.maximumWidth, "the pill never grows past its maximum width")

        let short = IndicatorPillLayout(measuredNameWidth: 20)
        expect(!short.nameIsTruncated, "a short name is not truncated")
        expect(short.size.width >= IndicatorPillMetrics.minimumWidth, "a short name still gets the minimum width")
    }

    static func testMeasuredNamesTruncateOnlyWhenTooWide() async {
        let long = IndicatorPillRenderer.layout(for: longDeviceName)
        expect(long.layout.nameIsTruncated, "the long sample name is truncated by real text measurement")
        expect(Double(long.logicalWidth) <= IndicatorPillMetrics.maximumWidth, "the long sample name's pill fits its maximum width")

        let short = IndicatorPillRenderer.layout(for: "Studio")
        expect(!short.layout.nameIsTruncated, "a short sample name is not truncated")
        expect(short.logicalWidth < long.logicalWidth, "a short name makes a narrower pill than a long one")
    }

    static func testRowsSitInsideThePillAndNeverOverlap() async {
        for width in [0.0, 20, 60, 160, 400] {
            let layout = IndicatorPillLayout(measuredNameWidth: width)
            let bounds = IndicatorRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height)
            for rect in [layout.dotRect, layout.nameRect, layout.stopRect] {
                expect(
                    rect.x >= bounds.x && rect.y >= bounds.y
                        && rect.x + rect.width <= bounds.width && rect.y + rect.height <= bounds.height,
                    "every element sits inside the pill at name width \(width)"
                )
            }
            expect(layout.dotRect.x + layout.dotRect.width <= layout.nameRect.x, "the dot ends before the name at \(width)")
            expect(layout.nameRect.x + layout.nameRect.width <= layout.stopRect.x, "the name ends before Stop at \(width)")
        }
    }

    static func testOnlyTheStopRectangleHitsStop() async {
        let layout = IndicatorPillLayout(measuredNameWidth: 80)
        let stop = layout.stopRect
        expect(stop.width >= IndicatorPillMetrics.stopSize.width && stop.height >= IndicatorPillMetrics.stopSize.height,
               "Stop is at least its design size")
        expect(stop.x + stop.width == layout.size.width - IndicatorPillMetrics.inset, "Stop sits one inset from the pill's right edge")
        expect(layout.hitsStop(x: stop.x + stop.width / 2, y: stop.y + stop.height / 2), "the centre of Stop hits it")
        expect(layout.hitsStop(x: stop.x, y: stop.y), "Stop's top-left corner hits it")
        expect(!layout.hitsStop(x: stop.x - 0.5, y: stop.y + 1), "just left of Stop misses")
        expect(!layout.hitsStop(x: stop.x + stop.width, y: stop.y + 1), "Stop's right edge is outside it")
        expect(!layout.hitsStop(x: stop.x + 1, y: stop.y - 0.5), "just above Stop misses")
        expect(!layout.hitsStop(x: stop.x + 1, y: stop.y + stop.height), "Stop's bottom edge is outside it")
        expect(!layout.hitsStop(x: layout.nameRect.x + 1, y: layout.nameRect.y + 1), "the device name is not Stop")
        expect(!layout.hitsStop(x: layout.dotRect.x + 1, y: layout.dotRect.y + 1), "the dot is not Stop")
        expect(
            layout.inputRegion == IndicatorRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height),
            "the input region is the pill and nothing around it"
        )
    }

    static func testDrawnPillFollowsTheScaleAndPaintsStop() async {
        let plain = IndicatorPillRenderer.render(deviceName: "Studio", appearance: .dark, scale: 1)
        let scaled = IndicatorPillRenderer.render(deviceName: "Studio", appearance: .dark, scale: 1.5)
        expect(plain.pixelWidth * plain.pixelHeight > 0, "a pill has pixels")
        expect(
            scaled.pixelWidth == Int((Double(plain.pixelWidth) * 1.5).rounded())
                && scaled.pixelHeight == Int((Double(plain.pixelHeight) * 1.5).rounded()),
            "the buffer grows with the output scale"
        )

        // Stop's fill is the alert colour: the pixel left of its label's
        // centre, on a row where no glyph is drawn near its edge.
        let layout = IndicatorPillRenderer.layout(for: "Studio").layout
        let x = Int(layout.stopRect.x + 3)
        let y = Int(layout.stopRect.y + layout.stopRect.height / 2)
        let offset = y * plain.stride + x * 4
        let blue = plain.pixels[offset], green = plain.pixels[offset + 1], red = plain.pixels[offset + 2]
        expect(plain.pixels[offset + 3] == 255, "the Stop button is opaque")
        expect(red == 0xE2 && green == 0x6F && blue == 0x5C, "the Stop button is painted in the alert colour")
        expect(plain.pixels[3] == 0 || plain.pixels[3] < 255, "the pill's rounded corner leaves its corner pixel see-through")
    }
}
#endif
