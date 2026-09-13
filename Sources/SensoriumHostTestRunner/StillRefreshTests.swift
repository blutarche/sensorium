import CoreMedia
import CoreVideo
import SensoriumCore
import SensoriumHost

/// Three pieces a still-screen refresh touches, each testable on its own: the
/// one frame a still screen is holding, the encoder-input gate the capture
/// stream runs through alongside it, and the checkpoint the frame rate is
/// judged by. The refresh is encoded on a session of its own and never passes
/// through that gate; what it shares with the stream is the pipeline the gate
/// belongs to.
///
/// Nothing here builds a `HostMediaPipeline`: that needs a real
/// ScreenCaptureKit stream and a real display. What the pipeline does with
/// these three is covered by the coordinator scenarios and, ultimately, by a
/// cross-machine run.
@MainActor
func runStillRefreshTests() async {
    let surface = CanvasSurfaceID.allCases[0]

    let held = LastCapturedFrame()
    expect(!held.isHoldingFrame, "a pipeline that has captured nothing holds no frame")
    held.record(makeCapturedFrame(presentationTimeNanoseconds: 1_000))
    expect(held.isHoldingFrame, "the frame just captured is the one a still screen would be sent again")
    let taken = held.take()
    expect(taken != nil, "the refresh gets the frame it is holding")
    expect(
        !held.isHoldingFrame,
        "and the reference is given up at that point: the encoder holds the frame while it encodes it, "
            + "and a second reference here would pin one of ScreenCaptureKit's pool surfaces behind it"
    )
    expect(held.take() == nil, "so a second refresh in the same still period has nothing to send, rather than sending the same frame twice")

    let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
    let gate = EncodeAdmissionGate(
        latencyRecorder: nil,
        sessionGate: sessionGate,
        surface: surface,
        encodedFrameHandler: { _ in }
    )
    expect(
        gate.admit(makeCapturedFrame(presentationTimeNanoseconds: 2_000)),
        "a gate with room takes the captured frame"
    )
    gate.shutDown()
    expect(
        !gate.admit(makeCapturedFrame(presentationTimeNanoseconds: 3_000)),
        "a gate that has shut down takes nothing, and says so, rather than letting a frame arriving "
            + "after teardown reach an encoder this pipeline has given up"
    )

    // A refresh is a whole key frame, sent because the screen stopped rather
    // than because capture delivered anything. It is
    // one more frame through the pipeline, so it counts; it is not evidence
    // about the frame rate in force, so its encode is not measured.
    let recorder = HostMediaLatencyRecorder()
    recorder.resetEncodeCheckpoint(for: surface)
    recordFrame(recorder, surface: surface, presentationTime: 1_000, submitAt: 1_050_000, outputAt: 1_060_000)
    recordFrame(recorder, surface: surface, presentationTime: 2_000, submitAt: 2_050_000, outputAt: 2_060_000)
    expect(
        recorder.encodeLatencySinceCheckpoint(for: surface).count == 1,
        "the checkpoint holds the one captured frame that was not the opening key frame, "
            + "got \(recorder.encodeLatencySinceCheckpoint(for: surface).count)"
    )
    let captureSamplesBefore = recorder.metrics(for: surface).samples(for: .capture).count
    recorder.recordHostRequestedFrame(surface: surface, presentationTimeNanoseconds: 3_000, atNanoseconds: 3_000_000)
    recorder.recordEncodeSubmit(surface: surface, presentationTimeNanoseconds: 3_000, atNanoseconds: 3_050_000)
    recorder.recordEncodeOutput(surface: surface, presentationTimeNanoseconds: 3_000, atNanoseconds: 3_900_000)
    let samples = recorder.encodeLatencySinceCheckpoint(for: surface)
    expect(
        samples.count == 1 && samples.p50 == 10_000,
        "the refresh's own encode never reaches the median the frame rate is judged by, "
            + "got \(samples.count) samples at p50 \(samples.p50)"
    )
    expect(
        recorder.frameCounts(for: surface).captured == 3 && recorder.frameCounts(for: surface).encoded == 3,
        "but it is counted as captured and encoded like any other frame, so the tick that sees it does not "
            + "read an encoder producing frames from nowhere, "
            + "got \(recorder.frameCounts(for: surface).captured) captured and \(recorder.frameCounts(for: surface).encoded) encoded"
    )
    expect(
        recorder.frameCounts(for: surface).hostRequested == 1,
        "and named as the host's own frame, so a reader asking what the screen did can subtract it, "
            + "got \(recorder.frameCounts(for: surface).hostRequested)"
    )
    expect(
        recorder.metrics(for: surface).samples(for: .capture).count == captureSamplesBefore,
        "its timestamp was minted microseconds before it was submitted, so it is no capture-stage measurement at all"
    )
    expect(
        recorder.metrics(for: surface).samples(for: .admit).count == 3,
        "the wait ahead of the encoder is still measured: that one is a wait this frame really had"
    )
    expect(
        recorder.metrics(for: surface).samples(for: .encode).count == 3,
        "and the session-wide encode percentile still sees it: what it cost is real, it is only not evidence "
            + "about a sustainable frame rate"
    )

    // The size of the frame that went out, in the host log, because a refresh
    // that is quietly tiny looks exactly like one that worked.
    expect(
        HostOperatorLog.describeFrameSize(bytes: 1_900_000) == "1.9 MB",
        "a frame of a million bytes or more reads in megabytes, got \(HostOperatorLog.describeFrameSize(bytes: 1_900_000))"
    )
    expect(
        HostOperatorLog.describeFrameSize(bytes: 593_000) == "593 KB",
        "a smaller one reads in whole kilobytes, got \(HostOperatorLog.describeFrameSize(bytes: 593_000))"
    )
    expect(
        HostOperatorLog.describeFrameSize(bytes: 400) == "0 KB",
        "and nothing reads in bytes: a frame that small is the failure the line exists to show, "
            + "got \(HostOperatorLog.describeFrameSize(bytes: 400))"
    )

    print("PASS: a still-screen refresh releases its frame, reports the picture size, and is counted without being measured")
}

private func recordFrame(
    _ recorder: HostMediaLatencyRecorder,
    surface: CanvasSurfaceID,
    presentationTime: Int64,
    submitAt: Int64,
    outputAt: Int64
) {
    recorder.recordCapture(surface: surface, presentationTimeNanoseconds: presentationTime, atNanoseconds: submitAt - 50_000)
    recorder.recordEncodeSubmit(surface: surface, presentationTimeNanoseconds: presentationTime, atNanoseconds: submitAt)
    recorder.recordEncodeOutput(surface: surface, presentationTimeNanoseconds: presentationTime, atNanoseconds: outputAt)
}

/// A 16x16 frame, which is all these tests need: nothing here looks at a
/// pixel, and a real capture buffer would need a real display.
private func makeCapturedFrame(presentationTimeNanoseconds: Int64) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
        print("FAIL: a test pixel buffer could not be created, status \(pixelStatus)")
        Foundation.exit(1)
    }
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        print("FAIL: a test format description could not be created, status \(formatStatus)")
        Foundation.exit(1)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: presentationTimeNanoseconds, timescale: 1_000_000_000),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        print("FAIL: a test sample buffer could not be created, status \(sampleStatus)")
        Foundation.exit(1)
    }
    return sampleBuffer
}
