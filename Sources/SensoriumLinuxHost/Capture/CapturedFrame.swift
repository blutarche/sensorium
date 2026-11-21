#if os(Linux)

import Foundation

/// The two 32-bit layouts the capture negotiates. The fourth byte of `bgra`
/// is alpha for a cursor image and padding for a screen frame.
public enum CapturePixelFormat: Equatable, Sendable {
    case bgrx
    case bgra
}

/// The cursor as the compositor describes it, when it sends it as metadata
/// rather than drawing it into the frame.
public struct CapturedCursor: Equatable, Sendable {
    public struct Image: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var stride: Int
        public var format: CapturePixelFormat
        public var pixels: Data

        public init(width: Int, height: Int, stride: Int, format: CapturePixelFormat, pixels: Data) {
            self.width = width
            self.height = height
            self.stride = stride
            self.format = format
            self.pixels = pixels
        }
    }

    /// Position on the monitor, in the frame's pixels.
    public var x: Int
    public var y: Int
    /// The point of the image that sits on `(x, y)`.
    public var hotspotX: Int
    public var hotspotY: Int
    /// False when the compositor hid the cursor.
    public var isVisible: Bool
    /// The image, sent once when it changes; nil when this update carries a
    /// position only and the previous image still applies.
    public var image: Image?

    public init(x: Int, y: Int, hotspotX: Int, hotspotY: Int, isVisible: Bool, image: Image?) {
        self.x = x
        self.y = y
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.isVisible = isVisible
        self.image = image
    }
}

/// One buffer from the stream, copied out of PipeWire's memory.
public struct CapturedFrame: Equatable, Sendable {
    /// Rows of `stride` bytes, `height` of them. Nil for a buffer that only
    /// carries a cursor update.
    public var pixels: Data?
    public var width: Int
    public var height: Int
    /// Bytes per row, which can exceed `width * 4`.
    public var stride: Int
    public var format: CapturePixelFormat
    /// When the compositor produced it, in nanoseconds on PipeWire's
    /// monotonic clock; nil when the producer gave none.
    public var presentationTimeNanoseconds: Int64?
    public var cursor: CapturedCursor?

    public init(
        pixels: Data?,
        width: Int,
        height: Int,
        stride: Int,
        format: CapturePixelFormat,
        presentationTimeNanoseconds: Int64?,
        cursor: CapturedCursor?
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.cursor = cursor
    }
}

public enum CaptureState: Equatable, Sendable {
    case connecting
    case streaming
    case paused
    case failed(String)
}

public enum CaptureError: Error, Equatable, Sendable {
    case couldNotCreate(String)
    case couldNotStart(errno: Int32)
    /// Frames are read from shared memory. Importing GPU buffers is not built.
    case dmaBufNotImplemented
}

#endif
