import SensoriumCore

/// Which mouse presses and releases the canvas forwards, once the viewer has
/// chrome of its own -- the shortcut strip and its handle -- drawn over the
/// picture.
///
/// A press aimed at that chrome is not the far machine's, and neither is the
/// release that ends it. A press aimed at the picture is, and so is its
/// release, wherever the pointer happens to be by then: a drag that ends over
/// the strip must still let go of the button, because a button left held down
/// on a machine nobody is sitting at is worse than a stray click.
///
/// Holds no view and reads no event, so both halves of every case are checked
/// without a window.
public struct CanvasChromeClickPolicy: Equatable, Sendable {
    private var forwarded: Set<CanvasPointerButton> = []

    public init() {}

    public mutating func shouldForwardPress(_ button: CanvasPointerButton, isOverChrome: Bool) -> Bool {
        guard !isOverChrome else { return false }
        forwarded.insert(button)
        return true
    }

    public mutating func shouldForwardRelease(_ button: CanvasPointerButton) -> Bool {
        forwarded.remove(button) != nil
    }
}
