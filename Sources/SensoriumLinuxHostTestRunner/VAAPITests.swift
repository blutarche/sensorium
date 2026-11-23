#if os(Linux)
import CAVCodec
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumLinuxHost

/// Thrown by a check that cannot run on this machine. The runner reports it
/// as SKIP, never as PASS.
struct TestSkipped: Error {
    let reason: String
}

private func openVAAPIEncoder(
    width: Int,
    height: Int,
    log: OutcomeLog
) throws -> LinuxH264Encoder {
    do {
        let encoder = try LinuxH264Encoder(
            configuration: LinuxEncoderConfiguration(width: width, height: height, backendPreference: .vaapi),
            outcomeHandler: { log.append($0) }
        )
        expect(encoder.backend == .vaapi, "the VA-API encoder was asked for and built")
        return encoder
    } catch let error as LinuxVideoEncoderError {
        throw TestSkipped(reason: "no VA-API H.264 encoder on this machine (\(error))")
    }
}

func testVAAPIStreamDecodesInTheViewerWithConstrainedBaseline() throws {
    let width = 640
    let height = 360
    let log = OutcomeLog()
    let encoder = try openVAAPIEncoder(width: width, height: height, log: log)
    let decoded = VAAPIDecodedCount()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil, outputHandler: { _ in decoded.increment() })
    for index in 0..<30 {
        if index == 14 { encoder.requestKeyFrame() }
        try encoder.encode(syntheticFrame(index: index, width: width, height: height))
        expect(log.outcomes.count == index + 1, "frame \(index) got its outcome during its own encode call")
        try decoder.decode(log.packets[index])
        expect(decoded.count == index + 1, "packet \(index) decoded to a picture at once")
    }
    let packets = log.packets
    expect(packets[0].isKeyFrame && packets[0].codecConfiguration != nil, "the first packet is a key frame with parameter sets")
    for (index, packet) in packets.enumerated() {
        let expected = index == 0 || index == 14
        expect(packet.isKeyFrame == expected, "frame \(index) key frame is \(packet.isKeyFrame), expected \(expected)")
        expect((packet.codecConfiguration != nil) == expected, "frame \(index) parameter sets ride on key frames only")
    }
    let configuration = try H264CodecConfigurationCodec.decode(packets[0].codecConfiguration!)
    let sps = configuration.sequenceParameterSet
    expect(sps[1] == 66, "the driver's SPS states profile_idc \(sps[1]), expected 66")
    expect(sps[2] & 0x40 != 0, "the driver's SPS sets constraint_set1_flag, got \(String(sps[2], radix: 2))")
    let times = packets.map(\.presentationTimeNanoseconds)
    expect(times == times.sorted(), "output order is presentation order")
}

/// A session can replace its encoder before the first picture arrives, so the
/// replaced one shuts down having never been sent a frame.
func testAVAAPIEncoderThatNeverGotAFrameShutsDownCleanly() throws {
    let log = OutcomeLog()
    let encoder = try openVAAPIEncoder(width: 640, height: 360, log: log)
    encoder.shutDown()
    expect(log.outcomes.isEmpty, "an encoder that never got a frame reports nothing at shutdown")
}

private final class VAAPIDecodedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func percentile(_ values: [UInt64], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    let position = min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)
    return Double(sorted[max(position, 0)]) / 1e6
}

private func describe(_ label: String, _ values: [UInt64]) -> String {
    String(format: "%@ p50 %.2f ms, p95 %.2f ms", label, percentile(values, 0.5), percentile(values, 0.95))
}

/// Per-frame latency at 2560x1440, from the `encode` call to the packet, with
/// the stages that make it up. Printed, not asserted: it is a measurement.
func testVAAPILatencyAt1440p() throws {
    let width = 2560
    let height = 1440
    let log = OutcomeLog()
    let encoder = try openVAAPIEncoder(width: width, height: height, log: log)
    let distinct = (0..<4).map { syntheticFrame(index: $0 * 25, width: width, height: height) }
    var total: [UInt64] = []
    var conversion: [UInt64] = []
    var upload: [UInt64] = []
    var encode: [UInt64] = []
    let warmUp = 10
    for index in 0..<130 {
        let source = distinct[index % distinct.count]
        let frame = LinuxVideoFrame(
            width: width,
            height: height,
            pixelFormat: .bgrx,
            bytesPerRow: source.bytesPerRow,
            pixels: source.pixels,
            presentationTimeNanoseconds: UInt64(index) * 16_666_667
        )
        let start = DispatchTime.now().uptimeNanoseconds
        try encoder.encode(frame)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        expect(log.outcomes.count == index + 1, "frame \(index) got its outcome during its own encode call")
        guard index >= warmUp else { continue }
        let stages = encoder.lastTimings
        total.append(elapsed)
        conversion.append(stages.conversion)
        upload.append(stages.upload)
        encode.append(stages.encode)
    }
    print("INFO: VA-API \(width)x\(height), \(total.count) frames after \(warmUp) warm-up")
    print("INFO:   " + describe("encode call to packet", total))
    print("INFO:   " + describe("BGRx to NV12 (CPU)", conversion))
    print("INFO:   " + describe("upload to GPU surface", upload))
    print("INFO:   " + describe("encode and packet wait", encode))
    let bytes = log.packets.reduce(0) { $0 + $1.payload.count }
    print("INFO:   \(bytes) payload bytes over \(log.packets.count) frames")
}
#endif
