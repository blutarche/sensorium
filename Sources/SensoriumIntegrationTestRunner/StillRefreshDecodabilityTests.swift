import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost

/// A still-screen refresh is encoded on a compression session of its own, so
/// the frame it produces carries parameter sets the stream's frames do not.
/// This runs the host's two encoders and the viewer's decoder against each
/// other, in this process, to establish that the viewer decodes such a frame
/// and keeps decoding the stream afterwards.
///
/// No display, no capture and no network: the pictures are drawn into pixel
/// buffers here and the decoded frames are counted and dropped. A machine with
/// no hardware H.264 encoder skips it, because there is nothing to encode with.
@MainActor
func runStillRefreshDecodabilityTests() async {
    // Small on purpose: what is being established is decodability across a
    // parameter-set change, which no pixel count changes.
    let configuration = VideoEncoderConfiguration.remoteDefault.scaled(toStreamScale: 0.5)
    let packetizer = H264SampleBufferPacketizer()
    let packets = PacketBox()
    guard let encoder = try? VideoToolboxEncoder(
        configuration: configuration,
        frameOutcomeHandler: { outcome in
            guard case .encoded(let sampleBuffer) = outcome,
                  let packet = try? packetizer.packet(from: sampleBuffer) else {
                return
            }
            packets.record(packet)
        }
    ) else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no still-refresh frame to decode")
        return
    }

    let decoded = DecodedFrameCounter()
    let decoder = VideoToolboxDecoder { frame in
        decoded.record(frame)
    }

    let pictures = (0..<8).map {
        movingPixelBuffer(width: configuration.encodeWidth, height: configuration.encodeHeight, step: $0)
    }
    for (index, picture) in pictures.enumerated() {
        try? encoder.encode(streamSampleBuffer(picture, frameIndex: index, framesPerSecond: configuration.framesPerSecond))
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let streamPackets = packets.take()
    guard let streamConfiguration = streamPackets.first?.codecConfiguration, streamPackets.count > 1 else {
        print("FAIL: the stream's own encoder produced no keyframe to compare a still refresh against")
        Foundation.exit(1)
    }
    for packet in streamPackets {
        try? decoder.decode(packet)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard decoded.count > 0 else {
        print("FAIL: the viewer decoded nothing from the stream's own frames")
        Foundation.exit(1)
    }

    // The refresh itself: the last picture, encoded whole on its own session.
    guard let still = try? StillFrameEncoder.encodeKeyFrame(
        imageBuffer: pictures[pictures.count - 1],
        configuration: configuration,
        presentationTimeNanoseconds: 5_000_000_000
    ), let stillPacket = try? packetizer.packet(from: still) else {
        print("FAIL: the still-refresh encoder produced no frame for a picture the stream had already encoded")
        Foundation.exit(1)
    }
    guard stillPacket.isKeyFrame, let stillConfiguration = stillPacket.codecConfiguration else {
        print("FAIL: a still refresh is not a keyframe carrying its own parameter sets, so the viewer could not decode it cold")
        Foundation.exit(1)
    }
    guard stillConfiguration != streamConfiguration else {
        print("FAIL: the still refresh carried the stream's parameter sets, so this test is not exercising a change of them")
        Foundation.exit(1)
    }
    let beforeStill = decoded.count
    try? decoder.decode(stillPacket)
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard decoded.count > beforeStill else {
        print("FAIL: the viewer did not decode a keyframe whose parameter sets differ from the stream's")
        Foundation.exit(1)
    }

    // And the stream continues. Its next frame is a keyframe, which is what
    // `HostMediaPipeline` asks for when it sends a refresh -- through the same
    // call, so this test exercises what production runs: the viewer's decoder
    // was rebuilt around the still frame's parameter sets and holds no
    // reference frames from the stream's session any more.
    encoder.completeFramesRequestingKeyFrame()
    for (index, picture) in pictures.enumerated() {
        try? encoder.encode(streamSampleBuffer(picture, frameIndex: pictures.count + index, framesPerSecond: configuration.framesPerSecond))
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let resumed = packets.take()
    guard let firstResumed = resumed.first, firstResumed.isKeyFrame else {
        print("FAIL: the stream's first frame after a still refresh was a delta the viewer's rebuilt decoder holds no reference for")
        Foundation.exit(1)
    }
    let beforeResume = decoded.count
    for packet in resumed {
        try? decoder.decode(packet)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard decoded.count > beforeResume else {
        print("FAIL: the viewer decoded nothing after the stream resumed behind a still refresh")
        Foundation.exit(1)
    }

    print("PASS: the viewer decodes a still refresh encoded on its own session, and the stream that resumes behind it")
}

private final class PacketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [EncodedVideoFramePacket] = []

    func record(_ packet: EncodedVideoFramePacket) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    func take() -> [EncodedVideoFramePacket] {
        lock.lock()
        defer { lock.unlock() }
        let taken = packets
        packets = []
        return taken
    }
}

private final class DecodedFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedCount = 0

    func record(_ frame: DecodedFrame) {
        lock.lock()
        decodedCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodedCount
    }
}

/// A plain picture with one thing moving in it, so the encoder has both
/// something to predict and something to encode.
private func movingPixelBuffer(width: Int, height: Int, step: Int) -> CVPixelBuffer {
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
        print("FAIL: a test pixel buffer could not be created, status \(status)")
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
        print("FAIL: a test drawing context could not be created")
        Foundation.exit(1)
    }
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 40 + step * 12, y: height / 3, width: 220, height: 160))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
    for column in 0..<12 {
        context.fill(CGRect(x: column * 60 + 10, y: 20 + (column % 3) * 9, width: 30, height: 6))
    }
    return pixelBuffer
}

private func streamSampleBuffer(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, framesPerSecond: Int) -> CMSampleBuffer {
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
        duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)),
        presentationTimeStamp: CMTime(value: Int64(frameIndex), timescale: CMTimeScale(framesPerSecond)),
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
