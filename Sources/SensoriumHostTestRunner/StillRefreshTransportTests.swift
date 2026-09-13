import CoreMedia
import CoreVideo
import Foundation
import SensoriumCore
import SensoriumHost

/// What a still-screen refresh is allowed to cost, and what happens to a
/// picture that costs more than the wire can carry.
@MainActor
func runStillRefreshTransportTests() async {
    expectCeilingNeverExceedsTheTransportLimit()
    expectRetryLadderDescendsThenGivesUp()
    await expectTheRealRefreshPathHoldsItsGuarantees()
    expectSequencingAndHandOffAreOneStep()
}

/// The ceiling exists to stop a refresh from being encoded larger than the
/// transport will accept. A ceiling above `EncodedVideoFrameCodec`'s payload
/// cap does the opposite: the frame passes the retry check, `encode` then
/// refuses it, and the person reading the host log is told a picture was sent
/// that never left this machine.
private func expectCeilingNeverExceedsTheTransportLimit() {
    let transportLimit = VideoEncoderConfiguration.stillRefreshTransportCeilingBytes
    expect(
        transportLimit <= EncodedVideoFrameCodec.maximumPayloadLength,
        "the still-refresh transport ceiling is inside the wire format's payload cap: "
            + "cap \(EncodedVideoFrameCodec.maximumPayloadLength), ceiling \(transportLimit)"
    )
    expect(
        transportLimit + EncodedVideoFrameCodec.maximumCodecConfigurationLength
            <= EncodedVideoFrameCodec.maximumPayloadLength,
        "and leaves room for the codec configuration a key frame carries with it, which "
            + "`EncodedVideoFrameCodec.encode` counts against the same cap"
    )
    for configuration in [
        VideoEncoderConfiguration.remoteDefault,
        VideoEncoderConfiguration.remoteDefault.scaled(toStreamScale: 1.75),
        VideoEncoderConfiguration.fullHiDPI
    ] {
        expect(
            configuration.stillRefreshCeilingBytes <= transportLimit,
            "a \(configuration.encodeWidth)x\(configuration.encodeHeight) refresh may not be encoded "
                + "larger than the wire accepts: ceiling \(configuration.stillRefreshCeilingBytes) bytes "
                + "against a transport limit of \(transportLimit)"
        )
    }
}

/// One softer attempt was never enough: quality mode has no upper bound, so a
/// picture with nothing to predict can be several times the ceiling at 0.5.
private func expectRetryLadderDescendsThenGivesUp() {
    let ceiling = 1_000
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: ceiling,
            ceilingBytes: ceiling,
            attemptsMade: 1
        ) == nil,
        "a frame inside the ceiling is the frame to send, so nothing is encoded twice for it"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: ceiling + 1,
            ceilingBytes: ceiling,
            attemptsMade: 1
        ) == 0.5,
        "the first frame over the ceiling earns one softer attempt"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: ceiling + 1,
            ceilingBytes: ceiling,
            attemptsMade: 2
        ) == 0.3,
        "and a second, softer still, because 0.5 of a photograph is still many times a screen of text"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: ceiling + 1,
            ceilingBytes: ceiling,
            attemptsMade: 3
        ) == nil,
        "after the ladder there is nothing softer left to try, and the picture is refused rather than "
            + "encoded a fourth time"
    )
}

/// The refresh path with the real encoders, offline: no display, no capture,
/// no network. A Mac with no hardware H.264 encoder skips this rather than
/// failing -- what it exercises is this Mac's encoder, and there is nothing to
/// exercise without one.
///
/// What it cannot reach is `HostMediaPipeline` itself, which needs an
/// `SCContentFilter` and so a real display and a granted Screen Recording
/// permission. Everything the pipeline's refresh is built from is real here:
/// `StillFrameEncoder`, the stream's own `VideoToolboxEncoder`, the
/// `H264SampleBufferPacketizer` both share, and a sink that can refuse.
private func expectTheRealRefreshPathHoldsItsGuarantees() async {
    let configuration = VideoEncoderConfiguration.remoteDefault.scaled(toStreamScale: 1.5)
    let sink = RecordingPacketSink()
    let packetizer = H264SampleBufferPacketizer()
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            guard case .encoded(let sampleBuffer) = outcome else { return }
            _ = try? packetizer.deliver(from: sampleBuffer) { sink.record($0) }
        }
    ) else {
        print("SKIP: this Mac has no hardware H.264 encoder, so there is no still-refresh path to drive")
        return
    }

    let width = configuration.encodeWidth
    let height = configuration.encodeHeight
    for index in 0..<6 {
        try? encoder.encode(refreshTestSampleBuffer(
            refreshTestPixelBuffer(width: width, height: height, shiftedBy: index),
            frameIndex: index
        ))
    }
    guard await sink.settle(untilAtLeast: 4) else {
        print("SKIP: this Mac's encoder produced too few frames to drive the refresh path")
        return
    }
    let streamPacketsBeforeRefresh = sink.packets.count
    expect(
        sink.packets.suffix(2).contains { !$0.isKeyFrame },
        "the stream is producing deltas by now, so the key frame asserted for below is the refresh's doing "
            + "and not simply the opening frame of a new compression session"
    )

    // Exactly the order `HostMediaPipeline.refreshStillPicture` runs: encode
    // the held picture whole, empty the stream's encoder and arm its next
    // frame as a recovery point, then hand the refresh on.
    let stillPicture = refreshTestPixelBuffer(width: width, height: height, shiftedBy: 99)
    let refreshTime: Int64 = 5_000_000_000
    let refreshed: CMSampleBuffer
    do {
        refreshed = try StillFrameEncoder.encodeKeyFrame(
            imageBuffer: stillPicture,
            configuration: configuration,
            presentationTimeNanoseconds: refreshTime
        )
    } catch StillFrameEncoderError.frameExceedsTransportLimit(let bytes) {
        expect(
            bytes > VideoEncoderConfiguration.stillRefreshTransportCeilingBytes,
            "a refusal names a frame that really is over the transport limit, got \(bytes)"
        )
        print("PASS: a still-screen refresh too large for the wire is refused rather than sent, at \(bytes) bytes")
        return
    } catch {
        expect(false, "the still-refresh encoder produced neither a frame nor a refusal: \(error)")
        return
    }
    let refreshedBytes = CMSampleBufferGetTotalSampleSize(refreshed)
    expect(
        refreshedBytes <= VideoEncoderConfiguration.stillRefreshTransportCeilingBytes,
        "a frame that is returned rather than refused is one the wire can carry: limit "
            + "\(VideoEncoderConfiguration.stillRefreshTransportCeilingBytes) bytes, got \(refreshedBytes)"
    )
    expect(
        CMSampleBufferGetPresentationTimeStamp(refreshed).value == refreshTime,
        "and carries the timestamp the caller already recorded its stages against, whatever quality it took "
            + "to fit, got \(CMSampleBufferGetPresentationTimeStamp(refreshed).value)"
    )

    // Two more frames submitted immediately before the flush, so there really
    // is something inside VideoToolbox for the flush to put out rather than an
    // encoder that had already drained on its own.
    for index in 8...9 {
        try? encoder.encode(refreshTestSampleBuffer(
            refreshTestPixelBuffer(width: width, height: height, shiftedBy: index),
            frameIndex: index
        ))
    }
    encoder.completeFramesRequestingKeyFrame()
    let packetsAtFlush = sink.packets.count
    try? await Task.sleep(nanoseconds: 200_000_000)
    expect(
        sink.packets.count == packetsAtFlush,
        "the flush emptied the encoder: nothing it was still holding arrives afterwards, which is what "
            + "keeps a delta from following the refresh onto the wire"
    )
    let delivered = (try? packetizer.deliver(from: refreshed) { sink.record($0) }) ?? false
    expect(delivered, "a sink that takes the frame answers so, and the refresh is a picture that went out")
    let refreshIndex = sink.packets.count - 1
    expect(
        sink.packets[refreshIndex].isKeyFrame,
        "the refresh goes out as a whole picture: a delta would be built on references the viewer is about "
            + "to throw away with its rebuilt decoder"
    )
    expect(
        (try? EncodedVideoFrameCodec.encode(sink.packets[refreshIndex])) != nil,
        "and the wire format accepts it, rather than refusing it at the write with the refresh already "
            + "counted and logged as sent"
    )
    expect(
        sink.packets.count == packetsAtFlush + 1,
        "the refresh is the next thing the transport sees after the flush: every frame that was still "
            + "inside VideoToolbox came out ahead of it, and nothing the stream had in flight follows it"
    )
    expect(
        packetsAtFlush > streamPacketsBeforeRefresh,
        "and the flush let out what was submitted just before it, rather than leaving it to arrive later"
    )

    try? encoder.encode(refreshTestSampleBuffer(
        refreshTestPixelBuffer(width: width, height: height, shiftedBy: 7),
        frameIndex: 7
    ))
    guard await sink.settle(untilAtLeast: refreshIndex + 2) else {
        expect(false, "the stream's encoder produced nothing after the refresh")
        return
    }
    expect(
        sink.packets[refreshIndex + 1].isKeyFrame,
        "the stream's next frame is a key frame of its own: the viewer rebuilt its decoder around the "
            + "refresh's parameter sets and holds no reference pictures from this encoder's session"
    )
    let sequences = sink.packets.map(\.sequence)
    expect(
        zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
        "sequence numbers reach the transport strictly increasing, across both the stream's thread and the "
            + "refresh: the viewer discards anything not newer than what it has already admitted, got \(sequences)"
    )

    sink.refusesEveryFrame = true
    let refusedPicture = refreshTestPixelBuffer(width: width, height: height, shiftedBy: 123)
    if let refused = try? StillFrameEncoder.encodeKeyFrame(
        imageBuffer: refusedPicture,
        configuration: configuration,
        presentationTimeNanoseconds: refreshTime + 1_000_000_000
    ) {
        encoder.completeFramesRequestingKeyFrame()
        expect(
            ((try? packetizer.deliver(from: refused) { sink.record($0) }) ?? false) == false,
            "a sink that refuses the frame says so, which is what stops a refusal being reported as a "
                + "picture that went out"
        )
    }
    // At full HiDPI the transport's limit is the binding half of the ceiling
    // and an incompressible picture passes it on the opening attempt, so this
    // is where the ladder and the refusal are actually exercised.
    expectAnIncompressiblePictureIsBroughtInsideTheLimit(configuration: .fullHiDPI)
    expectAnIncompressiblePictureIsBroughtInsideTheLimit(configuration: squareEncoderConfiguration(side: 4096))
    print("PASS: the still-refresh path sends a \(refreshedBytes)-byte key frame, numbers everything in order, and reports a refusal")
}

/// A picture with nothing to predict, which is what the retry ladder exists
/// for: at the opening quality it costs many times what a screen of text does,
/// so this is the case where a second and a third attempt actually run.
private func expectAnIncompressiblePictureIsBroughtInsideTheLimit(configuration: VideoEncoderConfiguration) {
    let noise = refreshTestNoisePixelBuffer(
        width: configuration.encodeWidth,
        height: configuration.encodeHeight
    )
    let requestedTime: Int64 = 9_000_000_000
    do {
        let frame = try StillFrameEncoder.encodeKeyFrame(
            imageBuffer: noise,
            configuration: configuration,
            presentationTimeNanoseconds: requestedTime
        )
        let bytes = CMSampleBufferGetTotalSampleSize(frame)
        expect(
            bytes <= configuration.stillRefreshCeilingBytes,
            "whatever the ladder ends on is inside the ceiling, or it is refused rather than returned: "
                + "ceiling \(configuration.stillRefreshCeilingBytes), got \(bytes)"
        )
        expect(
            CMSampleBufferGetPresentationTimeStamp(frame).value == requestedTime,
            "and carries the timestamp asked for, not one nudged forward to get past a shared session: "
                + "`HostMediaLatencyRecorder` looks the frame's stages up by exactly this number, got "
                + "\(CMSampleBufferGetPresentationTimeStamp(frame).value)"
        )
        print(
            "PASS: an incompressible \(configuration.encodeWidth)x\(configuration.encodeHeight) picture comes "
                + "back at \(bytes) bytes against a ceiling of \(configuration.stillRefreshCeilingBytes)"
        )
    } catch StillFrameEncoderError.frameExceedsTransportLimit(let bytes) {
        expect(
            bytes > VideoEncoderConfiguration.stillRefreshTransportCeilingBytes,
            "a refusal names a frame that really is over the transport limit, got \(bytes)"
        )
        print("PASS: an incompressible picture the ladder could not bring inside the limit is refused at \(bytes) bytes")
    } catch StillFrameEncoderError.sessionCreationFailed(let status) {
        print(
            "SKIP: this Mac's encoder will not open a \(configuration.encodeWidth)x\(configuration.encodeHeight) "
                + "session (status \(status)), so the retry ladder has nothing to run against"
        )
    } catch {
        expect(false, "an incompressible picture produced neither a frame nor a refusal: \(error)")
    }
}

/// Sequence numbers as the transport sees them, recorded on whichever thread
/// handed the frame over.
private final class RecordingPacketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [EncodedVideoFramePacket] = []
    private var refuses = false

    var packets: [EncodedVideoFramePacket] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var refusesEveryFrame: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refuses
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            refuses = newValue
        }
    }

    func record(_ packet: EncodedVideoFramePacket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(packet)
        return !refuses
    }

    /// Waits for VideoToolbox's own thread to report what it has, rather than
    /// assuming a submitted frame has already come back.
    func settle(untilAtLeast expected: Int) async -> Bool {
        for _ in 0..<50 where packets.count < expected {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return packets.count >= expected
    }
}

/// Numbering a frame and handing it on is one step, or two threads that each
/// took a number can arrive at the transport in the other order -- and the
/// viewer discards whichever of them arrives second, whole picture or not.
///
/// Driven with many deliveries from several threads at once, which is what
/// makes an interleaving observable at all; the guarantee itself is the lock
/// `H264SampleBufferPacketizer.deliver` holds across both.
private func expectSequencingAndHandOffAreOneStep() {
    guard let keyFrame = offlineEncodedKeyFrame() else {
        print("SKIP: this Mac has no hardware H.264 encoder, so there is no encoded frame to number")
        return
    }
    let packetizer = H264SampleBufferPacketizer()
    let observed = ObservedSequenceOrder()
    let threads = 4
    let framesPerThread = 60
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        for _ in 0..<framesPerThread {
            _ = try? packetizer.deliver(from: keyFrame) { observed.record($0.sequence) }
        }
    }
    let sequences = observed.sequences
    expect(
        sequences.count == threads * framesPerThread,
        "every delivery reached the sink, got \(sequences.count) of \(threads * framesPerThread)"
    )
    expect(
        zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
        "the sink sees sequence numbers strictly increasing however many threads are delivering: "
            + "a number taken under the lock and used outside it arrives out of order, and the client's "
            + "`VideoFrameIngress` throws away whatever it finds not newer than what it has"
    )
    print("PASS: \(sequences.count) concurrent deliveries reach the transport in sequence order")
}

private final class ObservedSequenceOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []

    var sequences: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(sequence)
        return true
    }
}

/// One real key frame from this Mac's encoder, or `nil` where there is no
/// hardware encoder to produce one.
private func offlineEncodedKeyFrame() -> CMSampleBuffer? {
    let configuration = VideoEncoderConfiguration.remoteDefault
    let output = EncodedKeyFrameBox()
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            guard case .encoded(let sampleBuffer) = outcome else { return }
            output.record(sampleBuffer)
        }
    ) else {
        return nil
    }
    try? encoder.encode(refreshTestSampleBuffer(
        refreshTestPixelBuffer(width: configuration.encodeWidth, height: configuration.encodeHeight, shiftedBy: 3),
        frameIndex: 0
    ))
    // Flushes what was just submitted, so the frame is in hand rather than
    // waited for on a guessed interval.
    encoder.completeFramesRequestingKeyFrame()
    return output.frame
}

private final class EncodedKeyFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: CMSampleBuffer?

    func record(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if recorded == nil {
            recorded = sampleBuffer
        }
    }

    var frame: CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A picture with enough structure to compress and enough movement between
/// frames to keep the stream producing deltas rather than repeating itself.
private func refreshTestPixelBuffer(width: Int, height: Int, shiftedBy shift: Int) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        print("FAIL: a refresh-path pixel buffer could not be created, status \(status)")
        Foundation.exit(1)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        print("FAIL: a refresh-path pixel buffer had no base address")
        Foundation.exit(1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * bytesPerRow + column * 4
            let value = UInt8(truncatingIfNeeded: ((column + shift * 17) / 8 + (row / 8)) * 31)
            bytes[offset] = value
            bytes[offset + 1] = value &+ 64
            bytes[offset + 2] = value &+ 128
            bytes[offset + 3] = 255
        }
    }
    return pixelBuffer
}

private func refreshTestSampleBuffer(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) -> CMSampleBuffer {
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        print("FAIL: a refresh-path format description could not be created, status \(formatStatus)")
        Foundation.exit(1)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: Int64(frameIndex), timescale: 60),
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
        print("FAIL: a refresh-path sample buffer could not be created, status \(sampleStatus)")
        Foundation.exit(1)
    }
    return sampleBuffer
}

/// Uncorrelated pixels: nothing for the encoder to predict within the frame,
/// which is the content quality mode has no upper bound against. Generated
/// from a fixed seed so what this costs is the same on every run.
private func refreshTestNoisePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        print("FAIL: a refresh-path noise buffer could not be created, status \(status)")
        Foundation.exit(1)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        print("FAIL: a refresh-path noise buffer had no base address")
        Foundation.exit(1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var state: UInt64 = 0x2545F4914F6CDD1D
    for row in 0..<height {
        for column in 0..<width {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let offset = row * bytesPerRow + column * 4
            bytes[offset] = UInt8(truncatingIfNeeded: state)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
            bytes[offset + 3] = 255
        }
    }
    return pixelBuffer
}

/// The largest square this Mac's hardware H.264 encoder accepts, where an
/// incompressible picture is past what the wire carries at every quality the
/// ladder has.
private func squareEncoderConfiguration(side: Int) -> VideoEncoderConfiguration {
    let bitRate = VideoEncoderConfiguration.averageBitRate(encodeWidth: side, encodeHeight: side)
    return VideoEncoderConfiguration(
        width: side,
        height: side,
        framesPerSecond: 60,
        codec: .h264,
        maxQueueDepth: 3,
        captureWidth: side,
        captureHeight: side,
        encodeWidth: side,
        encodeHeight: side,
        averageBitRate: bitRate,
        dataRateLimitBytes: VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: bitRate),
        dataRateLimitSeconds: 1.0,
        maxFrameDelayCount: 0,
        profileLevel: .mainAutoLevel,
        requiresHardwareAcceleration: true
    )
}
