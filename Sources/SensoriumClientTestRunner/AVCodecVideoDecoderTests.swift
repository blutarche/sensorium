#if canImport(CAVCodec)
import CAVCodec
import Foundation
import SensoriumClient
import SensoriumCore

/// The recorded H.264 clip these checks decode, sliced out of the fixture
/// blob by the lengths its sidecar records.
private struct DecoderFixture {
    let width: Int
    let height: Int
    let sequenceParameterSet: Data
    let pictureParameterSet: Data
    let accessUnits: [Data]
    let isKeyFrame: [Bool]

    /// The out-of-band parameter sets in the form the wire carries them.
    var codecConfiguration: Data {
        try! H264CodecConfigurationCodec.encode(H264CodecConfiguration(
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet
        ))
    }

    /// One packet as the viewer receives it: parameter sets ride along with
    /// every key frame, exactly as the host's packetizer sends them.
    func packet(_ index: Int, sequence: UInt64? = nil) -> EncodedVideoFramePacket {
        packet(index, carrying: isKeyFrame[index] ? codecConfiguration : nil, sequence: sequence)
    }

    /// The same packet with parameter sets of the caller's choosing, for the
    /// checks that feed a decoder something a host would never send.
    func packet(
        _ index: Int,
        carrying configuration: Data?,
        sequence: UInt64? = nil
    ) -> EncodedVideoFramePacket {
        EncodedVideoFramePacket(
            sequence: sequence ?? UInt64(index),
            presentationTimeNanoseconds: UInt64(index) * 33_333_333,
            isKeyFrame: isKeyFrame[index],
            codecConfiguration: configuration,
            payload: accessUnits[index]
        )
    }

    /// The fixture's parameter sets with the sequence parameter set's payload
    /// replaced by bytes that are not a sequence parameter set at all. The
    /// NAL header stays, so what libavcodec refuses is the content.
    var configurationWithBrokenSequenceParameterSet: Data {
        var broken = sequenceParameterSet
        for offset in 1..<broken.count {
            broken[broken.startIndex + offset] = 0x00
        }
        return try! H264CodecConfigurationCodec.encode(H264CodecConfiguration(
            sequenceParameterSet: broken,
            pictureParameterSet: pictureParameterSet
        ))
    }

    static func load() -> DecoderFixture {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let blob = try! Data(contentsOf: directory.appendingPathComponent("h264-sample.bin"))
        let sidecar = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("h264-sample.json"))
        ) as! [String: Any]
        let spsLength = sidecar["sequenceParameterSetLength"] as! Int
        let ppsLength = sidecar["pictureParameterSetLength"] as! Int
        let lengths = sidecar["accessUnitLengths"] as! [Int]
        var offset = spsLength + ppsLength
        var accessUnits: [Data] = []
        for length in lengths {
            accessUnits.append(Data(blob[offset..<(offset + length)]))
            offset += length
        }
        return DecoderFixture(
            width: sidecar["width"] as! Int,
            height: sidecar["height"] as! Int,
            sequenceParameterSet: Data(blob[0..<spsLength]),
            pictureParameterSet: Data(blob[spsLength..<(spsLength + ppsLength)]),
            accessUnits: accessUnits,
            isKeyFrame: sidecar["accessUnitIsKeyFrame"] as! [Bool]
        )
    }
}

/// Collects decoded frames from the decoder's own thread.
private final class CollectedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [DecodedFrame] = []

    func append(_ frame: DecodedFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    var all: [DecodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func removeAll() {
        lock.lock()
        frames = []
        lock.unlock()
    }
}

/// A path no render node can be at, so the decoder has no hardware device to
/// open and must fall back to software.
private let absentRenderNodePath = "/dev/dri/renderD-sensorium-absent"

func testAVCodecVideoDecoderTests() {
    let fixture = DecoderFixture.load()
    softwareDecodeProducesFramesOfTheFixtureSize(fixture)
    hardwareDecodeProducesVAAPISurfaces(fixture)
    resetBetweenKeyFramesDecodesBoth(fixture)
    aPacketBeforeAnyParameterSetIsRefused(fixture)
    aBrokenParameterSetIsRefusedAndRecoveredFrom(fixture)
    resetCyclesDoNotAccumulateFrames(fixture)
}

private func softwareDecodeProducesFramesOfTheFixtureSize(_ fixture: DecoderFixture) {
    let collected = CollectedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: absentRenderNodePath) { collected.append($0) }
    for index in fixture.accessUnits.indices {
        try! decoder.decode(fixture.packet(index))
    }
    let frames = collected.all
    expect(
        frames.count == fixture.accessUnits.count,
        "software decode returns every frame of the fixture -- got \(frames.count) of \(fixture.accessUnits.count)"
    )
    expect(
        frames.allSatisfy { $0.width == fixture.width && $0.height == fixture.height },
        "every decoded frame carries the fixture's size -- got \(frames.map { "\($0.width)x\($0.height)" })"
    )
    expect(
        decoder.hardwareAcceleration == .softwareFallback,
        "with no render node to open, the decoder reports a software fallback -- got \(String(describing: decoder.hardwareAcceleration))"
    )
    print("PASS: the libavcodec decoder decodes the fixture in software when no render node can be opened")
}

private func hardwareDecodeProducesVAAPISurfaces(_ fixture: DecoderFixture) {
    let renderNodePath = AVCodecVideoDecoder.defaultRenderNodePath
    guard FileManager.default.fileExists(atPath: renderNodePath) else {
        print("SKIP: no render node at \(renderNodePath), so VA-API decode cannot be checked on this machine")
        return
    }
    let collected = CollectedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: renderNodePath) { collected.append($0) }
    for index in fixture.accessUnits.indices {
        try! decoder.decode(fixture.packet(index))
    }
    let frames = collected.all
    expect(!frames.isEmpty, "VA-API decode returns frames -- got none")
    expect(
        decoder.hardwareAcceleration == .hardwareAccelerated,
        "decoding through the render node reports hardware acceleration -- got \(String(describing: decoder.hardwareAcceleration))"
    )
    let boxes = frames.compactMap { $0.payload as? AVFrameBox }
    expect(boxes.count == frames.count, "every frame carries a frame box -- got \(boxes.count) of \(frames.count)")
    expect(
        boxes.allSatisfy { $0.pixelFormat == AV_PIX_FMT_VAAPI },
        "every hardware frame is a VA-API surface -- got \(boxes.map(\.pixelFormat.rawValue))"
    )
    expect(
        boxes.allSatisfy { $0.vaSurfaceID != nil && $0.vaDisplay != nil },
        "every hardware frame hands on the surface and display a presenter needs to export it"
    )
    print("PASS: the libavcodec decoder decodes through VA-API and hands on the surfaces it produced")
}

private func resetBetweenKeyFramesDecodesBoth(_ fixture: DecoderFixture) {
    let keyFrames = fixture.isKeyFrame.indices.filter { fixture.isKeyFrame[$0] }
    expect(keyFrames.count >= 2, "the fixture carries two key frames to reset between -- got \(keyFrames.count)")
    let collected = CollectedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil) { collected.append($0) }
    try! decoder.decode(fixture.packet(keyFrames[0]))
    expect(collected.all.count == 1, "the first key frame decodes -- got \(collected.all.count) frames")
    decoder.reset()
    collected.removeAll()
    try! decoder.decode(fixture.packet(keyFrames[1]))
    expect(
        collected.all.count == 1,
        "the key frame after a reset decodes as well -- got \(collected.all.count) frames"
    )
    print("PASS: the libavcodec decoder decodes a key frame on either side of a reset")
}

private func aPacketBeforeAnyParameterSetIsRefused(_ fixture: DecoderFixture) {
    let decoder = AVCodecVideoDecoder(renderNodePath: nil) { _ in }
    let deltaIndex = fixture.isKeyFrame.firstIndex(of: false)!
    var thrown: Error?
    do {
        try decoder.decode(fixture.packet(deltaIndex))
    } catch {
        thrown = error
    }
    expect(
        thrown as? AVCodecVideoDecoderError == .decoderNotOpened,
        "a packet arriving before any parameter set is refused -- got \(String(describing: thrown))"
    )
    print("PASS: the libavcodec decoder refuses a packet that arrives before any parameter set")
}

private func aBrokenParameterSetIsRefusedAndRecoveredFrom(_ fixture: DecoderFixture) {
    let keyFrameIndex = fixture.isKeyFrame.firstIndex(of: true)!
    let collected = CollectedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil) { collected.append($0) }
    var thrown: Error?
    do {
        try decoder.decode(fixture.packet(
            keyFrameIndex,
            carrying: fixture.configurationWithBrokenSequenceParameterSet
        ))
    } catch {
        thrown = error
    }
    switch thrown as? AVCodecVideoDecoderError {
    case .packetSubmissionFailed, .decoderOpenFailed:
        break
    default:
        expect(
            false,
            "a parameter set libavcodec cannot read fails that packet -- got \(String(describing: thrown))"
        )
    }
    expect(collected.all.isEmpty, "and hands over no picture -- got \(collected.all.count) frames")
    try! decoder.decode(fixture.packet(keyFrameIndex))
    expect(
        collected.all.count == 1,
        "a sound parameter set after a broken one still opens and decodes -- got \(collected.all.count) frames"
    )
    print("PASS: the libavcodec decoder refuses parameter sets it cannot read and recovers on the next sound ones")
}

private func resetCyclesDoNotAccumulateFrames(_ fixture: DecoderFixture) {
    let keyFrameIndex = fixture.isKeyFrame.firstIndex(of: true)!
    let counts = FrameCycleCounts()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil) { _ in counts.recordDelivery() }
    try! decoder.decode(fixture.packet(keyFrameIndex))
    decoder.reset()
    let settled = AVFrameBox.liveCount
    let cycles = 200
    for _ in 0..<cycles {
        try! decoder.decode(fixture.packet(keyFrameIndex))
        decoder.reset()
    }
    expect(
        counts.delivered == cycles + 1,
        "every cycle decodes its key frame -- got \(counts.delivered) of \(cycles + 1)"
    )
    expect(
        counts.peakLive > settled,
        "a frame is alive while it is being delivered -- peak \(counts.peakLive), settled \(settled)"
    )
    expect(
        AVFrameBox.liveCount <= settled,
        "200 decode and reset cycles leave no frame behind -- \(settled) live before, \(AVFrameBox.liveCount) after"
    )
    print("PASS: repeated decode and reset cycles on the libavcodec decoder free every frame they wrapped")
}

/// Counts what the decoder handed over, and how many frames were alive at the
/// busiest moment, from the thread the decoder delivered on.
private final class FrameCycleCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries = 0
    private var peak = 0

    func recordDelivery() {
        lock.lock()
        deliveries += 1
        peak = max(peak, AVFrameBox.liveCount)
        lock.unlock()
    }

    var delivered: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    var peakLive: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}
#else
/// Nothing to decode where libavcodec is not the viewer's decoder.
func testAVCodecVideoDecoderTests() {}
#endif
