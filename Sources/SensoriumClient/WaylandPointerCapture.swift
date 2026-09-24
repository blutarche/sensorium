import Foundation
import SensoriumCore

/// What captured-pointer mode asks of a Wayland compositor, as the two acts
/// it really is: take the pointer, or give it back.
///
/// `lockPointer()` locks the pointer to this surface, starts relative motion,
/// and hides the cursor; `unlockPointer()` undoes all three. Keeping them
/// behind this protocol is what lets the state machine below be checked
/// without a compositor, a seat, or a surface.
@MainActor
public protocol WaylandPointerLocking: AnyObject {
    func lockPointer()
    func unlockPointer()
}

/// Captured-pointer mode for a Wayland surface: whether the pointer is
/// currently taken, and every way that can change.
///
/// The bookkeeping mirrors the macOS surface's exactly, through the same
/// `CanvasPointerAssociationPolicy`, so both platforms have one place where a
/// lock is balanced against an unlock. A compositor can end the lock on its
/// own -- the window lost focus, or the compositor refused the request -- so
/// unlike macOS, this side is not the only one that decides.
@MainActor
public final class WaylandPointerCaptureController {
    /// Weak: the window this asks is the window that owns it.
    private weak var locking: (any WaylandPointerLocking)?
    private let route: (CanvasSurfaceEvent) -> Void
    private var policy = CanvasPointerAssociationPolicy()
    private var hasCompositorConfirmedLock = false

    /// How long the compositor is given to confirm a lock before it is
    /// treated as refused. A lock nobody confirmed delivers no relative
    /// motion, so staying in captured-pointer mode would leave a hidden
    /// cursor and a pointer that does not move.
    public static let lockConfirmationSeconds = 1

    public init(locking: any WaylandPointerLocking, route: @escaping (CanvasSurfaceEvent) -> Void) {
        self.locking = locking
        self.route = route
    }

    public private(set) var isCapturing = false

    /// Whether every lock this window requested has been given back. False
    /// only while the pointer is really locked.
    public var isBalanced: Bool { !policy.isDisassociated }

    /// Enters or leaves captured-pointer mode: the viewer's own request,
    /// from the capture toggle or the first click of a capturing run.
    public func toggle() {
        set(isCapturing: !isCapturing)
    }

    /// The exits that must work whether or not capture is on: the escape
    /// gesture, and losing the keyboard.
    public func endIfNeeded() {
        guard isCapturing else { return }
        set(isCapturing: false)
    }

    /// `zwp_locked_pointer_v1.locked`.
    public func compositorConfirmedLock() {
        hasCompositorConfirmedLock = true
    }

    /// `zwp_locked_pointer_v1.unlocked`: the compositor ended the lock, which
    /// it does when this surface stops being the one the pointer is over or
    /// when it declines to keep the lock at all. Captured-pointer mode cannot
    /// outlive the lock it is made of.
    public func compositorEndedLock() {
        endIfNeeded()
    }

    /// Answers whether the lock went unconfirmed long enough to be treated as
    /// refused, and ends capture if it did. The caller reports it; nothing
    /// here logs.
    @discardableResult
    public func lockConfirmationDeadlinePassed() -> Bool {
        guard isCapturing, !hasCompositorConfirmedLock else { return false }
        endIfNeeded()
        return true
    }

    /// The last-resort exit, for a window that is going away mid-capture with
    /// no compositor event left to arrive. Matches
    /// `CanvasSurfaceView.forceRestoreCursor()`.
    public func reset() {
        endIfNeeded()
        apply(policy.reset())
    }

    private func set(isCapturing value: Bool) {
        isCapturing = value
        if value {
            hasCompositorConfirmedLock = false
        }
        apply(policy.capturingPointerChanged(value))
        route(.pointerCaptureChanged(isCaptured: value))
    }

    private func apply(_ transition: CanvasPointerAssociationPolicy.Transition) {
        switch transition {
        case .disassociate: locking?.lockPointer()
        case .associate: locking?.unlockPointer()
        case .none: break
        }
    }
}
