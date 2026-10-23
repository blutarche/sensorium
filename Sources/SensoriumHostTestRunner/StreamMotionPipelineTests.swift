import CoreMedia
import CoreVideo
import Foundation
import SensoriumCore
import SensoriumHost

/// A moving picture through the real pipeline and the real hardware encoder,
/// offline: frames from a script, no capture, no display, no network. A
/// machine with no hardware H.264 encoder skips it, as the other
/// real-encoder tests do.
@available(macOS 13.0, *)
@MainActor
func runStreamMotionPipelineTests() async {
    await expectAPipelineSendsAMovingPictureSmallerAndTheSettledOneWhole()
    await expectTheCoordinatorTellsTheStreamAboutAScrollOrADrag()
}

@available(macOS 13.0, *)
@MainActor
private func expectTheCoordinatorTellsTheStreamAboutAScrollOrADrag() async {
    let media = FakeCanvasMedia()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .unconfined,
        privateDesktopOffered: { true }
    )
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(media),
        videoSink: FakeVideoSink()
    )
    let surface = CanvasSurfaceID.allCases[0]
    func send(_ event: SensoriumInputEvent) async {
        _ = try? await coordinator.handleWritingResponse(.input(event, surfaceID: 0))
    }

    await send(.scrolled(deltaX: 0, deltaY: -4, x: 10, y: 10, phase: nil, momentumPhase: nil))
    expect(media.viewerInteractionCount == 0, "a surface that is not streaming has no picture to move")

    _ = try! await coordinator.handleWritingResponse(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
    )
    await send(.pointerMoved(x: 20, y: 20))
    await send(.key(keyCode: 0, isDown: true, modifiers: []))
    expect(media.viewerInteractionCount == 0, "hovering and typing leave the picture sharp")
    await send(.scrolled(deltaX: 0, deltaY: -4, x: 10, y: 10, phase: nil, momentumPhase: nil))
    expect(media.viewerInteractionCount == 1, "a scroll on the streaming surface reaches its stream")
    await send(.pointerButton(button: .left, isDown: true, x: 20, y: 20))
    await send(.pointerMoved(x: 40, y: 20))
    expect(media.viewerInteractionCount == 2, "and so does a drag")
    await send(.pointerButton(button: .left, isDown: false, x: 40, y: 20))
    await send(.pointerMoved(x: 60, y: 20))
    expect(media.viewerInteractionCount == 2, "and moving after the release does not")

    let settledScale = coordinator.appliedStreamScale(for: surface)
    expect(
        coordinator.streamedScale(for: surface) == settledScale,
        "the viewer is told the settled scale while the settled picture is sent"
    )
    media.encodingStreamScale = 1.08
    expect(
        coordinator.streamedScale(for: surface) == 1.08,
        "and the motion scale while the moving one is, so what it shows matches the picture it has"
    )
    expect(
        coordinator.appliedStreamScale(for: surface) == settledScale,
        "the scale the stream is built at does not change for it"
    )
    print("PASS: the coordinator passes a viewer scroll or drag to the stream it moves, and reports the scale of the picture being sent")
}

@available(macOS 13.0, *)
@MainActor
private final class MotionScriptedFrameSource: HostFrameSource {
    let frameHandler: @Sendable (CMSampleBuffer) -> Void

    init(frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.frameHandler = frameHandler
    }

    func start() async throws {}
    func stop() async throws {}
    func apply(framesPerSecond: Int) async throws {}
}

/// Each encoded frame's size and whether it is a key frame, in the order the
/// pipeline handed them on.
private final class MotionEncodedFrameLog: @unchecked Sendable {
    struct Frame: Equatable {
        let width: Int32
        let height: Int32
        let isKeyFrame: Bool
    }

    private let lock = NSLock()
    private var frames: [Frame] = []

    func record(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) == true
        lock.lock()
        frames.append(Frame(width: dimensions.width, height: dimensions.height, isKeyFrame: !notSync))
        lock.unlock()
    }

    var all: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

private func motionPipelineFrame(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer {
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
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
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription!,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer!
}

/// Stripes that move with `offset`, so every frame differs everywhere, as a
/// scrolled page does.
private func motionPipelinePixels(width: Int, height: Int, offset: Int) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
        let shade: UInt8 = ((row + offset) / 8) % 2 == 0 ? 230 : 40
        memset(base + row * bytesPerRow, Int32(shade), width * 4)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

@available(macOS 13.0, *)
@MainActor
private func waitForFrames(_ log: MotionEncodedFrameLog, count: Int, seconds: Double) async {
    let deadline = Date().addingTimeInterval(seconds)
    while log.all.count < count, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@available(macOS 13.0, *)
@MainActor
private func expectAPipelineSendsAMovingPictureSmallerAndTheSettledOneWhole() async {
    let logicalBitRate = VideoEncoderConfiguration.averageBitRate(encodeWidth: 1773, encodeHeight: 997)
    let configuration = VideoEncoderConfiguration(
        width: 1773,
        height: 997,
        framesPerSecond: 60,
        codec: .h264,
        maxQueueDepth: 3,
        captureWidth: 1773,
        captureHeight: 997,
        encodeWidth: 1773,
        encodeHeight: 997,
        averageBitRate: logicalBitRate,
        dataRateLimitBytes: VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: logicalBitRate),
        dataRateLimitSeconds: 1.0,
        maxFrameDelayCount: 0,
        profileLevel: .constrainedBaselineAutoLevel,
        requiresHardwareAcceleration: true
    )
    .scaled(toStreamScale: 2.0)
    .with(keyFrameIntervalSeconds: VideoEncoderConfiguration.viewerRecoveryKeyFrameIntervalSeconds)
    let surface = CanvasSurfaceID.allCases[0]
    let recorder = HostMediaLatencyRecorder()
    let log = MotionEncodedFrameLog()
    var source: MotionScriptedFrameSource?
    let pipeline: HostMediaPipeline
    do {
        pipeline = try await HostMediaPipeline(
            surface: surface,
            configuration: configuration,
            latencyRecorder: recorder,
            sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
                capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
            ),
            frameSourceFactory: { _, _, _, frameHandler in
                let made = MotionScriptedFrameSource(frameHandler: frameHandler)
                source = made
                return made
            },
            encodedFrameHandler: { sampleBuffer in
                log.record(sampleBuffer)
                return true
            }
        )
    } catch {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no moving picture to encode")
        return
    }
    try? await pipeline.start()
    let full = MotionEncodedFrameLog.Frame(width: 3546, height: 1994, isKeyFrame: true)
    let width = configuration.captureWidth
    let height = configuration.captureHeight

    /// A scroll: one change every 60th of a second, whether or not the
    /// encoder has finished the last one, so the admission gate drops what the
    /// encoder has no time for, as it does for capture.
    func scroll(_ count: Int, from offset: Int) async {
        for index in 0..<count {
            source!.frameHandler(motionPipelineFrame(motionPipelinePixels(width: width, height: height, offset: offset + index * 12)))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    source!.frameHandler(motionPipelineFrame(motionPipelinePixels(width: width, height: height, offset: 0)))
    await waitForFrames(log, count: 1, seconds: 3)
    expect(log.all == [full], "a stream opens with a full-size key frame, got \(log.all)")
    expect(pipeline.encodingStreamScale == nil, "and reports no motion scale of its own")
    try? await Task.sleep(nanoseconds: 200_000_000)

    await scroll(16, from: 12)
    let scrollEndedAt = Date()
    try? await Task.sleep(nanoseconds: 150_000_000)
    let scrolled = Array(log.all.dropFirst())
    let firstMoving = scrolled.firstIndex { $0.width == 1920 }
    expect(
        firstMoving.map { scrolled[..<$0].allSatisfy { $0.width == 3546 && !$0.isKeyFrame } } == true,
        "the changes before motion is shown go out at full size, as deltas, got \(scrolled)"
    )
    let moving = firstMoving.map { Array(scrolled[$0...]) } ?? []
    expect(
        moving.first == MotionEncodedFrameLog.Frame(width: 1920, height: 1080, isKeyFrame: true)
            && moving.count > 1
            && moving.dropFirst().allSatisfy { $0.width == 1920 && $0.height == 1080 && !$0.isKeyFrame },
        "from the change that shows motion on, the picture goes out at the motion size: one key frame, then deltas, got \(scrolled)"
    )
    expect(
        pipeline.encodingStreamScale.map { abs($0 - Double(1920) / Double(1773)) < 0.001 } == true,
        "the pipeline reports the motion scale while it sends the moving picture, got \(String(describing: pipeline.encodingStreamScale))"
    )

    let beforeSettle = log.all.count
    let hostRequestedBefore = recorder.frameCounts(for: surface).hostRequested
    await waitForFrames(log, count: beforeSettle + 1, seconds: 3)
    let settledAfter = Date().timeIntervalSince(scrollEndedAt)
    expect(
        log.all.count == beforeSettle + 1 && log.all.last == full,
        "once the screen stops, the last picture goes out again whole, at full size, as a key frame, got \(log.all.suffix(2))"
    )
    expect(
        settledAfter >= StreamMotionDetector.settleSeconds - 0.05 && settledAfter < StreamMotionDetector.settleSeconds + 0.5,
        "about a settle delay after the last change, got \(settledAfter) s"
    )
    expect(
        recorder.frameCounts(for: surface).hostRequested == hostRequestedBefore + 1,
        "that frame is the host's own, so nothing reads it as the screen changing"
    )
    expect(pipeline.encodingStreamScale == nil, "and the pipeline reports no motion scale again")
    try? await Task.sleep(nanoseconds: 700_000_000)
    expect(log.all.count == beforeSettle + 1, "a settled screen sends nothing more")

    let beforeInteraction = log.all.count
    pipeline.viewerInteracted()
    source!.frameHandler(motionPipelineFrame(motionPipelinePixels(width: width, height: height, offset: 500)))
    await waitForFrames(log, count: beforeInteraction + 1, seconds: 3)
    expect(
        log.all.count == beforeInteraction + 1
            && log.all.last == MotionEncodedFrameLog.Frame(width: 1920, height: 1080, isKeyFrame: true),
        "the first change after a viewer scroll is already the moving picture's key frame, got \(log.all.suffix(1))"
    )

    try? await pipeline.stop()
    let afterStop = log.all.count
    try? await Task.sleep(nanoseconds: 800_000_000)
    expect(log.all.count == afterStop, "a stopped pipeline sends no settled picture")
    print("PASS: a moving picture goes out at the motion size, from a key frame, and the settled one goes out whole a settle delay after the screen stops")
}
