import SensoriumCore

public enum VideoSendAdmission: Equatable, Sendable {
    case sendNow
    case queued
    /// The frame that was waiting has been replaced by this newer one.
    case replacedStaleFrame
    /// The waiting frame is worth more than this one; this frame is discarded.
    case droppedIncoming
}

/// Whether a frame is worth protecting from displacement. A waiting keyframe is
/// never dropped for a delta: it is the viewer's only way back after loss, and
/// the delta cannot be decoded without it. Types with no keyframe concept (raw
/// capture output, before any encoding has decided what kind of frame it will
/// become) answer `false`: there is nothing yet for a decoder to depend on, so
/// the newest frame simply wins.
public protocol VideoFrameAdmissible {
    var isKeyFrame: Bool { get }
}

extension EncodedVideoFramePacket: VideoFrameAdmissible {}

/// One frame in flight, one frame waiting. A downstream stage the encoder (or
/// capture) outruns turns an unbounded queue into growing memory and growing
/// latency instead of a visibly older picture.
public struct VideoFrameAdmissionQueue<Frame: VideoFrameAdmissible & Sendable>: Sendable {
    private var isSending = false
    private var waiting: Frame?
    public private(set) var droppedFrameCount = 0

    public init() {}

    public var hasWaitingFrame: Bool { waiting != nil }

    /// Whether the frame waiting here is a recovery point. Used one layer up
    /// to decide whether another surface's preference may jump ahead of it.
    public var hasWaitingKeyFrame: Bool { waiting?.isKeyFrame ?? false }

    public mutating func enqueue(_ frame: Frame) -> VideoSendAdmission {
        guard isSending else {
            isSending = true
            return .sendNow
        }
        return offerToWaitingSlot(frame)
    }

    /// The waiting-slot policy on its own, for a caller that owns the single
    /// in-flight slot itself instead of letting this queue own it — see
    /// `SurfaceVideoSendQueues`, where the one slot is the shared byte channel
    /// rather than any single surface's. Never returns `.sendNow`.
    public mutating func offerToWaitingSlot(_ frame: Frame) -> VideoSendAdmission {
        guard let waiting else {
            self.waiting = frame
            return .queued
        }
        guard frame.isKeyFrame || !waiting.isKeyFrame else {
            droppedFrameCount += 1
            return .droppedIncoming
        }
        droppedFrameCount += 1
        self.waiting = frame
        return .replacedStaleFrame
    }

    /// Removes and returns the waiting frame, without touching the in-flight
    /// slot. The counterpart to `offerToWaitingSlot`.
    public mutating func takeWaiting() -> Frame? {
        defer { waiting = nil }
        return waiting
    }

    /// Call when the in-flight send finishes. Returns the frame to send next, or
    /// `nil` when nothing is waiting.
    public mutating func completeSend() -> Frame? {
        guard let next = takeWaiting() else {
            isSending = false
            return nil
        }
        return next
    }
}

/// The transport hand-off queue: `Frame` is the already-encoded packet a link
/// slower than the encoder might not keep up with.
public typealias VideoSendQueue = VideoFrameAdmissionQueue<EncodedVideoFramePacket>

/// A per-surface send weight, mirroring `EncodeAdmissionPriority` one layer
/// down and derived from the same `CanvasFocusTracker`. Every surface is
/// `.normal` whenever no focus has been reported, which degrades the
/// scheduling below to plain fair share.
public enum VideoSendPriority: Int, Comparable, Sendable {
    case normal = 0
    case elevated = 1

    public static func < (lhs: VideoSendPriority, rhs: VideoSendPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One waiting slot per canvas in front of the single byte channel both
/// share. This buys keyframe scoping and nothing else: with one shared
/// queue, one surface's keyframe displaces the other's and that surface
/// then decodes nothing until its next IDR. Latency is unchanged, one send
/// is in flight either way. Focus preference is bounded by
/// `maximumConsecutivePriorityWins` and never reorders a waiting keyframe.
public struct SurfaceVideoSendQueues: Sendable {
    /// How many turns in a row a higher-priority surface may take while a
    /// lower-priority one has a frame waiting.
    public static let maximumConsecutivePriorityWins = 3

    private var queues = CanvasSurfaceSlots { _ in VideoSendQueue() }
    private var waitingPriority = CanvasSurfaceSlots<VideoSendPriority> { _ in .normal }
    /// The single in-flight slot: the shared byte channel, owned here rather
    /// than by any one surface's queue, which is what keeps exactly one send
    /// on the wire at a time.
    private var isSendInFlight = false
    /// Arrival order of surfaces currently holding a waiting frame. A surface
    /// is appended when its waiting slot goes from empty to full and removed
    /// once dispatched, so a re-queue always goes to the back of the line —
    /// the mechanism that stops the faster encoder from taking every turn.
    private var fairnessOrder: [CanvasSurfaceID] = []
    /// Turns the preferred surface has taken in a row while the other one had
    /// a frame waiting. Bounds preference so the unfocused window keeps
    /// receiving frames instead of freezing.
    private var consecutivePriorityWins = 0

    public init() {}

    /// Frames dropped across both surfaces because the link could not keep up.
    public var droppedFrameCount: Int {
        queues.all.reduce(0) { $0 + $1.droppedFrameCount }
    }

    /// Frames dropped for this surface alone, for per-surface telemetry.
    public func droppedFrameCount(for surface: CanvasSurfaceID) -> Int {
        queues[surface].droppedFrameCount
    }

    public mutating func enqueue(
        _ frame: EncodedVideoFramePacket,
        surface: CanvasSurfaceID,
        priority: VideoSendPriority = .normal
    ) -> VideoSendAdmission {
        guard isSendInFlight else {
            isSendInFlight = true
            return .sendNow
        }
        let admission = queues[surface].offerToWaitingSlot(frame)
        switch admission {
        case .queued:
            waitingPriority[surface] = priority
            fairnessOrder.append(surface)
        case .replacedStaleFrame:
            // Keeps the fairness turn the displaced frame already held: a
            // surface cannot jump the line by replacing its own waiting frame.
            waitingPriority[surface] = priority
        case .droppedIncoming, .sendNow:
            break
        }
        return admission
    }

    /// Call when the in-flight send finishes. Returns the surface whose turn it
    /// is and the frame to send for it, or `nil` when neither surface has
    /// anything waiting.
    /// A surface is listed in `fairnessOrder` exactly while it holds a waiting
    /// frame, so `nextWaitingIndex` names a surface whose `takeWaiting` has
    /// something to give. The loop rather than a `guard` is what makes that an
    /// assumption this method survives being wrong about: a surface that turns
    /// out to hold nothing is simply passed over, leaving the other surface's
    /// waiting frame and the in-flight slot alone, instead of clearing both
    /// and stranding that frame until the connection ends.
    public mutating func completeSend() -> (surface: CanvasSurfaceID, frame: EncodedVideoFramePacket)? {
        while let index = nextWaitingIndex() {
            let surface = fairnessOrder.remove(at: index)
            guard let frame = queues[surface].takeWaiting() else {
                continue
            }
            waitingPriority[surface] = .normal
            return (surface, frame)
        }
        isSendInFlight = false
        // Only surfaces with nothing waiting can still be listed here.
        fairnessOrder.removeAll()
        return nil
    }

    private mutating func nextWaitingIndex() -> Int? {
        var bestIndex: Int?
        var bestPriority: VideoSendPriority?
        for (index, surface) in fairnessOrder.enumerated() where queues[surface].hasWaitingFrame {
            let priority = effectivePriority(of: surface)
            if bestPriority == nil || priority > bestPriority! {
                bestPriority = priority
                bestIndex = index
            }
        }
        guard let bestIndex, let bestPriority else {
            return nil
        }
        // Nothing is being displaced: either one surface is waiting, or both
        // carry the same effective priority, which is the state a host that
        // never received a focus report is permanently in. `bestIndex` is
        // then the longest-waiting surface, exactly as plain fair share.
        guard let floorIndex = longestWaitingIndex(below: bestPriority) else {
            consecutivePriorityWins = 0
            return bestIndex
        }
        guard consecutivePriorityWins < Self.maximumConsecutivePriorityWins else {
            consecutivePriorityWins = 0
            return floorIndex
        }
        consecutivePriorityWins += 1
        return bestIndex
    }

    /// The longest-waiting surface ranked below `priority`, or `nil` when no
    /// surface is being outranked at all.
    private func longestWaitingIndex(below priority: VideoSendPriority) -> Int? {
        for (index, surface) in fairnessOrder.enumerated()
        where queues[surface].hasWaitingFrame && effectivePriority(of: surface) < priority {
            return index
        }
        return nil
    }

    /// A frame that is not a recovery point never outranks another surface's
    /// waiting keyframe, however the focus signal ranks the two surfaces: the
    /// viewer gates on `hasRecoveryKeyFrame`, so until that keyframe lands the
    /// other window shows nothing at all and every delta behind it is
    /// undecodable wire time. Preference among equals is untouched, and with
    /// no focus reported every surface is `.normal`, so this can never change
    /// the plain fair-share order.
    private func effectivePriority(of surface: CanvasSurfaceID) -> VideoSendPriority {
        guard waitingPriority[surface] == .elevated,
              !queues[surface].hasWaitingKeyFrame,
              CanvasSurfaceID.allCases.contains(where: { $0 != surface && queues[$0].hasWaitingKeyFrame }) else {
            return waitingPriority[surface]
        }
        return .normal
    }
}
