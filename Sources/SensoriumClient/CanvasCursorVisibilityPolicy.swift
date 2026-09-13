import Foundation

/// Whether the local hardware cursor should be hidden over the canvas, and
/// the single source of truth for when it actually changes.
///
/// The viewer draws its own local arrow over the canvas rather than hiding
/// it behind the streamed remote one: hiding it made every pointer movement
/// wait for the full capture-encode-send-decode-present pipeline, measured
/// at 34 ms p50 / 117 ms p95 glass-to-glass. So the ordinary case hides
/// nothing.
/// Captured-pointer mode is the one remaining reason: it disassociates the
/// physical mouse and sends raw relative motion instead of absolute position
/// (see `CanvasSurfaceView.togglePointerCapture()`), so the local arrow's
/// screen position stops tracking the mouse at all, and showing it there
/// would be actively misleading rather than merely stale.
///
/// `NSCursor`'s `hide()`/`unhide()` is a system-wide reference count, not a
/// per-caller flag, and the session status overlay (Connecting, Lost, a
/// refusal) is a second, independent reason to force the cursor visible over
/// its own buttons even while captured. Collapsing both reasons into one
/// `shouldHideCursor` boolean and reporting only the edges keeps exactly one
/// `hide()` ever outstanding, matched by exactly one `unhide()` when the last
/// reason clears -- verifiable here without AppKit, which is what
/// `CanvasSurfaceView` applies these transitions through.
public struct CanvasCursorVisibilityPolicy: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case hide
        case unhide
        case none
    }

    public private(set) var isCapturingPointer = false
    public private(set) var isOverlayVisible = false
    public private(set) var isHidden = false

    public init() {}

    public var shouldHideCursor: Bool {
        !isOverlayVisible && isCapturingPointer
    }

    @discardableResult
    public mutating func capturingPointerChanged(_ value: Bool) -> Transition {
        isCapturingPointer = value
        return settle()
    }

    @discardableResult
    public mutating func overlayVisibilityChanged(_ value: Bool) -> Transition {
        isOverlayVisible = value
        return settle()
    }

    /// Drops every reason at once -- used when the window itself is going
    /// away and no further AppKit event will report capture ending or the
    /// overlay closing.
    @discardableResult
    public mutating func reset() -> Transition {
        isCapturingPointer = false
        isOverlayVisible = false
        return settle()
    }

    private mutating func settle() -> Transition {
        let desired = shouldHideCursor
        guard desired != isHidden else { return .none }
        isHidden = desired
        return desired ? .hide : .unhide
    }
}
