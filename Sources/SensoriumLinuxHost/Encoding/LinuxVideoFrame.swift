#if os(Linux)
import Foundation

/// How the bytes of a CPU frame are laid out.
public enum LinuxPixelFormat: Equatable, Sendable {
    /// Four bytes per pixel in memory order blue, green, red, then a byte
    /// that is padding (`BGRx`) or alpha (`BGRA`). PipeWire's shared-memory
    /// desktop frames arrive in one of these two layouts. The fourth byte is
    /// never read, so the two are the same to the encoder.
    case bgrx
    case bgra
}

/// One desktop frame in CPU memory, on its way to the encoder.
///
/// This is the portable counterpart of the `CMSampleBuffer` the macOS host
/// hands its encoder: a picture and the time it was captured, with nothing
/// tied to a capture API.
public struct LinuxVideoFrame: Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: LinuxPixelFormat
    /// Bytes from the start of one row to the start of the next. Capture
    /// buffers pad rows, so this is at least `width * 4` and is never assumed
    /// to equal it.
    public let bytesPerRow: Int
    public let pixels: Data
    /// When the picture was captured, in nanoseconds on any monotonic clock
    /// that does not go backwards. It travels with the frame to the viewer.
    public let presentationTimeNanoseconds: UInt64

    public init(
        width: Int,
        height: Int,
        pixelFormat: LinuxPixelFormat,
        bytesPerRow: Int,
        pixels: Data,
        presentationTimeNanoseconds: UInt64
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }

    /// Whether `pixels` really holds `height` rows of `width` pixels at
    /// `bytesPerRow`. The last row needs no padding after it.
    public var isConsistent: Bool {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return false }
        return pixels.count >= bytesPerRow * (height - 1) + width * 4
    }
}
#endif
