import CoreGraphics
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// What one delivery from a capture stream is, and what the counters a
/// fidelity decision reads make of it.
///
/// ScreenCaptureKit's output callback fires on a cadence, not on a change:
/// with a minimum frame interval set, a screen nobody is touching still
/// produces `.complete` deliveries at that interval. Counting those as the
/// screen changing is what made a still screen read as a moving one, so the
/// dirty-rect list the stream attaches is what decides it.
@MainActor
func runScreenChangeAdmissionTests() async {
    let surface = CanvasSurfaceID.allCases[0]
    let changedRect = CGRect(x: 0, y: 0, width: 100, height: 40)

    expect(
        ScreenCaptureFrameAdmission.classify(status: .complete, dirtyRects: [changedRect]) == .screenChange,
        "a complete frame naming a redrawn rectangle is the screen changing"
    )
    expect(
        ScreenCaptureFrameAdmission.classify(status: .complete, dirtyRects: []) == .unchangedFrame,
        "a complete frame whose dirty-rect list is empty is the same picture again, not a change"
    )
    expect(
        ScreenCaptureFrameAdmission.classify(status: .complete, dirtyRects: nil) == .screenChange,
        "a complete frame that says nothing about dirty rectangles is treated as a change, because "
            + "refusing to send a picture on the strength of a measurement that is absent is the worse mistake"
    )
    expect(
        ScreenCaptureFrameAdmission.classify(status: .idle, dirtyRects: nil) == .noChangeNotice,
        "an idle status is the stream saying nothing changed, with no picture attached"
    )
    for status in [SCFrameStatus.blank, .suspended, .started, .stopped] {
        expect(
            ScreenCaptureFrameAdmission.classify(status: status, dirtyRects: nil) == .otherStatus,
            "a \(status) status carries no picture and says nothing about change"
        )
    }
    expect(
        ScreenCaptureFrameAdmission.classify(status: nil, dirtyRects: nil) == .otherStatus,
        "a sample buffer with no status attachment carries no picture either"
    )

    expect(
        ScreenCaptureFrameAdmission.shouldEncode(status: .complete, dirtyRects: [changedRect]),
        "the screen changing is the one delivery the encoder is given"
    )
    expect(
        !ScreenCaptureFrameAdmission.shouldEncode(status: .complete, dirtyRects: []),
        "the same picture again is not encoded: the still-screen refresh already resends it whole, "
            + "at a budget worth reading, once per still period"
    )
    expect(
        !ScreenCaptureFrameAdmission.shouldEncode(status: .idle, dirtyRects: nil),
        "an idle notice has no picture to encode"
    )

    // The counters a fidelity tick reads: a delivery that is not a change must
    // leave `captured` alone, and must still be counted somewhere, or the next
    // live log cannot say what the stream actually delivered.
    let recorder = HostMediaLatencyRecorder()
    for _ in 0..<19 {
        recorder.recordCaptureDelivery(.unchangedFrame, surface: surface)
    }
    recorder.recordCaptureDelivery(.noChangeNotice, surface: surface)
    recorder.recordCaptureDelivery(.otherStatus, surface: surface)
    let counts = recorder.frameCounts(for: surface)
    expect(
        counts.captured == 0,
        "a screen nobody touched captured nothing, however many deliveries the stream made, got \(counts.captured)"
    )
    expect(
        counts.unchangedFrames == 19,
        "every complete frame with an empty dirty-rect list is counted, got \(counts.unchangedFrames)"
    )
    expect(
        counts.noChangeNotices == 1,
        "and every idle notice separately, so a live log can say which of the two a static display sends, "
            + "got \(counts.noChangeNotices)"
    )
    expect(
        counts.otherStatusDeliveries == 1,
        "and every other-status delivery separately, so a stream sending only those does not read the "
            + "same as one that stopped delivering, got \(counts.otherStatusDeliveries)"
    )

    // The whole point of the counting change: with only unchanged frames
    // arriving, the tick that reads those counters sees a still screen and the
    // still-screen levers fire.
    var controller = StreamFidelityController(requestedScale: 1.0)
    let moving = StreamFidelityObservation(
        capturedDelta: 60,
        encodedDelta: 60,
        encodeP50Nanoseconds: 5_000_000,
        encodeSampleCount: 60,
        producedBitsPerSecond: 10_000_000
    )
    for tick in 0..<StreamFidelityController.warmUpTicks {
        _ = controller.observe(moving, atSeconds: Double(tick) - Double(StreamFidelityController.warmUpTicks))
    }
    // Far enough down that quality is one of the levers a still
    // screen has left to hand back.
    let encoderBehind = StreamFidelityObservation(
        capturedDelta: 60,
        encodeP50Nanoseconds: 45_000_000,
        encodeSampleCount: 60
    )
    var second = 0.0
    while controller.currentLevel.qualityScale == 1.0, second < 40 {
        _ = controller.observe(encoderBehind, atSeconds: second)
        second += 1
    }
    expect(
        controller.currentLevel.qualityScale < 1.0,
        "the surface has given quality up, got \(controller.currentLevel.qualityScale)"
    )

    // What the coordinator builds from two readings of the counters above,
    // when the only thing the stream delivered between them was the same
    // picture over and over.
    let stillTick = StreamFidelityObservation(
        capturedDelta: 0,
        encodedDelta: 0,
        producedBitsPerSecond: 0
    )
    var decisions: [StreamFidelityDecision] = []
    for _ in 0..<9 {
        decisions.append(controller.observe(stillTick, atSeconds: second))
        second += 1
    }
    expect(
        decisions.contains(where: { if case .liftQuality = $0 { return true } else { return false } }),
        "a stream delivering nothing but unchanged frames is a still screen, and quality returns to full, "
            + "got \(decisions)"
    )
    expect(
        decisions.contains(.refreshStill),
        "and the picture it is holding is sent again whole, got \(decisions)"
    )

    // A still screen produces no packets at all, so the flow report driven by
    // those packets says nothing about it. What the capture stream delivered
    // gets its own line, per surface, from the fidelity tick.
    let events = DiagnosticsRecorder()
    let media = FakeScalableCanvasMedia()
    let coordinator = HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        ),
        media: onlyOnSurfaceZero(media),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        flowReportSeconds: 5,
        onEvent: { events.record($0) }
    )
    _ = try! await coordinator.handleWritingResponse(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    )
    for tick in 0...5 {
        media.frameCounts = HostFrameCounts(
            captured: 0,
            encoded: 0,
            encodeSubmissionFailures: 0,
            unchangedFrames: 20 * (tick + 1),
            noChangeNotices: tick,
            otherStatusDeliveries: 2 * tick
        )
        await coordinator.tickFidelity(atSeconds: Double(tick))
    }
    let captureLines = events.messages.filter { $0.hasPrefix("canvas 0 capture") }
    expect(
        captureLines == [
            "canvas 0 capture over 5.0s: 0 screen changes, 100 unchanged frames, "
                + "5 no-change notices, 10 other deliveries",
        ],
        "one line per report interval says what the stream delivered while nothing moved, got \(captureLines)"
    )

    print("PASS: an unchanged frame is neither encoded nor counted as the screen changing, and the still-screen levers fire on it")
}
