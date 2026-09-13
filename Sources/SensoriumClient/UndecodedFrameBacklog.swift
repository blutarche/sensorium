import SensoriumCore

/// Which encoded packets a viewer keeps when they arrive faster than it can
/// decode them, and which it gives up.
///
/// A decoded frame can always be given up, because nothing else is expressed in
/// terms of it. An encoded one usually cannot: every frame from a key frame up
/// to the next one is a difference from the frame before it, so skipping one in
/// the middle does not make the rest late, it makes them wrong. That leaves
/// exactly two safe moves, and this type makes only those.
///
/// A key frame arriving describes a whole picture by itself, so every packet
/// still waiting behind it is now unnecessary and all of them go at once.
///
/// How long a packet has waited is not a reason to give it up. Several packets
/// arriving together is what a viewer sees every time it was busy for a moment,
/// and a hardware decode costs a few milliseconds, so catching up on thirty
/// held packets costs about a tenth of a second. Giving the group up instead
/// holds the picture still until the next key frame, which the host's encoder
/// bounds at one second. Catching up is the cheaper of the two by a wide
/// margin, so this type always catches up.
///
/// `maximumPending` is a memory bound and nothing more: a group that reaches it
/// is given up because a viewer must not grow a queue without end. Nothing is
/// taken after that until the next key frame arrives. The host bounds that
/// wait: its encoder asks for a key frame at least once a second
/// (`kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration`), and sends one
/// besides whenever fidelity changes or a still screen is refreshed.
///
/// Admitting nothing before the session's first key frame is not this type's
/// job -- `VideoFrameIngress` already refuses a delta it has no picture to
/// apply, upstream of here.
public struct UndecodedFrameBacklog: Sendable {
    /// The most packets that may wait at once. Two seconds of a 45 fps stream,
    /// which is well past any stall a viewer catches up from and short of any
    /// amount of memory worth worrying about.
    public static let defaultMaximumPending = 90

    public let maximumPending: Int

    private var pending: [EncodedVideoFramePacket] = []
    /// Whether the group in flight was given up, so nothing but a key frame is
    /// worth taking. The picture on screen is held for as long as this lasts.
    public private(set) var isAwaitingKeyFrame = false

    public init(maximumPending: Int = UndecodedFrameBacklog.defaultMaximumPending) {
        self.maximumPending = max(1, maximumPending)
    }

    public var count: Int { pending.count }

    /// Takes one packet and reports how many packets that cost, this one
    /// included. Zero means nothing was given up.
    @discardableResult
    public mutating func admit(_ packet: EncodedVideoFramePacket) -> Int {
        if packet.isKeyFrame {
            let superseded = pending.count
            pending = [packet]
            isAwaitingKeyFrame = false
            return superseded
        }
        if isAwaitingKeyFrame {
            return 1
        }
        pending.append(packet)
        guard pending.count > maximumPending else {
            return 0
        }
        let held = pending.count
        // A key frame still waiting is kept: it is a whole picture already in
        // hand, and showing it is better than holding an older one. The wait
        // for the next key frame stands even so, because the deltas given up
        // here are what the frames after it are differences from.
        if let newestKeyFrame = pending.lastIndex(where: { $0.isKeyFrame }) {
            pending = [pending[newestKeyFrame]]
        } else {
            pending.removeAll()
        }
        isAwaitingKeyFrame = true
        return held - pending.count
    }

    /// The oldest packet still worth decoding. Oldest, not newest: the ones
    /// held here are exactly the ones a later frame is a difference from, and
    /// `admit` has already dropped whatever was safe to drop.
    public mutating func takeNext() -> EncodedVideoFramePacket? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// Back to a backlog that has admitted nothing. `isAwaitingKeyFrame`
    /// returns to false for the same reason `init` starts there: whatever comes
    /// next is arriving through an ingress that admits no delta before a key
    /// frame.
    public mutating func reset() {
        pending.removeAll()
        isAwaitingKeyFrame = false
    }
}
