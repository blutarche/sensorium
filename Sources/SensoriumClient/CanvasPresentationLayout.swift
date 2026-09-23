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
}
