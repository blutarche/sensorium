import Foundation

/// One round trip of the time-sync exchange, measured on the client.
///
/// `hostRepliedNanoseconds` comes from the host's monotonic clock and shares no
/// origin with the client's: both are since-boot counters on different machines.
/// Comparing a host capture timestamp against a client present timestamp is
/// meaningless until that difference is estimated.
public struct ClockOffsetSample: Equatable, Sendable {
    public let clientSentNanoseconds: Int64
    public let hostRepliedNanoseconds: Int64
    public let clientReceivedNanoseconds: Int64

    public init(
        clientSentNanoseconds: Int64,
        hostRepliedNanoseconds: Int64,
        clientReceivedNanoseconds: Int64
    ) {
        self.clientSentNanoseconds = clientSentNanoseconds
        self.hostRepliedNanoseconds = hostRepliedNanoseconds
        self.clientReceivedNanoseconds = clientReceivedNanoseconds
    }

    public var roundTripNanoseconds: Int64 {
        clientReceivedNanoseconds - clientSentNanoseconds
    }

    /// `host - client`, so a host timestamp is read on the client's clock by
    /// subtracting it. Assumes a symmetric path, which is why the lowest round
    /// trip wins: the shortest observed trip is the least distorted by queueing.
    public var offsetNanoseconds: Int64 {
        hostRepliedNanoseconds - (clientSentNanoseconds + roundTripNanoseconds / 2)
    }
}

/// Estimates the host-minus-client offset from the lowest-round-trip sample among
/// the most recent ones, rather than averaging. An average lets one queued reply
/// drag the estimate; the minimum-delay sample is the one whose symmetry
/// assumption is closest to true.
///
/// Only recent samples are considered because the two machines' clocks drift
/// apart, so an old best sample describes an offset that no longer holds.
public struct HostClockOffsetEstimator: Equatable, Sendable {
    /// At the 10 second time-sync cadence this spans five minutes, over which
    /// clocks that differ by a few parts per million drift apart by at most a
    /// few milliseconds.
    public static let windowSize = 30

    private var recent: [ClockOffsetSample] = []

    public init() {}

    @discardableResult
    public mutating func record(_ sample: ClockOffsetSample) -> Bool {
        guard sample.roundTripNanoseconds >= 0 else {
            return false
        }
        recent.append(sample)
        if recent.count > Self.windowSize {
            recent.removeFirst(recent.count - Self.windowSize)
        }
        return true
    }

    private var best: ClockOffsetSample? {
        recent.min { $0.roundTripNanoseconds < $1.roundTripNanoseconds }
    }

    public var offsetNanoseconds: Int64? { best?.offsetNanoseconds }
    public var roundTripNanoseconds: Int64? { best?.roundTripNanoseconds }

    /// Reads a host timestamp on the client's clock. `nil` until a sample exists,
    /// so an unsynchronised session reports no latency instead of a fabricated one.
    public func clientTimeNanoseconds(forHostTimeNanoseconds hostTime: Int64) -> Int64? {
        guard let offset = offsetNanoseconds else {
            return nil
        }
        return hostTime - offset
    }
}

/// Client half of the time-sync exchange.
///
/// Only a reply that echoes an outstanding request counts. Without that check a
/// host could hand the client any offset it liked and the latency report would
/// describe a round trip that never happened.
public struct SessionClockSynchronizer: Sendable {
    public static let maximumOutstandingRequests = 8

    private var outstanding: [Int64] = []
    private var estimator = HostClockOffsetEstimator()
    /// The most recently accepted sample's own round trip, independent of
    /// `estimator`'s lowest-recent selection: `roundTripNanoseconds` below is
    /// the best recent clock-offset evidence, which is exactly the wrong
    /// number for a live ping display -- a link that has since gotten worse
    /// would show its best recent moment for minutes. This is updated on
    /// every accepted reply, better or worse.
    private var latestSample: Int64?

    public init() {}

    public var offsetNanoseconds: Int64? { estimator.offsetNanoseconds }
    public var roundTripNanoseconds: Int64? { estimator.roundTripNanoseconds }
    /// This session's most recent round trip, for a display that must track
    /// the link as it is now. See `latestSample`'s own doc comment for why
    /// this is not `roundTripNanoseconds`.
    public var latestRoundTripNanoseconds: Int64? { latestSample }
    public var outstandingRequestCount: Int { outstanding.count }

    public mutating func makeRequest(atNanoseconds now: Int64) -> SensoriumMessage {
        outstanding.append(now)
        if outstanding.count > Self.maximumOutstandingRequests {
            outstanding.removeFirst(outstanding.count - Self.maximumOutstandingRequests)
        }
        return .timeSyncRequest(clientTimeNanoseconds: now)
    }

    @discardableResult
    public mutating func receiveReply(
        clientTimeNanoseconds: Int64,
        hostTimeNanoseconds: Int64,
        receivedAtNanoseconds: Int64
    ) -> Bool {
        guard let index = outstanding.firstIndex(of: clientTimeNanoseconds) else {
            return false
        }
        outstanding.remove(at: index)
        let sample = ClockOffsetSample(
            clientSentNanoseconds: clientTimeNanoseconds,
            hostRepliedNanoseconds: hostTimeNanoseconds,
            clientReceivedNanoseconds: receivedAtNanoseconds
        )
        if sample.roundTripNanoseconds >= 0 {
            latestSample = sample.roundTripNanoseconds
        }
        return estimator.record(sample)
    }

    public func clientTimeNanoseconds(forHostTimeNanoseconds hostTime: Int64) -> Int64? {
        estimator.clientTimeNanoseconds(forHostTimeNanoseconds: hostTime)
    }
}
