import Foundation

/// Turns the timestamps a live session already carries into per-stage latency.
///
/// Client-local stages are always measurable. Anything spanning both machines
/// waits for a clock sample, and a frame whose converted capture time is later
/// than its present time is refused rather than recorded as fast: a bad offset
/// must show up as missing data, not as a flattering number.
public struct SessionLatencyRecorder: Sendable {
    private var synchronizer = SessionClockSynchronizer()
    public private(set) var metrics = SessionMetrics()

    public init() {}

    public var clockOffsetNanoseconds: Int64? { synchronizer.offsetNanoseconds }
    public var clockRoundTripNanoseconds: Int64? { synchronizer.roundTripNanoseconds }

    public mutating func makeClockRequest(atNanoseconds now: Int64) -> SensoriumMessage {
        synchronizer.makeRequest(atNanoseconds: now)
    }

    @discardableResult
    public mutating func receiveClockReply(
        clientTimeNanoseconds: Int64,
        hostTimeNanoseconds: Int64,
        receivedAtNanoseconds: Int64
    ) -> Bool {
        synchronizer.receiveReply(
            clientTimeNanoseconds: clientTimeNanoseconds,
            hostTimeNanoseconds: hostTimeNanoseconds,
            receivedAtNanoseconds: receivedAtNanoseconds
        )
    }

    /// Returns whether the host-relative stages were recorded. The client-local
    /// stages are recorded either way.
    @discardableResult
    public mutating func recordFrame(
        hostCapturedAtNanoseconds: Int64,
        receivedAtNanoseconds: Int64,
        decodedAtNanoseconds: Int64,
        presentedAtNanoseconds: Int64
    ) -> Bool {
        metrics.recordFrame(
            capturedInClientTimeNanoseconds: clientTime(forHostCapturedAtNanoseconds: hostCapturedAtNanoseconds),
            receivedAtNanoseconds: receivedAtNanoseconds,
            decodedAtNanoseconds: decodedAtNanoseconds,
            presentedAtNanoseconds: presentedAtNanoseconds
        )
    }

    /// One `input`/`inputApplied` round trip, entirely client-local: both
    /// timestamps come from this machine's own clock, so unlike `recordFrame`
    /// this needs no clock synchronization first.
    @discardableResult
    public mutating func recordInputRoundTrip(sentAtNanoseconds: Int64, repliedAtNanoseconds: Int64) -> Bool {
        metrics.record(stage: .inputRoundTrip, startedAtNanoseconds: sentAtNanoseconds, endedAtNanoseconds: repliedAtNanoseconds)
    }

    /// Reads a host capture timestamp on the client's own clock, `nil` until
    /// a clock-offset sample exists. Exposed so a caller keeping a second,
    /// per-surface `SessionMetrics` can record the identical frame against
    /// this recorder's one clock synchronizer instead of owning its own.
    public func clientTime(forHostCapturedAtNanoseconds hostCapturedAtNanoseconds: Int64) -> Int64? {
        synchronizer.clientTimeNanoseconds(forHostTimeNanoseconds: hostCapturedAtNanoseconds)
    }
}
