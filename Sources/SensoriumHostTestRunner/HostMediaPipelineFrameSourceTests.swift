import CoreMedia
import CoreVideo
import Foundation
import SensoriumCore
import SensoriumHost

/// Stands in for ScreenCaptureKit: delivers exactly the frames it is told to,
/// into the closures the pipeline gave its factory.
@available(macOS 13.0, *)
@MainActor
private final class ScriptedFrameSource: HostFrameSource {
    let frameHandler: @Sendable (CMSampleBuffer) -> Void
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var appliedFramesPerSecond: [Int] = []

    init(frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.frameHandler = frameHandler
    }

    func start() async throws { startCount += 1 }
    func stop() async throws { stopCount += 1 }
    func apply(framesPerSecond: Int) async throws { appliedFramesPerSecond.append(framesPerSecond) }
}

private final class EncodedFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func scriptedSampleBuffer(width: Int, height: Int) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer!,
        formatDescriptionOut: &formatDescription
    )
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: MonotonicClock.nowNanoseconds(), timescale: 1_000_000_000),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer!,
        formatDescription: formatDescription!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// `HostMediaPipeline` takes its frames from a `HostFrameSource` so a rig
/// that must not touch ScreenCaptureKit can stream through the real encoder,
/// admission gate and latency recorder.
@available(macOS 13.0, *)
@MainActor
func runHostMediaPipelineFrameSourceTests() async {
    let surface = CanvasSurfaceID.allCases[0]
    let configuration = VideoEncoderConfiguration.remoteDefault
    let recorder = HostMediaLatencyRecorder()
    let encoded = EncodedFrameCounter()
    var source: ScriptedFrameSource?
    let pipeline = try! HostMediaPipeline(
        surface: surface,
        configuration: configuration,
        latencyRecorder: recorder,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        frameSourceFactory: { _, _, _, frameHandler in
            let made = ScriptedFrameSource(frameHandler: frameHandler)
            source = made
            return made
        },
        encodedFrameHandler: { _ in
            encoded.record()
            return true
        }
    )
    try! await pipeline.start()
    expect(source?.startCount == 1, "starting the pipeline starts its frame source, got \(String(describing: source?.startCount))")

    source!.frameHandler(scriptedSampleBuffer(width: configuration.captureWidth, height: configuration.captureHeight))
    expect(
        recorder.frameCounts(for: surface).captured == 1,
        "a frame the source delivers is recorded as captured, got \(recorder.frameCounts(for: surface).captured)"
    )
    for _ in 0..<100 where encoded.value == 0 {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    expect(encoded.value == 1, "a frame the source delivers is admitted to the encoder and comes out encoded, got \(encoded.value)")

    try! await pipeline.apply(framesPerSecond: 30)
    expect(source?.appliedFramesPerSecond == [30], "a frame-rate change reaches the frame source, got \(String(describing: source?.appliedFramesPerSecond))")

    try! await pipeline.stop()
    expect(source?.stopCount == 1, "stopping the pipeline stops its frame source, got \(String(describing: source?.stopCount))")

    let packets = EncodedFrameCounter()
    var packetSource: ScriptedFrameSource?
    let packetPipeline = try! HostMediaPipeline(
        surface: surface,
        configuration: configuration,
        sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        frameSourceFactory: { _, _, _, frameHandler in
            let made = ScriptedFrameSource(frameHandler: frameHandler)
            packetSource = made
            return made
        },
        encodedPacketHandler: { _ in
            packets.record()
            return true
        }
    )
    try! await packetPipeline.start()
    packetSource!.frameHandler(scriptedSampleBuffer(width: configuration.captureWidth, height: configuration.captureHeight))
    for _ in 0..<100 where packets.value == 0 {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    expect(packets.value >= 1, "a packetizing pipeline built from a frame source hands its encoded frame on as a packet, got \(packets.value)")
    try! await packetPipeline.stop()

    print("PASS: a pipeline built from a scripted frame source records a capture, admits the frame to the encoder, and drives the source's start, frame rate and stop")
}
