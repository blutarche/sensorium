import Foundation
import SensoriumCore
import SensoriumHost

/// How long a still-screen refresh took to send, from the moment its frame was
/// handed to the transport until the write ended. The recorder already sees
/// both ends of every frame; these check that it reports this one frame, and
/// only this one, with the transport's own word on whether the write worked.
@MainActor
func runStillRefreshSendTimeTests() async {
    expectTheRecorderReportsOnlyTheHostRequestedFramesSend()
    await expectTheSessionReportsWhetherTheRefreshsWriteWorked()
}

private let surfaceZero = CanvasSurfaceID.allCases[0]
private let surfaceOne = CanvasSurfaceID.allCases[1]

/// Every send the recorder reported, in order.
private final class HostRequestedSendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(surface: CanvasSurfaceID, send: HostRequestedFrameSend)] = []

    var sends: [(surface: CanvasSurfaceID, send: HostRequestedFrameSend)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ surface: CanvasSurfaceID, _ send: HostRequestedFrameSend) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((surface, send))
    }
}

private func expectTheRecorderReportsOnlyTheHostRequestedFramesSend() {
    let recorder = HostMediaLatencyRecorder()
    let log = HostRequestedSendLog()
    recorder.observeHostRequestedFrameSends { log.record($0, $1) }

    // A frame the screen produced goes through every stage and is sent.
    recorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_000_000)
    recorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_100_000)
    recorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 9_000_000)
    recorder.recordSendCompleted(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 700_000_000)
    expect(log.sends.isEmpty, "a frame the screen produced is no refresh, however long it took, got \(log.sends.count) reports")

    // The refresh: encoded, handed to the transport, and written 640 ms later.
    recorder.recordHostRequestedFrame(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_000_000_000)
    recorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_001_000_000)
    recorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_060_000_000)
    recorder.recordHostRequestedFrameHandOff(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_061_000_000)
    recorder.recordSendCompleted(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_701_000_000)
    expect(
        log.sends.count == 1
            && log.sends[0].surface == surfaceZero
            && log.sends[0].send == HostRequestedFrameSend(
                nanoseconds: 640_000_000,
                completedAtNanoseconds: 2_701_000_000,
                succeeded: true
            ),
        "the refresh's send is reported once, on its surface, timed from its hand-off to the end of its write, "
            + "got \(log.sends)"
    )
    recorder.recordSendCompleted(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_800_000_000)
    expect(log.sends.count == 1, "and a second completion for the same frame reports nothing, got \(log.sends.count)")

    // A refresh on the other surface whose write failed.
    recorder.recordHostRequestedFrame(surface: surfaceOne, presentationTimeNanoseconds: 3_000, atNanoseconds: 3_000_000_000)
    recorder.recordHostRequestedFrameHandOff(surface: surfaceOne, presentationTimeNanoseconds: 3_000, atNanoseconds: 3_010_000_000)
    recorder.recordSendCompleted(
        surface: surfaceOne,
        presentationTimeNanoseconds: 3_000,
        atNanoseconds: 3_040_000_000,
        succeeded: false
    )
    expect(
        log.sends.count == 2
            && log.sends[1].surface == surfaceOne
            && log.sends[1].send == HostRequestedFrameSend(
                nanoseconds: 30_000_000,
                completedAtNanoseconds: 3_040_000_000,
                succeeded: false
            ),
        "a write that failed is reported as one, on the surface it belonged to, got \(log.sends)"
    )
    print("PASS: the recorder reports how long a still-screen refresh took to send, and nothing for any other frame")
}

@MainActor
private func expectTheSessionReportsWhetherTheRefreshsWriteWorked() async {
    let recorder = HostMediaLatencyRecorder()
    let log = HostRequestedSendLog()
    recorder.observeHostRequestedFrameSends { log.record($0, $1) }
    let channel = FakeHostByteChannel(scriptedMessages: [])
    let session = HostNetworkSession(
        connection: channel,
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        ),
        latencyRecorder: recorder
    )
    session.start()

    func refreshFrame(_ sequence: UInt64) -> EncodedVideoFramePacket {
        EncodedVideoFramePacket(
            sequence: sequence,
            presentationTimeNanoseconds: sequence * 1_000_000,
            isKeyFrame: true,
            codecConfiguration: Data([1, 2, 3]),
            payload: Data(repeating: UInt8(sequence & 0xFF), count: 64)
        )
    }

    recorder.recordHostRequestedFrameHandOff(
        surface: surfaceZero,
        presentationTimeNanoseconds: 1_000_000,
        atNanoseconds: MonotonicClock.nowNanoseconds()
    )
    expect(session.send(refreshFrame(1), surface: surfaceZero, priority: .normal), "the refresh is taken")
    expect(
        await waitUntil(timeoutSeconds: 2) { log.sends.count == 1 },
        "the end of its write is reported, got \(log.sends.count) reports"
    )
    expect(log.sends[0].send.succeeded, "as a write that worked, got \(log.sends)")

    channel.sendBytesError = HostNetworkSessionError.closed
    recorder.recordHostRequestedFrameHandOff(
        surface: surfaceZero,
        presentationTimeNanoseconds: 2_000_000,
        atNanoseconds: MonotonicClock.nowNanoseconds()
    )
    expect(session.send(refreshFrame(2), surface: surfaceZero, priority: .normal), "the next refresh is taken")
    expect(
        await waitUntil(timeoutSeconds: 2) { log.sends.count == 2 },
        "the end of its write is reported too, got \(log.sends.count) reports"
    )
    expect(!log.sends[1].send.succeeded, "and a write that failed is reported as one, got \(log.sends)")
    channel.cancel()
    print("PASS: the transport tells the recorder whether a still-screen refresh's write worked")
}
