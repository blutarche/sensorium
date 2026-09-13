import CoreVideo

/// One decoded frame on its way to the presenter.
///
/// `timing` is absent when the frame could not be tied back to its receipt —
/// a duplicate callback, or a receipt already evicted. Such a frame is still
/// presented; it simply contributes no latency sample.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timing: FrameTiming?

    public init(pixelBuffer: CVPixelBuffer, timing: FrameTiming? = nil) {
        self.pixelBuffer = pixelBuffer
        self.timing = timing
    }
}
