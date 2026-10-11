import Foundation

/// What a surface's encode-admission gate is told by the send path in front
/// of the wire.
public protocol VideoSendFeedbackListener: AnyObject, Sendable {
    /// The surface's send waiting slot has just emptied, so a capture held
    /// for it may go to the encoder.
    func sendWaitingSlotEmptied()
    /// The surface lost a frame on the way out and needs a key frame.
    func keyFrameNeeded()
}

/// One connection's link between each surface's send waiting slot and the
/// encode-admission gate that feeds that surface, shared the way
/// `CanvasFocusTracker` is: the network session writes it, and every media
/// pipeline the session runs registers its gate with it.
///
/// It exists so that frames are given up before the encoder rather than after
/// it. A capture dropped before encoding costs the viewer nothing; an encoded
/// delta dropped after it leaves every later delta built on a picture the
/// viewer never received.
///
/// Lock-guarded rather than actor-isolated for the same reason as the focus
/// tracker: it is read on the capture and encoder threads once per frame. Its
/// lock is never held while calling out, so it can be read under a caller's
/// own lock.
public final class VideoSendFeedback: @unchecked Sendable {
    private struct WeakListener {
        weak var listener: (any VideoSendFeedbackListener)?
    }

    private let lock = NSLock()
    private var waitingSlotOccupied = CanvasSurfaceSlots { _ in false }
    private var listeners = CanvasSurfaceSlots { _ in WeakListener() }

    public init() {}

    public func isWaitingSlotOccupied(on surface: CanvasSurfaceID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return waitingSlotOccupied[surface]
    }

    /// Kept in step with the send queues by the send path, under the send
    /// queues' own lock, so this never disagrees with the slot for longer
    /// than the call that changed both.
    public func setWaitingSlotOccupied(_ occupied: Bool, on surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        waitingSlotOccupied[surface] = occupied
    }

    /// Replaces any listener `surface` had: a rebuilt pipeline's gate takes
    /// over from the one it replaces.
    public func attach(_ listener: any VideoSendFeedbackListener, on surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        listeners[surface] = WeakListener(listener: listener)
    }

    /// Removes `listener` only if it is still the one attached, so a gate
    /// shutting down after its replacement attached leaves the replacement in
    /// place.
    public func detach(_ listener: any VideoSendFeedbackListener, on surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        if listeners[surface].listener === listener {
            listeners[surface] = WeakListener()
        }
    }

    /// Call after `setWaitingSlotOccupied(false, on:)`, outside any lock of
    /// the caller's: the listener may submit a capture to the encoder from
    /// inside this call.
    public func waitingSlotEmptied(on surface: CanvasSurfaceID) {
        listener(on: surface)?.sendWaitingSlotEmptied()
    }

    public func requestKeyFrame(on surface: CanvasSurfaceID) {
        listener(on: surface)?.keyFrameNeeded()
    }

    private func listener(on surface: CanvasSurfaceID) -> (any VideoSendFeedbackListener)? {
        lock.lock()
        defer { lock.unlock() }
        return listeners[surface].listener
    }
}
