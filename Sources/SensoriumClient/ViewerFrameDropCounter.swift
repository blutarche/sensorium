import Foundation

/// How many frames this viewer gave up instead of showing, and where it gave
/// them up.
///
/// A remote desktop shows what the host screen looks like now, so a viewer that
/// cannot keep up with what is arriving has to skip forward rather than work
/// through everything it is holding. Every frame it skips is counted here.
///
/// The two places are counted apart because they cost different things. A
/// packet given up before decoding takes the rest of its group of frames with
/// it, since each of those is expressed as a difference from a picture that was
/// never decoded; the picture is then held until the next key frame. A decoded
/// frame given up before presentation costs only itself, because a newer
/// complete picture is already in hand.
///
/// Not an actor: the decode callback and the receive loop both reach this from
/// off the main actor, and neither can afford to suspend.
public final class ViewerFrameDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var beforeDecode = 0
    private var beforePresent = 0

    public init() {}

    /// Packets the decoder never saw.
    public var droppedBeforeDecode: Int {
        lock.lock()
        defer { lock.unlock() }
        return beforeDecode
    }

    /// Decoded frames a newer frame replaced before the screen was drawn.
    public var droppedBeforePresent: Int {
        lock.lock()
        defer { lock.unlock() }
        return beforePresent
    }

    /// Both together, which is what the session's latency summary reports:
    /// a person reading it wants to know the viewer is skipping frames at all
    /// before they want to know where.
    public var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return beforeDecode + beforePresent
    }

    public func recordDroppedBeforeDecode(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        beforeDecode += count
        lock.unlock()
    }

    public func recordDroppedBeforePresent(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        beforePresent += count
        lock.unlock()
    }

    /// Cumulative for the life of one window, so a reconnect behind the same
    /// window keeps counting rather than starting over: what a person wants to
    /// know is whether this viewer has been skipping frames, not whether it
    /// skipped one since the last time the socket was rebuilt.
    public func reset() {
        lock.lock()
        beforeDecode = 0
        beforePresent = 0
        lock.unlock()
    }
}
