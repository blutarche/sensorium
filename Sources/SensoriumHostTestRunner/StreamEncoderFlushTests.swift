import CoreMedia
import CoreVideo
import Foundation
import SensoriumHost

/// A still-screen refresh empties the stream's encoder and holds whatever the
/// stream submits next until the refresh has been handed on. VideoToolbox's
/// flush waits for the frame in flight to come out, and that frame's output
/// callback is where `EncodeAdmissionGate` submits the next capture, straight
/// back into `encode`. Driven here on a real encoder, offline: no display, no
/// capture, no network. A machine with no hardware H.264 encoder skips it, as
/// the other real-encoder tests do.
@MainActor
func runStreamEncoderFlushTests() async {
    await expectAFlushNeverWaitsOnTheFrameItsOwnCallbackSubmits()
    await expectAFrameAcceptedDuringTheHoldWaitsForTheRefresh()
    await expectEveryHoldIsResumedBeforeHeldFramesGoIn()
}

/// The output callback here resubmits from inside itself, the way the
/// admission gate does, so a frame is in flight whenever the flush starts and
/// its callback calls `encode` while the flush is waiting for it. The flush
/// runs on a thread of its own and is given 5 seconds: a flush that holds what
/// `encode` needs while it waits never returns, and the runner must report
/// that rather than hang on it.
private func expectAFlushNeverWaitsOnTheFrameItsOwnCallbackSubmits() async {
    let configuration = VideoEncoderConfiguration.remoteDefault
    // Built before the encoder exists: making a full-size picture inside the
    // output callback would stretch the time a frame is in flight unevenly.
    let frames = flushTestFrames(count: 20, configuration: configuration)
    let chain = ResubmittingFrameChain(frames: frames)
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            chain.finished(outcome)
        }
    ) else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no flush to drive")
        return
    }
    chain.encoder = encoder

    do {
        try encoder.encode(frames[0])
        chain.recordAccepted(callbackIndex: nil)
    } catch {
        expect(false, "the stream's encoder takes the opening frame, got \(error)")
    }
    let flushReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        chain.setHoldInProgress(true)
        encoder.holdFramesAndFlush()
        flushReturned.signal()
    }
    expect(
        waitForSignal(flushReturned, seconds: 5),
        "a still-refresh flush returns while the frame in flight's output callback submits the next frame "
            + "through `encode`: a flush that holds the encoder's lock while VideoToolbox waits on that "
            + "callback never returns, and freezes whichever thread called it"
    )
    encoder.resumeHeldFramesWithKeyFrame()
    chain.setHoldInProgress(false)
    expect(
        await waitUntil(timeoutSeconds: 5) { chain.isSettled },
        "every frame the encoder accepted is reported on, and the chain of resubmissions runs to its end "
            + "after the hold: \(chain.outcomeCount) outcomes for \(chain.acceptedCount) accepted frames"
    )

    expect(
        chain.refusedSubmissions.isEmpty,
        "no frame submitted from the output callback is refused, during the hold or after it, got "
            + "\(chain.refusedSubmissions)"
    )
    expect(
        chain.outcomeCount == chain.acceptedCount,
        "every frame the encoder accepted gets exactly one outcome, which is what lets the admission gate "
            + "free its slot: \(chain.outcomeCount) outcomes for \(chain.acceptedCount) accepted frames"
    )
    let encoded = chain.encodedFrames
    expect(
        Set(encoded.map(\.index)).count == encoded.count,
        "no frame is reported twice, got \(encoded.map(\.index))"
    )
    let submittedDuringHold = chain.indicesSubmittedDuringHold
    expect(
        !submittedDuringHold.isEmpty,
        "the output callback submitted a frame while the hold was in force, so the re-entry this test "
            + "exists for really happened"
    )
    let keyFrameIndices = encoded.filter(\.isKeyFrame).map(\.index)
    expect(
        keyFrameIndices.first == 0,
        "the opening frame of a new compression session is a key frame, got key frames at \(keyFrameIndices)"
    )
    expect(
        keyFrameIndices.count == 2,
        "the resume's request makes exactly one more key frame and is then spent: the stream goes back "
            + "to deltas, got key frames at \(keyFrameIndices)"
    )
    if keyFrameIndices.count == 2 {
        expect(
            submittedDuringHold.contains(keyFrameIndices[1]),
            "the key frame the resume asked for is a frame the callback submitted during the hold, so "
                + "nothing submitted after the flush began can be a delta built on what the flush let out: "
                + "key frame at \(keyFrameIndices[1]), submitted during the hold \(submittedDuringHold)"
        )
    }
    withExtendedLifetime(encoder) {}
    print(
        "PASS: a still-refresh flush returns while its own output callback submits the next frame, "
            + "every frame gets one outcome, and frame \(keyFrameIndices.last ?? -1) submitted during the "
            + "hold comes out a key frame"
    )
}

/// The refresh is handed on between the hold and the resume, so a stream
/// frame accepted in that time must not reach VideoToolbox before the resume.
/// If it did, its output could reach the transport ahead of the refresh, and
/// the stream's next delta would follow the refresh built on a picture the
/// viewer's rebuilt decoder never saw.
private func expectAFrameAcceptedDuringTheHoldWaitsForTheRefresh() async {
    guard let primed = await primedFlushTestEncoder() else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no hold to drive")
        return
    }
    let encoder = primed.encoder
    let log = primed.log

    encoder.holdFramesAndFlush()
    expect(
        encodeOnAnotherThread(primed.heldFrame, encoder: encoder),
        "`encode` accepts a frame during a hold and returns at once, without throwing"
    )
    try? await Task.sleep(nanoseconds: 300_000_000)
    expect(
        log.outcomeCount == primed.primingFrameCount,
        "a frame accepted after the flush produces no outcome before the refresh has been handed on: "
            + "its output could otherwise reach the transport ahead of the refresh, got "
            + "\(log.outcomeCount - primed.primingFrameCount) early"
    )
    log.recordRefreshHandedOn()
    encoder.resumeHeldFramesWithKeyFrame()
    expect(
        await waitUntil(timeoutSeconds: 5) { log.outcomeCount == primed.primingFrameCount + 1 },
        "the resume submits the held frame and it is reported on, got \(log.outcomeCount) outcomes for "
            + "\(primed.primingFrameCount + 1) accepted frames"
    )
    expectHeldFrameFollowsTheRefreshAsAKeyFrame(log, heldIndex: primed.heldIndex)
    withExtendedLifetime(encoder) {}
    print("PASS: a frame accepted during the hold comes out after the refresh is handed on, as a key frame")
}

/// Holds nest. Every hold is paired with exactly one resume, and held frames
/// go in only when the last of them resumes: a frame let in early by an inner
/// resume could still overtake the refresh an outer hold is waiting to send.
private func expectEveryHoldIsResumedBeforeHeldFramesGoIn() async {
    guard let primed = await primedFlushTestEncoder() else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no hold to nest")
        return
    }
    let encoder = primed.encoder
    let log = primed.log

    encoder.holdFramesAndFlush()
    encoder.holdFramesAndFlush()
    expect(
        encodeOnAnotherThread(primed.heldFrame, encoder: encoder),
        "`encode` accepts a frame during a nested hold and returns at once, without throwing"
    )
    encoder.resumeHeldFramesWithKeyFrame()
    try? await Task.sleep(nanoseconds: 300_000_000)
    expect(
        log.outcomeCount == primed.primingFrameCount,
        "one resume of two leaves the frame held, so it produces no outcome yet, got "
            + "\(log.outcomeCount - primed.primingFrameCount) early"
    )
    log.recordRefreshHandedOn()
    encoder.resumeHeldFramesWithKeyFrame()
    expect(
        await waitUntil(timeoutSeconds: 5) { log.outcomeCount == primed.primingFrameCount + 1 },
        "the second resume submits the held frame and it is reported on, got \(log.outcomeCount) outcomes "
            + "for \(primed.primingFrameCount + 1) accepted frames"
    )
    expectHeldFrameFollowsTheRefreshAsAKeyFrame(log, heldIndex: primed.heldIndex)
    withExtendedLifetime(encoder) {}
    print("PASS: a nested hold keeps a frame held until its last resume")
}

private func expectHeldFrameFollowsTheRefreshAsAKeyFrame(_ log: OrderedEncoderLog, heldIndex: Int) {
    let entries = log.entries
    let markerPosition = entries.firstIndex { $0 == .refreshHandedOn }
    let heldPosition = entries.firstIndex {
        if case .encoded(heldIndex, _) = $0 { return true }
        return false
    }
    guard let markerPosition, let heldPosition else {
        expect(false, "the log holds both the refresh hand-off and the held frame's output, got \(entries)")
        return
    }
    expect(
        heldPosition > markerPosition,
        "the held frame comes out after the refresh is handed on, never ahead of it, got \(entries)"
    )
    expect(
        entries[heldPosition] == .encoded(index: heldIndex, isKeyFrame: true),
        "and it is a key frame, so the stream's frames after the refresh decode on the viewer's rebuilt "
            + "decoder, got \(entries[heldPosition])"
    )
}

/// An encoder that has already put out its opening key frame and a delta or
/// two, so a key frame after the hold is the resume's doing.
private struct PrimedFlushTestEncoder {
    let encoder: VideoToolboxEncoder
    let log: OrderedEncoderLog
    let primingFrameCount: Int
    let heldIndex: Int
    let heldFrame: SendableSampleBuffer
}

private func primedFlushTestEncoder() async -> PrimedFlushTestEncoder? {
    let configuration = VideoEncoderConfiguration.remoteDefault
    let primingFrameCount = 3
    let frames = flushTestFrames(count: primingFrameCount + 1, configuration: configuration)
    let log = OrderedEncoderLog()
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            log.record(outcome)
        }
    ) else {
        return nil
    }
    for frame in frames.prefix(primingFrameCount) {
        do {
            try encoder.encode(frame)
        } catch {
            expect(false, "the stream's encoder takes each priming frame, got \(error)")
        }
    }
    expect(
        await waitUntil(timeoutSeconds: 5) { log.outcomeCount == primingFrameCount },
        "every priming frame is reported on, got \(log.outcomeCount) of \(primingFrameCount)"
    )
    expect(
        log.entries.last == .encoded(index: primingFrameCount - 1, isKeyFrame: false),
        "the stream is producing deltas by now, so a key frame after the hold is the resume's doing, got "
            + "\(log.entries)"
    )
    return PrimedFlushTestEncoder(
        encoder: encoder,
        log: log,
        primingFrameCount: primingFrameCount,
        heldIndex: primingFrameCount,
        heldFrame: SendableSampleBuffer(frames[primingFrameCount])
    )
}

private func flushTestFrames(count: Int, configuration: VideoEncoderConfiguration) -> [CMSampleBuffer] {
    (0..<count).map { index in
        refreshTestSampleBuffer(
            refreshTestPixelBuffer(
                width: configuration.encodeWidth,
                height: configuration.encodeHeight,
                shiftedBy: index
            ),
            frameIndex: index
        )
    }
}

/// Submits from a thread other than the caller's, as capture does, and
/// answers whether `encode` returned within 5 seconds without throwing.
private func encodeOnAnotherThread(_ frame: SendableSampleBuffer, encoder: VideoToolboxEncoder) -> Bool {
    let returned = DispatchSemaphore(value: 0)
    let accepted = LockedFlag()
    DispatchQueue.global().async {
        if (try? encoder.encode(frame.sampleBuffer)) != nil {
            accepted.set()
        }
        returned.signal()
    }
    return waitForSignal(returned, seconds: 5) && accepted.isSet
}

/// `DispatchSemaphore.wait` from a synchronous frame, so an async test can
/// bound a wait on another thread without suspending on it.
private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// Carries one frame to the thread that submits it. Nothing reads or writes
/// the buffer after it is built except that one `encode` call.
private struct SendableSampleBuffer: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer

    init(_ sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

/// Encoder outputs and the test's own refresh hand-off, in one log, in the
/// order they happened.
private final class OrderedEncoderLog: @unchecked Sendable {
    enum Entry: Equatable, CustomStringConvertible {
        case encoded(index: Int, isKeyFrame: Bool)
        case dropped
        case failed(OSStatus)
        case refreshHandedOn

        var description: String {
            switch self {
            case .encoded(let index, let isKeyFrame):
                return isKeyFrame ? "key \(index)" : "delta \(index)"
            case .dropped:
                return "dropped"
            case .failed(let status):
                return "failed \(status)"
            case .refreshHandedOn:
                return "refresh"
            }
        }
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var outcomeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0 != .refreshHandedOn }.count
    }

    func record(_ outcome: VideoEncodeOutcome) {
        let entry: Entry
        switch outcome {
        case .encoded(let sampleBuffer):
            entry = .encoded(index: flushTestFrameIndex(of: sampleBuffer), isKeyFrame: flushTestIsKeyFrame(sampleBuffer))
        case .dropped:
            entry = .dropped
        case .failed(let status):
            entry = .failed(status)
        }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(entry)
    }

    func recordRefreshHandedOn() {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(.refreshHandedOn)
    }
}

/// The output callback's side of the deadlock test: records every outcome and
/// submits the next frame from inside the callback, as `EncodeAdmissionGate`
/// does, until the frames run out.
private final class ResubmittingFrameChain: @unchecked Sendable {
    struct EncodedFrame {
        let index: Int
        let isKeyFrame: Bool
    }

    private let lock = NSLock()
    private let frames: [CMSampleBuffer]
    private weak var heldEncoder: VideoToolboxEncoder?
    private var nextIndex = 1
    /// Frames taken from `frames` whose `encode` has not yet returned.
    private var claimedNotSubmitted = 0
    private var accepted = 0
    private var outcomes = 0
    private var encoded: [EncodedFrame] = []
    private var refused: [Int] = []
    private var holdInProgress = false
    private var duringHold: [Int] = []

    init(frames: [CMSampleBuffer]) {
        self.frames = frames
    }

    /// Held weakly, like `EncodeAdmissionGate.encoder`: the encoder owns the
    /// callback that owns this object.
    var encoder: VideoToolboxEncoder? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return heldEncoder
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            heldEncoder = newValue
        }
    }

    var acceptedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    var outcomeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outcomes
    }

    var encodedFrames: [EncodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return encoded
    }

    var refusedSubmissions: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    var indicesSubmittedDuringHold: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return duringHold
    }

    /// Every frame has been submitted or refused, and every accepted one has
    /// come back. A frame taken but not yet through `encode` counts as
    /// neither, or the last one would read as settled before it is accepted.
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (nextIndex >= frames.count || !refused.isEmpty) && claimedNotSubmitted == 0 && outcomes == accepted
    }

    func setHoldInProgress(_ inProgress: Bool) {
        lock.lock()
        defer { lock.unlock() }
        holdInProgress = inProgress
    }

    /// `callbackIndex` names a frame the output callback submitted; `nil` is
    /// one the test submitted itself.
    func recordAccepted(callbackIndex: Int?) {
        lock.lock()
        defer { lock.unlock() }
        accepted += 1
        if callbackIndex != nil {
            claimedNotSubmitted -= 1
        }
        if let callbackIndex, holdInProgress {
            duringHold.append(callbackIndex)
        }
    }

    func finished(_ outcome: VideoEncodeOutcome) {
        lock.lock()
        outcomes += 1
        if case .encoded(let sampleBuffer) = outcome {
            encoded.append(EncodedFrame(
                index: flushTestFrameIndex(of: sampleBuffer),
                isKeyFrame: flushTestIsKeyFrame(sampleBuffer)
            ))
        }
        let index = nextIndex < frames.count ? nextIndex : nil
        if index != nil {
            nextIndex += 1
            claimedNotSubmitted += 1
        }
        let encoder = heldEncoder
        lock.unlock()
        guard let index, let encoder else {
            return
        }
        // Outside this object's lock, exactly as the gate calls it: `encode`
        // may take the encoder's own lock, and nothing here may be held then.
        do {
            try encoder.encode(frames[index])
            recordAccepted(callbackIndex: index)
        } catch {
            lock.lock()
            refused.append(index)
            claimedNotSubmitted -= 1
            lock.unlock()
        }
    }
}

/// Every test frame is stamped with its index at 60 per second.
private func flushTestFrameIndex(of sampleBuffer: CMSampleBuffer) -> Int {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    return Int(CMTimeConvertScale(presentationTime, timescale: 60, method: .roundHalfAwayFromZero).value)
}

private func flushTestIsKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[CFString: Any]],
        let first = attachments.first else {
        return true
    }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
}
