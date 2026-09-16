import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import SensoriumHost

/// What a still-screen refresh actually costs in bytes, measured against the
/// stream's own encoder on the same picture.
///
/// This is the one test in the suite that runs a real `VTCompressionSession`.
/// It needs no display, no capture and no network: the picture is drawn into a
/// pixel buffer here, in this process, and the encoded frames are counted and
/// thrown away. A machine with no hardware H.264 encoder skips it rather than
/// failing, because what it measures is this machine's encoder and there is
/// nothing to measure without one.
@MainActor
func runStillRefreshEncodeMeasurementTests() async {
    // The resolution a 1920x1200 canvas streams at when the viewer asks for a
    // sharper picture than its logical size, which is where a soft still
    // screen was actually noticed.
    let configuration = VideoEncoderConfiguration.remoteDefault.scaled(toStreamScale: 1.5)
    let sizes = EncodedFrameSizes()
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            if case .encoded(let sampleBuffer) = outcome {
                sizes.record(sampleBuffer)
            }
        }
    ) else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no still-refresh frame size to measure")
        return
    }

    let width = configuration.encodeWidth
    let height = configuration.encodeHeight
    let movingFrames = (0..<24).map { textPixelBuffer(width: width, height: height, scrolledBy: $0) }
    let stillFrame = textPixelBuffer(width: width, height: height, scrolledBy: 500)

    for (index, pixelBuffer) in movingFrames.enumerated() {
        try? encoder.encode(measurementSampleBuffer(pixelBuffer, frameIndex: index))
        try? await Task.sleep(nanoseconds: 16_000_000)
    }
    await sizes.settle(untilAtLeast: movingFrames.count / 2)
    let routineFrameBytes = sizes.medianDeltaFrameBytes
    sizes.reset()

    // The same picture as a key frame on the stream's own session, at the
    // budget the stream is running at -- the cost of resending it as a key
    // frame rather than through the cheaper still-refresh path.
    encoder.requestKeyFrame()
    try? encoder.encode(measurementSampleBuffer(stillFrame, frameIndex: 100))
    await sizes.settle(untilAtLeast: 1)
    let streamKeyFrameBytes = sizes.largestFrameBytes

    guard routineFrameBytes > 0, streamKeyFrameBytes > 0 else {
        print("SKIP: this machine's encoder produced no frames to measure against")
        return
    }

    let refreshed = try? StillFrameEncoder.encodeKeyFrame(
        imageBuffer: stillFrame,
        configuration: configuration,
        presentationTimeNanoseconds: 1_000_000_000
    )
    expect(refreshed != nil, "the still-refresh encoder produces a frame for a picture the stream's own encoder accepted")
    let refreshedBytes = refreshed.map { CMSampleBufferGetTotalSampleSize($0) } ?? 0
    expect(
        refreshedBytes >= 20 * routineFrameBytes,
        "a refreshed still frame is a whole picture, not a delta: expected at least twenty times a routine "
            + "frame's \(routineFrameBytes) bytes, got \(refreshedBytes)"
    )
    expect(
        Double(refreshedBytes) >= 1.5 * Double(streamKeyFrameBytes),
        "and worth more than the same picture keyed at the stream's own budget, which is what left it soft: "
            + "expected at least 1.5x \(streamKeyFrameBytes) bytes, got \(refreshedBytes)"
    )
    expect(
        refreshedBytes <= configuration.stillRefreshCeilingBytes,
        "a screen of text fits the ceiling on the first attempt, so nothing is encoded twice for it: "
            + "ceiling \(configuration.stillRefreshCeilingBytes) bytes, got \(refreshedBytes)"
    )
    print("PASS: a still-screen refresh costs \(refreshedBytes) bytes against \(streamKeyFrameBytes) at the stream budget and \(routineFrameBytes) routine")
}

/// Compressed frame sizes as VideoToolbox reports them, on its own thread.
private final class EncodedFrameSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(bytes: Int, isKeyFrame: Bool)] = []

    func record(_ sampleBuffer: CMSampleBuffer) {
        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           (first[kCMSampleAttachmentKey_NotSync] as? Bool) == true {
            isKeyFrame = false
        }
        let bytes = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        lock.lock()
        frames.append((bytes, isKeyFrame))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Waits for the encoder's own thread to report what it has, rather than
    /// assuming a submitted frame has already come back.
    func settle(untilAtLeast expected: Int) async {
        for _ in 0..<50 where count < expected {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    var medianDeltaFrameBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        let deltas = frames.filter { !$0.isKeyFrame }.map(\.bytes).sorted()
        guard !deltas.isEmpty else { return 0 }
        return deltas[deltas.count / 2]
    }

    var largestFrameBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.map(\.bytes).max() ?? 0
    }

    func reset() {
        lock.lock()
        frames = []
        lock.unlock()
    }
}

/// A screen of small monospaced text: the content a soft still picture is
/// actually noticed on, and the hardest thing for an encoder short of bits.
private func textPixelBuffer(width: Int, height: Int, scrolledBy scrollOffset: Int) -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height
    ]
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        print("FAIL: a measurement pixel buffer could not be created, status \(status)")
        Foundation.exit(1)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        print("FAIL: a measurement drawing context could not be created")
        Foundation.exit(1)
    }
    context.setFillColor(CGColor(red: 0.99, green: 0.99, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 460, height: height))
    let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
    let lines = [
        "public func refreshStillPicture() throws -> Int? {",
        "    guard let captured = lastCapturedFrame.take() else { return nil }",
        "    let still = try StillFrameEncoder.encodeKeyFrame(imageBuffer: image)",
        "    deliverEncodedFrame(still)",
        "}",
        "// A still screen sends one frame and then nothing at all.",
        "let baselinePixels = 1920 * 1200   // 12 Mbps at 60 fps"
    ]
    var baseline = height - 150
    var lineNumber = scrollOffset
    while baseline > 40 {
        let text = String(format: "%4d  ", lineNumber) + lines[abs(lineNumber) % lines.count]
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
            ]
        )
        context.textPosition = CGPoint(x: 500, y: CGFloat(baseline))
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        baseline -= 34
        lineNumber += 1
    }
    return pixelBuffer
}

private func measurementSampleBuffer(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) -> CMSampleBuffer {
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        print("FAIL: a measurement format description could not be created, status \(formatStatus)")
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
        print("FAIL: a measurement sample buffer could not be created, status \(sampleStatus)")
        Foundation.exit(1)
    }
    return sampleBuffer
}
