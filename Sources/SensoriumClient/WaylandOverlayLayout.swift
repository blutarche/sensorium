import Foundation

/// A rectangle in a window's own logical units, counted from its top-left
/// corner -- the corner a Wayland surface counts from. Plain doubles rather
/// than a platform rectangle type, because the two platforms that read this
/// have different ones and the arithmetic is the same either way.
public struct ViewerChromeRect: Equatable, Sendable {
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

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < x + width && pointY >= y && pointY < y + height
    }
}

/// Where each piece of the session window's chrome sits, given the window's
/// logical size and the size the piece measured itself at.
///
/// Pure geometry. The Linux session window draws these as Wayland
/// subsurfaces, but nothing here knows that: the rects are decided without a
/// compositor, so the placement is verified without one.
public enum WaylandOverlayLayout {
    /// How far every overlay stays clear of the window's edges.
    public static let edgeMargin: Double = Double(ViewerChromeMetrics.Space.md)

    /// How long a transient notice stays up before it takes itself away.
    /// Long enough to read a full sentence, short enough not to become a
    /// second, permanent status line -- the same span the macOS banner uses.
    public static let noticeAutoDismissSeconds: Double = 6

    /// Centred on both axes: the panel is the only thing on screen worth
    /// reading while it is up.
    public static func statusPanel(
        windowWidth: Double,
        windowHeight: Double,
        contentWidth: Double,
        contentHeight: Double
    ) -> ViewerChromeRect {
        let size = fitted(
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            windowWidth: windowWidth,
            windowHeight: windowHeight
        )
        return ViewerChromeRect(
            x: centredX(size.width, in: windowWidth),
            y: max(edgeMargin, (windowHeight - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }

    /// Top centre, where a banner about one refused request is read and then
    /// forgotten -- clear of the status panel's own centre. It takes the same
    /// `topInset` the diagnostics panel does, so a pinned strip's band is
    /// never read over.
    public static func transientNotice(
        windowWidth: Double,
        contentWidth: Double,
        contentHeight: Double,
        topInset: Double = 0
    ) -> ViewerChromeRect {
        let width = min(contentWidth, max(0, windowWidth - edgeMargin * 2))
        return ViewerChromeRect(
            x: centredX(width, in: windowWidth),
            y: topInset + edgeMargin,
            width: width,
            height: contentHeight
        )
    }

    /// Top right, out of the way of the picture's own middle, the way the
    /// macOS diagnostics panel sits. `topInset` is the band a pinned strip
    /// has claimed, which this panel moves down by rather than sitting under.
    public static func diagnosticsHUD(
        windowWidth: Double,
        contentWidth: Double,
        contentHeight: Double,
        topInset: Double = 0
    ) -> ViewerChromeRect {
        let width = min(contentWidth, max(0, windowWidth - edgeMargin * 2))
        return ViewerChromeRect(
            x: max(edgeMargin, windowWidth - width - edgeMargin),
            y: topInset + edgeMargin,
            width: width,
            height: contentHeight
        )
    }

    /// Hanging from the top edge, centred. An unpinned strip floats over the
    /// picture there; a pinned one claims that band and the picture moves
    /// down below it -- see `topInset`.
    public static func shortcutStrip(
        windowWidth: Double,
        contentWidth: Double,
        contentHeight: Double
    ) -> ViewerChromeRect {
        let width = min(contentWidth, max(0, windowWidth - edgeMargin * 2))
        return ViewerChromeRect(
            x: centredX(width, in: windowWidth),
            y: 0,
            width: width,
            height: contentHeight
        )
    }

    /// Flush with the top edge, under the strip it opens: a hover target set
    /// in from the edge is one the pointer can miss by overshooting.
    public static func stripHandle(
        windowWidth: Double,
        contentWidth: Double,
        contentHeight: Double
    ) -> ViewerChromeRect {
        ViewerChromeRect(
            x: centredX(contentWidth, in: windowWidth),
            y: 0,
            width: contentWidth,
            height: contentHeight
        )
    }

    /// The band across the top a pinned, open strip claims, which the
    /// picture and the diagnostics panel move down by. The rule itself is
    /// `ShortcutStripLayoutPolicy`, the same one the macOS window applies to
    /// its own video view, so the two platforms cannot drift apart on when a
    /// strip costs the picture height.
    public static func topInset(isPinned: Bool, isStripOpen: Bool, stripHeight: Double) -> Double {
        Double(ShortcutStripLayoutPolicy.videoTopInset(
            isPinned: isPinned,
            isStripOpen: isStripOpen,
            stripHeight: CGFloat(stripHeight)
        ))
    }

    /// Where the picture itself sits once a pinned strip has taken its band:
    /// the whole window below the band, in the same logical units a pointer
    /// position is reported in.
    ///
    /// A Wayland surface counts from its top-left corner, so the band moves
    /// the picture down as well as shrinking it, and a pointer position has
    /// to have `y` taken off it before it means anything on the far machine.
    /// The macOS view is not flipped and so only shrinks -- see
    /// `CanvasSurfaceView.videoBounds`.
    public static func videoArea(
        windowWidth: Double,
        windowHeight: Double,
        topInset: Double
    ) -> ViewerChromeRect {
        let inset = max(0, min(topInset, windowHeight))
        return ViewerChromeRect(
            x: 0,
            y: inset,
            width: windowWidth,
            height: Double(ShortcutStripLayoutPolicy.videoHeight(
                fullHeight: CGFloat(windowHeight),
                topInset: CGFloat(inset)
            ))
        )
    }

    /// How tall the picture's own drawable is once a pinned strip's band has
    /// been taken off it, in the real pixels the host is asked to stream at.
    /// Never below one: a drawable of no height is not one a compositor will
    /// take.
    public static func videoDrawablePixelHeight(
        drawablePixelHeight: Double,
        topInset: Double,
        scale: Double
    ) -> Double {
        guard topInset > 0 else { return drawablePixelHeight }
        let band = Double(pixelSize(logical: topInset, scale: scale))
        return max(1, drawablePixelHeight - band)
    }

    /// A logical length in the real pixels the compositor's fractional scale
    /// asks for. Rounded up, never below one: a buffer a fraction of a pixel
    /// short would clip the edge drawn into it, and a zero-sized buffer is
    /// not a buffer a compositor will take.
    public static func pixelSize(logical: Double, scale: Double) -> Int {
        max(1, Int((logical * scale).rounded(.up)))
    }

    private static func centredX(_ width: Double, in windowWidth: Double) -> Double {
        max(edgeMargin, (windowWidth - width) / 2)
    }

    private static func fitted(
        contentWidth: Double,
        contentHeight: Double,
        windowWidth: Double,
        windowHeight: Double
    ) -> (width: Double, height: Double) {
        (
            min(contentWidth, max(0, windowWidth - edgeMargin * 2)),
            min(contentHeight, max(0, windowHeight - edgeMargin * 2))
        )
    }
}
