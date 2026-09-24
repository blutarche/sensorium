#if canImport(CoreVideo)
import CoreVideo
import Foundation

func makeTestPixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    // Backed by an IOSurface, as every decoded frame is: that is what lets the
    // GPU read a frame where it already lies instead of taking a copy of it.
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        10,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        print("FAIL: could not allocate a test pixel buffer")
        Foundation.exit(1)
    }
    return buffer
}
#endif
