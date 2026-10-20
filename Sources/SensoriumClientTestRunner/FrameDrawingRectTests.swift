import SensoriumClient

/// A frame that is within a pixel or two of the rect it was fitted into is
/// drawn at its own size on whole pixels, so every texel lands on exactly one
/// drawable pixel and nothing is resampled.
func testFrameDrawingRectTests() {
    func drawn(
        _ fitted: CanvasVideoRect,
        frame width: Double,
        _ height: Double,
        topInset: Double = 0
    ) -> CanvasVideoRect {
        CanvasPresentationLayout.drawingRect(
            fittedRect: fitted,
            frameWidth: width,
            frameHeight: height,
            topInset: topInset
        )
    }

    let wide = CanvasPresentationLayout.videoRect(
        sourceWidth: 3424,
        sourceHeight: 1926,
        viewportWidth: 3840,
        viewportHeight: 1926
    )
    let exact = drawn(wide, frame: 3424, 1926)
    expect(
        exact == CanvasVideoRect(x: 208, y: 0, width: 3424, height: 1926),
        "a frame the exact size of its fitted rect is drawn there at its own size, got \(exact)"
    )

    let fitted = CanvasVideoRect(x: 100, y: 50, width: 1000, height: 600)
    let nearMisses: [(width: Double, height: Double, expected: CanvasVideoRect)] = [
        (1001, 600, CanvasVideoRect(x: 100, y: 50, width: 1001, height: 600)),
        (999, 600, CanvasVideoRect(x: 101, y: 50, width: 999, height: 600)),
        (1002, 600, CanvasVideoRect(x: 99, y: 50, width: 1002, height: 600)),
        (998, 600, CanvasVideoRect(x: 101, y: 50, width: 998, height: 600)),
        (1000, 601, CanvasVideoRect(x: 100, y: 50, width: 1000, height: 601)),
        (1000, 599, CanvasVideoRect(x: 100, y: 51, width: 1000, height: 599)),
        (1000, 602, CanvasVideoRect(x: 100, y: 49, width: 1000, height: 602)),
        (1000, 598, CanvasVideoRect(x: 100, y: 51, width: 1000, height: 598)),
        (1002, 598, CanvasVideoRect(x: 99, y: 51, width: 1002, height: 598)),
    ]
    for nearMiss in nearMisses {
        let rect = drawn(fitted, frame: nearMiss.width, nearMiss.height)
        expect(
            rect == nearMiss.expected,
            "a \(Int(nearMiss.width))x\(Int(nearMiss.height)) frame in a 1000x600 fitted rect is drawn"
                + " at its own size, centred on whole pixels, got \(rect), wanted \(nearMiss.expected)"
        )
    }

    for (width, height) in [(1003.0, 600.0), (997.0, 600.0), (1000.0, 603.0), (1000.0, 597.0), (1003.0, 603.0)] {
        let rect = drawn(fitted, frame: width, height)
        expect(
            rect == fitted,
            "a \(Int(width))x\(Int(height)) frame, 3 px off a 1000x600 fitted rect, is stretched to fit,"
                + " got \(rect)"
        )
    }

    let fractional = drawn(CanvasVideoRect(x: 12.75, y: 7.3, width: 1000.5, height: 600), frame: 1000, 600)
    expect(
        fractional == CanvasVideoRect(x: 13, y: 7, width: 1000, height: 600),
        "a fitted rect at a fractional origin moves the frame to the nearest whole pixel, got \(fractional)"
    )
    let odd = drawn(CanvasVideoRect(x: 101, y: 33, width: 999, height: 599), frame: 1000, 600)
    expect(
        odd == CanvasVideoRect(x: 101, y: 33, width: 1000, height: 600),
        "a frame one pixel larger than an odd-sized fitted rect is centred and rounded, got \(odd)"
    )

    let banded = CanvasVideoRect(x: 20, y: 48, width: 1000, height: 600)
    let taller = drawn(banded, frame: 1000, 602, topInset: 48)
    expect(
        taller == CanvasVideoRect(x: 20, y: 48, width: 1000, height: 602),
        "a frame taller than the room below a pinned strip starts at the strip's edge, never under it,"
            + " got \(taller)"
    )
    let shorter = drawn(banded, frame: 1000, 598, topInset: 48)
    expect(
        shorter == CanvasVideoRect(x: 20, y: 49, width: 1000, height: 598),
        "a frame shorter than the room below a pinned strip is still centred in it, got \(shorter)"
    )
    let fractionalBand = drawn(CanvasVideoRect(x: 0, y: 47.5, width: 1000, height: 600), frame: 1000, 602, topInset: 47.5)
    expect(
        fractionalBand == CanvasVideoRect(x: 0, y: 48, width: 1000, height: 602),
        "a strip ending part way through a pixel keeps that whole pixel, got \(fractionalBand)"
    )
    let unbanded = drawn(CanvasVideoRect(x: 0, y: 0, width: 1000, height: 600), frame: 1000, 602)
    expect(
        unbanded == CanvasVideoRect(x: 0, y: -1, width: 1000, height: 602),
        "with no strip, a frame two pixels taller than the window stays centred, got \(unbanded)"
    )

    let empty = CanvasVideoRect(x: 0, y: 0, width: 0, height: 0)
    expect(
        drawn(empty, frame: 2, 2) == empty,
        "a viewport with no room for a picture still draws nothing"
    )
    print("PASS: a frame within 2 px of its fitted rect is drawn at its own size on whole pixels")
}
