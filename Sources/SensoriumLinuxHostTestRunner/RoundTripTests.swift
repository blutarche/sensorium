#if os(Linux)
import CAVCodec
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumLinuxHost

/// The luma plane of a decoded frame, tightly packed.
private func lumaPlane(of decoded: DecodedFrame) -> [UInt8]? {
    guard let box = decoded.payload as? AVFrameBox, let frame = box.frame,
          let plane = frame.pointee.data.0 else { return nil }
    let stride = Int(frame.pointee.linesize.0)
    var out = [UInt8](repeating: 0, count: box.width * box.height)
    for y in 0..<box.height {
        for x in 0..<box.width {
            out[y * box.width + x] = plane[y * stride + x]
        }
    }
    return out
}

/// The luma the converter gives the source frame: what a lossless encoder
/// would hand the decoder.
private func expectedLuma(of frame: LinuxVideoFrame) -> [UInt8] {
    let width = frame.width
    let height = frame.height
    var luma = [UInt8](repeating: 0, count: width * height)
    var chroma = [UInt8](repeating: 0, count: width * height)
    frame.pixels.withUnsafeBytes { source in
        luma.withUnsafeMutableBufferPointer { lumaPlane in
            chroma.withUnsafeMutableBufferPointer { chromaPlane in
                YUV420Converter.convert(
                    source: source.baseAddress!,
                    sourceBytesPerRow: frame.bytesPerRow,
                    width: width,
                    height: height,
                    layout: .nv12,
                    luma: lumaPlane.baseAddress!,
                    lumaBytesPerRow: width,
                    chroma: chromaPlane.baseAddress!,
                    chromaBytesPerRow: width,
                    redChroma: nil,
                    redChromaBytesPerRow: 0
                )
            }
        }
    }
    return luma
}

/// A decoded frame keeps its decoder's lifetime rules, so the frames are
/// held in a box that outlives the closure.
private final class DecodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DecodedFrame] = []

    func append(_ frame: DecodedFrame) {
        lock.lock()
        stored.append(frame)
        lock.unlock()
    }

    var frames: [DecodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func testTheViewersDecoderOpensTheStreamAndTheLumaMatches() throws {
    // 178x98 is not a multiple of 16 on either axis, so the stream's cropping
    // is exercised too.
    let width = 178
    let height = 98
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(width: width, height: height, backendPreference: .openH264),
        outcomeHandler: { log.append($0) }
    )
    let decoded = DecodedFrames()
    // Software decode, with the decoder libavcodec picks for H.264 and the
    // rest of the viewer's own setup: no render node is offered.
    let decoder = AVCodecVideoDecoder(renderNodePath: nil, outputHandler: { decoded.append($0) })
    var inputs: [LinuxVideoFrame] = []
    for index in 0..<24 {
        let frame = syntheticFrame(index: index, width: width, height: height)
        inputs.append(frame)
        try encoder.encode(frame)
        if index == 11 { encoder.requestKeyFrame() }
        let packet = log.packets[index]
        try decoder.decode(packet)
        // No decoder delay: a picture is on screen as soon as its packet is
        // handed over, which a screen that stops changing depends on.
        expect(decoded.frames.count == index + 1, "packet \(index) decoded to a picture at once")
    }
    expect(log.packets[12].isKeyFrame, "the requested key frame decoded in the same stream")
    for (index, picture) in decoded.frames.enumerated() {
        expect(picture.width == width && picture.height == height, "picture \(index) is \(picture.width)x\(picture.height)")
        guard let actual = lumaPlane(of: picture) else {
            expect(false, "picture \(index) has a luma plane")
            return
        }
        let wanted = expectedLuma(of: inputs[index])
        var total = 0
        for position in 0..<actual.count {
            total += abs(Int(actual[position]) - Int(wanted[position]))
        }
        let mean = Double(total) / Double(actual.count)
        expect(mean < 4, "picture \(index) luma is off by \(mean) on average")
    }
}
#endif
