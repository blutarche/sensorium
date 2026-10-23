import CoreMedia
import CoreVideo
import Foundation
import SensoriumCore
import SensoriumHost

/// The size a moving picture is encoded at, and the encoder that sends a
/// stream at two sizes without a rebuild between them.
@MainActor
func runStreamMotionEncoderTests() async {
    expectAMovingPictureIsEncodedAtTheMotionPixelBudget()
    expectASmallStreamHasNoMotionSize()
    expectFramesGoToTheEncoderForTheirModeWithAKeyFrameAtEachSwitch()
    expectKeyFrameRequestsAndHoldsReachBothEncoders()
    expectAKeyFrameLostRightAfterASwitchIsAskedForAgain()
    expectPrimingSendsNothing()
    expectAStreamWithNoMotionSizeIsOneEncoder()
    expectTheChangedFractionIsTheDirtyAreaOverTheFrame()
}

private func expectTheChangedFractionIsTheDirtyAreaOverTheFrame() {
    let fraction = StreamMotionEncoder.changedFraction(
        dirtyRects: [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 300, y: 100, width: 100, height: 50)],
        frameWidth: 400,
        frameHeight: 200
    )
    expect(fraction == 0.125, "two rects covering an eighth of the frame between them are an eighth of it, got \(String(describing: fraction))")
    expect(
        StreamMotionEncoder.changedFraction(
            dirtyRects: [CGRect(x: -50, y: 150, width: 100, height: 100)],
            frameWidth: 400,
            frameHeight: 200
        ) == 50.0 * 50.0 / (400.0 * 200.0),
        "only the part of a rect inside the frame counts"
    )
    expect(
        StreamMotionEncoder.changedFraction(
            dirtyRects: [CGRect(x: 0, y: 0, width: 400, height: 200), CGRect(x: 0, y: 0, width: 400, height: 200)],
            frameWidth: 400,
            frameHeight: 200
        ) == 1,
        "rects that overlap never add up to more than the whole frame"
    )
    expect(
        StreamMotionEncoder.changedFraction(dirtyRects: nil, frameWidth: 400, frameHeight: 200) == nil,
        "a frame whose change capture did not describe has no fraction, and the detector counts it as the whole frame"
    )
}

/// Stands in for one of the two encoders behind `StreamMotionEncoder`,
/// recording what it was asked for in the order it was asked.
private final class MotionFakeEncoder: MotionRoutableEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(presentationTime: Int64, keyFrame: Bool)] = []
    private var keyFrameRequested = false
    private(set) var keyFrameRequestCount = 0
    private(set) var holdCount = 0
    private(set) var resumeCount = 0
    /// Called from inside `encode`, as VideoToolbox's output callback is
    /// called while a flush waits for it.
    var onEncode: (@Sendable (CMSampleBuffer) -> Void)?

    var encoded: [(presentationTime: Int64, keyFrame: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func encode(_ sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        frames.append((CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value, keyFrameRequested))
        keyFrameRequested = false
        let onEncode = onEncode
        lock.unlock()
        onEncode?(sampleBuffer)
    }

    func requestKeyFrame() {
        lock.lock()
        keyFrameRequested = true
        keyFrameRequestCount += 1
        lock.unlock()
    }

    func holdFramesAndFlush() {
        lock.lock()
        holdCount += 1
        lock.unlock()
    }

    func resumeHeldFramesWithKeyFrame() {
        lock.lock()
        resumeCount += 1
        keyFrameRequested = true
        lock.unlock()
    }
}

/// A clock the test moves by hand, the settle checks the router asks for,
/// and what reached the admission gate and the settle handler.
private final class MotionRouterHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var nowSeconds = 100.0
    private var pendingChecks: [(afterSeconds: Double, check: @Sendable () -> Void)] = []
    private var finishedOutcomes = 0
    private var settles = 0

    var now: Double {
        get { lock.lock(); defer { lock.unlock() }; return nowSeconds }
        set { lock.lock(); nowSeconds = newValue; lock.unlock() }
    }

    var outcomesFinished: Int { lock.lock(); defer { lock.unlock() }; return finishedOutcomes }
    var settleCount: Int { lock.lock(); defer { lock.unlock() }; return settles }
    var checks: [Double] { lock.lock(); defer { lock.unlock() }; return pendingChecks.map(\.afterSeconds) }

    func makeRouter() -> StreamMotionEncoder {
        StreamMotionEncoder(
            clock: { [self] in now },
            scheduleSettleCheck: { [self] afterSeconds, check in
                lock.lock()
                pendingChecks.append((afterSeconds, check))
                lock.unlock()
            },
            settled: { [self] in
                lock.lock()
                settles += 1
                lock.unlock()
            },
            frameFinished: { [self] _ in
                lock.lock()
                finishedOutcomes += 1
                lock.unlock()
            }
        )
    }

    /// Runs the oldest settle check the router asked for, as its timer would.
    func runNextCheck() {
        lock.lock()
        guard !pendingChecks.isEmpty else {
            lock.unlock()
            return
        }
        let next = pendingChecks.removeFirst()
        lock.unlock()
        next.check()
    }
}

private func expectFramesGoToTheEncoderForTheirModeWithAKeyFrameAtEachSwitch() {
    let harness = MotionRouterHarness()
    let router = harness.makeRouter()
    let settled = MotionFakeEncoder()
    let moving = MotionFakeEncoder()
    router.attach(settled: settled, moving: moving)
    var presentationTime: Int64 = 0
    func send() {
        presentationTime += 1
        try? router.encode(makeCaptureSampleBuffer(presentationTimeNanoseconds: presentationTime))
    }

    send()
    expect(
        settled.encoded.count == 1 && !settled.encoded[0].keyFrame && moving.encoded.isEmpty,
        "a stream starts on its settled encoder, with no key frame of the router's own"
    )
    expect(router.encodingRole == .settled, "and says so")

    for _ in 0..<StreamMotionDetector.continuousChangeCount {
        harness.now += 1.0 / 60
        router.screenChanged(changedFraction: 1)
        send()
    }
    expect(
        settled.encoded.count == StreamMotionDetector.continuousChangeCount,
        "the changes before motion is shown stay on the settled encoder, got \(settled.encoded.count)"
    )
    expect(
        moving.encoded.count == 1 && moving.encoded[0].keyFrame,
        "the change that shows motion is the moving encoder's first frame, and a key frame, since the viewer has none of its references"
    )
    expect(router.encodingRole == .moving, "the stream says it is encoding the moving picture")
    let lastChange = harness.now
    expect(
        harness.checks.count == 1 && abs(harness.checks[0] - StreamMotionDetector.settleSeconds) < 1e-9,
        "one settle check is asked for, a settle delay out, got \(harness.checks)"
    )

    harness.now = lastChange + 0.1
    router.screenChanged(changedFraction: 1)
    send()
    expect(
        moving.encoded.count == 2 && !moving.encoded[1].keyFrame,
        "a moving picture keeps its encoder, as deltas"
    )
    expect(harness.checks.count == 1, "with the one check already pending, a further change asks for no other")

    harness.now = lastChange + 0.3
    harness.runNextCheck()
    expect(harness.settleCount == 0, "a check that comes before the deadline does not settle")
    expect(
        harness.checks.count == 1 && abs(harness.checks[0] - 0.3) < 1e-9,
        "it asks again for the time still to go, got \(harness.checks)"
    )
    harness.now = lastChange + 0.1 + StreamMotionDetector.settleSeconds
    harness.runNextCheck()
    expect(harness.settleCount == 1, "the check at the deadline settles the stream, once")
    expect(harness.checks.isEmpty, "and a settled stream asks for no further check")
    expect(router.encodingRole == .moving, "the last frame sent was still the moving one")

    send()
    expect(
        settled.encoded.count == StreamMotionDetector.continuousChangeCount + 1 && settled.encoded.last!.keyFrame,
        "the frame after the settle goes back to the settled encoder as a key frame"
    )
    expect(router.encodingRole == .settled, "and the stream says so")
    send()
    expect(!settled.encoded.last!.keyFrame, "after which it sends deltas")

    router.stop()
    for _ in 0..<StreamMotionDetector.continuousChangeCount {
        harness.now += 1.0 / 60
        router.screenChanged(changedFraction: 1)
    }
    harness.now += 10
    harness.runNextCheck()
    expect(harness.settleCount == 1, "a stopped stream settles nothing")
}

private func expectKeyFrameRequestsAndHoldsReachBothEncoders() {
    let harness = MotionRouterHarness()
    let router = harness.makeRouter()
    let settled = MotionFakeEncoder()
    let moving = MotionFakeEncoder()
    router.attach(settled: settled, moving: moving)
    router.requestKeyFrame()
    expect(
        settled.keyFrameRequestCount == 1 && moving.keyFrameRequestCount == 1,
        "a viewer's key frame request reaches both encoders, so it is served whichever sends next"
    )
    router.holdFramesAndFlush()
    expect(settled.holdCount == 1 && moving.holdCount == 1, "a still refresh empties and holds both encoders")
    router.resumeHeldFramesWithKeyFrame()
    expect(settled.resumeCount == 1 && moving.resumeCount == 1, "and resumes both")
}

private func expectAKeyFrameLostRightAfterASwitchIsAskedForAgain() {
    let harness = MotionRouterHarness()
    let router = harness.makeRouter()
    let settled = MotionFakeEncoder()
    let moving = MotionFakeEncoder()
    router.attach(settled: settled, moving: moving)
    let movingOutcome = router.outcomeHandler(for: .moving)
    for index in 0..<StreamMotionDetector.continuousChangeCount {
        harness.now += 1.0 / 60
        router.screenChanged(changedFraction: 1)
        try? router.encode(makeCaptureSampleBuffer(presentationTimeNanoseconds: Int64(index)))
    }
    let requestsAtSwitch = moving.keyFrameRequestCount
    movingOutcome(.dropped)
    expect(
        moving.keyFrameRequestCount == requestsAtSwitch + 1,
        "the key frame that opened the moving picture was dropped, so the next frame is asked to be one again"
    )
    expect(harness.outcomesFinished == 1, "and the drop still releases its admission slot")
    movingOutcome(.encoded(makeCaptureSampleBuffer(presentationTimeNanoseconds: 50)))
    movingOutcome(.dropped)
    expect(
        moving.keyFrameRequestCount == requestsAtSwitch + 1,
        "once the switch has a frame out, a later drop is the encoder's ordinary business"
    )
    expect(harness.outcomesFinished == 3, "every outcome reaches the admission gate")
}

private func expectPrimingSendsNothing() {
    let harness = MotionRouterHarness()
    let router = harness.makeRouter()
    let settled = MotionFakeEncoder()
    let moving = MotionFakeEncoder()
    router.attach(settled: settled, moving: moving)
    let movingOutcome = router.outcomeHandler(for: .moving)
    moving.onEncode = { sampleBuffer in
        movingOutcome(.encoded(sampleBuffer))
    }
    router.prime(with: makeCaptureSampleBuffer(presentationTimeNanoseconds: 1))
    expect(moving.encoded.count == 1, "priming encodes one frame on the moving encoder")
    expect(harness.outcomesFinished == 0, "and sends nothing: it went through no admission slot and the viewer never sees it")
    expect(
        moving.holdCount == 1 && moving.resumeCount == 1,
        "the flush waits for it to come out, and the resume asks that the first real frame be a key frame"
    )
    moving.onEncode = nil
    movingOutcome(.dropped)
    expect(harness.outcomesFinished == 1, "after priming, every outcome reaches the admission gate")
    expect(settled.encoded.isEmpty, "the settled encoder is not touched")
}

private func expectAStreamWithNoMotionSizeIsOneEncoder() {
    let harness = MotionRouterHarness()
    let router = harness.makeRouter()
    let settled = MotionFakeEncoder()
    router.attach(settled: settled, moving: nil)
    router.viewerInteracted()
    for index in 0..<30 {
        harness.now += 1.0 / 60
        router.screenChanged(changedFraction: 1)
        try? router.encode(makeCaptureSampleBuffer(presentationTimeNanoseconds: Int64(index)))
    }
    expect(
        settled.encoded.count == 30 && settled.encoded.allSatisfy { !$0.keyFrame },
        "a stream with no motion size sends every frame from its one encoder, with no key frames of the router's own"
    )
    expect(harness.checks.isEmpty, "and has nothing to settle")
    expect(router.encodingRole == .settled, "and is always settled")
}

/// A canvas `width` by `height` points, captured and encoded at 1x.
private func motionTestCanvas(width: Int, height: Int) -> VideoEncoderConfiguration {
    let bitRate = VideoEncoderConfiguration.averageBitRate(encodeWidth: width, encodeHeight: height)
    return VideoEncoderConfiguration(
        width: width,
        height: height,
        framesPerSecond: 60,
        codec: .h264,
        maxQueueDepth: 3,
        captureWidth: width,
        captureHeight: height,
        encodeWidth: width,
        encodeHeight: height,
        averageBitRate: bitRate,
        dataRateLimitBytes: VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: bitRate),
        dataRateLimitSeconds: 1.0,
        maxFrameDelayCount: 0,
        profileLevel: .constrainedBaselineAutoLevel,
        requiresHardwareAcceleration: true
    )
}

private func expectAMovingPictureIsEncodedAtTheMotionPixelBudget() {
    let settled = motionTestCanvas(width: 1773, height: 997)
        .scaled(toStreamScale: 2.0)
        .with(framesPerSecond: 45)
        .with(qualityScale: 0.7)
        .with(keyFrameIntervalSeconds: VideoEncoderConfiguration.viewerRecoveryKeyFrameIntervalSeconds)
    guard let moving = settled.motionConfiguration else {
        expect(false, "a 3546x1994 stream has a motion size")
        return
    }
    expect(
        moving.encodeWidth == 1920 && moving.encodeHeight == 1080,
        "a moving picture is encoded at the motion pixel budget, the same shape as the settled one, got "
            + "\(moving.encodeWidth)x\(moving.encodeHeight)"
    )
    expect(
        moving.width == settled.width && moving.height == settled.height,
        "it is a smaller encode of the same canvas, so its stream scale is against the same logical size"
    )
    expect(
        moving.captureWidth == settled.captureWidth && moving.captureHeight == settled.captureHeight,
        "capture is untouched: the motion encoder scales the frames capture already delivers"
    )
    expect(
        moving.framesPerSecond == settled.framesPerSecond
            && moving.qualityScale == settled.qualityScale
            && moving.keyFrameIntervalSeconds == settled.keyFrameIntervalSeconds
            && moving.codec == settled.codec
            && moving.profileLevel == settled.profileLevel,
        "the frame rate, quality, key frame interval, codec and profile in force are carried over"
    )
    expect(
        moving.averageBitRate == VideoEncoderConfiguration.averageBitRate(
            encodeWidth: 1920,
            encodeHeight: 1080,
            framesPerSecond: 45,
            qualityScale: 0.7
        ),
        "every pixel is worth what it is worth at the settled size, so the bitrate follows the pixel count"
    )
}

private func expectASmallStreamHasNoMotionSize() {
    let budget = VideoEncoderConfiguration.motionPixelBudget
    expect(budget == 1920 * 1080, "the motion pixel budget is 1920x1080")

    let fullHD = motionTestCanvas(width: 1920, height: 1200)
    expect(
        fullHD.motionConfiguration == nil,
        "a 1920x1200 stream is barely above the budget, and a motion size would save too little to be worth a key frame"
    )
    let justUnder = motionTestCanvas(width: 2340, height: 1316)
    expect(
        justUnder.encodeWidth * justUnder.encodeHeight
            < Int(Double(budget) * VideoEncoderConfiguration.motionMinimumReduction),
        "this stream is just under the smallest one with a motion size"
    )
    expect(justUnder.motionConfiguration == nil, "so it has none")
    let justOver = motionTestCanvas(width: 2560, height: 1440)
    expect(justOver.motionConfiguration != nil, "a 2560x1440 stream has a motion size")
}
