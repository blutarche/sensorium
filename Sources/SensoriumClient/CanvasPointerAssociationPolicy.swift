import Foundation

/// Whether the physical mouse should be associated with the cursor position
/// right now, and the single source of truth for when it actually changes.
///
/// Captured-pointer mode sends raw relative deltas
/// (`CanvasSurfaceEvent.pointerMovedRelative`), which only make sense once
/// `CGAssociateMouseAndMouseCursorPosition(0)` has disconnected the physical
/// mouse from the cursor machine-wide -- otherwise the real, invisible cursor
/// keeps moving under the hidden pointer, reaches a screen edge, and the OS
/// pins it there: the deltas stop arriving and the pointer is stuck. An unbalanced
/// disassociate is worse than an unbalanced `NSCursor.hide()`: it leaves the
/// user's physical mouse disconnected from the cursor machine-wide, with
/// nothing on screen and nothing to click to fix it. This mirrors
/// `CanvasCursorVisibilityPolicy`'s settle-and-report shape so the same
/// exit paths -- everywhere `CanvasSurfaceView` already calls
/// `togglePointerCapture()` or forces capture off -- keep this balanced for
/// the same reason they keep the cursor's visibility balanced.
public struct CanvasPointerAssociationPolicy: Equatable, Sendable {
    public enum Transition: Equatable, Sendable {
        case disassociate
        case associate
        case none
    }

    public private(set) var isCapturing = false
    public private(set) var isDisassociated = false

    public init() {}

    @discardableResult
    public mutating func capturingPointerChanged(_ value: Bool) -> Transition {
        isCapturing = value
        return settle()
    }

    /// The last-resort exit, matching `CanvasCursorVisibilityPolicy.reset()`:
    /// forces association back on regardless of how capture ended, for a path
    /// that cannot go through `capturingPointerChanged(false)` itself -- an
    /// abrupt session teardown mid-capture.
    @discardableResult
    public mutating func reset() -> Transition {
        isCapturing = false
        return settle()
    }

    private mutating func settle() -> Transition {
        guard isCapturing != isDisassociated else { return .none }
        isDisassociated = isCapturing
        return isCapturing ? .disassociate : .associate
    }
}
