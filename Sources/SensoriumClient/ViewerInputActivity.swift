import Foundation
import SensoriumCore

/// When this viewer last sent an input event to the host.
///
/// `ClientSessionController` stamps it at the one place input leaves for the
/// host, and the frame presenters read it to tell whether the person is
/// interacting (see `PresentationPacer`). Not an actor: the stamp is written
/// from the session's actor and read from the main thread on every display
/// refresh, and neither side can afford to wait for the other.
public final class ViewerInputActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastInputNanoseconds: Int64?

    public init() {}

    /// Notes that an input event was sent at `nanoseconds` on the monotonic
    /// clock. An earlier stamp never replaces a later one.
    public func recordInput(atNanoseconds nanoseconds: Int64) {
        lock.lock()
        lastInputNanoseconds = max(lastInputNanoseconds ?? nanoseconds, nanoseconds)
        lock.unlock()
    }

    /// Whether an input event was sent within
    /// `PresentationPacer.interactionWindowNanoseconds` before `now`.
    public func isInteracting(nowNanoseconds now: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastInputNanoseconds else { return false }
        return now - last <= PresentationPacer.interactionWindowNanoseconds
    }
}
