import Foundation

/// Why the send path asked a surface's encoder for a key frame. The raw value
/// is the wording of the host's log line.
public enum KeyFrameRecoveryCause: String, Equatable, Sendable {
    /// The send queue dropped a delta.
    case sendQueueDiscard = "send-queue discard"
    /// A frame's write to the transport failed.
    case writeFailure = "write failure"
    /// The viewer gave up a group of frames and asked for one.
    case viewerRequest = "viewer request"
}

/// Decides when a surface that lost a frame, on the way out or at the viewer,
/// asks its encoder for a key frame. A key frame costs many deltas' worth of bits, so the ask is
/// bounded: one outstanding request per surface, and requests at least
/// `minimumIntervalNanoseconds` apart. A loss inside that interval is not
/// forgotten; its request is made once the interval is up, unless a key frame
/// has ended the wait by then.
///
/// Pure bookkeeping: the caller supplies the time and owns the timer a held
/// request needs.
public struct KeyFrameRecoveryPacer: Sendable {
    public static let defaultMinimumIntervalNanoseconds: Int64 = 1_000_000_000

    public enum Decision: Equatable, Sendable {
        /// Ask the encoder now.
        case requestNow
        /// Ask nothing now; call `deferredRequestDue` at this time.
        case requestAt(nanoseconds: Int64)
        /// A request is already outstanding or already held.
        case none
    }

    public let minimumIntervalNanoseconds: Int64
    private var lastRequestAt = CanvasSurfaceSlots<Int64?> { _ in nil }
    private var isRequestOutstanding = CanvasSurfaceSlots { _ in false }
    private var heldCause = CanvasSurfaceSlots<KeyFrameRecoveryCause?> { _ in nil }

    public init(minimumIntervalNanoseconds: Int64 = KeyFrameRecoveryPacer.defaultMinimumIntervalNanoseconds) {
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
    }

    /// `surface` has just started waiting for a key frame.
    public mutating func keyFrameNeeded(
        on surface: CanvasSurfaceID,
        cause: KeyFrameRecoveryCause,
        atNanoseconds now: Int64
    ) -> Decision {
        guard !isRequestOutstanding[surface], heldCause[surface] == nil else {
            return .none
        }
        if let last = lastRequestAt[surface], now - last < minimumIntervalNanoseconds {
            heldCause[surface] = cause
            return .requestAt(nanoseconds: last + minimumIntervalNanoseconds)
        }
        lastRequestAt[surface] = now
        isRequestOutstanding[surface] = true
        return .requestNow
    }

    /// A key frame of `surface` reached the send path and ended its wait.
    public mutating func keyFrameArrived(on surface: CanvasSurfaceID) {
        isRequestOutstanding[surface] = false
    }

    /// The time a `.requestAt` named has come. Answers the cause to ask with,
    /// or `nil` when there is nothing to ask for: no request was held, or a
    /// key frame ended the wait first.
    public mutating func deferredRequestDue(
        on surface: CanvasSurfaceID,
        isStillAwaiting: Bool,
        atNanoseconds now: Int64
    ) -> KeyFrameRecoveryCause? {
        guard let cause = heldCause[surface] else {
            return nil
        }
        heldCause[surface] = nil
        guard isStillAwaiting, !isRequestOutstanding[surface] else {
            return nil
        }
        lastRequestAt[surface] = now
        isRequestOutstanding[surface] = true
        return cause
    }
}
