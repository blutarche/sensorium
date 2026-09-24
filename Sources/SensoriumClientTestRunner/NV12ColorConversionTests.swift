import Foundation
import SensoriumClient

/// The coefficients the Linux presenter's shader converts with, checked here
/// rather than on a GPU: the shader source is generated from this same table,
/// so three pixels whose answer is known pin both at once.
func testNV12ColorConversionTests() {
    let conversion = NV12ColorConversion.videoRange709

    let black = conversion.rgb(luma: 16.0 / 255.0, blueChroma: 128.0 / 255.0, redChroma: 128.0 / 255.0)
    expect(isClose(black.red, 0), "BT.709 limited range codes black as 16,128,128 -- red \(black.red)")
    expect(isClose(black.green, 0), "BT.709 limited range codes black as 16,128,128 -- green \(black.green)")
    expect(isClose(black.blue, 0), "BT.709 limited range codes black as 16,128,128 -- blue \(black.blue)")

    let white = conversion.rgb(luma: 235.0 / 255.0, blueChroma: 128.0 / 255.0, redChroma: 128.0 / 255.0)
    expect(isClose(white.red, 1), "BT.709 limited range codes white as 235,128,128 -- red \(white.red)")
    expect(isClose(white.green, 1), "BT.709 limited range codes white as 235,128,128 -- green \(white.green)")
    expect(isClose(white.blue, 1), "BT.709 limited range codes white as 235,128,128 -- blue \(white.blue)")

    // Chroma at the bottom of its range with luma at the top: the green term
    // leaves the representable range, so this also pins the clamp.
    let outOfGamut = conversion.rgb(luma: 235.0 / 255.0, blueChroma: 16.0 / 255.0, redChroma: 16.0 / 255.0)
    expect(isClose(outOfGamut.red, 0.212600), "235,16,16 converts to red 0.212600, got \(outOfGamut.red)")
    expect(isClose(outOfGamut.green, 1), "235,16,16 leaves the range in green and is clamped, got \(outOfGamut.green)")
    expect(isClose(outOfGamut.blue, 0.072200), "235,16,16 converts to blue 0.072200, got \(outOfGamut.blue)")

    expect(
        conversion.glslMatrixLiteral
            == "mat3(1.164384, 1.164384, 1.164384, 0.0, -0.213249, 2.112402, 1.792741, -0.532909, 0.0)",
        "the shader matrix is generated from the same table, column by column -- got \(conversion.glslMatrixLiteral)"
    )
    expect(
        conversion.glslOffsetLiteral == "vec3(0.062745, 0.501961, 0.501961)",
        "the shader's subtracted offset is generated from the same table -- got \(conversion.glslOffsetLiteral)"
    )

    // What the stream says it is, not what the viewer hopes: a frame coded for
    // standard definition names the older matrix, and anything that names
    // nothing at all is read as high definition.
    expect(
        NV12ColorConversion.matching(colorspace: .bt709, isFullRange: false) == .videoRange709,
        "a stream signalling BT.709 limited range converts with the BT.709 limited table"
    )
    expect(
        NV12ColorConversion.matching(colorspace: .bt709, isFullRange: true) == .fullRange709,
        "a stream signalling BT.709 full range converts with the BT.709 full table"
    )
    expect(
        NV12ColorConversion.matching(colorspace: .bt601, isFullRange: false) == .videoRange601,
        "a stream signalling BT.601 limited range converts with the BT.601 limited table"
    )
    expect(
        NV12ColorConversion.matching(colorspace: .unspecified, isFullRange: false) == .videoRange709,
        "a stream that signals no matrix at all is read as BT.709 limited range"
    )

    print("PASS: NV12 to RGB conversion matches BT.709 at black, white and a clamped pixel, and the shader matrix is generated from the same table")
}

private func isClose(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 1e-5
}
