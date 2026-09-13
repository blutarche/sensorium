import Foundation

/// What the viewer reported about one surface over the last interval, when it
/// reported anything at all. Every field is optional because a viewer that has
/// not decoded a frame yet has no percentile to offer, and a fabricated zero
/// would read as perfect health.
///
/// How long frames took to arrive is deliberately not among them. That
/// measurement carries the error in relating two machines' clocks, and on an
/// ordinary wireless link it reads the same whether the link is idle or full,
/// so no fidelity decision may rest on it. What the link is doing is read
/// from how much of what was produced arrived.
public struct StreamFidelityViewerObservation: Equatable, Sendable {
    public let decodeP95Nanoseconds: Int64?
    public let presentedFramesPerSecond: Double?
    public let decodedFramesPerSecond: Double?
    public let receivedBitsPerSecond: Double?

    public init(
        decodeP95Nanoseconds: Int64? = nil,
        presentedFramesPerSecond: Double? = nil,
        decodedFramesPerSecond: Double? = nil,
        receivedBitsPerSecond: Double? = nil
    ) {
        self.decodeP95Nanoseconds = decodeP95Nanoseconds
        self.presentedFramesPerSecond = presentedFramesPerSecond
        self.decodedFramesPerSecond = decodedFramesPerSecond
        self.receivedBitsPerSecond = receivedBitsPerSecond
    }
}

/// One tick's evidence about one surface: counters as deltas since the
/// previous tick, latencies as percentiles since the last encode checkpoint.
///
/// `viewer` is `nil` whenever the viewer's own report is missing or too old to
/// trust. That absence is meaningful and is never filled in with a default:
/// missing viewer evidence must be able to hold fidelity where it is, and must
/// never be able to raise it.
public struct StreamFidelityObservation: Equatable, Sendable {
    public let capturedDelta: Int
    public let encodedDelta: Int
    /// Captured frames the encoder never saw because capture outran it.
    public let encoderInputDroppedDelta: Int
    /// Frames refused by the bound shared across every pipeline on this host.
    public let globalAdmissionDroppedDelta: Int
    /// Encoded frames the transport hand-off could not take.
    public let sendQueueDroppedDelta: Int
    public let encodeP50Nanoseconds: Int64?
    /// How many encode samples back `encodeP50Nanoseconds`. Below
    /// `EncodeSustainabilityPolicy.minimumSampleCount` there is warm-up, not
    /// yet a measure of steady-state cost.
    public let encodeSampleCount: Int
    /// What the encoder produced over the interval. This is what the stream
    /// asked of the link, so it is what decides whether the link is worth
    /// blaming at all -- but it is not what the viewer's own reading is
    /// measured against, because frames the transport discarded before the
    /// wire are counted here and never reached anyone.
    public let producedBitsPerSecond: Double?
    /// What the transport actually handed to the wire over the interval: the
    /// only figure the viewer's `receivedBitsPerSecond` can honestly be
    /// compared with. `nil` when nothing in this pipeline is counting sends,
    /// which yields no ratio at all rather than one measured against bits that
    /// may never have left this machine.
    public let sentBitsPerSecond: Double?
    public let viewer: StreamFidelityViewerObservation?
    /// How long this tick actually took, wall-clock. Divided by
    /// `capturedDelta`, this is the screen's own observed capture period --
    /// how much of the tick each captured frame actually got, which on a
    /// screen producing far fewer frames than the applied frame rate is far
    /// longer than that rate's nominal frame period. `nil` for a caller that
    /// has no tick boundary to report, which falls back to judging the
    /// encoder against the nominal period alone.
    public let tickDurationNanoseconds: Int64?

    public init(
        capturedDelta: Int,
        encodedDelta: Int = 0,
        encoderInputDroppedDelta: Int = 0,
        globalAdmissionDroppedDelta: Int = 0,
        sendQueueDroppedDelta: Int = 0,
        encodeP50Nanoseconds: Int64? = nil,
        encodeSampleCount: Int = 0,
        producedBitsPerSecond: Double? = nil,
        sentBitsPerSecond: Double? = nil,
        viewer: StreamFidelityViewerObservation? = nil,
        tickDurationNanoseconds: Int64? = nil
    ) {
        self.capturedDelta = capturedDelta
        self.encodedDelta = encodedDelta
        self.encoderInputDroppedDelta = encoderInputDroppedDelta
        self.globalAdmissionDroppedDelta = globalAdmissionDroppedDelta
        self.sendQueueDroppedDelta = sendQueueDroppedDelta
        self.encodeP50Nanoseconds = encodeP50Nanoseconds
        self.encodeSampleCount = encodeSampleCount
        self.producedBitsPerSecond = producedBitsPerSecond
        self.sentBitsPerSecond = sentBitsPerSecond
        self.viewer = viewer
        self.tickDurationNanoseconds = tickDurationNanoseconds
    }
}
