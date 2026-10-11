import CoreMedia
import CoreVideo
import Foundation
import SensoriumHost

/// A still-screen refresh empties the stream's encoder while the stream is
/// still running. VideoToolbox's flush waits for the frame in flight to come
/// out, and that frame's output callback is where `EncodeAdmissionGate`
/// submits the next capture, straight back into `encode`. Driven here on a
/// real encoder, offline: no display, no capture, no network. A machine with
/// no hardware H.264 encoder skips it, as the other real-encoder tests do.
@MainActor
func runStreamEncoderFlushTests() async {
    await expectAFlushNeverWaitsOnTheFrameItsOwnCallbackSubmits()
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
    let frames = (0..<20).map { index in
        refreshTestSampleBuffer(
            refreshTestPixelBuffer(
                width: configuration.encodeWidth,
                height: configuration.encodeHeight,
                shiftedBy: index
            ),
            frameIndex: index
        )
    }
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
        chain.setFlushInProgress(true)
        encoder.completeFramesRequestingKeyFrame()
        chain.setFlushInProgress(false)
        flushReturned.signal()
    }
    expect(
        waitForSignal(flushReturned, seconds: 5),
        "a still-refresh flush returns while the frame in flight's output callback submits the next frame "
            + "through `encode`: a flush that holds the encoder's lock while VideoToolbox waits on that "
            + "callback never returns, and freezes whichever thread called it"
    )
    expect(
        await waitUntil(timeoutSeconds: 5) { chain.isSettled },
        "every frame the encoder accepted is reported on, and the chain of resubmissions runs to its end "
            + "after the flush: \(chain.outcomeCount) outcomes for \(chain.acceptedCount) accepted frames"
    )

    expect(
        chain.refusedSubmissions.isEmpty,
        "no frame submitted from the output callback is refused, during the flush or after it, got "
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
    let submittedDuringFlush = chain.indicesSubmittedDuringFlush
    expect(
        !submittedDuringFlush.isEmpty,
        "the output callback submitted a frame while the flush was running, so the re-entry this test "
            + "exists for really happened"
    )
    let keyFrameIndices = encoded.filter(\.isKeyFrame).map(\.index)
    expect(
        keyFrameIndices.first == 0,
        "the opening frame of a new compression session is a key frame, got key frames at \(keyFrameIndices)"
    )
    expect(
        keyFrameIndices.count == 2,
        "the flush's request makes exactly one more key frame and is then spent: the stream goes back "
            + "to deltas, got key frames at \(keyFrameIndices)"
    )
    if keyFrameIndices.count == 2 {
        expect(
            submittedDuringFlush.contains(keyFrameIndices[1]),
            "the key frame the flush asked for is a frame the callback submitted while the flush was "
                + "running, so nothing submitted after the flush began can be a delta built on what the "
                + "flush let out: key frame at \(keyFrameIndices[1]), submitted during the flush "
                + "\(submittedDuringFlush)"
        )
    }
    withExtendedLifetime(encoder) {}
    print(
        "PASS: a still-refresh flush returns while its own output callback submits the next frame, "
            + "every frame gets one outcome, and frame \(keyFrameIndices.last ?? -1) submitted during the "
            + "flush comes out a key frame"
    )
}

/// `DispatchSemaphore.wait` from a synchronous frame, so the async test above
/// can bound a wait on another thread without suspending on it.
private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// The output callback's side of the test: records every outcome and submits
/// the next frame from inside the callback, as `EncodeAdmissionGate` does,
/// until the frames run out.
private final class ResubmittingFrameChain: @unchecked Sendable {
    struct EncodedFrame {
        let index: Int
        let isKeyFrame: Bool
    }

    private let lock = NSLock()
    private let frames: [CMSampleBuffer]
    private weak var heldEncoder: VideoToolboxEncoder?
    private var nextIndex = 1
    private var accepted = 0
    private var outcomes = 0
    private var encoded: [EncodedFrame] = []
    private var refused: [Int] = []
    private var flushInProgress = false
    private var duringFlush: [Int] = []

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

    var indicesSubmittedDuringFlush: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return duringFlush
    }

    /// Every frame has been submitted or refused, and every accepted one has
    /// come back.
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (nextIndex >= frames.count || !refused.isEmpty) && outcomes == accepted
    }

    func setFlushInProgress(_ inProgress: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flushInProgress = inProgress
    }

    /// `callbackIndex` names a frame the output callback submitted; `nil` is
    /// one the test submitted itself.
    func recordAccepted(callbackIndex: Int?) {
        lock.lock()
        defer { lock.unlock() }
        accepted += 1
        if let callbackIndex, flushInProgress {
            duringFlush.append(callbackIndex)
        }
    }

    func finished(_ outcome: VideoEncodeOutcome) {
        lock.lock()
        outcomes += 1
        if case .encoded(let sampleBuffer) = outcome {
            encoded.append(EncodedFrame(
                index: Self.frameIndex(of: sampleBuffer),
                isKeyFrame: Self.isKeyFrame(sampleBuffer)
            ))
        }
        let index = nextIndex < frames.count ? nextIndex : nil
        if index != nil {
            nextIndex += 1
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
            lock.unlock()
        }
    }

    private static func frameIndex(of sampleBuffer: CMSampleBuffer) -> Int {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return Int(CMTimeConvertScale(presentationTime, timescale: 60, method: .roundHalfAwayFromZero).value)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
            let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
