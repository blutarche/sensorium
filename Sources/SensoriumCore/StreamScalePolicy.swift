import Foundation

/// Turns the viewer's actual drawable size into the HiDPI scale factor the
/// canvas is streamed at, so the picture is pixel-perfect at whatever size the
/// window happens to be and the extra encode cost is paid only when it is
/// actually enlarged.
///
/// The scale is the fraction of the canvas's own native resolution to send:
/// `1.0` is the canvas's 1920x1200 logical size, `2.0` its real 3840x2400
/// pixels. Both ends are hard limits — below `1.0` the stream would be softer
/// for no benefit, and above `2.0` there are no further canvas
/// pixels in existence to encode. Both axes take the same factor, so the
/// canvas aspect ratio survives any window shape and the viewer's existing
/// letterbox handles the remainder.
public enum StreamScalePolicy {
    public static let minimumScale: Double = 1.0
    public static let maximumScale: Double = 2.0
    /// Resize steps coarse enough that dragging a window edge cannot churn the
    /// encoder over a handful of pixels.
    public static let quantum: Double = 0.25
    /// What a viewer that never reports a drawable size is assumed to want,
    /// and what the host streams until told otherwise.
    public static let defaultScale: Double = 1.0
    /// Larger than any drawable a Metal view can actually own; anything beyond
    /// it is a hostile or broken value, not a window.
    public static let maximumDrawablePixels: Double = 16_384

    /// The bounds and quantum every session-owned canvas stream is resolved
    /// against, as one `ScaleRange` -- the same three constants above,
    /// carried together for a caller that wants a range rather than this
    /// policy's own free functions. Deliberately not the only `ScaleRange`
    /// that will ever exist: host-screen mode, which captures a real
    /// physical display instead of the session canvas, asks for its own
    /// range with its own bounds.
    public static let sessionCanvasRange = ScaleRange(minimum: minimumScale, maximum: maximumScale, quantum: quantum)

    public static func isPlausibleDrawableDimension(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= maximumDrawablePixels
    }

    /// Every explicit scale a viewer may ask for, in the wire's own quantum
    /// steps -- what a resolution picker offers alongside "Automatic", which
    /// is a separate no-cap choice this list does not include.
    public static let steps: [Double] = sessionCanvasRange.steps

    /// Whether a viewer-supplied cap on the streamed scale is one this canvas
    /// could ever be streamed at. Validated on the same ground as the
    /// dimensions beside it on the wire: the cap reaches the encoder's
    /// resolution, so an authenticated client does not get to name an
    /// arbitrary number. Outside `minimumScale...maximumScale` it is not a
    /// preference, it is a broken or hostile value.
    public static func isPlausibleMaximumScale(_ value: Double) -> Bool {
        value.isFinite && value >= minimumScale && value <= maximumScale
    }

    /// `nil` when the values could not have come from a real viewer surface.
    /// Never a substituted default: a caller that cannot tell the difference
    /// between a refused value and a derived one would let a hostile peer pick
    /// the encoder's resolution.
    public static func scale(
        drawablePixelWidth: Double,
        drawablePixelHeight: Double,
        canvasLogicalWidth: Double,
        canvasLogicalHeight: Double
    ) -> Double? {
        guard isPlausibleDrawableDimension(drawablePixelWidth),
              isPlausibleDrawableDimension(drawablePixelHeight),
              canvasLogicalWidth.isFinite,
              canvasLogicalHeight.isFinite,
              canvasLogicalWidth > 0,
              canvasLogicalHeight > 0 else {
            return nil
        }
        let fit = min(
            drawablePixelWidth / canvasLogicalWidth,
            drawablePixelHeight / canvasLogicalHeight
        )
        return sessionCanvasRange.normalized(fit)
    }

    /// Rounds to the nearest step rather than down: half a step of extra
    /// resolution is cheaper than a visibly soft picture, and the clamp
    /// `ScaleRange.normalized` applies elsewhere keeps a value inside
    /// `1.0...2.0` either way -- this is the un-clamped rounding alone, for
    /// a caller that already knows its input is in range.
    public static func quantize(_ scale: Double) -> Double {
        sessionCanvasRange.quantized(scale)
    }

    /// Whether moving from `currentlyApplied` to `requested` is worth
    /// rebuilding the capture/encode pipeline for. A rebuild is a real,
    /// visible gap -- a system-wide window enumeration, a torn-down and
    /// recreated `VTCompressionSession` -- and a change of exactly one
    /// quantum step, the kind a window-edge settling one pixel differently
    /// produces, is not worth paying it for. `false` exactly at the
    /// boundary is deliberate: two steps (`2 * quantum`) is the first
    /// difference actually worth the cost.
    public static func isWorthReconfiguring(from currentlyApplied: Double, to requested: Double) -> Bool {
        abs(requested - currentlyApplied) > quantum
    }
}
