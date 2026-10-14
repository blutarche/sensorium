import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// What the host does instead of letting the viewer decode a delta built on a
/// picture it never received: captures wait before the encoder while a
/// surface's send slot is full, and a surface that still loses a delta sends
/// nothing but a key frame until one arrives, which it asks its encoder for.
@MainActor
func runVideoSendRecoveryTests() async {
    expectDeltaBehindAWaitingDeltaGatesLaterDeltasUntilAKeyFrame()
    expectRefusedDeltaGatesLaterDeltasUntilANewKeyFrame()
    expectFailedWriteGatesLaterDeltasUntilAKeyFrame()
    expectRecoveryRequestsArePaced()
    expectCapturesWaitBeforeTheEncoderWhileTheSendSlotIsFull()
    expectAHeldCaptureNeverGoesInAfterANewerOne()
    await expectSendQueueDropAsksForOneKeyFrameAndSendsNoDeltaAfterIt()
    await expectFailedWriteAsksForAKeyFrameAndSendsNoDeltaAfterIt()
    await expectHeldKeyFrameRequestIsServedWhenTheSecondIsUp()
    await expectCanvasMediaCarriesTheSessionsSendFeedbackIntoEveryPipeline()
    await expectEachRecoveryRequestIsLoggedOnce()
    await expectCapturesHeldForTheLinkReadAsLinkPressure()
    await expectEachKeyFrameWriteIsTimedForItsSurface()
}

private let surfaceZero = CanvasSurfaceID.allCases[0]
private let surfaceOne = CanvasSurfaceID.allCases[1]

/// Records what a surface's encode gate would be told, in order.
private final class RecordingFeedbackListener: VideoSendFeedbackListener, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sendWaitingSlotEmptied() {
        lock.lock()
        defer { lock.unlock() }
        recorded.append("slot emptied")
    }

    func keyFrameNeeded() {
        lock.lock()
        defer { lock.unlock() }
        recorded.append("key frame")
    }
}

/// Every key frame a session reported asking for, in order.
private final class RecoveryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ surface: CanvasSurfaceID, _ cause: KeyFrameRecoveryCause) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append("surface \(surface.wireValue): \(cause.rawValue)")
    }
}

/// A session on a fake channel whose surface 0 encode gate is `listener`.
@MainActor
private func makeRecoverySession(
    channel: FakeHostByteChannel,
    listener: RecordingFeedbackListener,
    keyFrameRecoveryInterval: Duration = .seconds(1)
) -> (HostNetworkSession, VideoSendFeedback, RecoveryRequestRecorder) {
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        keyConfinement: .unconfined
    )
    let feedback = VideoSendFeedback()
    feedback.attach(listener, on: surfaceZero)
    let session = HostNetworkSession(
        connection: channel,
        controller: controller,
        sendFeedback: feedback,
        keyFrameRecoveryInterval: keyFrameRecoveryInterval
    )
    let requests = RecoveryRequestRecorder()
    // Through the protocol, as the coordinator registers it, so the session's
    // own method is proven to be the one the coordinator reaches.
    let sink: any CanvasVideoSending = session
    sink.observeKeyFrameRecoveryRequests { surface, cause in requests.record(surface, cause) }
    return (session, feedback, requests)
}

private func sentVideoSequences(_ channel: FakeHostByteChannel) -> [UInt64] {
    channel.sentPackets.compactMap { packet in
        switch packet {
        case let .video(frame), let .videoForSurface(_, frame):
            return frame.sequence
        default:
            return nil
        }
    }
}

private func recoveryFrame(_ sequence: UInt64, keyFrame: Bool = false) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 1_000_000,
        isKeyFrame: keyFrame,
        codecConfiguration: keyFrame ? Data([1, 2, 3]) : nil,
        payload: Data([UInt8(sequence & 0xFF)])
    )
}

/// The waiting delta refers only to frames already sent, so it still decodes
/// and keeps its slot. The newer delta is the one lost, and every delta after
/// it is built on it.
private func expectDeltaBehindAWaitingDeltaGatesLaterDeltasUntilAKeyFrame() {
    var queues = SurfaceVideoSendQueues()
    expect(queues.enqueue(recoveryFrame(1, keyFrame: true), surface: surfaceZero) == .sendNow, "the key frame takes the idle wire")
    expect(queues.enqueue(recoveryFrame(2), surface: surfaceZero) == .queued, "a delta waits behind it")
    expect(
        queues.enqueue(recoveryFrame(3), surface: surfaceZero) == .droppedIncoming,
        "a newer delta does not displace the waiting delta: it is the one dropped"
    )
    expect(queues.hasWaitingFrame(surfaceZero), "the waiting delta keeps its slot")
    expect(queues.isAwaitingKeyFrame(surfaceZero), "the surface now waits for a key frame")
    expect(queues.droppedFrameCount == 1, "the dropped delta counts as one frame dropped to keep up, as before")
    expect(
        queues.enqueue(recoveryFrame(4), surface: surfaceZero) == .awaitingKeyFrame,
        "a later delta is refused while the surface waits for a key frame"
    )
    expect(queues.droppedFrameCount == 1, "a delta refused for want of a key frame is not a frame dropped to keep up")
    expect(
        queues.completeSend()?.frame.sequence == 2,
        "the waiting delta is the next frame out: it is built only on frames already sent"
    )
    expect(
        queues.enqueue(recoveryFrame(5), surface: surfaceZero) == .awaitingKeyFrame,
        "sending it does not end the wait"
    )
    expect(queues.completeSend() == nil, "and nothing of the dropped delta's line follows it")
    expect(
        queues.enqueue(recoveryFrame(6), surface: surfaceZero) == .awaitingKeyFrame,
        "an idle wire does not let a delta through either"
    )
    expect(queues.enqueue(recoveryFrame(7, keyFrame: true), surface: surfaceZero) == .sendNow, "a key frame goes out")
    expect(!queues.isAwaitingKeyFrame(surfaceZero), "and ends the wait")
    expect(queues.enqueue(recoveryFrame(8), surface: surfaceZero) == .queued, "so the deltas after it are taken again")
    print("PASS: a delta arriving behind a waiting delta is dropped, the waiting one still goes out, and the surface waits for a key frame")
}

/// A delta refused because a key frame is waiting was encoded after that key
/// frame, so the waiting key frame still goes out but cannot end the wait:
/// the deltas behind it are built on the one that was refused.
private func expectRefusedDeltaGatesLaterDeltasUntilANewKeyFrame() {
    var queues = SurfaceVideoSendQueues()
    _ = queues.enqueue(recoveryFrame(1, keyFrame: true), surface: surfaceZero)
    expect(queues.enqueue(recoveryFrame(2, keyFrame: true), surface: surfaceZero) == .queued, "a key frame waits")
    expect(
        queues.enqueue(recoveryFrame(3), surface: surfaceZero) == .droppedIncoming,
        "a delta never displaces a waiting key frame"
    )
    expect(queues.isAwaitingKeyFrame(surfaceZero), "the refused delta leaves the surface waiting for a key frame")
    expect(
        queues.enqueue(recoveryFrame(4), surface: surfaceZero) == .awaitingKeyFrame,
        "so the delta built on it is refused too"
    )
    expect(queues.completeSend()?.frame.sequence == 2, "the waiting key frame still goes out")
    expect(
        queues.enqueue(recoveryFrame(5), surface: surfaceZero) == .awaitingKeyFrame,
        "but sending it does not end the wait"
    )
    expect(queues.enqueue(recoveryFrame(6, keyFrame: true), surface: surfaceZero) == .queued, "a newer key frame is taken")
    expect(!queues.isAwaitingKeyFrame(surfaceZero), "and ends the wait")
    expect(queues.completeSend()?.frame.sequence == 6, "it goes out next")
    expect(queues.enqueue(recoveryFrame(7), surface: surfaceZero) == .queued, "and the deltas after it are taken")
    print("PASS: a delta refused behind a waiting key frame gates the surface until a newer key frame")
}

/// A frame whose write failed never reached the viewer, so whatever was built
/// on it cannot be decoded either. The wait is set before the next waiting
/// frame is dispatched, so the delta already waiting never goes out.
private func expectFailedWriteGatesLaterDeltasUntilAKeyFrame() {
    var queues = SurfaceVideoSendQueues()
    _ = queues.enqueue(recoveryFrame(1), surface: surfaceZero)
    expect(queues.enqueue(recoveryFrame(2), surface: surfaceZero) == .queued, "a delta waits behind the one in flight")
    expect(queues.noteWriteFailed(surfaceZero), "a failed write starts a wait for a key frame")
    expect(!queues.hasWaitingFrame(surfaceZero), "and takes the waiting delta built on the lost frame out of the slot")
    expect(queues.completeSend() == nil, "so nothing of that surface is dispatched after the failed write")
    expect(queues.enqueue(recoveryFrame(3), surface: surfaceZero) == .awaitingKeyFrame, "later deltas are refused")
    expect(!queues.noteWriteFailed(surfaceZero), "a second failure while already waiting starts nothing new")
    expect(queues.enqueue(recoveryFrame(4, keyFrame: true), surface: surfaceZero) == .sendNow, "a key frame goes out")
    expect(!queues.isAwaitingKeyFrame(surfaceZero), "and ends the wait")

    // A key frame already waiting is the recovery: it is a whole picture, and
    // nothing after it refers to the frame that failed.
    _ = queues.enqueue(recoveryFrame(5, keyFrame: true), surface: surfaceZero)
    expect(!queues.noteWriteFailed(surfaceZero), "a failure with a key frame waiting starts no wait")
    expect(queues.completeSend()?.frame.sequence == 5, "and that key frame still goes out")

    // The other surface's stream does not depend on this one's.
    var pair = SurfaceVideoSendQueues()
    _ = pair.enqueue(recoveryFrame(6), surface: surfaceZero)
    _ = pair.enqueue(recoveryFrame(7), surface: surfaceOne)
    expect(pair.noteWriteFailed(surfaceZero), "surface 0's failed write gates surface 0")
    expect(!pair.isAwaitingKeyFrame(surfaceOne), "but not surface 1")
    expect(pair.completeSend()?.frame.sequence == 7, "whose waiting delta still goes out")
    print("PASS: a failed write gates its surface until a key frame, before the next waiting frame can leave")
}

/// One request per wait for a key frame, at most one a second per surface,
/// and a request held back by that limit is still made when the second is up
/// unless a key frame got there first.
private func expectRecoveryRequestsArePaced() {
    let second: Int64 = 1_000_000_000
    var pacer = KeyFrameRecoveryPacer(minimumIntervalNanoseconds: second)
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .sendQueueDiscard, atNanoseconds: 10 * second) == .requestNow,
        "the first loss asks for a key frame at once"
    )
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .writeFailure, atNanoseconds: 10 * second + 1) == .none,
        "a second loss while that request is outstanding asks for nothing more"
    )
    expect(
        pacer.keyFrameNeeded(on: surfaceOne, cause: .writeFailure, atNanoseconds: 10 * second + 2) == .requestNow,
        "the other surface's encoder is asked on its own account"
    )
    pacer.keyFrameArrived(on: surfaceZero)
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .writeFailure, atNanoseconds: 10 * second + second / 4)
            == .requestAt(nanoseconds: 11 * second),
        "a loss within a second of the last request is held until the second is up"
    )
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .sendQueueDiscard, atNanoseconds: 10 * second + second / 2) == .none,
        "a further loss while one is held back schedules nothing more"
    )
    expect(
        pacer.deferredRequestDue(on: surfaceZero, isStillAwaiting: true, atNanoseconds: 11 * second) == .writeFailure,
        "the held request is made when the second is up, for the loss that was held"
    )
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .sendQueueDiscard, atNanoseconds: 11 * second + 1) == .none,
        "and is outstanding like any other"
    )
    pacer.keyFrameArrived(on: surfaceZero)
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .sendQueueDiscard, atNanoseconds: 11 * second + second / 2)
            == .requestAt(nanoseconds: 12 * second),
        "the second is counted from the held request, which was the last one made"
    )
    pacer.keyFrameArrived(on: surfaceZero)
    expect(
        pacer.deferredRequestDue(on: surfaceZero, isStillAwaiting: false, atNanoseconds: 12 * second) == nil,
        "a key frame that ended the wait first leaves nothing to ask for"
    )
    expect(
        pacer.keyFrameNeeded(on: surfaceZero, cause: .writeFailure, atNanoseconds: 12 * second + 1) == .requestNow,
        "and since nothing was asked then, the next loss is asked for at once"
    )
    expect(KeyFrameRecoveryCause.sendQueueDiscard.rawValue == "send-queue discard", "the discard cause reads as the log names it")
    expect(KeyFrameRecoveryCause.writeFailure.rawValue == "write failure", "the write-failure cause reads as the log names it")
    print("PASS: key frames asked for after a loss are one per wait, at most one a second per surface, and a held one is still asked for")
}

/// Dropping a capture before the encoder costs the viewer nothing, while an
/// encoded delta dropped after it costs every delta that follows. So while a
/// surface's send slot holds a frame, its captures wait in front of the
/// encoder instead, newest wins, and the newest goes in the moment the slot
/// empties. With the slot empty nothing waits.
private func expectCapturesWaitBeforeTheEncoderWhileTheSendSlotIsFull() {
    let feedback = VideoSendFeedback()
    let recorder = HostMediaLatencyRecorder()
    let encoder = FakeFrameEncoder()
    let gate = EncodeAdmissionGate(
        latencyRecorder: recorder,
        sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 2),
        surface: surfaceZero,
        sendFeedback: feedback,
        encodedFrameHandler: { _ in }
    )
    gate.encoder = encoder

    expect(gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 1)), "a capture is taken")
    expect(encoder.submittedPresentationTimes == [1], "with the send slot empty it goes straight to the encoder")
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))

    feedback.setWaitingSlotOccupied(true, on: surfaceZero)
    for time in Int64(2)...4 {
        expect(gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: time)), "a capture is held, not refused")
    }
    expect(
        encoder.submittedPresentationTimes == [1],
        "while the send slot holds a frame no capture reaches the encoder, got \(encoder.submittedPresentationTimes)"
    )
    expect(
        feedback.capturesDroppedForTheLink(on: surfaceZero) == 2
            && recorder.frameCounts(for: surfaceZero).encoderInputDropped == 0,
        "the two older held captures count as lost to the link, not to the encoder, got "
            + "\(feedback.capturesDroppedForTheLink(on: surfaceZero)) and "
            + "\(recorder.frameCounts(for: surfaceZero).encoderInputDropped)"
    )
    feedback.setWaitingSlotOccupied(false, on: surfaceZero)
    feedback.waitingSlotEmptied(on: surfaceZero)
    expect(
        encoder.submittedPresentationTimes == [1, 4],
        "the newest held capture goes in as soon as the slot empties, got \(encoder.submittedPresentationTimes)"
    )

    // The encoder finishing does not let a capture past a full slot either.
    feedback.setWaitingSlotOccupied(true, on: surfaceZero)
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 5))
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))
    expect(
        encoder.submittedPresentationTimes == [1, 4],
        "a capture held while the slot is full stays held when the encoder finishes, got \(encoder.submittedPresentationTimes)"
    )
    feedback.setWaitingSlotOccupied(false, on: surfaceZero)
    feedback.waitingSlotEmptied(on: surfaceZero)
    expect(encoder.submittedPresentationTimes == [1, 4, 5], "and goes in when the slot empties")

    // A capture replaced while the encoder is still busy is the encoder's.
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 50))
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 51))
    expect(
        recorder.frameCounts(for: surfaceZero).encoderInputDropped == 1
            && feedback.capturesDroppedForTheLink(on: surfaceZero) == 2,
        "a capture the busy encoder had no room for is an encoder-input drop"
    )
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))
    expect(encoder.submittedPresentationTimes == [1, 4, 5, 51], "and the newest goes in when the encoder finishes")
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))

    // Only this surface's slot holds this surface's captures.
    feedback.setWaitingSlotOccupied(true, on: surfaceOne)
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 6))
    expect(encoder.submittedPresentationTimes == [1, 4, 5, 51, 6], "the other surface's full slot holds nothing here")
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))

    feedback.requestKeyFrame(on: surfaceZero)
    expect(encoder.keyFrameRequestCount == 1, "a key frame asked for on this surface reaches this surface's encoder")
    feedback.requestKeyFrame(on: surfaceOne)
    expect(encoder.keyFrameRequestCount == 1, "one asked for on the other surface does not")
    gate.shutDown()
    feedback.requestKeyFrame(on: surfaceZero)
    expect(encoder.keyFrameRequestCount == 1, "a gate that has shut down is no longer reached")
    print("PASS: captures wait before the encoder while their surface's send slot is full, and the newest goes in when it empties")
}

/// A delta dropped at the send queue asks its encoder for one key frame, the
/// waiting delta it could not follow still goes out, and nothing built on the
/// dropped one does.
@MainActor
private func expectSendQueueDropAsksForOneKeyFrameAndSendsNoDeltaAfterIt() async {
    let channel = FakeHostByteChannel(scriptedMessages: [])
    channel.sendDelay = .milliseconds(60)
    let listener = RecordingFeedbackListener()
    let (session, feedback, requests) = makeRecoverySession(channel: channel, listener: listener)
    session.start()

    expect(session.send(recoveryFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is sent")
    expect(session.send(recoveryFrame(2), surface: surfaceZero, priority: .normal), "a delta waits behind it")
    expect(feedback.isWaitingSlotOccupied(on: surfaceZero), "and fills surface 0's send slot")
    expect(
        !session.send(recoveryFrame(3), surface: surfaceZero, priority: .normal),
        "a delta arriving behind the waiting delta is not taken"
    )
    expect(feedback.isWaitingSlotOccupied(on: surfaceZero), "the waiting delta keeps the slot")
    expect(listener.events == ["key frame"], "the encoder is asked for a key frame at once, got \(listener.events)")
    expect(requests.requests == ["surface 0: send-queue discard"], "the request is reported once, got \(requests.requests)")
    expect(!session.send(recoveryFrame(4), surface: surfaceZero, priority: .normal), "a later delta is refused")
    expect(listener.events.count == 1, "and asks for nothing more while the request is outstanding")
    _ = await waitUntil(timeoutSeconds: 2) { sentVideoSequences(channel) == [1, 2] && listener.events.count == 2 }
    try? await Task.sleep(for: .milliseconds(100))
    expect(
        sentVideoSequences(channel) == [1, 2],
        "the waiting delta went out and nothing built on the dropped one did, got \(sentVideoSequences(channel))"
    )
    expect(
        listener.events == ["key frame", "slot emptied"],
        "the slot is reported empty when the waiting delta leaves it, got \(listener.events)"
    )

    expect(session.send(recoveryFrame(5, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is sent")
    expect(session.send(recoveryFrame(6), surface: surfaceZero, priority: .normal), "and deltas are taken again")
    expect(
        session.send(recoveryFrame(7, keyFrame: true), surface: surfaceZero, priority: .normal),
        "a key frame displacing a waiting delta is taken"
    )
    expect(
        requests.requests.count == 1 && listener.events.count == 2,
        "and asks for nothing: the frame that displaced the delta is itself the key frame the viewer needs"
    )
    _ = await waitUntil(timeoutSeconds: 2) { sentVideoSequences(channel) == [1, 2, 5, 7] }
    expect(sentVideoSequences(channel) == [1, 2, 5, 7], "the key frames went out, got \(sentVideoSequences(channel))")
    channel.cancel()
    print("PASS: a send-queue drop asks the surface's encoder for one key frame and lets nothing built on the dropped delta out")
}

@MainActor
private func expectFailedWriteAsksForAKeyFrameAndSendsNoDeltaAfterIt() async {
    let channel = FakeHostByteChannel(scriptedMessages: [])
    channel.sendDelay = .milliseconds(60)
    channel.sendBytesError = HostNetworkSessionError.closed
    let listener = RecordingFeedbackListener()
    let (session, feedback, requests) = makeRecoverySession(channel: channel, listener: listener)
    session.start()

    expect(session.send(recoveryFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is sent")
    expect(await waitUntil(timeoutSeconds: 2) { channel.peakConcurrentSends == 1 }, "its write starts")
    // Read by each write as it starts, so only the write already under way fails.
    channel.sendBytesError = nil
    expect(session.send(recoveryFrame(2), surface: surfaceZero, priority: .normal), "a delta waits behind it")
    expect(
        await waitUntil(timeoutSeconds: 2) { listener.events.count == 2 },
        "the failed write is reported to the encode gate, got \(listener.events)"
    )
    expect(
        listener.events == ["key frame", "slot emptied"],
        "a key frame is asked for before the slot the lost frame's delta held is reported empty, got \(listener.events)"
    )
    expect(requests.requests == ["surface 0: write failure"], "the request names the write failure, got \(requests.requests)")
    expect(!feedback.isWaitingSlotOccupied(on: surfaceZero), "the delta built on the lost frame is out of the slot")
    expect(!session.send(recoveryFrame(3), surface: surfaceZero, priority: .normal), "a later delta is refused")
    expect(session.send(recoveryFrame(4, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is sent")
    _ = await waitUntil(timeoutSeconds: 2) { !sentVideoSequences(channel).isEmpty }
    try? await Task.sleep(for: .milliseconds(100))
    expect(
        sentVideoSequences(channel) == [4],
        "the next frame on the wire after the failed write is the key frame, got \(sentVideoSequences(channel))"
    )
    channel.cancel()
    print("PASS: a failed write asks the surface's encoder for a key frame and lets no delta out after it")
}

@MainActor
private func expectHeldKeyFrameRequestIsServedWhenTheSecondIsUp() async {
    let channel = FakeHostByteChannel(scriptedMessages: [])
    channel.sendDelay = .milliseconds(100)
    let listener = RecordingFeedbackListener()
    let (session, _, requests) = makeRecoverySession(
        channel: channel,
        listener: listener,
        keyFrameRecoveryInterval: .milliseconds(400)
    )
    session.start()
    let discard = "surface 0: send-queue discard"

    _ = session.send(recoveryFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal)
    _ = session.send(recoveryFrame(2), surface: surfaceZero, priority: .normal)
    _ = session.send(recoveryFrame(3), surface: surfaceZero, priority: .normal)
    expect(requests.requests == [discard], "the first loss asks at once")
    expect(session.send(recoveryFrame(4, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame ends the wait")
    expect(
        !session.send(recoveryFrame(5), surface: surfaceZero, priority: .normal),
        "a delta refused behind it starts a new wait"
    )
    try? await Task.sleep(for: .milliseconds(150))
    expect(requests.requests == [discard], "whose request is held inside the interval, got \(requests.requests)")
    expect(
        await waitUntil(timeoutSeconds: 2) { requests.requests.count == 2 },
        "and made once the interval is up, got \(requests.requests)"
    )
    expect(requests.requests == [discard, discard], "for the loss that was held")
    expect(listener.events.filter { $0 == "key frame" }.count == 2, "and it reaches the encoder")

    // A key frame that ends the wait before the interval is up leaves the
    // held request with nothing to ask for.
    _ = await waitUntil(timeoutSeconds: 2) { sentVideoSequences(channel) == [1, 4] }
    _ = session.send(recoveryFrame(6, keyFrame: true), surface: surfaceZero, priority: .normal)
    _ = session.send(recoveryFrame(7), surface: surfaceZero, priority: .normal)
    _ = session.send(recoveryFrame(8), surface: surfaceZero, priority: .normal)
    expect(requests.requests.count == 2, "a loss soon after the held request was made is held in turn")
    expect(session.send(recoveryFrame(9, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame ends that wait")
    try? await Task.sleep(for: .milliseconds(600))
    expect(
        requests.requests.count == 2,
        "a held request whose wait a key frame ended asks for nothing, got \(requests.requests)"
    )
    channel.cancel()
    print("PASS: a key-frame request held by the one-second limit is made when the second is up, unless a key frame came first")
}

@MainActor
private final class InertMediaPipeline: CanvasMediaPipelining {
    func start() async throws {}
    func stop() async throws {}
    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) throws {}
    func requestKeyFrame() {}
    func refreshStillPicture() async throws -> Int? { nil }
}

/// The gate can only hold captures for a send slot it can see, so every
/// pipeline a canvas builds, the first and every rebuild, is handed the
/// connection's own feedback rather than a fresh one nothing writes.
@MainActor
private func expectCanvasMediaCarriesTheSessionsSendFeedbackIntoEveryPipeline() async {
    let feedback = VideoSendFeedback()
    var handed: [VideoSendFeedback] = []
    let media = ScreenCaptureCanvasMedia(
        surface: surfaceZero,
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        sendFeedback: feedback,
        pipelineFactory: { _, _, _, _, _, _, sendFeedback, _, _, _, _ in
            handed.append(sendFeedback)
            return InertMediaPipeline()
        },
        contentFilterProvider: { _ in SCContentFilter() }
    )
    try! await media.start(canvasDisplayID: 42, onPacket: { _ in true })
    try? await media.reconfigure(streamScale: 0.5)
    expect(
        handed.count == 2 && handed.allSatisfy { $0 === feedback },
        "every pipeline the canvas builds is handed the connection's send feedback, got \(handed.count) pipelines"
    )
    await media.stop()
    print("PASS: a canvas hands every pipeline it builds the connection's own send feedback")
}

@MainActor
private func expectEachRecoveryRequestIsLoggedOnce() async {
    let sink = FakeVideoSink()
    let events = DiagnosticsRecorder()
    let coordinator = HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        ),
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: sink,
        onEvent: { events.record($0) }
    )
    sink.reportKeyFrameRecoveryRequest(on: surfaceZero, cause: .sendQueueDiscard)
    sink.reportKeyFrameRecoveryRequest(on: surfaceOne, cause: .writeFailure)
    let expected = [
        "key frame requested on canvas 0: send-queue discard",
        "key frame requested on canvas 1: write failure",
    ]
    _ = await waitUntil(timeoutSeconds: 2) { events.messages.filter { $0.hasPrefix("key frame requested") }.count == 2 }
    expect(
        events.messages.filter { $0.hasPrefix("key frame requested") } == expected,
        "each request is one log line naming the surface and the cause, got \(events.messages)"
    )
    withExtendedLifetime(coordinator) {}
    print("PASS: each key frame asked for after a loss is one log line naming the surface and the cause")
}

/// The send path marks the slot empty before it tells the gate, so a capture
/// can arrive in between, find the slot empty and go straight in. The capture
/// still held from before is older, and encoding it next would step the
/// picture backwards.
private func expectAHeldCaptureNeverGoesInAfterANewerOne() {
    let feedback = VideoSendFeedback()
    let recorder = HostMediaLatencyRecorder()
    let encoder = FakeFrameEncoder()
    let gate = EncodeAdmissionGate(
        latencyRecorder: recorder,
        sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 2),
        surface: surfaceZero,
        sendFeedback: feedback,
        encodedFrameHandler: { _ in }
    )
    gate.encoder = encoder

    feedback.setWaitingSlotOccupied(true, on: surfaceZero)
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 1))
    feedback.setWaitingSlotOccupied(false, on: surfaceZero)
    _ = gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: 2))
    expect(encoder.submittedPresentationTimes == [2], "a capture finding the slot empty goes straight in")
    feedback.waitingSlotEmptied(on: surfaceZero)
    gate.frameFinished(.encoded(makeCaptureSampleBuffer()))
    expect(
        encoder.submittedPresentationTimes == [2],
        "the older capture held before it is never encoded after it, got \(encoder.submittedPresentationTimes)"
    )
    expect(
        feedback.capturesDroppedForTheLink(on: surfaceZero) == 1
            && recorder.frameCounts(for: surfaceZero).encoderInputDropped == 0,
        "it was waiting for the link, so it counts as lost to the link, got "
            + "\(feedback.capturesDroppedForTheLink(on: surfaceZero))"
    )
    print("PASS: a capture held for a full slot is dropped, not encoded, once a newer one has gone in")
}

/// Hands frames to nobody but reports the drops of a real session, which is
/// what the coordinator reads for the link; and accepts every frame, so the
/// session's own queue adds no drops of its own.
private final class SessionDropReportingSink: CanvasVideoSending, @unchecked Sendable {
    private let session: HostNetworkSession

    init(_ session: HostNetworkSession) {
        self.session = session
    }

    func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool {
        true
    }

    var droppedVideoFrameCount: Int { session.droppedVideoFrameCount }

    func droppedVideoFrameCount(for surface: CanvasSurfaceID) -> Int {
        session.droppedVideoFrameCount(for: surface)
    }
}

/// Before captures waited for the send slot, a link that could not keep up
/// lost encoded frames at the send queue, and that is what names the link.
/// A capture now held for the link and replaced by a newer one is the same
/// loss, so it is counted there too and the link is still named, not the
/// encoder: an encoder well inside its budget is not what is behind.
@MainActor
private func expectCapturesHeldForTheLinkReadAsLinkPressure() async {
    let feedback = VideoSendFeedback()
    let recorder = HostMediaLatencyRecorder()
    let session = HostNetworkSession(
        connection: FakeHostByteChannel(scriptedMessages: []),
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        ),
        sendFeedback: feedback
    )
    let media = FakeScalableCanvasMedia()
    let coordinator = HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        ),
        media: onlyOnSurfaceZero(media),
        videoSink: SessionDropReportingSink(session),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        latencyRecorder: recorder
    )
    _ = try! await coordinator.handleWritingResponse(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    )
    let encoder = FakeFrameEncoder()
    let gate = EncodeAdmissionGate(
        latencyRecorder: recorder,
        sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 2),
        surface: surfaceZero,
        sendFeedback: feedback,
        encodedFrameHandler: { _ in }
    )
    gate.encoder = encoder

    // Sixty captures a tick. The send slot is full except once every sixth
    // capture, when the newest held capture goes in and is encoded at once:
    // fifty captures a tick are lost to the link, none to the encoder.
    feedback.setWaitingSlotOccupied(true, on: surfaceZero)
    var presentationTime: Int64 = 0
    var sequence: UInt64 = 0
    for tick in 0...8 {
        for capture in 0..<60 {
            presentationTime += 16_666_667
            recorder.recordCapture(
                surface: surfaceZero,
                presentationTimeNanoseconds: presentationTime,
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
            gate.admit(makeCaptureSampleBuffer(presentationTimeNanoseconds: presentationTime))
            guard capture % 6 == 5 else { continue }
            feedback.setWaitingSlotOccupied(false, on: surfaceZero)
            feedback.waitingSlotEmptied(on: surfaceZero)
            feedback.setWaitingSlotOccupied(true, on: surfaceZero)
            gate.frameFinished(.encoded(makeCaptureSampleBuffer()))
            recorder.recordEncodeOutput(
                surface: surfaceZero,
                presentationTimeNanoseconds: encoder.submittedPresentationTimes.last ?? 0,
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
            sequence += 1
            media.emit(EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: UInt64(presentationTime),
                isKeyFrame: false,
                codecConfiguration: nil,
                payload: Data(repeating: 0xAB, count: 100_000)
            ))
        }
        media.frameCounts = recorder.frameCounts(for: surfaceZero)
        await coordinator.tickFidelity(atSeconds: Double(tick))
    }
    expect(
        coordinator.fidelityLimitReason(for: surfaceZero) == FidelityLimitReason.link,
        "a link that holds captures back is named as the link, got "
            + "\(String(describing: coordinator.fidelityLimitReason(for: surfaceZero)))"
    )
    expect(
        recorder.frameCounts(for: surfaceZero).encoderInputDropped == 0,
        "a capture held for the link is not an encoder-input drop, got "
            + "\(recorder.frameCounts(for: surfaceZero).encoderInputDropped)"
    )
    expect(
        session.droppedVideoFrameCount(for: surfaceZero) == 450 && session.droppedVideoFrameCount == 450,
        "it is counted with the frames the link could not carry, got \(session.droppedVideoFrameCount(for: surfaceZero))"
    )
    gate.shutDown()
    print("PASS: captures lost waiting for the link count as link drops, so a congested link is still named the link")
}

/// A key frame's write is timed from its start to its completion and counted
/// against its own surface, for the periodic video line. A delta is not
/// counted, a failed write is not counted, and taking the window starts the
/// next one.
@MainActor
private func expectEachKeyFrameWriteIsTimedForItsSurface() async {
    let channel = FakeHostByteChannel(scriptedMessages: [])
    channel.sendDelay = .milliseconds(60)
    let (session, _, _) = makeRecoverySession(channel: channel, listener: RecordingFeedbackListener())
    let sink: any CanvasVideoSending = session
    session.start()

    expect(session.send(recoveryFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is sent")
    expect(session.send(recoveryFrame(2), surface: surfaceZero, priority: .normal), "a delta waits behind it")
    expect(
        await waitUntil(timeoutSeconds: 2) { sentVideoSequences(channel) == [1, 2] },
        "both frames are written, got \(sentVideoSequences(channel))"
    )
    try? await Task.sleep(for: .milliseconds(50))
    let window = sink.takeKeyFrameSendWindow(for: surfaceZero)
    expect(window.count == 1, "the one key frame is counted and the delta is not, got \(window)")
    expect(
        window.largestBytes == 4,
        "its size is payload plus codec configuration, got \(window.largestBytes)"
    )
    expect(
        window.slowestNanoseconds >= 60_000_000 && window.slowestNanoseconds < 2_000_000_000,
        "its write is timed from start to completion, got \(window.slowestNanoseconds) ns"
    )
    expect(sink.takeKeyFrameSendWindow(for: surfaceZero).count == 0, "taking the window starts the next one")
    expect(sink.takeKeyFrameSendWindow(for: surfaceOne).count == 0, "and no other surface was charged for it")

    channel.sendBytesError = HostNetworkSessionError.closed
    expect(session.send(recoveryFrame(3, keyFrame: true), surface: surfaceZero, priority: .normal), "a key frame is handed over")
    _ = await waitUntil(timeoutSeconds: 2) { channel.peakConcurrentSends >= 1 }
    try? await Task.sleep(for: .milliseconds(150))
    expect(
        sink.takeKeyFrameSendWindow(for: surfaceZero).count == 0,
        "a key frame whose write failed put nothing on the wire and is not counted"
    )
    channel.cancel()
    print("PASS: each key frame's write is timed from start to completion and counted against its own surface")
}
