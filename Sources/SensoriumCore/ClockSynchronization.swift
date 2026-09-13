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

/// Retains the single lowest-round-trip sample rather than averaging. An average
/// lets one queued reply drag the estimate; the minimum-delay sample is the one
/// whose symmetry assumption is closest to true.
public struct HostClockOffsetEstimator: Equatable, Sendable {
    private var best: ClockOffsetSample?

    public init() {}

    @discardableResult
    public mutating func record(_ sample: ClockOffsetSample) -> Bool {
        guard sample.roundTripNanoseconds >= 0 else {
            return false
        }
        if let best, best.roundTripNanoseconds <= sample.roundTripNanoseconds {
            return true
        }
        best = sample
        return true
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

    public init() {}

    public var offsetNanoseconds: Int64? { estimator.offsetNanoseconds }
    public var roundTripNanoseconds: Int64? { estimator.roundTripNanoseconds }
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
        return estimator.record(ClockOffsetSample(
            clientSentNanoseconds: clientTimeNanoseconds,
            hostRepliedNanoseconds: hostTimeNanoseconds,
            clientReceivedNanoseconds: receivedAtNanoseconds
        ))
    }

    public func clientTimeNanoseconds(forHostTimeNanoseconds hostTime: Int64) -> Int64? {
        estimator.clientTimeNanoseconds(forHostTimeNanoseconds: hostTime)
    }
}
