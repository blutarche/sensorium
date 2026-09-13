import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation

/// A presenter that holds the frame it was handed until it is released, so
/// frames can be put in front of a viewer that is still drawing the last one.
actor GatedFramePresenter {
    private(set) var presentedIDs: [Int64] = []
    private var isReleased = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func present(_ id: Int64) async {
        presentedIDs.append(id)
        resumeWaiters()
        guard !isReleased else { return }
        await withCheckedContinuation { held = $0 }
    }

    func release() {
        isReleased = true
        held?.resume()
        held = nil
    }

    /// Waits for `count` presentations, or gives up after `timeoutSeconds` so
    /// a coalescer that never hands over what it was given fails the
    /// assertion that follows instead of hanging the whole suite.
    func wait(untilPresented count: Int, timeoutSeconds: Double = 5) async {
        guard presentedIDs.count < count else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            await self?.stopWaiting()
        }
        await withCheckedContinuation { waiters.append((count, $0)) }
        deadline.cancel()
    }

    private func stopWaiting() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume()
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { presentedIDs.count >= $0.count }
        waiters.removeAll { presentedIDs.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

/// Identifies a decoded frame by its host capture time, which is the one field
/// a test can set and read back through `DecodedFrame`.
private func makeIdentifiedFrame(_ id: Int64) -> DecodedFrame {
    DecodedFrame(
        pixelBuffer: makeTestPixelBuffer(),
        timing: FrameTiming(
            hostCapturedAtNanoseconds: id,
            receivedAtNanoseconds: id + 1,
            decodedAtNanoseconds: id + 2
        )
    )
}

private func makeKeyFrame(sequence: UInt64) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 1_000,
        isKeyFrame: true,
        payload: Data([UInt8(truncatingIfNeeded: sequence)])
    )
}

private func makeDeltaFrame(sequence: UInt64) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 1_000,
        isKeyFrame: false,
        payload: Data([UInt8(truncatingIfNeeded: sequence)])
    )
}

@MainActor
func testViewerFrameCoalescingTests() async {
    // Frames arriving while one is being handed over are kept in order, not
    // collapsed onto the newest. Which of them belongs on which refresh is the
    // presenter's decision, and it cannot make it about frames it never saw.
    let presenter = GatedFramePresenter()
    let presentDrops = ViewerFrameDropCounter()
    let coalescer = DecodedFrameCoalescer(drops: presentDrops) { frame in
        await presenter.present(frame.timing?.hostCapturedAtNanoseconds ?? -1)
    }
    coalescer.submit(makeIdentifiedFrame(1))
    await presenter.wait(untilPresented: 1)
    for id in Int64(2)...Int64(8) {
        coalescer.submit(makeIdentifiedFrame(id))
    }
    await presenter.release()
    await presenter.wait(untilPresented: 8)
    let presentedIDs = await presenter.presentedIDs
    expect(
        presentedIDs == Array(Int64(1)...Int64(8)),
        "a burst arriving while the presenter is busy reaches it whole and in order, got \(presentedIDs)"
    )
    expect(
        presentDrops.droppedBeforePresent == 0,
        "and none of it is given up, got \(presentDrops.droppedBeforePresent)"
    )
    expect(
        presentDrops.droppedBeforeDecode == 0,
        "nor is any of it counted as a packet the decoder never saw"
    )

    // What is bounded is memory. A presenter that has stopped taking frames
    // altogether leaves the oldest behind rather than growing a queue without
    // end, and every one of those is counted.
    let stuckPresenter = GatedFramePresenter()
    let floodDrops = ViewerFrameDropCounter()
    let flooded = DecodedFrameCoalescer(drops: floodDrops) { frame in
        await stuckPresenter.present(frame.timing?.hostCapturedAtNanoseconds ?? -1)
    }
    let flood = Int64(DecodedFrameCoalescer.maximumPending) + 12
    flooded.submit(makeIdentifiedFrame(1))
    await stuckPresenter.wait(untilPresented: 1)
    for id in Int64(2)...flood {
        flooded.submit(makeIdentifiedFrame(id))
    }
    await stuckPresenter.release()
    await stuckPresenter.wait(untilPresented: DecodedFrameCoalescer.maximumPending + 1)
    let floodedIDs = await stuckPresenter.presentedIDs
    expect(
        floodedIDs.first == 1 && floodedIDs.last == flood,
        "the frame already in flight is still shown, and the newest frame of the flood is still reached, got \(floodedIDs)"
    )
    expect(
        floodedIDs.count == DecodedFrameCoalescer.maximumPending + 1,
        "only the bound's worth of frames is held behind it, got \(floodedIDs.count)"
    )
    expect(
        floodDrops.droppedBeforePresent == Int(flood) - floodedIDs.count,
        "and every frame left behind is counted, got \(floodDrops.droppedBeforePresent) for \(floodedIDs.count) shown"
    )

    // An encoded frame cannot be given up the way a decoded one can: every
    // frame up to the next key frame is a difference from it.
    let millisecond: Int64 = 1_000_000
    var backlog = UndecodedFrameBacklog()
    expect(
        backlog.admit(makeDeltaFrame(sequence: 1)) == 0,
        "a first packet costs nothing"
    )
    expect(
        backlog.admit(makeDeltaFrame(sequence: 2)) == 0,
        "nor does a second"
    )
    expect(
        backlog.admit(makeKeyFrame(sequence: 3)) == 2,
        "a key frame makes both packets waiting behind it unnecessary, because it is a whole picture on its own"
    )
    expect(
        backlog.takeNext()?.sequence == 3 && backlog.count == 0,
        "and the key frame itself is what is left to decode, never one of the deltas it superseded"
    )
    expect(!backlog.isAwaitingKeyFrame, "a key frame in hand is not a key frame being waited for")

    // Several packets waiting is what every viewer sees the moment it was busy
    // for a frame or two. Each costs a few milliseconds to decode, so keeping
    // them costs far less than holding one picture until the next key frame.
    var bursting = UndecodedFrameBacklog()
    expect(
        bursting.admit(makeKeyFrame(sequence: 10)) == 0,
        "the key frame that opens a group is admitted"
    )
    for sequence in UInt64(11)...UInt64(20) {
        let arrival = Int64(sequence - 10) * millisecond
        expect(
            bursting.admit(makeDeltaFrame(sequence: sequence)) == 0,
            "a burst of packets arriving while one decode runs is kept, not given up, got a drop at \(sequence)"
        )
    }
    expect(
        bursting.count == 11 && !bursting.isAwaitingKeyFrame,
        "eleven packets that have each waited a few milliseconds are all still worth decoding, got \(bursting.count)"
    )

    // A stall of any length is caught up on rather than given up. Hardware
    // decode costs a few milliseconds a frame, so working through thirty held
    // packets is quicker than holding one picture until the next key frame.
    var stalled = UndecodedFrameBacklog()
    expect(
        stalled.admit(makeKeyFrame(sequence: 30)) == 0,
        "the key frame that opens a group is admitted"
    )
    for sequence in UInt64(31)...UInt64(60) {
        let arrival = Int64(sequence - 30) * 16 * millisecond
        expect(
            stalled.admit(makeDeltaFrame(sequence: sequence)) == 0,
            "a packet admitted half a second after the oldest one arrived is still worth decoding, got a drop at \(sequence)"
        )
    }
    expect(
        stalled.count == 31 && !stalled.isAwaitingKeyFrame,
        "a viewer that was busy for half a second holds every packet it received and waits for no key frame, got \(stalled.count)"
    )
    var caughtUp: [UInt64] = []
    while let packet = stalled.takeNext() {
        caughtUp.append(packet.sequence)
    }
    expect(
        caughtUp == Array(UInt64(30)...UInt64(60)),
        "and they are decoded in the order they arrived, got \(caughtUp)"
    )

    // The count cap is memory and nothing else: it is the one thing that still
    // costs a group, so a viewer nobody is draining never grows a queue
    // without end.
    var capped = UndecodedFrameBacklog(maximumPending: 4)
    expect(
        capped.admit(makeKeyFrame(sequence: 40)) == 0,
        "the key frame that opens a group is admitted"
    )
    for sequence in UInt64(41)...UInt64(43) {
        expect(
            capped.admit(makeDeltaFrame(sequence: sequence)) == 0,
            "packets up to the cap are kept, got a drop at \(sequence)"
        )
    }
    expect(
        capped.admit(makeDeltaFrame(sequence: 44)) == 4,
        "the packet past the cap costs the rest of its group, so a viewer nobody is draining never grows one without end"
    )
    expect(
        capped.takeNext()?.sequence == 40 && capped.isAwaitingKeyFrame,
        "the kept key frame and the wait for the next one are the same either way"
    )

    checkDecodingHappensOffTheReadPath()
    await checkVideoReachesTheDecoderWhileTheMainActorIsBusy()

    // What the viewer gave up reaches the two readers that act on it: the
    // person reading the session summary, and the host's own fidelity ladder.
    let monitor = SessionLatencyMonitor()
    guard case .timeSyncRequest = await monitor.makeClockRequest(atNanoseconds: 1_000) else {
        print("FAIL: the monitor produces a time-sync request")
        Foundation.exit(1)
    }
    _ = await monitor.receiveClockReply(
        clientTimeNanoseconds: 1_000,
        hostTimeNanoseconds: 5_100,
        receivedAtNanoseconds: 1_200
    )
    _ = await monitor.recordPresentedFrame(
        timing: FrameTiming(
            hostCapturedAtNanoseconds: 5_000,
            receivedAtNanoseconds: 1_300,
            decodedAtNanoseconds: 1_500
        ),
        presentedAtNanoseconds: 1_900
    )
    guard let quietSummary = await monitor.summaryLine() else {
        print("FAIL: a measured session produces a summary line")
        Foundation.exit(1)
    }
    expect(
        !quietSummary.contains("dropped at viewer"),
        "a viewer that showed every frame it received says nothing about dropping any: \(quietSummary)"
    )
    await monitor.setDroppedAtViewerCount(17)
    guard let droppingSummary = await monitor.summaryLine() else {
        print("FAIL: a measured session still produces a summary line once frames have been dropped")
        Foundation.exit(1)
    }
    expect(
        droppingSummary.contains("dropped at viewer 17"),
        "the session summary names how many frames this viewer gave up, got: \(droppingSummary)"
    )
    expect(
        droppingSummary.contains("end-to-end p50"),
        "and appends it rather than replacing what was already there: \(droppingSummary)"
    )

    // The host learns about it through the reading it already receives: a
    // viewer presenting less than it decoded is what names the viewer as the
    // stage that cannot keep up, so a chronically slow one is given a lower
    // rung instead of being left to discard half of every second forever.
    var builder = ViewerTelemetryBuilder()
    _ = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: ClientStreamReading(pixelWidth: 1920, pixelHeight: 1200, bitsPerSecond: nil, decodedFrameCount: 0),
        presentedFrameCount: 0,
        atNanoseconds: 0
    )
    let reading = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: ClientStreamReading(
            pixelWidth: 1920,
            pixelHeight: 1200,
            bitsPerSecond: 8_000_000,
            decodedFrameCount: 60
        ),
        presentedFrameCount: 24,
        atNanoseconds: 1_000_000_000
    )
    expect(
        reading.decodedFramesPerSecond == 60 && reading.presentedFramesPerSecond == 24,
        "the reading the host receives carries both counts, so the gap between them is visible"
    )
    expect(
        StreamFidelityPressure.viewerEvidencePressure(
            StreamFidelityViewerObservation(
                decodeP95Nanoseconds: nil,
                presentedFramesPerSecond: reading.presentedFramesPerSecond,
                decodedFramesPerSecond: reading.decodedFramesPerSecond,
                receivedBitsPerSecond: reading.receivedBitsPerSecond
            ),
            producedBitsPerSecond: 8_000_000,
            sentBitsPerSecond: 8_000_000,
            appliedFramesPerSecond: 60
        ) == .viewer,
        "and a viewer showing 24 of the 60 frames it decoded is named as the stage that cannot keep up"
    )

    print("viewer frame coalescing tests passed")
}

/// Decoding is not on the read path: while a decode is running, whoever handed
/// the packet over has already gone back to reading the socket. Otherwise the
/// frames still arriving pile up in the transport's own buffers, where nothing
/// can skip them and nothing counts them.
///
/// Synchronous, and called from the async test above: it drives the decode
/// queue with semaphores and flushes it with `sync`, which is what makes every
/// assertion here deterministic rather than a wait for a deadline.
private func checkDecodingHappensOffTheReadPath() {
    let decodeQueue = DispatchQueue(label: "sensorium.test.viewer-decode")
    let decodeDrops = ViewerFrameDropCounter()
    let decodeGate = DispatchSemaphore(value: 0)
    let firstDecodeStarted = DispatchSemaphore(value: 0)
    let decodedSequences = DecodedSequenceRecorder()
    let queue = VideoDecodeQueue(
        drops: decodeDrops,
        queue: decodeQueue
    ) { packet in
        if packet.sequence == 20 {
            firstDecodeStarted.signal()
            decodeGate.wait()
        }
        decodedSequences.record(packet.sequence)
    }
    queue.submit(makeKeyFrame(sequence: 20))
    expect(
        firstDecodeStarted.wait(timeout: .now() + 5) == .success,
        "a submitted packet is decoded without the submitting thread being asked to wait for it"
    )
    expect(
        decodedSequences.sequences.isEmpty,
        "and submit returned while that decode was still running, got \(decodedSequences.sequences)"
    )
    for sequence in UInt64(21)...UInt64(23) {
        queue.submit(makeDeltaFrame(sequence: sequence))
    }
    decodeGate.signal()
    decodeQueue.sync {}
    expect(
        decodedSequences.sequences == [20, 21, 22, 23],
        "packets that arrived while one decode was stuck are decoded, not given up: a few milliseconds each is far"
            + " less than holding the picture until the next key frame, got \(decodedSequences.sequences)"
    )
    expect(
        decodeDrops.droppedBeforeDecode == 0,
        "so nothing is counted as given up, got \(decodeDrops.droppedBeforeDecode)"
    )
    expect(!queue.isAwaitingKeyFrame, "and the viewer is not waiting for a key frame it does not need")

    // A packet that waited out a long stall is decoded too. The picture it
    // builds is what every later frame in its group is a difference from, and
    // catching up on it costs one hardware decode.
    let secondDecodeStarted = DispatchSemaphore(value: 0)
    let secondGate = DispatchSemaphore(value: 0)
    let stalled = VideoDecodeQueue(
        drops: decodeDrops,
        queue: decodeQueue
    ) { packet in
        if packet.sequence == 30 {
            secondDecodeStarted.signal()
            secondGate.wait()
        }
        decodedSequences.record(packet.sequence)
    }
    stalled.submit(makeKeyFrame(sequence: 30))
    expect(
        secondDecodeStarted.wait(timeout: .now() + 5) == .success,
        "the key frame that opens the group is decoded"
    )
    stalled.submit(makeDeltaFrame(sequence: 31))
    expect(
        decodeDrops.droppedBeforeDecode == 0,
        "a packet that came off the socket half a second ago is kept, got \(decodeDrops.droppedBeforeDecode) given up"
    )
    expect(!stalled.isAwaitingKeyFrame, "and no key frame is waited for")
    stalled.submit(makeDeltaFrame(sequence: 32))
    secondGate.signal()
    decodeQueue.sync {}
    expect(
        decodedSequences.sequences == [20, 21, 22, 23, 30, 31, 32],
        "every packet held during the stall is decoded in the order it arrived, got \(decodedSequences.sequences)"
    )
    stalled.stop()
    stalled.submit(makeKeyFrame(sequence: 33))
    decodeQueue.sync {}
    expect(
        decodedSequences.sequences == [20, 21, 22, 23, 30, 31, 32],
        "a stopped queue decodes nothing further, got \(decodedSequences.sequences)"
    )

    // A decode failure can no longer be thrown at whoever handed the packet
    // over, so it is held for the next receive to throw -- the same path that
    // ended the session before decoding moved off the read path.
    let failingQueue = DispatchQueue(label: "sensorium.test.failing-decode")
    let failing = VideoDecodeQueue(queue: failingQueue) { _ in
        throw VideoToolboxDecoderError.missingCodecConfiguration
    }
    failing.submit(makeKeyFrame(sequence: 30))
    failingQueue.sync {}
    expect(
        failing.takeFailure() as? VideoToolboxDecoderError == .missingCodecConfiguration,
        "a decode that failed off the read path is held for the next receive to throw"
    )
    expect(
        failing.takeFailure() == nil,
        "and it is reported once, not on every packet that follows it"
    )
}

/// A viewer draws, lays out its chrome and handles input on the main actor. A
/// video packet that had to wait for all of that would arrive with the packets
/// behind it in one burst, which is what makes a viewer give up a whole group
/// of frames under motion. So the route from the socket to the decoder must
/// contain nothing that waits on the main actor, and the only way to check that
/// is to hold the main actor and watch a packet arrive anyway.
@MainActor
private func checkVideoReachesTheDecoderWhileTheMainActorIsBusy() async {
    let router = SurfaceFrameRouter()
    let window = MainActorCanvasWindow(surfaceID: 0)
    let sink = window.videoSink
    router.setWindow(window, atSurfaceID: 0)
    router.setVideoSink(sink, atSurfaceID: 0)
    let dispatch = ReceivedVideoDispatch(statistics: ClientStreamStatistics(), router: router)

    let mainActorHeld = DispatchSemaphore(value: 0)
    let releaseMainActor = DispatchSemaphore(value: 0)
    Task { @MainActor in
        mainActorHeld.signal()
        blockUntilSignalled(releaseMainActor)
    }

    // The dispatch runs in a task of its own so this check is bounded either
    // way: a route that does wait on the main actor times out here rather than
    // holding the whole runner.
    let arrived = await Task.detached { () -> Bool in
        blockUntilSignalled(mainActorHeld)
        let dispatched = Task.detached {
            try? await dispatch.dispatch(
                .video(makeKeyFrame(sequence: 40)),
                receivedAtNanoseconds: 1_000
            )
        }
        let arrived = sink.waitForPacket(timeoutSeconds: 5)
        releaseMainActor.signal()
        await dispatched.value
        return arrived
    }.value

    expect(
        arrived,
        "a video packet reaches the decoder while the main actor is busy, so a slow draw never turns into a burst of packets"
    )
    expect(
        sink.receivedSequences == [40],
        "and it is the packet that was sent, exactly once, got \(sink.receivedSequences)"
    )
    expect(
        window.receivedByTheWindow.isEmpty,
        "the window itself is never handed a frame while a sink is registered, got \(window.receivedByTheWindow)"
    )
}

/// Blocks the calling thread until the semaphore is signalled. Synchronous on
/// purpose: holding the main actor is the whole point here, which is the one
/// thing an async wait would not do.
private func blockUntilSignalled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// A `CanvasSurfaceWindow` isolated to the main actor exactly as the production
/// window is, with the same video entry point beside it. What the window itself
/// is handed is recorded separately from what the sink is handed, so a test can
/// tell the two routes apart.
@MainActor
final class MainActorCanvasWindow: @MainActor CanvasSurfaceWindow {
    nonisolated let surfaceID: UInt32
    nonisolated let videoSink = RecordingVideoSink()
    private var windowReceived: [UInt64] = []

    init(surfaceID: UInt32) {
        self.surfaceID = surfaceID
    }

    var receivedByTheWindow: [UInt64] { windowReceived }

    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        windowReceived.append(packet.sequence)
    }

    func stopDecoding() {}

    func updateSessionHUD(_ snapshot: SessionHUDSnapshot) {}
}

/// Records the packets a surface's decoder was handed, from whichever thread
/// handed them over, and lets a waiter block until one arrives.
final class RecordingVideoSink: SurfaceVideoReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [UInt64] = []
    private let arrival = DispatchSemaphore(value: 0)

    var receivedSequences: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return sequences
    }

    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        lock.lock()
        sequences.append(packet.sequence)
        lock.unlock()
        arrival.signal()
    }

    func waitForPacket(timeoutSeconds: Int) -> Bool {
        arrival.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success
    }
}

/// Records what a decode closure was handed, from whichever thread the decode
/// queue ran it on.
final class DecodedSequenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []

    var sequences: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ sequence: UInt64) {
        lock.lock()
        recorded.append(sequence)
        lock.unlock()
    }
}
