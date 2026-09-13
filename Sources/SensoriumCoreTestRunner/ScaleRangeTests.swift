import Foundation
import SensoriumCore

func testScaleRangeIsGeneralAndTheSessionCanvasRangeReproducesTodaysConstants() {
    // A range general enough for any caller, not just the canvas
    let hostScreenExampleRange = ScaleRange(minimum: 0.5, maximum: 3.0, quantum: 0.5)
    expect(
        hostScreenExampleRange.steps == [0.5, 1.0, 1.5, 2.0, 2.5, 3.0],
        "steps are every quantum apart between minimum and maximum, for whatever bounds a caller carries -- not hardcoded to the canvas's own 1.0...2.0"
    )
    expect(
        hostScreenExampleRange.contains(0.5) && hostScreenExampleRange.contains(3.0) && hostScreenExampleRange.contains(1.75),
        "both bounds and every value between them are contained"
    )
    expect(
        !hostScreenExampleRange.contains(0.49) && !hostScreenExampleRange.contains(3.01),
        "a value just outside either bound is not contained"
    )
    expect(
        hostScreenExampleRange.quantized(1.24) == 1.0 && hostScreenExampleRange.quantized(1.26) == 1.5,
        "quantized rounds to the nearest step for this range's own quantum, not the canvas's 0.25"
    )
    expect(
        hostScreenExampleRange.normalized(10.0) == 3.0 && hostScreenExampleRange.normalized(-1.0) == 0.5,
        "normalized clamps into this range's own bounds before quantizing, regardless of what those bounds are"
    )
    expect(
        hostScreenExampleRange.normalized(1.8) == 2.0,
        "normalized quantizes an in-range value that is not already on a step"
    )

    // The session-canvas range reproduces today's constants exactly
    // This is the acceptance guard: host-screen mode gaining its own
    // ScaleRange must not have changed what a canvas session is bounded to.
    expect(
        StreamScalePolicy.sessionCanvasRange
            == ScaleRange(minimum: StreamScalePolicy.minimumScale, maximum: StreamScalePolicy.maximumScale, quantum: StreamScalePolicy.quantum),
        "the session-canvas range is built from exactly minimumScale, maximumScale, and quantum -- nothing else, nothing hardcoded separately"
    )
    expect(
        StreamScalePolicy.sessionCanvasRange == ScaleRange(minimum: 1.0, maximum: 2.0, quantum: 0.25),
        "today's actual canvas bounds, reproduced exactly: 1.0x to 2.0x in steps of 0.25"
    )
    expect(
        StreamScalePolicy.steps == StreamScalePolicy.sessionCanvasRange.steps,
        "StreamScalePolicy.steps is the session-canvas range's own steps, not a second, independently-derived list"
    )
    expect(
        StreamScalePolicy.quantize(1.6) == StreamScalePolicy.sessionCanvasRange.quantized(1.6),
        "StreamScalePolicy.quantize delegates to the session-canvas range rather than duplicating the rounding rule"
    )
    let oversizedFit = Swift.min(5000.0 / 1920.0, 5000.0 / 1200.0)
    expect(
        StreamScalePolicy.scale(
            drawablePixelWidth: 5000, drawablePixelHeight: 5000,
            canvasLogicalWidth: 1920, canvasLogicalHeight: 1200
        ) == StreamScalePolicy.sessionCanvasRange.normalized(oversizedFit),
        "a geometry-derived scale is normalized through the session-canvas range, so a drawable far larger than the canvas still clamps to exactly maximumScale"
    )
}
