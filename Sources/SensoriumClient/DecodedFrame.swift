import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// One decoded frame on its way to the presenter.
///
/// `width` and `height` are the frame's own pixel dimensions, carried here so
/// that pacing, coalescing and per-surface statistics need nothing from the
/// platform image itself. The image travels alongside them in whatever form
/// this platform's decoder produces.
///
/// `timing` is absent when the frame could not be tied back to its receipt —
/// a duplicate callback, or a receipt already evicted. Such a frame is still
/// presented; it simply contributes no latency sample.
public struct DecodedFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let timing: FrameTiming?

    #if canImport(CoreVideo)
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer, timing: FrameTiming? = nil) {
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        self.pixelBuffer = pixelBuffer
        self.timing = timing
    }
    #else
    /// The platform image this frame carries, opaque to everything that only
    /// paces, coalesces or counts frames.
    public let payload: AnyObject

    public init(payload: AnyObject, width: Int, height: Int, timing: FrameTiming? = nil) {
        self.payload = payload
        self.width = width
        self.height = height
        self.timing = timing
    }
    #endif
}
