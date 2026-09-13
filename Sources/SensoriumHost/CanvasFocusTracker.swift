import Foundation

/// Which canvas the viewer says it is looking at, shared by the two places
/// that can act on it: the encoder-input gate both pipelines contend for, and
/// the send queues in front of the one byte channel both canvases share.
///
/// Deliberately a lock-guarded class rather than actor-isolated state. It is
/// written on the main actor, from the session's message handler, and read
/// from the encoder's own callback thread once per frame; an `await` on that
/// path is exactly the backlog `VideoSendQueue` exists to prevent.
///
/// `nil` covers both states that mean "prefer nobody" — no focus report has
/// ever arrived, and the viewer reported that the user is looking at a local
/// app. Both derive `.normal` for every surface.
public final class CanvasFocusTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var focused: CanvasSurfaceID?

    public init() {}

    public var focusedSurface: CanvasSurfaceID? {
        lock.lock()
        defer { lock.unlock() }
        return focused
    }

    public func setFocusedSurface(_ surface: CanvasSurfaceID?) {
        lock.lock()
        defer { lock.unlock() }
        focused = surface
    }

    /// The weight this surface's encoded frames go to the wire with.
    public func sendPriority(for surface: CanvasSurfaceID) -> VideoSendPriority {
        focusedSurface == surface ? .elevated : .normal
    }

    /// The weight this surface's captured frames contend for the shared
    /// hardware encoder with.
    public func encodePriority(for surface: CanvasSurfaceID) -> EncodeAdmissionPriority {
        focusedSurface == surface ? .elevated : .normal
    }
}
