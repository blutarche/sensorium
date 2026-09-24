import Foundation

/// Turns the coded values of a two-plane YCbCr frame into red, green and
/// blue: one matrix and the offset subtracted before it.
///
/// One table, two readers. The Linux presenter generates its fragment shader
/// from it, and the verification runner converts three known pixels through
/// it, so a shader that has drifted from the coefficients cannot pass. The
/// coefficients themselves are the ones the Metal presenter's biplanar path
/// already converts with.
public struct NV12ColorConversion: Hashable, Sendable {
    /// Scales the luma channel.
    public let luma: Double
    /// The chroma terms, named for the channel each contributes to and the
    /// chroma channel it is read from.
    public let redFromRedChroma: Double
    public let greenFromBlueChroma: Double
    public let greenFromRedChroma: Double
    public let blueFromBlueChroma: Double
    /// What a black frame carries in each channel, subtracted before the
    /// matrix is applied.
    public let lumaOffset: Double
    public let chromaOffset: Double

    /// Converts one pixel. Every value is the coded sample divided by its
    /// full scale, which is what both a sampler and this function read.
    /// Clamped, because a coded pixel can name a colour outside the range a
    /// screen can show and the shader clamps it too.
    public func rgb(
        luma sampledLuma: Double,
        blueChroma: Double,
        redChroma: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let y = luma * (sampledLuma - lumaOffset)
        let u = blueChroma - chromaOffset
        let v = redChroma - chromaOffset
        return (
            red: Self.clamped(y + redFromRedChroma * v),
            green: Self.clamped(y + greenFromBlueChroma * u + greenFromRedChroma * v),
            blue: Self.clamped(y + blueFromBlueChroma * u)
        )
    }

    /// The matrix exactly as the shader declares it. GLSL's `mat3` takes its
    /// columns in order, which is the order this writes them in.
    public var glslMatrixLiteral: String {
        let columns = [
            [luma, luma, luma],
            [0, greenFromBlueChroma, blueFromBlueChroma],
            [redFromRedChroma, greenFromRedChroma, 0]
        ]
        return "mat3(" + columns.flatMap { $0 }.map(Self.literal).joined(separator: ", ") + ")"
    }

    public var glslOffsetLiteral: String {
        "vec3(" + [lumaOffset, chromaOffset, chromaOffset].map(Self.literal).joined(separator: ", ") + ")"
    }

    /// Which matrix a stream is coded for, as the stream itself signals it.
    public enum SignalledColorspace: Equatable, Sendable {
        case bt709
        case bt601
        /// The stream named no matrix, or named one this viewer has no table
        /// for.
        case unspecified
    }

    /// Frames coded for standard definition name the older matrix; everything
    /// else, including anything that names nothing at all, is read as the high
    /// definition one the encoders in use here produce.
    public static func matching(
        colorspace: SignalledColorspace,
        isFullRange: Bool
    ) -> NV12ColorConversion {
        switch (colorspace, isFullRange) {
        case (.bt601, true): return .fullRange601
        case (.bt601, false): return .videoRange601
        case (_, true): return .fullRange709
        case (_, false): return .videoRange709
        }
    }

    public static let videoRange709 = NV12ColorConversion(
        luma: 1.164384,
        redFromRedChroma: 1.792741,
        greenFromBlueChroma: -0.213249,
        greenFromRedChroma: -0.532909,
        blueFromBlueChroma: 2.112402,
        lumaOffset: 16.0 / 255.0,
        chromaOffset: 128.0 / 255.0
    )
    public static let fullRange709 = NV12ColorConversion(
        luma: 1,
        redFromRedChroma: 1.5748,
        greenFromBlueChroma: -0.187324,
        greenFromRedChroma: -0.468124,
        blueFromBlueChroma: 1.8556,
        lumaOffset: 0,
        chromaOffset: 0.5
    )
    public static let videoRange601 = NV12ColorConversion(
        luma: 1.164384,
        redFromRedChroma: 1.596027,
        greenFromBlueChroma: -0.391762,
        greenFromRedChroma: -0.812968,
        blueFromBlueChroma: 2.017232,
        lumaOffset: 16.0 / 255.0,
        chromaOffset: 128.0 / 255.0
    )
    public static let fullRange601 = NV12ColorConversion(
        luma: 1,
        redFromRedChroma: 1.402,
        greenFromBlueChroma: -0.344136,
        greenFromRedChroma: -0.714136,
        blueFromBlueChroma: 1.772,
        lumaOffset: 0,
        chromaOffset: 0.5
    )

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Six decimal places, with the trailing zeros trimmed but never the
    /// decimal point: GLSL reads `0` as an integer, which does not convert to
    /// a float inside a `mat3`.
    private static func literal(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0"), !text.hasSuffix(".0") {
            text.removeLast()
        }
        return text
    }
}
