import Foundation

/// Carries decoded frames from the decoder's own thread to the presenter, in
/// order, without letting them pile up without end.
///
/// A short queue rather than one slot. Frames arrive from a network in small
/// groups, and which of a group belongs on which display refresh is
/// `PresentationPacer`'s decision -- one it cannot make about frames that were
/// thrown away on the way to it. So a frame is kept while the one before it is
/// still being handed over, and only a queue past `maximumPending` gives
/// anything up: at that point the presenter has stopped taking frames
/// altogether, and the oldest are the ones worth least.
///
/// At most one presentation is in flight at a time, so a presenter slower than
/// the decoder cannot accumulate work behind it.
///
/// This replaces one unstructured task per decoded frame. That pile had no
/// bound at all: while the main actor was busy, each arriving frame added
/// another task holding another pixel buffer.
///
/// Not an actor: `submit(_:)` is called from the decoder's own output callback,
/// which runs on VideoToolbox's thread and cannot suspend.
public final class DecodedFrameCoalescer: @unchecked Sendable {
    public typealias Present = @Sendable (DecodedFrame) async -> Void

    /// The most decoded frames that may wait at once. Eight is more than a
    /// burst off a link ever holds, and is a memory bound rather than a
    /// judgement about which picture is worth showing.
    public static let maximumPending = 8

    private let lock = NSLock()
    private var pending: [DecodedFrame] = []
    private var isPresenting = false
    private var isStopped = false
    private let present: Present
    private let drops: ViewerFrameDropCounter?

    public init(drops: ViewerFrameDropCounter? = nil, present: @escaping Present) {
        self.drops = drops
        self.present = present
    }

    public func submit(_ frame: DecodedFrame) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        pending.append(frame)
        var superseded = 0
        if pending.count > Self.maximumPending {
            superseded = pending.count - Self.maximumPending
            pending.removeFirst(superseded)
        }
        let shouldStart = !isPresenting
        if shouldStart {
            isPresenting = true
        }
        lock.unlock()
        drops?.recordDroppedBeforePresent(superseded)
        guard shouldStart else { return }
        Task { [weak self] in
            await self?.drain()
        }
    }

    /// Ends presentation for good and gives up whatever was waiting. A frame
    /// already handed to the presenter is left to finish: it is a picture the
    /// session really did produce, and tearing it out mid-draw would replace
    /// what the person is looking at with an empty drawable.
    public func stop() {
        lock.lock()
        let abandoned = pending.count
        pending.removeAll()
        isStopped = true
        lock.unlock()
        drops?.recordDroppedBeforePresent(abandoned)
    }

    private func drain() async {
        while let frame = takePendingFrame() {
            await present(frame)
        }
    }

    /// Synchronous on purpose: a lock must not be held across a suspension,
    /// and the only thing this has to do atomically is hand over the pending
    /// frame or stand down.
    private func takePendingFrame() -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, !pending.isEmpty else {
            isPresenting = false
            return nil
        }
        return pending.removeFirst()
    }
}
