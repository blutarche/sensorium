import Foundation
import SensoriumCore

/// Nothing in the pipeline is behind: a median encode well inside the frame
/// budget, nothing dropped, everything sent promptly.
private func healthyObservation(
    viewer: StreamFidelityViewerObservation? = nil
) -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000,
        sentBitsPerSecond: 10_000_000,
        viewer: viewer
    )
}

/// A median encode of 45ms is past 90% of the frame period at every frame
/// rate the ladder has, so this stays pressure however far the controller
/// steps down.
private func encoderPressuredObservation() -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 40,
        encodeP50Nanoseconds: 45_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000
    )
}

private func stillObservation() -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: 1,
        encodedDelta: 1,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 200_000
    )
}

/// A screen nobody is changing: nothing captured, and so no median encode
/// either. That is what a real still screen reports.
private func stillTickObservation() -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: 0,
        encodedDelta: 0,
        encodeP50Nanoseconds: nil,
        encodeSampleCount: 0,
        producedBitsPerSecond: 0
    )
}

/// The picture a level describes, named the way a decision carries it.
private func level(fps: Int, quality: Double = 1.0, scaleSteps: Int = 0) -> StreamFidelityLevel {
    StreamFidelityLevel(
        framesPerSecond: fps,
        qualityScale: quality,
        scaleStepsBelowRequested: scaleSteps
    )
}

/// Walks a controller past the warm-up that ignores everything it is told.
/// The ticks right after a session start or a rebuild are the encoder's
/// opening burst, and no scenario below means to be read as one.
private func warmUp(_ controller: inout StreamFidelityController, endingBefore seconds: Double = 0) {
    for tick in 0..<StreamFidelityController.warmUpTicks {
        _ = controller.observe(
            healthyObservation(),
            atSeconds: seconds - Double(StreamFidelityController.warmUpTicks - tick)
        )
    }
}

func testStreamFidelityLadderSpendsResolutionBeforeFrameRateAndQuality() {
    expect(
        StreamFidelityLadder.frameRates == [60, 45, 30, 20],
        "the frame rates a surface may be held to, fastest first"
    )
    expect(
        StreamFidelityLadder.qualityScales == [1.0, 0.75, 0.5],
        "the bitrate multipliers, sharpest first"
    )
    expect(
        StreamFidelityLadder.frameRate(at: StreamFidelityLadder.gentleFrameRateFloorIndex) == 30,
        "the frame rate stops at 30 until quality has been spent, because below that a moving picture is unwatchable"
    )
    expect(
        StreamFidelityLadder.frameRate(at: StreamFidelityLadder.fullFrameRateIndex) == 60
            && StreamFidelityLadder.qualityScale(at: StreamFidelityLadder.fullQualityIndex) == 1.0,
        "a surface with nothing behind it streams 60 fps at the full bitrate"
    )

    expect(
        StreamFidelityLadder.scaleStepCount(requestedScale: 1.0) == 0,
        "a viewer already at the minimum scale has no resolution to spend"
    )
    expect(
        StreamFidelityLadder.scaleStepCount(requestedScale: 1.5) == 2,
        "a 1.5x request has one step for each 0.25 down to 1.0x"
    )
    expect(
        StreamFidelityLadder.scaleStepCount(requestedScale: 2.0) == 4,
        "a 2.0x request has four"
    )
    expect(
        StreamFidelityLadder.scaleStepCount(requestedScale: .nan) == 0,
        "a nonsense requested scale has none rather than crashing"
    )

    let scales = (0...4).map {
        level(fps: 60, scaleSteps: $0).streamScale(requestedScale: 2.0)
    }
    expect(
        scales == [2.0, 1.75, 1.5, 1.25, 1.0],
        "each step is one quantum below the one above it, ending exactly on the minimum scale"
    )
    expect(
        level(fps: 60, scaleSteps: 99).streamScale(requestedScale: 2.0) == StreamScalePolicy.minimumScale,
        "a step past the end clamps to the minimum scale, never below it"
    )

    expect(
        StreamFidelityLadder.level(scaleStepsBelowRequested: 0, frameRateIndex: 99, qualityIndex: 99)
            == level(fps: 20, quality: 0.5),
        "an index past the end of either lever clamps to the last value that exists"
    )
    expect(
        StreamFidelityLadder.level(scaleStepsBelowRequested: -3, frameRateIndex: -3, qualityIndex: -3)
            == level(fps: 60, quality: 1.0),
        "a negative index clamps to the full picture"
    )
}

func testStreamFidelityPressureNamesTheStageThatCannotKeepUp() {
    /// One tick on its own: no history behind it, which is what every rule
    /// needing several ticks in a row must refuse to act on.
    func classify(_ observation: StreamFidelityObservation, fps: Int = 60) -> StreamFidelityPressure {
        var history = StreamFidelityPressure.History()
        return StreamFidelityPressure.classify(observation, appliedFramesPerSecond: fps, history: &history)
    }
    /// The same tick `times` times in a row, reporting what the last one
    /// decides once the ones before it are in the history.
    func classifyRepeated(
        _ observation: StreamFidelityObservation,
        times: Int,
        fps: Int = 60
    ) -> StreamFidelityPressure {
        var history = StreamFidelityPressure.History()
        var pressure = StreamFidelityPressure.none
        for _ in 0..<times {
            pressure = StreamFidelityPressure.classify(
                observation,
                appliedFramesPerSecond: fps,
                history: &history
            )
        }
        return pressure
    }
    func withViewer(_ viewer: StreamFidelityViewerObservation) -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            producedBitsPerSecond: 10_000_000,
            sentBitsPerSecond: 10_000_000,
            viewer: viewer
        )
    }

    expect(
        EncodeSustainabilityPolicy.frameBudgetNanoseconds(framesPerSecond: 60) == 16_666_666,
        "one frame period at 60fps is 16.7ms"
    )
    expect(classify(healthyObservation()) == .none, "a pipeline inside every budget is not pressured")

    expect(
        classify(StreamFidelityObservation(
            capturedDelta: 60,
            encodeP50Nanoseconds: 15_500_000,
            encodeSampleCount: EncodeSustainabilityPolicy.minimumSampleCount
        )) == .encoder,
        "a median encode past 90% of the frame period is the encoder, on the first tick that shows it"
    )
    expect(
        classify(StreamFidelityObservation(
            capturedDelta: 60,
            encodeP50Nanoseconds: 15_500_000,
            encodeSampleCount: EncodeSustainabilityPolicy.minimumSampleCount - 1
        )) == .none,
        "a median from fewer samples than the sustainability minimum decides nothing"
    )
    expect(
        classify(StreamFidelityObservation(
            capturedDelta: 60,
            encodeP50Nanoseconds: 13_600_000,
            encodeSampleCount: 60
        )) == .none,
        "a median encode inside 90% of the frame period is a marginal 60fps, not a stage that is behind"
    )
    expect(
        classify(
            StreamFidelityObservation(
                capturedDelta: 60,
                encodeP50Nanoseconds: 15_500_000,
                encodeSampleCount: 60
            ),
            fps: 45
        ) == .none,
        "the same encode time is affordable once the frame rate has lengthened the period"
    )
    let admissionDropping = StreamFidelityObservation(
        capturedDelta: 60,
        encoderInputDroppedDelta: 2,
        globalAdmissionDroppedDelta: 2
    )
    expect(
        classify(admissionDropping) == .none,
        "one tick that lost four frames of sixty ahead of the encoder is a hiccup, not the encoder"
    )
    expect(
        classifyRepeated(admissionDropping, times: 2) == .encoder,
        "two ticks in a row past what the admission path may lose is the encoder"
    )
    expect(
        classifyRepeated(
            StreamFidelityObservation(capturedDelta: 60, encoderInputDroppedDelta: 3),
            times: 5
        ) == .none,
        "exactly five percent dropped is the limit, not yet past it, however long it lasts"
    )

    let sendQueueDropping = StreamFidelityObservation(
        capturedDelta: 60,
        sendQueueDroppedDelta: 1,
        producedBitsPerSecond: 10_000_000
    )
    expect(
        classify(sendQueueDropping) == .none,
        "a single encoded frame the transport could not take is an opening hiccup, not the link"
    )
    expect(
        classifyRepeated(sendQueueDropping, times: 2) == .link,
        "frames the transport could not take in two of the last three ticks is the link"
    )
    expect(
        classifyRepeated(
            StreamFidelityObservation(
                capturedDelta: 60,
                sendQueueDroppedDelta: 1,
                producedBitsPerSecond: 500_000
            ),
            times: 10
        ) == .none,
        "half a megabit a second is not a link that is full, however many frames the transport refused"
    )
    let receivingLess = withViewer(StreamFidelityViewerObservation(receivedBitsPerSecond: 6_000_000))
    expect(
        classifyRepeated(receivingLess, times: 2) == .none,
        "two ticks of a viewer receiving less than it should is not yet the link"
    )
    expect(
        classifyRepeated(receivingLess, times: 3) == .link,
        "three ticks in a row of a viewer receiving less than seventy percent of what was produced is the link"
    )
    expect(
        classifyRepeated(
            StreamFidelityObservation(
                capturedDelta: 60,
                producedBitsPerSecond: 1_000_000,
                viewer: StreamFidelityViewerObservation(receivedBitsPerSecond: 0)
            ),
            times: 10
        ) == .none,
        "a stream producing one megabit a second cannot be blaming a link for what it never asked of it"
    )
    expect(
        classifyRepeated(
            withViewer(StreamFidelityViewerObservation(receivedBitsPerSecond: 8_000_000)),
            times: 10
        ) == .none,
        "a viewer receiving nearly everything produced is not pressure"
    )

    let decodingSlowly = withViewer(StreamFidelityViewerObservation(decodeP95Nanoseconds: 15_000_000))
    expect(
        classifyRepeated(decodingSlowly, times: 2) == .none,
        "two ticks of slow decoding are not yet the viewer"
    )
    expect(
        classifyRepeated(decodingSlowly, times: 3) == .viewer,
        "three ticks in a row of a decode past 80% of the frame period is the viewer"
    )
    let presentingHalf = withViewer(StreamFidelityViewerObservation(
        presentedFramesPerSecond: 30,
        decodedFramesPerSecond: 60
    ))
    expect(
        classifyRepeated(presentingHalf, times: 2) == .none,
        "two ticks of a viewer presenting half of what it decoded are not yet the viewer"
    )
    expect(
        classifyRepeated(presentingHalf, times: 3) == .viewer,
        "three ticks in a row of a viewer presenting half of what it decoded is the viewer"
    )
    expect(
        classifyRepeated(
            withViewer(StreamFidelityViewerObservation(
                presentedFramesPerSecond: 4,
                decodedFramesPerSecond: 8
            )),
            times: 10
        ) == .none,
        "a viewer decoding a handful of frames a second has no frame rate worth a ratio"
    )
    expect(
        classifyRepeated(
            withViewer(StreamFidelityViewerObservation(
                presentedFramesPerSecond: 20,
                decodedFramesPerSecond: 20
            )),
            times: 10
        ) == .none,
        "a viewer presenting everything it decoded is fine however few frames that is"
    )

    let stillButAlarming = StreamFidelityObservation(
        capturedDelta: 1,
        encoderInputDroppedDelta: 60,
        globalAdmissionDroppedDelta: 60,
        sendQueueDroppedDelta: 60,
        encodeP50Nanoseconds: 900_000_000,
        encodeSampleCount: 600,
        producedBitsPerSecond: 10_000_000,
        viewer: StreamFidelityViewerObservation(
            decodeP95Nanoseconds: 900_000_000,
            presentedFramesPerSecond: 0,
            decodedFramesPerSecond: 60,
            receivedBitsPerSecond: 0
        )
    )
    expect(
        classifyRepeated(stillButAlarming, times: 10) == .none,
        "a still screen is never pressured, whatever the last frames before it cost"
    )
    expect(
        classifyRepeated(
            StreamFidelityObservation(capturedDelta: 0, encoderInputDroppedDelta: 9),
            times: 10
        ) == .none,
        "a tick that captured nothing has no ratio to evaluate and reports no pressure"
    )
}

func testStreamFidelityPressurePrefersTheEarliestStageThatIsBehind() {
    /// Every rule below the encoder's own median needs several ticks in a
    /// row, so each scenario is held long enough for all of them to be true
    /// at once. Only then is the order they are reported in a real choice.
    func sustained(_ observation: StreamFidelityObservation) -> StreamFidelityPressure {
        var history = StreamFidelityPressure.History()
        var pressure = StreamFidelityPressure.none
        for _ in 0..<3 {
            pressure = StreamFidelityPressure.classify(
                observation,
                appliedFramesPerSecond: 60,
                history: &history
            )
        }
        return pressure
    }

    let strainedViewer = StreamFidelityViewerObservation(
        decodeP95Nanoseconds: 15_000_000,
        presentedFramesPerSecond: 10,
        decodedFramesPerSecond: 60,
        receivedBitsPerSecond: 1_000_000
    )
    let everythingBehind = StreamFidelityObservation(
        capturedDelta: 60,
        encoderInputDroppedDelta: 6,
        sendQueueDroppedDelta: 4,
        encodeP50Nanoseconds: 15_500_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000,
        viewer: strainedViewer
    )
    expect(
        sustained(everythingBehind) == .encoder,
        "an encoder that is behind is named before the stages downstream of it"
    )

    let linkAndViewerBehind = StreamFidelityObservation(
        capturedDelta: 60,
        sendQueueDroppedDelta: 4,
        producedBitsPerSecond: 10_000_000,
        viewer: strainedViewer
    )
    expect(
        sustained(linkAndViewerBehind) == .link,
        "a link that is behind is named before the viewer it is starving"
    )

    let viewerBehind = StreamFidelityObservation(
        capturedDelta: 60,
        producedBitsPerSecond: 10_000_000,
        viewer: StreamFidelityViewerObservation(
            decodeP95Nanoseconds: 15_000_000,
            presentedFramesPerSecond: 10,
            decodedFramesPerSecond: 60,
            receivedBitsPerSecond: 9_900_000
        )
    )
    expect(
        sustained(viewerBehind) == .viewer,
        "a viewer that cannot keep up with what arrived intact is the viewer"
    )
}


/// A screen with moving parts on a host whose encoder costs 24ms a frame at
/// the scale it is streaming: 1.44 seconds of encode for every second of 60
/// captured frames, which is why the viewer cannot keep up.
private func videoObservation(
    encodeP50Nanoseconds: Int64 = 24_000_000,
    capturedDelta: Int = 60
) -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: capturedDelta,
        encodedDelta: capturedDelta,
        encodeP50Nanoseconds: encodeP50Nanoseconds,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000,
        tickDurationNanoseconds: 1_000_000_000
    )
}

func testStreamFidelityChoosesTheResolutionThatHoldsSixtyFramesASecond() {
    var controller = StreamFidelityController(requestedScale: 1.75)
    warmUp(&controller)

    // Predicted cost is the measured median times the square of the scale
    // ratio: 1.75x costs 1.44 of a second, 1.50x costs 1.06, and 1.25x costs
    // 0.73, which is the first that fits inside the 0.8 a climb asks for.
    expect(
        controller.observe(videoObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 60, scaleSteps: 2), reason: .encoder),
        "the encoder's measured cost names the resolution that holds 60 fps, and the surface goes there in one move"
    )
    expect(
        controller.currentLevel.streamScale(requestedScale: 1.75) == 1.25,
        "which is 1.25x, got \(controller.currentLevel.streamScale(requestedScale: 1.75))x"
    )
    expect(
        controller.currentLevel.framesPerSecond == 60 && controller.currentLevel.qualityScale == 1.0,
        "the frame rate and the quality are what the resolution was spent to protect"
    )
    expect(controller.limitReason == .encoder, "and the viewer is told which stage took the resolution")

    // The screen stops moving. Nothing is captured, so nothing is encoded,
    // and every scale is affordable again.
    expect(
        controller.observe(stillTickObservation(), atSeconds: 1) == .hold,
        "one still tick is not yet a screen that has stopped"
    )
    expect(
        controller.observe(stillTickObservation(), atSeconds: 2)
            == .stepUp(to: level(fps: 60, scaleSteps: 0)),
        "two still ticks return the picture to exactly the scale the viewer asked for"
    )
    expect(
        controller.currentLevel.streamScale(requestedScale: 1.75) == 1.75,
        "got \(controller.currentLevel.streamScale(requestedScale: 1.75))x"
    )
    expect(controller.limitReason == nil, "nothing is holding a still screen back")
}

func testStreamFidelityHoldsTheRequestedScaleOnAQuietCodingScreen() {
    /// A screen someone is reading and typing on: ten changed frames a
    /// second, each costing 30ms to encode. That is 0.3 of a second of
    /// encode per second, and nothing about it says the picture has to get
    /// smaller.
    let coding = StreamFidelityObservation(
        capturedDelta: 10,
        encodedDelta: 10,
        encodeP50Nanoseconds: 30_000_000,
        encodeSampleCount: 10,
        producedBitsPerSecond: 2_000_000,
        tickDurationNanoseconds: 1_000_000_000
    )

    var controller = StreamFidelityController(requestedScale: 1.75)
    warmUp(&controller)
    for second in 0...20 {
        expect(
            controller.observe(coding, atSeconds: Double(second)) == .hold,
            "a screen producing ten frames a second leaves the encoder idle most of the tick, at second \(second)"
        )
    }
    expect(
        controller.currentLevel.streamScale(requestedScale: 1.75) == 1.75,
        "so it keeps the resolution the viewer asked for, got \(controller.currentLevel.streamScale(requestedScale: 1.75))x"
    )
    expect(
        controller.currentLevel.framesPerSecond == 60,
        "and the full frame rate, ready for the moment something moves"
    )
    expect(controller.limitReason == nil, "nothing is being held back")
}

func testStreamFidelitySpendsResolutionBeforeTheFrameRateAndQuality() {
    var controller = StreamFidelityController(requestedScale: 2.0)
    warmUp(&controller)

    // 45ms a frame at 2.00x is affordable at no scale this ladder has, so
    // the resolution goes straight to its floor rather than a step at a time.
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 60, scaleSteps: 4), reason: .encoder),
        "resolution is the first lever, and the cost model names how much of it to spend"
    )
    expect(
        controller.currentLevel.streamScale(requestedScale: 2.0) == StreamScalePolicy.minimumScale,
        "which is the minimum scale"
    )

    let spent: [StreamFidelityLevel] = [
        level(fps: 45, scaleSteps: 4),
        level(fps: 30, scaleSteps: 4),
        level(fps: 30, quality: 0.75, scaleSteps: 4),
        level(fps: 30, quality: 0.5, scaleSteps: 4),
        level(fps: 20, quality: 0.5, scaleSteps: 4)
    ]
    var now = 2.0
    for expected in spent {
        expect(
            controller.observe(encoderPressuredObservation(), atSeconds: now)
                == .stepDown(to: expected, reason: .encoder),
            "with the resolution already at its floor the cheap levers move, expected \(expected)"
        )
        now += 2
    }
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: now) == .hold,
        "and there is nothing left to spend"
    )
}

func testStreamFidelityStepsDownAfterOnePressuredTickAndBackUpAfterTwo() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    expect(
        controller.currentLevel == level(fps: 60),
        "a new surface streams exactly what the viewer asked for"
    )
    expect(controller.limitReason == nil, "nothing limits a surface that has never stepped down")
    warmUp(&controller)

    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "one pressured tick is acted on: waiting a second one is a second of frames nobody can watch"
    )
    expect(
        controller.limitReason == .encoder,
        "the surface remembers which stage took the frame rate, so the viewer can be told"
    )
    expect(
        controller.observe(healthyObservation(), atSeconds: 1) == .hold,
        "one unpressured tick is not yet a trend, and nothing changes inside two seconds anyway"
    )
    expect(
        controller.observe(healthyObservation(), atSeconds: 2) == .stepUp(to: level(fps: 60)),
        "two consecutive unpressured ticks take the frame rate back"
    )
    expect(controller.limitReason == nil, "nothing limits a surface streaming what was asked for")
}

func testStreamFidelityAppliesAtMostOneChangeEveryTwoSeconds() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the first pressured tick steps down"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0.5) == .hold,
        "the tick right after a change is never a second change"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 1.5) == .hold,
        "more pressured ticks still wait while the last change is under two seconds old"
    )
    expect(
        controller.currentLevel.framesPerSecond == 45,
        "the held-back step did not move the picture anyway"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 2.0)
            == .stepDown(to: level(fps: 30), reason: .encoder),
        "the step goes through as soon as two seconds have passed"
    )
}

func testStreamFidelityLiftsQualityOnAStillScreenAndAsksForAKeyFrame() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the surface gives up the first of its frame rate"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 2)
            == .stepDown(to: level(fps: 30), reason: .encoder),
        "and the rest of what the frame rate is allowed to lose"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 4)
            == .stepDown(to: level(fps: 30, quality: 0.75), reason: .encoder),
        "and then reaches the first softer picture"
    )

    expect(
        controller.observe(stillObservation(), atSeconds: 6) == .hold,
        "one still tick is not yet a still screen"
    )
    let lift = controller.observe(stillObservation(), atSeconds: 7)
    expect(
        lift == .liftQuality(to: level(fps: 30, quality: 1.0)),
        "two still ticks sharpen the picture without moving either lever"
    )
    expect(lift.requestsKeyFrame, "a sharper picture is only visible once a whole frame is coded at the new quality")
    expect(!StreamFidelityDecision.hold.requestsKeyFrame, "no other decision asks for a key frame")
    expect(
        controller.currentLevel.qualityScale == 1.0 && controller.currentLevel.framesPerSecond == 30,
        "quality is back to full while the screen is still, and the frame rate stays where it was put"
    )
    expect(
        controller.observe(stillObservation(), atSeconds: 8) == .hold,
        "quality is lifted once, not on every still tick"
    )

    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 9)
            == .stepDown(to: level(fps: 30, quality: 0.5), reason: .encoder),
        "pressure after the still screen steps down as usual"
    )
    expect(
        controller.currentLevel.qualityScale == 0.5,
        "the lift ends with the step down and the quality the lever chose applies again"
    )
}

func testStreamFidelityHoldsOffALeverAProbeFailedIntoForLongerEachTime() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    var now = 0.0
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: now)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the surface gives up the frame rate"
    )
    now += 1

    var holdOffSeconds: [Double] = []
    var lastFailureSeconds: Double?
    for _ in 0..<5 {
        var recoveredAt: Double?
        let giveUpAt = now + 400
        while recoveredAt == nil && now < giveUpAt {
            if controller.observe(healthyObservation(), atSeconds: now) == .stepUp(to: level(fps: 60)) {
                recoveredAt = now
            }
            now += 1
        }
        guard let recoveredAt else {
            expect(false, "a surface always gets the frame rate back once the hold-off expires")
            return
        }
        if let lastFailureSeconds {
            holdOffSeconds.append(recoveredAt - lastFailureSeconds)
        }
        expect(
            controller.observe(encoderPressuredObservation(), atSeconds: now)
                == .stepDown(to: level(fps: 45), reason: .encoder),
            "pressure while a lever is on probation gives it straight back, without the anti-thrash delay"
        )
        lastFailureSeconds = now
        now += 1
    }
    expect(
        holdOffSeconds == [60, 120, 240, 300],
        "each failed probe holds the lever off for twice as long as the last, capped at five minutes, "
            + "got \(holdOffSeconds)"
    )
}

func testStreamFidelityClearedCeilingsReopenALeverAndForgetItsHoldOff() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the surface gives up the frame rate"
    )
    expect(controller.observe(healthyObservation(), atSeconds: 1) == .hold, "one unpressured tick is not a trend")
    expect(
        controller.observe(healthyObservation(), atSeconds: 2) == .stepUp(to: level(fps: 60)),
        "two unpressured ticks take it back"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 3)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the probe fails and the frame rate is held off"
    )

    for tick in 4...30 {
        expect(
            controller.observe(healthyObservation(), atSeconds: Double(tick)) == .hold,
            "unpressured ticks alone do not reopen a lever that is held off, at second \(tick)"
        )
    }
    controller.clearCeilings()
    expect(
        controller.observe(healthyObservation(), atSeconds: 31) == .stepUp(to: level(fps: 60)),
        "clearing the hold-offs reopens the lever at once"
    )
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 32)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the reopened lever fails its probe again"
    )
    var now = 33.0
    var recoveredAt: Double?
    while recoveredAt == nil && now < 300 {
        if controller.observe(healthyObservation(), atSeconds: now) == .stepUp(to: level(fps: 60)) {
            recoveredAt = now
        }
        now += 1
    }
    expect(
        recoveredAt == 92,
        "the hold-off starts again at its first length, because clearing forgot the earlier failures, "
            + "got \(String(describing: recoveredAt))"
    )
}

func testStreamFidelityLowersQualityFirstForALinkAndNeedsViewerEvidenceToRaiseIt() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    let congested = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        sendQueueDroppedDelta: 4,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000
    )
    expect(
        controller.observe(congested, atSeconds: 0) == .hold,
        "one tick of frames the transport refused is not yet the link"
    )
    expect(
        controller.observe(congested, atSeconds: 1)
            == .stepDown(to: level(fps: 60, quality: 0.75), reason: .link),
        "a link short of bits gets smaller frames, which costs no motion at all"
    )
    expect(
        controller.currentLevel.framesPerSecond == 60,
        "the frame rate is untouched: it is not what a link is short of"
    )
    expect(controller.limitReason == .link, "and the viewer is told the link is what took it")

    for tick in 2...20 {
        expect(
            controller.observe(healthyObservation(), atSeconds: Double(tick)) == .hold,
            "a host that looks healthy is not evidence that the link recovered, at second \(tick)"
        )
    }
    let healthyViewer = StreamFidelityViewerObservation(
        decodeP95Nanoseconds: 4_000_000,
        presentedFramesPerSecond: 45,
        decodedFramesPerSecond: 45,
        receivedBitsPerSecond: 9_800_000
    )
    expect(
        controller.observe(healthyObservation(viewer: healthyViewer), atSeconds: 21)
            == .stepUp(to: level(fps: 60)),
        "the viewer's own report is what raises a picture the link softened"
    )
    expect(controller.limitReason == nil, "nothing is holding the picture back any more")
}

func testStreamFidelityIgnoresTheOpeningBurstAndTheOneAfterEveryRebuild() {
    expect(
        StreamFidelityController.warmUpTicks == 3,
        "a session start and a rebuild each get three ticks before anything they report is acted on"
    )
    var controller = StreamFidelityController(requestedScale: 1.0)
    // What a real pipeline reports as it starts: the frames capture outran
    // before the encoder was going, the frames the transport could not take
    // while the connection settled, and an opening median dominated by the
    // key frame none of it will cost again.
    let openingBurst = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 27,
        encoderInputDroppedDelta: 14,
        sendQueueDroppedDelta: 33,
        encodeP50Nanoseconds: 45_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000
    )
    for tick in 0..<StreamFidelityController.warmUpTicks {
        expect(
            controller.observe(openingBurst, atSeconds: Double(tick)) == .hold,
            "a pipeline that has just started is not measured by what its first frames cost"
        )
    }
    expect(controller.currentLevel == level(fps: 60), "the opening burst costs nothing at all")

    expect(
        controller.observe(openingBurst, atSeconds: 3)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "evidence that outlives the warm-up is acted on exactly as any other would be"
    )

    controller.beginWarmUp()
    for tick in 4..<(4 + StreamFidelityController.warmUpTicks) {
        expect(
            controller.observe(openingBurst, atSeconds: Double(tick)) == .hold,
            "a rebuilt pipeline is warmed up again: its first frames are the new configuration's key frame, not its cost"
        )
    }
    expect(
        controller.currentLevel == level(fps: 45),
        "nothing is given up on evidence measured while a pipeline was still warming up"
    )
}

func testStreamFidelityReplaysTheRecordedWiFiRunAndSettlesOneStepDown() {
    /// A one-second slice of a measured local run: a surface capturing 60
    /// frames, producing well under a megabit a second of them, and
    /// encoding at whatever the resolution costs.
    func tick(
        sendQueueDropped: Int = 0,
        encoderInputDropped: Int = 0,
        encodeP50Nanoseconds: Int64,
        producedBitsPerSecond: Double
    ) -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60 - encoderInputDropped,
            encoderInputDroppedDelta: encoderInputDropped,
            sendQueueDroppedDelta: sendQueueDropped,
            encodeP50Nanoseconds: encodeP50Nanoseconds,
            encodeSampleCount: 60,
            producedBitsPerSecond: producedBitsPerSecond
        )
    }
    /// What the run actually measured once it was going: a median encode of
    /// 13.6ms, inside what 60fps affords, and a stream of half to one
    /// megabit a second.
    func recordedTick(atSeconds seconds: Int) -> StreamFidelityObservation {
        tick(
            encodeP50Nanoseconds: 13_600_000,
            producedBitsPerSecond: seconds.isMultiple(of: 2) ? 500_000 : 1_100_000
        )
    }

    var asRecorded = StreamFidelityController(requestedScale: 1.0)
    _ = asRecorded.observe(
        tick(
            sendQueueDropped: 33,
            encoderInputDropped: 14,
            encodeP50Nanoseconds: 13_600_000,
            producedBitsPerSecond: 1_100_000
        ),
        atSeconds: 0
    )
    for second in 1...60 {
        _ = asRecorded.observe(recordedTick(atSeconds: second), atSeconds: Double(second))
    }
    expect(
        asRecorded.currentLevel == level(fps: 60) && asRecorded.limitReason == nil,
        "the recorded run gives up nothing: an opening burst of refused frames is not a congested link, "
            + "and a stream of half a megabit a second never asked enough of one to find out"
    )

    // The same run on a display where 60fps is genuinely marginal: 16.0ms is
    // past what a 16.7ms frame period affords and inside what 45fps does.
    // The viewer is already asking for the minimum scale, so there is no
    // resolution to spend and the frame rate is what answers it.
    var controller = StreamFidelityController(requestedScale: 1.0)
    let marginalEncode: Int64 = 16_000_000
    _ = controller.observe(
        tick(
            sendQueueDropped: 33,
            encoderInputDropped: 14,
            encodeP50Nanoseconds: marginalEncode,
            producedBitsPerSecond: 1_100_000
        ),
        atSeconds: 0
    )
    for second in 1...2 {
        _ = controller.observe(
            tick(encodeP50Nanoseconds: marginalEncode, producedBitsPerSecond: 1_100_000),
            atSeconds: Double(second)
        )
    }
    expect(
        controller.observe(
            tick(encodeP50Nanoseconds: marginalEncode, producedBitsPerSecond: 1_100_000),
            atSeconds: 3
        ) == .stepDown(to: level(fps: 45), reason: .encoder),
        "a median encode past what 60fps affords costs exactly the frame rate, and names the encoder"
    )

    var stepUps = 0
    for second in 4...60 {
        if case .stepUp = controller.observe(
            tick(encodeP50Nanoseconds: marginalEncode, producedBitsPerSecond: 1_100_000),
            atSeconds: Double(second)
        ) {
            stepUps += 1
        }
    }
    expect(
        controller.currentLevel == level(fps: 45),
        "the run settles exactly one step down: the encode that does not fit 60fps fits 45, and nothing else is behind"
    )
    expect(
        controller.limitReason == .encoder,
        "the viewer is told the encoder is what it is limited by, not the link it never filled"
    )
    expect(
        stepUps == 0,
        "the frame rate is not probed for while the encode that refused it is what the surface is still measuring"
    )

    // The median the run actually recorded, 13.6ms, is inside what 60fps
    // affords but not inside it with room to spare, and nothing is climbed
    // back into without room to spare.
    for second in 61...180 {
        _ = controller.observe(
            tick(encodeP50Nanoseconds: 13_600_000, producedBitsPerSecond: 1_100_000),
            atSeconds: Double(second)
        )
    }
    expect(
        controller.currentLevel == level(fps: 45),
        "a median that only just fits the faster frame period is not enough to go back to it"
    )

    var recoveredAt: Double?
    for second in 181...300 {
        let decision = controller.observe(
            tick(encodeP50Nanoseconds: 12_000_000, producedBitsPerSecond: 1_100_000),
            atSeconds: Double(second)
        )
        if decision == .stepUp(to: level(fps: 60)), recoveredAt == nil {
            recoveredAt = Double(second)
        }
    }
    expect(recoveredAt != nil, "a median encode with real room inside a 60fps frame period takes the frame rate back")
    expect(
        controller.currentLevel == level(fps: 60),
        "and it stays there, because the number that refused the frame rate is the number that returned it"
    )
}

func testStreamFidelityWillNotClimbBackIntoAFrameRateTheEncoderCannotAfford() {
    /// A tick whose only interesting number is what the median encode cost.
    func encoding(_ nanoseconds: Int64) -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60,
            encodeP50Nanoseconds: nanoseconds,
            encodeSampleCount: 60,
            producedBitsPerSecond: 10_000_000
        )
    }

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the surface gives up the frame rate to the encoder"
    )

    // 15.0ms is 90% of a 60fps frame period and two thirds of a 45fps one:
    // comfortable where the surface now is, and exactly the cost that put it
    // there. Nothing about a frame rate being met is evidence about the one
    // above it.
    for tick in 1...60 {
        expect(
            controller.observe(encoding(15_000_000), atSeconds: Double(tick)) == .hold,
            "an encode that only fits the frame rate it is on never takes the one above it back, tick \(tick)"
        )
    }
    expect(controller.currentLevel == level(fps: 45), "the surface is still one step down after a minute of it")
    expect(controller.limitReason == .encoder, "and still reports the stage holding it there")

    expect(
        controller.observe(encoding(12_500_000), atSeconds: 61) == .stepUp(to: level(fps: 60)),
        "an encode with room to spare inside the faster frame period is what takes it back"
    )
    for tick in 62...70 {
        expect(
            controller.observe(encoding(12_500_000), atSeconds: Double(tick)) == .hold,
            "and stays there: the margin it cleared is what makes the probe survive its probation"
        )
    }
    expect(controller.currentLevel == level(fps: 60), "nothing hands it back on evidence that never got worse")

    var unmeasured = StreamFidelityController(requestedScale: 1.0)
    warmUp(&unmeasured)
    _ = unmeasured.observe(encoderPressuredObservation(), atSeconds: 0)
    for tick in 1...30 {
        _ = unmeasured.observe(
            StreamFidelityObservation(capturedDelta: 60, encodedDelta: 60, producedBitsPerSecond: 10_000_000),
            atSeconds: Double(tick)
        )
    }
    expect(
        unmeasured.currentLevel == level(fps: 45),
        "a tick that measured no encode at all holds where it is: unmeasured is not the same as affordable"
    )
}

func testStreamFidelityReadsEveryDropCounterAsThisTicksOwn() {
    /// The frames and bitrates one host log recorded, line by line, on a
    /// 1920x1200 canvas streamed at 1.50x: a burst of frames refused while
    /// the pipeline filled for the first time, then a busy screen, then a
    /// screen that went quiet. `droppedTotal` is the running count the host
    /// keeps for the life of the stream, which is what the counters a tick
    /// reads are: the drops of this tick alone are the difference between
    /// two of them.
    let recorded: [(captured: Int, droppedTotal: Int, producedBitsPerSecond: Double)] = [
        (100, 20, 730_000),
        (148, 21, 770_000),
        (184, 21, 2_270_000),
        (4, 21, 320_000),
        (1, 21, 20_000)
    ]
    func tick(
        captured: Int,
        dropped: Int,
        producedBitsPerSecond: Double
    ) -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: captured,
            encodedDelta: captured - dropped,
            encoderInputDroppedDelta: dropped,
            encodeP50Nanoseconds: 13_600_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: producedBitsPerSecond
        )
    }

    var controller = StreamFidelityController(requestedScale: 2.0)
    warmUp(&controller)
    var previousTotal = 0
    for (index, line) in recorded.enumerated() {
        _ = controller.observe(
            tick(
                captured: line.captured,
                dropped: line.droppedTotal - previousTotal,
                producedBitsPerSecond: line.producedBitsPerSecond
            ),
            atSeconds: Double(index)
        )
        previousTotal = line.droppedTotal
    }
    expect(
        controller.currentLevel == level(fps: 60) && controller.limitReason == nil,
        "an opening burst of refused frames is one bad tick, not a pipeline that cannot keep up, "
            + "so the run gives up nothing, got \(controller.currentLevel)"
    )

    // The same recorded run with every tick told the whole session's drop
    // total instead of its own. The counters never come back down, so the
    // burst of the first seconds is still being charged to every tick minutes
    // later, and the quiet ticks the resolution is taken back on can never
    // happen.
    var readAsTotals = StreamFidelityController(requestedScale: 2.0)
    warmUp(&readAsTotals)
    for (index, line) in recorded.enumerated() {
        _ = readAsTotals.observe(
            tick(
                captured: line.captured,
                dropped: line.droppedTotal,
                producedBitsPerSecond: line.producedBitsPerSecond
            ),
            atSeconds: Double(index)
        )
    }
    expect(
        readAsTotals.currentLevel.scaleStepsBelowRequested > 0,
        "the same run read cumulatively makes the picture smaller when it never needed to, "
            + "which is what the delta above exists to prevent"
    )

    // Nothing else is behind, and the screen has gone quiet.
    for second in 5...20 {
        _ = controller.observe(
            tick(captured: 60, dropped: 0, producedBitsPerSecond: 730_000),
            atSeconds: Double(second)
        )
    }
    expect(
        controller.currentLevel == level(fps: 60),
        "and it stays at the picture the viewer asked for, got \(controller.currentLevel)"
    )
}

func testStreamFidelityRefreshesTheStillPictureOncePerStillPeriod() {
    func movingTick() -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60,
            encodeP50Nanoseconds: 5_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 10_000_000
        )
    }

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(controller.observe(stillTickObservation(), atSeconds: 0) == .hold, "one still tick is not yet a still screen")
    expect(
        controller.observe(stillTickObservation(), atSeconds: 1) == .refreshStill,
        "the last picture sent was a delta encoded for a moving screen, so a still screen is sent one good frame"
    )
    for second in 2...8 {
        expect(
            controller.observe(stillTickObservation(), atSeconds: Double(second)) != .refreshStill,
            "the picture is refreshed once, not on every tick of a screen that stays still"
        )
    }

    // The screen moves and goes quiet again: that is a new still picture, and
    // it gets its own refresh.
    _ = controller.observe(movingTick(), atSeconds: 9)
    expect(controller.observe(stillTickObservation(), atSeconds: 10) == .hold, "one still tick is not yet a still screen")
    expect(
        controller.observe(stillTickObservation(), atSeconds: 11) == .refreshStill,
        "a screen that moved and stopped again is a new picture to refresh"
    )
}

func testStreamFidelityTakesTheFrameRateBackOnAStillScreen() {
    /// The recorded run's own numbers: a median encode of 16.0ms, past what a
    /// 16.7ms frame period affords and inside what 45fps does.
    func recordedTick() -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60,
            encodeP50Nanoseconds: 16_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 1_100_000
        )
    }

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    for second in 0...20 {
        _ = controller.observe(recordedTick(), atSeconds: Double(second))
    }
    expect(
        controller.currentLevel == level(fps: 45) && controller.limitReason == .encoder,
        "the recorded run settles one step down, held there by the encoder"
    )

    for second in 21...28 {
        _ = controller.observe(stillTickObservation(), atSeconds: Double(second))
    }
    expect(
        controller.currentLevel == level(fps: 60),
        "a screen nobody is changing costs the encoder nothing, so the frame rate it gave up comes back, "
            + "got \(controller.currentLevel.framesPerSecond) fps"
    )
    expect(
        controller.limitReason == nil,
        "and the viewer is told nothing is holding the picture back any more"
    )
}

func testStreamFidelityGivesBackWhatAStillScreenBoughtWhenItMovesAgain() {
    /// The recorded run's own numbers: a median encode of 16.0ms, past what a
    /// 16.7ms frame period affords and inside what 45fps does.
    func recordedTick() -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60,
            encodeP50Nanoseconds: 16_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 1_100_000
        )
    }

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    for second in 0...20 {
        _ = controller.observe(recordedTick(), atSeconds: Double(second))
    }
    expect(
        controller.currentLevel == level(fps: 45),
        "the recorded run settles one step down, got \(controller.currentLevel)"
    )

    for second in 21...50 {
        _ = controller.observe(stillTickObservation(), atSeconds: Double(second))
    }
    expect(
        controller.currentLevel == level(fps: 60),
        "stillness takes the frame rate back, got \(controller.currentLevel)"
    )

    expect(
        controller.observe(recordedTick(), atSeconds: 51)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the first tick of a screen moving again gives back what stillness bought"
    )
    expect(
        controller.limitReason == .encoder,
        "landing exactly where the moving screen last proved it could run, got \(controller.currentLevel.framesPerSecond) fps"
    )

    // And it stays there: the encode this run measures is affordable at 45fps
    // and not at 60, so nothing climbs back to be given up again.
    for second in 52...70 {
        expect(
            controller.observe(recordedTick(), atSeconds: Double(second)) == .hold,
            "what the moving screen can afford is held, with no climb-and-fall cycle, at second \(second)"
        )
    }
}

func testStreamFidelityRefreshesTheStillPictureAgainAfterARebuild() {
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    _ = controller.observe(stillTickObservation(), atSeconds: 0)
    expect(
        controller.observe(stillTickObservation(), atSeconds: 1) == .refreshStill,
        "a still screen is sent one good frame of the picture it is holding"
    )
    expect(
        controller.observe(stillTickObservation(), atSeconds: 2) != .refreshStill,
        "and only one, while the picture stays the same"
    )

    // The pipeline is rebuilt, which is how every resolution change is
    // applied: the picture the viewer is holding was encoded by an encoder
    // that no longer exists, so the refreshed frame has to be sent again.
    controller.beginWarmUp()
    for second in 3...5 {
        expect(
            controller.observe(stillTickObservation(), atSeconds: Double(second)) == .hold,
            "a rebuild's warm-up decides nothing, at second \(second)"
        )
    }
    _ = controller.observe(stillTickObservation(), atSeconds: 6)
    expect(
        controller.observe(stillTickObservation(), atSeconds: 7) == .refreshStill,
        "the screen is still and the picture it is holding came from a pipeline that is gone, so it is sent again"
    )
}

func testStreamFidelityJudgesTheLinkOnWhatWasSentRatherThanWhatWasEncoded() {
    /// A surface whose encoder is producing more than the transport is
    /// carrying: the difference is frames the send queue dropped before they
    /// reached the wire.
    func dropping(receivedBitsPerSecond: Double) -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 60,
            encodeP50Nanoseconds: 5_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 10_000_000,
            sentBitsPerSecond: 3_000_000,
            viewer: StreamFidelityViewerObservation(receivedBitsPerSecond: receivedBitsPerSecond)
        )
    }
    func sustained(_ observation: StreamFidelityObservation, times: Int) -> StreamFidelityPressure {
        var history = StreamFidelityPressure.History()
        var pressure = StreamFidelityPressure.none
        for _ in 0..<times {
            pressure = StreamFidelityPressure.classify(
                observation,
                appliedFramesPerSecond: 60,
                history: &history
            )
        }
        return pressure
    }

    expect(
        sustained(dropping(receivedBitsPerSecond: 2_900_000), times: 5) == .none,
        "a viewer receiving what the transport actually sent is not a starved link, however much more the "
            + "encoder produced and the send queue then discarded"
    )
    expect(
        sustained(dropping(receivedBitsPerSecond: 1_000_000), times: 3) == .link,
        "a viewer receiving well under what was actually sent is still the link"
    )
    expect(
        sustained(
            StreamFidelityObservation(
                capturedDelta: 60,
                producedBitsPerSecond: 10_000_000,
                viewer: StreamFidelityViewerObservation(receivedBitsPerSecond: 0)
            ),
            times: 5
        ) == .none,
        "a tick with no send accounting behind it offers no ratio at all, rather than one measured against "
            + "bytes that may never have left this machine"
    )

    // A surface the link softened climbs back out on the viewer's own report,
    // which is what the self-locking accounting made unreachable: the viewer
    // was compared against bits the send queue had already discarded, so
    // every tick read as a starved link and no tick could ever raise the
    // picture it had taken.
    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    let congested = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        sendQueueDroppedDelta: 4,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000,
        sentBitsPerSecond: 2_000_000
    )
    _ = controller.observe(congested, atSeconds: 0)
    expect(
        controller.observe(congested, atSeconds: 1)
            == .stepDown(to: level(fps: 60, quality: 0.75), reason: .link),
        "frames the transport could not take, tick after tick, soften the picture for the link"
    )

    // What the recorded run looked like once the drops started: an encoder
    // producing far more than the link carried, and a viewer receiving every
    // bit that actually made it onto the wire.
    let carryingWhatItSends = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000,
        sentBitsPerSecond: 2_000_000,
        viewer: StreamFidelityViewerObservation(
            decodeP95Nanoseconds: 4_000_000,
            presentedFramesPerSecond: 45,
            decodedFramesPerSecond: 45,
            receivedBitsPerSecond: 1_980_000
        )
    )
    var climbedAt: Double?
    for second in 2...40 {
        if controller.observe(carryingWhatItSends, atSeconds: Double(second)) == .stepUp(to: level(fps: 60)),
           climbedAt == nil {
            climbedAt = Double(second)
        }
    }
    expect(
        climbedAt != nil,
        "a viewer receiving what was sent is the evidence that raises a picture the link took, and the surface "
            + "is no longer locked below it for as long as the session lasts"
    )
    expect(controller.currentLevel == level(fps: 60), "the surface is back at what the viewer asked for")
}

func testStreamFidelityHoldsOffALeverThatFailsAfterItsProbation() {
    let congested = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        sendQueueDroppedDelta: 4,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000
    )
    let healthyViewer = StreamFidelityViewerObservation(
        decodeP95Nanoseconds: 4_000_000,
        presentedFramesPerSecond: 20,
        decodedFramesPerSecond: 20,
        receivedBitsPerSecond: 9_800_000
    )
    let deepest = level(fps: 20, quality: 0.5)
    let oneAbove = level(fps: 30, quality: 0.5)

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    var now = 0.0
    while controller.currentLevel != deepest && now < 200 {
        _ = controller.observe(congested, atSeconds: now)
        now += 1
    }
    expect(
        controller.currentLevel == deepest,
        "a link that keeps refusing frames spends every lever there is, got \(controller.currentLevel)"
    )

    var holdOffSeconds: [Double] = []
    var lastFailureSeconds: Double?
    for _ in 0..<5 {
        var recoveredAt: Double?
        let giveUpAt = now + 500
        while recoveredAt == nil && now < giveUpAt {
            if controller.observe(healthyObservation(viewer: healthyViewer), atSeconds: now)
                == .stepUp(to: oneAbove) {
                recoveredAt = now
            }
            now += 1
        }
        guard let recoveredAt else {
            expect(false, "a surface always gets a lever back once the hold-off expires")
            return
        }
        if let lastFailureSeconds {
            holdOffSeconds.append(recoveredAt - lastFailureSeconds)
        }
        // A pipeline rebuild lands between the probe and the evidence that
        // answers it, and warms the controller up again.
        controller.beginWarmUp()
        var failedAt: Double?
        while failedAt == nil && now < recoveredAt + 30 {
            if controller.observe(congested, atSeconds: now) == .stepDown(to: deepest, reason: .link) {
                failedAt = now
            }
            now += 1
        }
        guard let failedAt else {
            expect(false, "a link that is still refusing frames takes the lever back off the surface")
            return
        }
        expect(
            failedAt - recoveredAt >= StreamFidelityController.probationSeconds,
            "the rebuild outlasts probation, so the hold-off cannot be left to probation alone"
        )
        lastFailureSeconds = failedAt
    }
    expect(
        holdOffSeconds == [60, 120, 240, 300],
        "a lever that fails this soon after being taken back is held off for twice as long each time, "
            + "got \(holdOffSeconds)"
    )
}

/// A screen producing far fewer frames than the applied frame rate is idle
/// for most of each tick, so a median encode that would blow the nominal
/// frame period is not evidence the encoder is behind. There was hardly
/// anything to encode. The budget has to grow with the tick's own observed
/// capture period.
func testStreamFidelityEncoderPressureJudgesAgainstTheScreensOwnCaptureRate() {
    var quietHistory = StreamFidelityPressure.History()
    let tenFramesInOneSecond = StreamFidelityObservation(
        capturedDelta: 10,
        encodedDelta: 10,
        encodeP50Nanoseconds: 30_000_000,
        encodeSampleCount: 10,
        producedBitsPerSecond: 2_000_000,
        tickDurationNanoseconds: 1_000_000_000
    )
    expect(
        StreamFidelityPressure.classify(tenFramesInOneSecond, appliedFramesPerSecond: 60, history: &quietHistory) == .none,
        "10 captured frames over a full second leaves the encoder idle most of the tick; a 30ms median is not pressure"
    )

    var busyHistory = StreamFidelityPressure.History()
    let fiftyFiveFramesInOneSecond = StreamFidelityObservation(
        capturedDelta: 55,
        encodedDelta: 55,
        encodeP50Nanoseconds: 30_000_000,
        encodeSampleCount: 55,
        producedBitsPerSecond: 10_000_000,
        tickDurationNanoseconds: 1_000_000_000
    )
    expect(
        StreamFidelityPressure.classify(fiftyFiveFramesInOneSecond, appliedFramesPerSecond: 60, history: &busyHistory) == .encoder,
        "55 captured frames over the same second leaves almost no slack; the same 30ms median is the encoder"
    )
}

/// The mirror of the classifier rule, on the recovery side: a frame rate
/// given up to the encoder must be climbable once the screen's own observed
/// capture period, not just the target's nominal one, makes the median
/// encode affordable.
func testStreamFidelityClimbsBackIntoAFrameRateTheQuietScreenMakesAffordable() {
    func steadyEncoderPressure() -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 60,
            encodedDelta: 40,
            encodeP50Nanoseconds: 45_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 10_000_000
        )
    }
    // 15ms is 90% of the 16.67ms period 60fps asks for, never affordable
    // against that alone, but comfortably inside 80% of the 200ms a
    // five-frame-a-second tick actually took to produce its frames.
    func quietTick() -> StreamFidelityObservation {
        StreamFidelityObservation(
            capturedDelta: 5,
            encodedDelta: 5,
            encodeP50Nanoseconds: 15_000_000,
            encodeSampleCount: 60,
            producedBitsPerSecond: 2_000_000,
            tickDurationNanoseconds: 1_000_000_000
        )
    }

    var controller = StreamFidelityController(requestedScale: 1.0)
    warmUp(&controller)
    expect(
        controller.observe(steadyEncoderPressure(), atSeconds: 0)
            == .stepDown(to: level(fps: 45), reason: .encoder),
        "the surface gives up the frame rate to the encoder"
    )

    var tick = 1.0
    for _ in 0..<(StreamFidelityController.unpressuredTicksBeforeStepUp - 1) {
        expect(
            controller.observe(quietTick(), atSeconds: tick) == .hold,
            "not yet two unpressured ticks, at second \(tick)"
        )
        tick += 1
    }
    expect(
        controller.observe(quietTick(), atSeconds: tick) == .stepUp(to: level(fps: 60)),
        "the quiet screen's own 200ms capture period is what makes 15ms affordable at 60fps, "
            + "which the nominal 16.67ms period alone never would"
    )
}

/// A tick of a surface the encoder is keeping up with easily, on a link that
/// is delivering only part of what is put on the wire.
private func linkObservation(
    producedBitsPerSecond: Double,
    receivedBitsPerSecond: Double,
    capturedDelta: Int = 60
) -> StreamFidelityObservation {
    StreamFidelityObservation(
        capturedDelta: capturedDelta,
        encodedDelta: capturedDelta,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: producedBitsPerSecond,
        sentBitsPerSecond: producedBitsPerSecond,
        viewer: StreamFidelityViewerObservation(
            decodeP95Nanoseconds: 4_000_000,
            presentedFramesPerSecond: Double(capturedDelta),
            decodedFramesPerSecond: Double(capturedDelta),
            receivedBitsPerSecond: receivedBitsPerSecond
        ),
        tickDurationNanoseconds: 1_000_000_000
    )
}

/// A surface a starved link has already driven to the minimum scale: 16
/// Mbit/s on the wire, 6 Mbit/s arriving, for the three ticks the classifier
/// asks for. The last of those ticks is second 2.
private func linkStarvedController() -> StreamFidelityController {
    var controller = StreamFidelityController(requestedScale: 1.75)
    warmUp(&controller)
    let starved = linkObservation(producedBitsPerSecond: 16_000_000, receivedBitsPerSecond: 6_000_000)
    for tick in 0...2 {
        _ = controller.observe(starved, atSeconds: Double(tick))
    }
    return controller
}

func testStreamFidelityGivesResolutionUpToWhatTheLinkCanCarry() {
    var controller = StreamFidelityController(requestedScale: 1.75)
    warmUp(&controller)
    let starved = linkObservation(producedBitsPerSecond: 16_000_000, receivedBitsPerSecond: 6_000_000)
    for tick in 0...1 {
        expect(
            controller.observe(starved, atSeconds: Double(tick)) == .hold,
            "a link is named from several ticks running, not one, at second \(tick)"
        )
    }
    // 4.8 Mbit/s is what the viewer is receiving, less the room a budget
    // leaves. Bits go with pixels, so 16 Mbit/s at 1.75x predicts 11.8 at
    // 1.50x, 8.2 at 1.25x and 5.2 at 1.00x: none of them fit, and the
    // resolution goes to its floor in one move rather than four.
    expect(
        controller.observe(starved, atSeconds: 2)
            == .stepDown(to: level(fps: 60, scaleSteps: 3), reason: .link),
        "a starved link buys its room back in pixels first, and the budget names how many to give up"
    )
    expect(
        controller.currentLevel.framesPerSecond == 60 && controller.currentLevel.qualityScale == 1.0,
        "the motion and the sharpness are what the resolution was spent to protect"
    )
    expect(controller.limitReason == .link, "and the viewer is told the link is what took it")

    // The smaller picture costs 5.2 Mbit/s, which the link carries whole. The
    // budget rises by a tenth for every tick with nothing wrong in it, so the
    // next resolution up is affordable several ticks later, not at once.
    let carried = linkObservation(producedBitsPerSecond: 5_200_000, receivedBitsPerSecond: 5_200_000)
    for tick in 3...7 {
        expect(
            controller.observe(carried, atSeconds: Double(tick)) == .hold,
            "a budget that has not yet risen to what the next resolution costs holds the picture, at second \(tick)"
        )
    }
    expect(
        controller.observe(carried, atSeconds: 8) == .stepUp(to: level(fps: 60, scaleSteps: 2)),
        "and a link that keeps carrying everything sent gets the resolution back"
    )
    expect(
        controller.currentLevel.streamScale(requestedScale: 1.75) == 1.25,
        "one resolution at a time, to the largest the budget now covers, got "
            + "\(controller.currentLevel.streamScale(requestedScale: 1.75))x"
    )
}

func testStreamFidelityLetsAQuietScreenBackToTheScaleItsBitsFit() {
    // Two changed frames a second at 300 kbit/s: a whole screen of that at
    // 1.75x is under a megabit a second, well inside the 4.8 the starved link
    // measured, so the viewer gets the resolution it asked for back.
    let cheap = linkObservation(
        producedBitsPerSecond: 300_000,
        receivedBitsPerSecond: 300_000,
        capturedDelta: 2
    )
    var quiet = linkStarvedController()
    expect(
        quiet.observe(cheap, atSeconds: 3) == .hold,
        "one quiet tick is not yet a screen that has settled"
    )
    expect(
        quiet.observe(cheap, atSeconds: 4) == .stepUp(to: level(fps: 60, scaleSteps: 0)),
        "a screen costing the link almost nothing is streamed at exactly the scale the viewer asked for"
    )
    expect(quiet.limitReason == nil, "with nothing left holding it back")

    // The same two frames a second, each one expensive: 2 Mbit/s at 1.00x
    // predicts 6.1 at 1.75x, past the budget, and 4.5 at 1.50x, inside it.
    let expensive = linkObservation(
        producedBitsPerSecond: 2_000_000,
        receivedBitsPerSecond: 2_000_000,
        capturedDelta: 2
    )
    var busy = linkStarvedController()
    _ = busy.observe(expensive, atSeconds: 3)
    expect(
        busy.observe(expensive, atSeconds: 4) == .stepUp(to: level(fps: 60, scaleSteps: 1)),
        "a quiet screen whose frames cost the link real bits climbs only as far as the budget covers"
    )
    expect(busy.limitReason == .link, "and the link is still what is holding the rest of it back")
}

func testStreamFidelityHoldsOffAResolutionTheRebuildRefused() {
    var controller = StreamFidelityController(requestedScale: 2.0)
    warmUp(&controller)
    // 45ms a frame is affordable at no scale this ladder has, so every
    // decision below is for the deepest resolution still worth trying.
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 0)
            == .stepDown(to: level(fps: 60, scaleSteps: 4), reason: .encoder),
        "the first answer to an encoder this far behind is the smallest picture there is"
    )
    controller.streamScaleDidNotApply(atSeconds: 0)
    expect(
        controller.currentLevel.scaleStepsBelowRequested == 0,
        "a rebuild that failed leaves the stream at the scale it was already running"
    )

    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 2)
            == .stepDown(to: level(fps: 60, scaleSteps: 3), reason: .encoder),
        "a resolution the pipeline just refused is not asked for again, and the next one up from it is"
    )
    controller.streamScaleDidNotApply(atSeconds: 2)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 4)
            == .stepDown(to: level(fps: 60, scaleSteps: 2), reason: .encoder),
        "each refusal is remembered on its own, so a pressured surface never proposes the same one twice"
    )
    controller.streamScaleDidNotApply(atSeconds: 4)

    // The first hold-off runs for a minute. What made a rebuild fail can pass,
    // so the resolution is worth one more try once it has.
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 60)
            == .stepDown(to: level(fps: 60, scaleSteps: 4), reason: .encoder),
        "once a hold-off has run out the resolution behind it is worth trying again"
    )
    controller.streamScaleDidNotApply(atSeconds: 60)
    expect(
        controller.observe(encoderPressuredObservation(), atSeconds: 170)
            == .stepDown(to: level(fps: 60, scaleSteps: 3), reason: .encoder),
        "and a resolution that failed twice is held off for twice as long as it was the first time"
    )
}
