import Foundation
import SensoriumCore

func testStreamScaleFollowsViewerDrawableWithinCanvasNativeLimit() {
    func scale(_ width: Double, _ height: Double) -> Double? {
        StreamScalePolicy.scale(
            drawablePixelWidth: width,
            drawablePixelHeight: height,
            canvasLogicalWidth: 1920,
            canvasLogicalHeight: 1200
        )
    }

    expect(scale(1920, 1200) == 1.0, "the default 1920x1200 drawable streams the canvas at 1x")
    expect(scale(3840, 2400) == 2.0, "a full-native drawable streams the canvas at its real 2x pixels")
    expect(scale(2880, 1800) == 1.5, "an intermediate drawable streams the matching intermediate scale")

    // Below 1x the stream would be softer than today for no benefit, and above
    // 2x there are no more canvas pixels to send.
    expect(scale(960, 600) == 1.0, "a drawable smaller than the canvas never streams below 1x")
    expect(scale(7680, 4800) == 2.0, "a drawable larger than the canvas never streams above its native 2x")

    // A non-16:10 drawable takes the axis that actually constrains the fit, so
    // the canvas aspect ratio is preserved and nothing is distorted.
    expect(scale(3840, 1200) == 1.0, "a wide non-16:10 drawable follows its limiting axis")
    expect(scale(1920, 2400) == 1.0, "a tall non-16:10 drawable follows its limiting axis")
    expect(scale(3840, 1800) == 1.5, "a 3840x1800 drawable is limited by height, not width")

    // Quantized so a live window drag cannot churn the encoder over a pixel.
    expect(scale(2000, 1250) == 1.0, "a drawable a few percent over 1x quantizes back to 1x")
    expect(scale(2500, 1562) == 1.25, "a drawable near 1.3x quantizes to the 0.25 step")
    expect(scale(3600, 2250) == 2.0, "a drawable near 1.9x quantizes to the 0.25 step")
    for value in stride(from: 1000.0, through: 4200.0, by: 7.0) {
        guard let derived = scale(value, value * 1200 / 1920) else {
            expect(false, "every plausible drawable width derives a scale")
            return
        }
        expect(
            (derived / StreamScalePolicy.quantum).rounded() * StreamScalePolicy.quantum == derived,
            "every derived scale lands exactly on a 0.25 step"
        )
        expect(
            derived >= StreamScalePolicy.minimumScale && derived <= StreamScalePolicy.maximumScale,
            "every derived scale stays within 1x...2x"
        )
    }

    // Hostile or degenerate input from an authenticated peer is still input.
    expect(scale(0, 1200) == nil, "a zero drawable width is refused")
    expect(scale(1920, 0) == nil, "a zero drawable height is refused")
    expect(scale(-1920, 1200) == nil, "a negative drawable width is refused")
    expect(scale(1920, -1200) == nil, "a negative drawable height is refused")
    expect(scale(.nan, 1200) == nil, "a NaN drawable width is refused")
    expect(scale(1920, .nan) == nil, "a NaN drawable height is refused")
    expect(scale(.infinity, 1200) == nil, "an infinite drawable width is refused")
    expect(
        scale(StreamScalePolicy.maximumDrawablePixels + 1, 1200) == nil,
        "an absurdly large drawable width is refused rather than clamped"
    )
    expect(
        scale(1920, StreamScalePolicy.maximumDrawablePixels + 1) == nil,
        "an absurdly large drawable height is refused rather than clamped"
    )
    expect(
        StreamScalePolicy.scale(
            drawablePixelWidth: 1920,
            drawablePixelHeight: 1200,
            canvasLogicalWidth: 0,
            canvasLogicalHeight: 1200
        ) == nil,
        "a degenerate canvas size derives no scale"
    )
    expect(StreamScalePolicy.defaultScale == 1.0, "the protocol default scale is today's 1x behaviour")

    // A pipeline rebuild is a real, visible gap, so a change of exactly one
    // quantum step is not worth it; two steps is.
    expect(
        !StreamScalePolicy.isWorthReconfiguring(from: 1.5, to: 1.75),
        "one quantum step up is not worth a rebuild"
    )
    expect(
        !StreamScalePolicy.isWorthReconfiguring(from: 1.75, to: 1.5),
        "one quantum step down is not worth a rebuild either -- the check is symmetric"
    )
    expect(
        !StreamScalePolicy.isWorthReconfiguring(from: 1.5, to: 1.5),
        "no change at all is never worth a rebuild"
    )
    expect(
        StreamScalePolicy.isWorthReconfiguring(from: 1.5, to: 2.0),
        "two quantum steps is worth a rebuild"
    )
    expect(
        StreamScalePolicy.isWorthReconfiguring(from: 2.0, to: 1.0),
        "a large drop is worth a rebuild"
    )
}

/// The two thresholds `StreamFidelityPressure` reads an encode measurement
/// against. The frame budget is covered beside the classifier itself; this is
/// the sample floor that decides when a measurement counts at all.
func testEncodeSustainabilityPolicyWithholdsAVerdictUntilThereAreRealSamples() {
    // Capture is change-driven, so a quiet screen can deliver only a
    // handful of samples between two ticks, and the first of those is the
    // encoder's opening IDR -- neither is a real measure of ongoing cost.
    expect(
        !EncodeSustainabilityPolicy.hasEnoughSamples(0),
        "no samples yet is never enough for a verdict"
    )
    expect(
        !EncodeSustainabilityPolicy.hasEnoughSamples(EncodeSustainabilityPolicy.minimumSampleCount - 1),
        "one short of the minimum is still not enough"
    )
    expect(
        EncodeSustainabilityPolicy.hasEnoughSamples(EncodeSustainabilityPolicy.minimumSampleCount),
        "exactly the minimum is enough"
    )
    expect(
        EncodeSustainabilityPolicy.hasEnoughSamples(EncodeSustainabilityPolicy.minimumSampleCount + 100),
        "well past the minimum is still enough"
    )
}

/// The cap rides on `viewerDrawableSize` rather than a faked drawable: the
/// pixel dimensions tell the encoder how big the window is, and lying about
/// them to express a preference would corrupt the one measurement the host
/// derives the scale from.
func testViewerDrawableSizeCarriesAUserScaleCapAndValidatesItLikeItsDimensions() {
    let capped = SensoriumMessage.viewerDrawableSize(
        pixelWidth: 3840,
        pixelHeight: 2400,
        surfaceID: nil,
        maximumScale: 1.5
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(capped)) == capped,
        "a user scale cap round-trips alongside the drawable it accompanies"
    )

    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
    let uncapped = try! SensoriumFrameCodec.decode(frame([
        "type": "viewerDrawableSize",
        "drawablePixelWidth": 3840,
        "drawablePixelHeight": 2400
    ]))
    expect(
        uncapped == .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil),
        "a client that predates the cap is read as no cap at all, exactly as before"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(uncapped), as: UTF8.self).contains("maximumScale"),
        "no cap is an absent field, so an uncapped viewer's message is the bytes it always was"
    )

    // Validated exactly like the dimensions beside it: this reaches the
    // encoder's resolution, so an authenticated client is still not trusted
    // with an arbitrary number.
    // JSON cannot carry NaN or infinity at all, so the `isFinite` half of the
    // check is unreachable from the wire and only the range is exercised here.
    for hostile in [0.0, -1.0, 0.5, 2.5] {
        expect(
            (try? SensoriumFrameCodec.decode(frame([
                "type": "viewerDrawableSize",
                "drawablePixelWidth": 3840,
                "drawablePixelHeight": 2400,
                "maximumScale": hostile
            ]))) == nil,
            "a maximumScale of \(hostile) is refused at decode, like a degenerate dimension"
        )
    }
}

func testViewerDrawableSizeRoundTripsAndRefusesDegenerateValues() {
    let message = SensoriumMessage.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "a viewer drawable size round-trips both pixel dimensions"
    )

    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    expect(
        (try? SensoriumFrameCodec.decode(frame(["type": "viewerDrawableSize"]))) == nil,
        "a viewer drawable size with no dimensions is rejected"
    )
    expect(
        (try? SensoriumFrameCodec.decode(frame([
            "type": "viewerDrawableSize",
            "drawablePixelWidth": 3840,
        ]))) == nil,
        "a viewer drawable size missing one dimension is rejected"
    )
    expect(
        (try? SensoriumFrameCodec.decode(frame([
            "type": "viewerDrawableSize",
            "drawablePixelWidth": 0,
            "drawablePixelHeight": 2400,
        ]))) == nil,
        "a zero drawable dimension is rejected at the wire boundary"
    )
    expect(
        (try? SensoriumFrameCodec.decode(frame([
            "type": "viewerDrawableSize",
            "drawablePixelWidth": -3840,
            "drawablePixelHeight": 2400,
        ]))) == nil,
        "a negative drawable dimension is rejected at the wire boundary"
    )
    expect(
        (try? SensoriumFrameCodec.decode(frame([
            "type": "viewerDrawableSize",
            "drawablePixelWidth": 1e9,
            "drawablePixelHeight": 1e9,
        ]))) == nil,
        "an absurdly large drawable dimension is rejected at the wire boundary"
    )

    // Every other message must still decode unchanged: a peer that never sends
    // the new one keeps working exactly as before.
    let canvasRequest = SensoriumMessage.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(canvasRequest)) == canvasRequest,
        "the canvas request is unaffected by the new message"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(canvasRequest), as: UTF8.self)
            .contains("drawablePixel"),
        "messages that carry no drawable size do not grow new wire fields"
    )
}

/// The focus signal has three states, not two: a surface is focused, or the
/// viewer has no focus at all because the user is looking at a local app.
/// "no viewer focus" must never collapse to "surface 0", which is what an
/// absent `surfaceID` means everywhere else on this wire.
