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
    /// The step between the scales a person can choose from, and between the
    /// rungs of the fidelity ladder. A scale derived from the viewer's
    /// drawable is not rounded to it.
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

    /// The scale at which the canvas exactly fills the drawable on its
    /// limiting axis, clamped to `minimumScale...maximumScale` and not
    /// rounded to a step: both viewers resample any frame that is not the
    /// size they draw, and the result is visibly softer text. 3840x1926
    /// pixels over a 2560x1440 canvas is 1.3375.
    ///
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
        return Swift.min(Swift.max(fit, minimumScale), maximumScale)
    }

    /// Rounds a scale to the nearest step, without clamping, for a caller
    /// that wants one of the scales a person can choose. Half a step of
    /// extra resolution is cheaper than a visibly soft picture, so it rounds
    /// to the nearest step rather than down.
    public static func quantize(_ scale: Double) -> Double {
        sessionCanvasRange.quantized(scale)
    }

    /// Whether the stream should follow a drawable that moved from
    /// `currentlyApplied` to `requested` as soon as the drawable stops
    /// moving. True for any increase, since a window that grew is soft until
    /// the stream follows it, and for a drop of more than one quantum.
    /// False for no change and for a drop of at most one quantum: a strip of
    /// controls that shows and hides shrinks the drawable by that much, so
    /// the host waits longer before rebuilding for it, in case it reverts.
    /// The comparison allows for floating-point error, so 1.5 against 1.25
    /// counts as exactly one quantum.
    public static func isWorthReconfiguring(from currentlyApplied: Double, to requested: Double) -> Bool {
        let epsilon = 1e-9
        let change = requested - currentlyApplied
        if change > 0 {
            return change > epsilon
        }
        return -change > quantum + epsilon
    }
}
