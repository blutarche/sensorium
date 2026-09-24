/// Whether a session window's overlays are committing with the picture or on
/// their own clock.
///
/// A Wayland subsurface in synchronised mode does not reach the screen until
/// its parent commits, which is exactly what a resize needs: the picture at
/// its new size and every overlay at its new place arrive as one update,
/// with no frame showing one without the other. Outside a resize the
/// overlays are better off desynchronised, so a notice or a closing strip
/// does not wait on the next video frame to appear.
///
/// Holds no Wayland object: it decides when the mode changes, and the window
/// applies it.
public struct WaylandOverlaySyncGate: Equatable, Sendable {
    public private(set) var isSynchronised = false

    public init() {}

    /// A configure changed the surface's size. Answers whether the mode
    /// changed, so a caller only talks to the compositor when it has to.
    public mutating func surfaceResized() -> Bool {
        guard !isSynchronised else { return false }
        isSynchronised = true
        return true
    }

    /// The picture has been drawn at the new size, so the overlays that were
    /// waiting for it can go back to their own clock.
    public mutating func pictureDrawn() -> Bool {
        guard isSynchronised else { return false }
        isSynchronised = false
        return true
    }
}
