import Dispatch
import Foundation
import SensoriumClient
import SensoriumCore

/// A viewer whose decode queue gives a group of frames up asks the host for a
/// key frame at that moment, once per group, for the surface that lost it. It
/// never asks before the surface's first key frame, and stopping the queue is
/// not a reason to ask.
@MainActor
func testKeyFrameRequestTests() async {
    testDecodeQueueReportsEachGroupGivenUpOnce()
    testVideoSinkCarriesItsHandlerAcrossDecodeQueues()
    await testRunnerAsksForAKeyFrameOnTheSurfaceThatGaveAGroupUp()
    await testConnectDeclaresKeyFrameRecoveryRightAfterTheHello()
    print("PASS: a viewer asks for a key frame once per group its decode queue gives up, on the surface that gave it up")
}

private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func fire() {
        lock.lock()
        fired += 1
        lock.unlock()
    }
}

private func keyFrame(_ sequence: UInt64) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 1_000,
        isKeyFrame: true,
        payload: Data([UInt8(truncatingIfNeeded: sequence)])
    )
}

private func delta(_ sequence: UInt64) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 1_000,
        isKeyFrame: false,
        payload: Data([UInt8(truncatingIfNeeded: sequence)])
    )
}

/// A decode queue whose decodes never run until `resume()`, so every packet
/// submitted waits in its backlog exactly as it would behind a stalled
/// decoder. Resumed before release: a suspended dispatch queue must not be
/// freed.
private func stalledDecodeQueue(maximumPending: Int) -> (VideoDecodeQueue, DispatchQueue) {
    let stalled = DispatchQueue(label: "key-frame-request-tests.stalled-decode")
    stalled.suspend()
    let queue = VideoDecodeQueue(maximumPending: maximumPending, queue: stalled) { _ in }
    return (queue, stalled)
}

private func testDecodeQueueReportsEachGroupGivenUpOnce() {
    let (queue, stalled) = stalledDecodeQueue(maximumPending: 3)
    let givenUp = FireCounter()
    queue.setGroupGivenUpHandler { givenUp.fire() }

    for sequence in UInt64(1)...UInt64(5) {
        queue.submit(delta(sequence))
    }
    expect(givenUp.count == 0, "nothing is asked for before the surface's first key frame, got \(givenUp.count)")

    queue.submit(keyFrame(6))
    queue.submit(delta(7))
    queue.submit(delta(8))
    expect(givenUp.count == 0, "a backlog within its bound gives nothing up, got \(givenUp.count)")
    queue.submit(delta(9))
    expect(queue.isAwaitingKeyFrame && givenUp.count == 1, "the delta past the bound gives the group up and asks once, got \(givenUp.count)")
    for sequence in UInt64(10)...UInt64(20) {
        queue.submit(delta(sequence))
    }
    expect(givenUp.count == 1, "the deltas that follow are part of the same wait and ask for nothing more, got \(givenUp.count)")

    queue.submit(keyFrame(21))
    expect(!queue.isAwaitingKeyFrame && givenUp.count == 1, "the key frame ends the wait without asking")
    for sequence in UInt64(22)...UInt64(25) {
        queue.submit(delta(sequence))
    }
    expect(givenUp.count == 2, "a second group given up asks a second time, got \(givenUp.count)")

    queue.stop()
    queue.submit(keyFrame(26))
    for sequence in UInt64(27)...UInt64(40) {
        queue.submit(delta(sequence))
    }
    expect(givenUp.count == 2, "stopping the queue, and anything handed to it afterwards, asks for nothing, got \(givenUp.count)")
    stalled.resume()

    let (resetQueue, resetStalled) = stalledDecodeQueue(maximumPending: 3)
    let resetGivenUp = FireCounter()
    resetQueue.setGroupGivenUpHandler { resetGivenUp.fire() }
    resetQueue.submit(keyFrame(1))
    resetQueue.submit(delta(2))
    resetQueue.stop()
    expect(resetGivenUp.count == 0, "a queue stopped with frames still waiting gave nothing up, got \(resetGivenUp.count)")
    resetStalled.resume()
}

private func testVideoSinkCarriesItsHandlerAcrossDecodeQueues() {
    let sink = SurfaceVideoSink()
    let asked = FireCounter()

    let (first, firstStalled) = stalledDecodeQueue(maximumPending: 1)
    sink.attach(first)
    sink.setKeyFrameNeededHandler { asked.fire() }
    try? sink.receive(keyFrame(1), receivedAtNanoseconds: 1)
    try? sink.receive(delta(2), receivedAtNanoseconds: 2)
    expect(asked.count == 1, "a handler set after the queue was attached still hears its group given up, got \(asked.count)")
    first.stop()
    firstStalled.resume()

    let (second, secondStalled) = stalledDecodeQueue(maximumPending: 1)
    sink.attach(second)
    try? sink.receive(keyFrame(3), receivedAtNanoseconds: 3)
    try? sink.receive(delta(4), receivedAtNanoseconds: 4)
    expect(asked.count == 2, "and so does the next decode session's queue, got \(asked.count)")
    second.stop()
    secondStalled.resume()
}

@MainActor
private func testRunnerAsksForAKeyFrameOnTheSurfaceThatGaveAGroupUp() async {
    let primary = RecordingSurfaceWindow(surfaceID: 0)
    let secondary = RecordingSurfaceWindow(surfaceID: 1)
    let connection = ScriptedControlConnection(responses: [])
    let runner = ClientSessionRunner(
        connection: connection,
        session: ClientSessionController(transport: FakeClientTransport()),
        window: primary
    )

    let (primaryQueue, primaryStalled) = stalledDecodeQueue(maximumPending: 1)
    primary.videoSink.attach(primaryQueue)
    try? primary.videoSink.receive(keyFrame(1), receivedAtNanoseconds: 1)
    try? primary.videoSink.receive(delta(2), receivedAtNanoseconds: 2)
    try? primary.videoSink.receive(delta(3), receivedAtNanoseconds: 3)
    expect(
        connection.enqueuedPackets == [.control(.keyFrameRequest(surfaceID: 0))],
        "a group given up on the first surface asks for its key frame once, got \(connection.enqueuedPackets)"
    )

    // The second display opens live, the way the Displays menu opens it.
    try! await runner.attachSecondDisplay(secondary)
    let (secondaryQueue, secondaryStalled) = stalledDecodeQueue(maximumPending: 1)
    secondary.videoSink.attach(secondaryQueue)
    try? secondary.videoSink.receive(keyFrame(1), receivedAtNanoseconds: 1)
    try? secondary.videoSink.receive(delta(2), receivedAtNanoseconds: 2)
    expect(
        connection.enqueuedPackets == [
            .control(.keyFrameRequest(surfaceID: 0)),
            .control(.keyFrameRequest(surfaceID: 1))
        ],
        "and one given up on the second surface names the second surface, got \(connection.enqueuedPackets)"
    )

    primaryQueue.stop()
    secondaryQueue.stop()
    primaryStalled.resume()
    secondaryStalled.resume()
}

/// Every authenticated connect says, once, that this viewer asks for its key
/// frames, whatever decoder it has: right after the hello and any decoder
/// preference, before the target is requested.
private func testConnectDeclaresKeyFrameRecoveryRightAfterTheHello() async {
    func isDeclaration(_ message: SensoriumMessage) -> Bool {
        if case .viewerKeyFrameRecovery = message { return true } else { return false }
    }
    let identity = try! DeviceIdentity.generate()
    for preference in [nil, ViewerH264Profile.constrainedBaseline] {
        let transport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed"),
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        _ = try! await ClientSessionController(
            transport: transport,
            identity: identity,
            decoderPreference: preference
        ).connect(deviceName: "Laptop")
        let sent = await transport.sent
        let expectedIndex = preference == nil ? 1 : 2
        expect(
            sent.filter(isDeclaration).count == 1
                && sent.firstIndex(where: isDeclaration) == expectedIndex,
            "a viewer with preference \(String(describing: preference)) declares once, right after its hello "
                + "and any preference, got \(sent)"
        )
    }

    let unauthenticated = ScriptedClientTransport(responses: [
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ])
    _ = try! await ClientSessionController(transport: unauthenticated).connect(deviceName: "Laptop")
    expect(
        await !unauthenticated.sent.contains(where: isDeclaration),
        "an unauthenticated connect declares nothing, which the host would refuse"
    )
}
