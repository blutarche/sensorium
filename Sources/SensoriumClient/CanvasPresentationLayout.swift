/// The rectangle, in the units of whatever viewport it was computed for
/// (viewport points for input, drawable pixels for rendering), that the
/// source frame is scaled into. Any remainder is letterboxed/pillarboxed
/// outside this rect.
public struct CanvasVideoRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Pure aspect-fit geometry shared by presentation and input mapping so the
/// two can never disagree about where the video is actually drawn.
public enum CanvasPresentationLayout {
    /// Scales the source to the largest size that fits entirely inside the
    /// viewport while preserving its aspect ratio, then centers it — the
    /// same "fit" behavior regardless of whether the viewport is larger or
    /// smaller than the source. It never crops: the whole source is always
    /// visible, and the destination always spans an axis of the viewport.
    ///
    /// `topInset` is a band across the top of the viewport the picture may
    /// not use -- what a pinned shortcut strip claims. The picture is fitted
    /// into what is left and then moved down past it, so the band is never
    /// drawn over and the picture is never cropped to make room.
    public static func videoRect(
        sourceWidth: Double,
        sourceHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        topInset: Double = 0
    ) -> CanvasVideoRect {
        let inset = max(0, min(topInset, viewportHeight))
        let viewportHeight = viewportHeight - inset
        guard sourceWidth > 0, sourceHeight > 0, viewportWidth > 0, viewportHeight > 0 else {
            return CanvasVideoRect(x: 0, y: 0, width: 0, height: 0)
        }
        let sourceAspect = sourceWidth / sourceHeight
        let viewportAspect = viewportWidth / viewportHeight

        var width = viewportWidth
        var height = viewportHeight
        if viewportAspect > sourceAspect {
            // Viewport is relatively wider than the source: bars on the sides.
            width = viewportHeight * sourceAspect
        } else if viewportAspect < sourceAspect {
            // Viewport is relatively taller than the source: bars top/bottom.
            height = viewportWidth / sourceAspect
        }
        return CanvasVideoRect(
            x: (viewportWidth - width) / 2,
            y: inset + (viewportHeight - height) / 2,
            width: width,
            height: height
        )
    }

    /// The rect to draw a frame into, given the rect `videoRect` fitted it
    /// to. A frame within two pixels of that rect on both axes is drawn at
    /// its own size, centred on it and moved to whole pixels, so each texel
    /// covers exactly one pixel and nothing is resampled. Any other frame is
    /// drawn into the fitted rect.
    ///
    /// The frame never starts above `topInset`. A frame taller than the room
    /// below the inset starts at its edge instead and loses its last rows,
    /// at most two, to the viewport.
    ///
    /// Input mapping keeps using the fitted rect: the two differ by at most a
    /// pixel, which is finer than a pointer position.
    public static func drawingRect(
        fittedRect fitted: CanvasVideoRect,
        frameWidth: Double,
        frameHeight: Double,
        topInset: Double = 0
    ) -> CanvasVideoRect {
        let tolerance = 2.0
        guard fitted.width > 0, fitted.height > 0,
              abs(fitted.width - frameWidth) <= tolerance,
              abs(fitted.height - frameHeight) <= tolerance else {
            return fitted
        }
        let x = (fitted.x + (fitted.width - frameWidth) / 2).rounded()
        var y = (fitted.y + (fitted.height - frameHeight) / 2).rounded()
        if topInset > 0 {
            y = max(y, topInset.rounded(.up))
        }
        return CanvasVideoRect(x: x, y: y, width: frameWidth, height: frameHeight)
    }
}
