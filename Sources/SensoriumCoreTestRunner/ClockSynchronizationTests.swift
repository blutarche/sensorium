import Foundation
import SensoriumCore

func testClockOffsetEstimatorPrefersTheLowestRoundTripSample() {
    var estimator = HostClockOffsetEstimator()
    expect(estimator.offsetNanoseconds == nil, "an estimator with no sample offers no offset")

    // Host clock runs 1_000 ns ahead of the client clock; a symmetric 200 ns
    // round trip therefore replies at the client midpoint plus that offset.
    expect(
        estimator.record(ClockOffsetSample(
            clientSentNanoseconds: 10_000,
            hostRepliedNanoseconds: 11_100,
            clientReceivedNanoseconds: 10_200
        )),
        "a well-ordered sample is accepted"
    )
    expect(estimator.offsetNanoseconds == 1_000, "offset is the host reply minus the client midpoint")
    expect(estimator.roundTripNanoseconds == 200, "round trip is the client-side elapsed time")

    // A slower, asymmetric round trip carries a worse estimate and must not
    // displace the better one.
    expect(
        estimator.record(ClockOffsetSample(
            clientSentNanoseconds: 20_000,
            hostRepliedNanoseconds: 29_000,
            clientReceivedNanoseconds: 30_000
        )),
        "a slower sample is still a valid sample"
    )
    expect(estimator.offsetNanoseconds == 1_000, "a higher round trip does not replace a better estimate")
    expect(estimator.roundTripNanoseconds == 200, "the retained round trip stays the lowest observed")

    expect(
        estimator.record(ClockOffsetSample(
            clientSentNanoseconds: 40_000,
            hostRepliedNanoseconds: 41_050,
            clientReceivedNanoseconds: 40_100
        )),
        "a faster sample is accepted"
    )
    expect(estimator.offsetNanoseconds == 1_000, "a faster symmetric sample confirms the same offset")
    expect(estimator.roundTripNanoseconds == 100, "the lowest round trip is retained")

    expect(
        !estimator.record(ClockOffsetSample(
            clientSentNanoseconds: 50_000,
            hostRepliedNanoseconds: 50_010,
            clientReceivedNanoseconds: 49_999
        )),
        "a reply that arrives before it was sent is rejected"
    )
    expect(estimator.offsetNanoseconds == 1_000, "a rejected sample cannot move the offset")
}

func testTimeSyncMessagesRoundTripThroughVersionedFrame() {
    let request = SensoriumMessage.timeSyncRequest(clientTimeNanoseconds: 1_234_567_890_123)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(request)) == request,
        "a time-sync request round-trips its client timestamp"
    )

    let reply = SensoriumMessage.timeSyncReply(
        clientTimeNanoseconds: 1_234_567_890_123,
        hostTimeNanoseconds: 9_876_543_210_987
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(reply)) == reply,
        "a time-sync reply round-trips both timestamps"
    )

    // The reply must echo the request timestamp; a host that invents one would
    // let the client compute an offset from a round trip that never happened.
    var replyWithoutEcho = try! JSONSerialization.jsonObject(
        with: Data(try! SensoriumFrameCodec.encode(reply).dropFirst(4))
    ) as! [String: Any]
    replyWithoutEcho.removeValue(forKey: "clientTimeNanoseconds")
    let payload = try! JSONSerialization.data(withJSONObject: replyWithoutEcho, options: [.sortedKeys])
    var truncated = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { truncated.append(contentsOf: $0) }
    truncated.append(payload)
    expect(
        (try? SensoriumFrameCodec.decode(truncated)) == nil,
        "a time-sync reply without the echoed client timestamp is rejected"
    )
}

func testSessionLatencyRecorderNeedsClockSyncBeforeReportingEndToEnd() {
    var recorder = SessionLatencyRecorder()

    // Client-local stages are measurable immediately; anything spanning the two
    // machines is not, and must stay absent rather than be guessed.
    expect(
        !recorder.recordFrame(
            hostCapturedAtNanoseconds: 5_000,
            receivedAtNanoseconds: 1_000,
            decodedAtNanoseconds: 1_400,
            presentedAtNanoseconds: 1_900
        ),
        "an unsynchronised recorder reports no host-relative latency"
    )
    expect(recorder.metrics.samples(for: .decode).p50 == 400, "decode is client-local and always measured")
    expect(recorder.metrics.samples(for: .present).p50 == 500, "present is client-local and always measured")
    expect(recorder.metrics.samples(for: .endToEnd).count == 0, "end-to-end stays empty until the clocks are related")
    expect(recorder.metrics.samples(for: .receive).count == 0, "transit stays empty until the clocks are related")

    // Host clock 4_000 ns ahead of the client, measured over a 200 ns round trip.
    _ = recorder.makeClockRequest(atNanoseconds: 10_000)
    expect(
        recorder.receiveClockReply(
            clientTimeNanoseconds: 10_000,
            hostTimeNanoseconds: 14_100,
            receivedAtNanoseconds: 10_200
        ),
        "a reply to an outstanding request is accepted"
    )

    // Captured at host 5_000 == client 1_000; received at client 1_300.
    expect(
        recorder.recordFrame(
            hostCapturedAtNanoseconds: 5_000,
            receivedAtNanoseconds: 1_300,
            decodedAtNanoseconds: 1_500,
            presentedAtNanoseconds: 1_800
        ),
        "a synchronised recorder measures the host-relative stages"
    )
    expect(recorder.metrics.samples(for: .receive).p50 == 300, "transit is capture-to-receive in client time")
    expect(recorder.metrics.samples(for: .endToEnd).p50 == 800, "end-to-end is capture-to-present in client time")

    // A frame whose converted capture time lands after it was presented means the
    // offset is still wrong; recording it would understate latency.
    expect(
        !recorder.recordFrame(
            hostCapturedAtNanoseconds: 99_000,
            receivedAtNanoseconds: 1_300,
            decodedAtNanoseconds: 1_500,
            presentedAtNanoseconds: 1_800
        ),
        "a capture timestamp in the client's future is refused"
    )
    expect(recorder.metrics.samples(for: .endToEnd).count == 1, "the refused frame added no end-to-end sample")
}

func testLatencyTraceWriterAppendsOneJSONLineForEachStage() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-trace-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    var recorder = SessionLatencyRecorder()
    _ = recorder.makeClockRequest(atNanoseconds: 0)
    recorder.receiveClockReply(
        clientTimeNanoseconds: 0,
        hostTimeNanoseconds: 100,
        receivedAtNanoseconds: 200
    )
    recorder.recordFrame(
        hostCapturedAtNanoseconds: 100,
        receivedAtNanoseconds: 300,
        decodedAtNanoseconds: 400,
        presentedAtNanoseconds: 600
    )

    let writer = try! LatencyTraceWriter(url: url, sessionLabel: "unit")
    try! writer.write(recorder.metrics)
    try! writer.write(recorder.metrics)

    let lines = try! String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    let stagesPerWrite = recorder.metrics.traceLines().count
    expect(stagesPerWrite == 4, "decode, present, receive and end-to-end each produced a stage line")
    expect(lines.count == stagesPerWrite * 2, "a second write appends rather than truncating")

    let decoded = lines.map { line in
        try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    }
    expect(decoded.allSatisfy { $0["session"] as? String == "unit" }, "every line carries the session label")
    expect(
        Set(decoded.compactMap { $0["stage"] as? String }) == ["decode", "present", "receive", "endToEnd"],
        "the stage names are the ones the recorder measured"
    )
    expect(
        decoded.contains { $0["stage"] as? String == "endToEnd" && ($0["p50Nanoseconds"] as? Int) == 500 },
        "the end-to-end p50 survives the round trip through the trace file"
    )

    // The writer must never invent a destination outside the caller's directory.
    expect(
        (try? LatencyTraceWriter(
            url: url.deletingLastPathComponent()
                .appendingPathComponent("no-such-sensorium-dir-\(UUID().uuidString)")
                .appendingPathComponent("trace.jsonl"),
            sessionLabel: "unit"
        )) == nil,
        "a trace path whose directory does not exist is refused"
    )
}

/// `SessionMetricStage.inputRoundTrip`: entirely client-local, unlike
/// `recordFrame`'s host-relative stages, so it needs no clock synchronization
/// first, and it appears in the trace file automatically the same way every
/// other stage with samples already does -- `traceLines()` iterates
/// `SessionMetricStage.allCases`, not a hand-kept list.
func testSessionLatencyRecorderRecordsInputRoundTripAndItAppearsInTheTrace() {
    var recorder = SessionLatencyRecorder()
    expect(
        recorder.metrics.samples(for: .inputRoundTrip).count == 0,
        "a session with no input round trips reports none"
    )
    expect(
        recorder.recordInputRoundTrip(sentAtNanoseconds: 1_000, repliedAtNanoseconds: 1_600),
        "a round trip whose reply arrives after it was sent is recorded"
    )
    expect(
        !recorder.recordInputRoundTrip(sentAtNanoseconds: 2_000, repliedAtNanoseconds: 1_900),
        "a reply timestamped before its own send is refused rather than recorded as a negative duration"
    )
    expect(
        recorder.metrics.samples(for: .inputRoundTrip).p50 == 600,
        "the recorded sample is the elapsed nanoseconds between send and reply"
    )

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-trace-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try! LatencyTraceWriter(url: url, sessionLabel: "unit")
    try! writer.write(recorder.metrics)

    let lines = try! String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    let decoded = lines.map { line in
        try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    }
    expect(
        decoded.contains { $0["stage"] as? String == "inputRoundTrip" && ($0["p50Nanoseconds"] as? Int) == 600 },
        "the trace file carries the input round trip stage automatically, with no separate opt-in"
    )
}

func testMonotonicClockOnlyMovesForward() {
    let first = MonotonicClock.nowNanoseconds()
    var last = first
    for _ in 0..<1_000 {
        let now = MonotonicClock.nowNanoseconds()
        expect(now >= last, "the monotonic clock never goes backwards")
        last = now
    }
    expect(last > first, "the monotonic clock advances over a thousand reads")
}

func testMonotonicClockSuccessiveReadsAreCloseAndNonDecreasing() {
    let first = MonotonicClock.nowNanoseconds()
    let second = MonotonicClock.nowNanoseconds()
    expect(second >= first, "a second immediate read never goes backwards")
    expect(second - first < 1_000_000_000, "two successive reads stay well under a second apart")
}

func testClockSynchronizerAcceptsOnlyRepliesToRequestsItSent() {
    var synchronizer = SessionClockSynchronizer()

    // A reply nobody asked for must not move the offset: the echoed timestamp is
    // the only thing tying a reply to a real, measured round trip.
    expect(
        !synchronizer.receiveReply(
            clientTimeNanoseconds: 777,
            hostTimeNanoseconds: 10_000,
            receivedAtNanoseconds: 900
        ),
        "an unsolicited time-sync reply is rejected"
    )
    expect(synchronizer.offsetNanoseconds == nil, "a rejected reply leaves the session unsynchronised")

    guard case let .timeSyncRequest(sent) = synchronizer.makeRequest(atNanoseconds: 1_000) else {
        print("FAIL: makeRequest produces a time-sync request")
        Foundation.exit(1)
    }
    expect(sent == 1_000, "the request carries the timestamp it was made at")
    expect(
        synchronizer.receiveReply(
            clientTimeNanoseconds: 1_000,
            hostTimeNanoseconds: 6_100,
            receivedAtNanoseconds: 1_200
        ),
        "a reply echoing an outstanding request is accepted"
    )
    expect(synchronizer.offsetNanoseconds == 5_000, "the accepted reply yields the host-minus-client offset")

    // Replays must not accumulate: the same echoed timestamp answers once.
    expect(
        !synchronizer.receiveReply(
            clientTimeNanoseconds: 1_000,
            hostTimeNanoseconds: 99_999,
            receivedAtNanoseconds: 1_201
        ),
        "a replayed reply for an already-answered request is rejected"
    )
    expect(synchronizer.offsetNanoseconds == 5_000, "a replayed reply cannot move the offset")

    // Outstanding requests are bounded so a silent host cannot grow the set.
    for tick in 0..<(SessionClockSynchronizer.maximumOutstandingRequests + 5) {
        _ = synchronizer.makeRequest(atNanoseconds: 2_000 + Int64(tick))
    }
    expect(
        synchronizer.outstandingRequestCount == SessionClockSynchronizer.maximumOutstandingRequests,
        "unanswered requests are capped instead of accumulating"
    )
    expect(
        !synchronizer.receiveReply(
            clientTimeNanoseconds: 2_000,
            hostTimeNanoseconds: 7_000,
            receivedAtNanoseconds: 2_100
        ),
        "a request evicted by the cap is no longer answerable"
    )
}

