#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumLinuxHost

func testEveryFrameGetsOneOutcomeAndTheFirstIsAKeyFrameWithParameterSets() throws {
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(width: 178, height: 98, backendPreference: .openH264),
        outcomeHandler: { log.append($0) }
    )
    expect(encoder.backend == .openH264, "the software encoder was asked for and built")
    let frameCount = 12
    for index in 0..<frameCount {
        try encoder.encode(syntheticFrame(index: index, width: 178, height: 98))
        expect(log.outcomes.count == index + 1, "frame \(index) got its outcome during its own encode call")
    }
    let packets = log.packets
    expect(packets.count == frameCount, "\(frameCount) frames in, \(packets.count) packets out")
    expect(packets.map(\.sequence) == (0..<UInt64(frameCount)).map { $0 }, "sequence numbers count up from 0")
    expect(packets[0].isKeyFrame, "the first packet is a key frame")
    expect(packets[0].codecConfiguration != nil, "the first packet carries the parameter sets")
    expect(packets.dropFirst().allSatisfy { !$0.isKeyFrame && $0.codecConfiguration == nil }, "later packets are plain deltas")
    for (index, packet) in packets.enumerated() {
        expect(packet.presentationTimeNanoseconds == UInt64(index) * 16_666_667, "packet \(index) keeps its capture time")
    }
}

/// Encodes one frame and returns the SPS the key frame carried, raw.
private func sequenceParameterSet(
    of profile: LinuxEncoderProfile,
    backend: LinuxEncoderBackendPreference = .openH264
) throws -> Data {
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(width: 178, height: 98, profile: profile, backendPreference: backend),
        outcomeHandler: { log.append($0) }
    )
    try encoder.encode(syntheticFrame(index: 0, width: 178, height: 98))
    let configuration = try H264CodecConfigurationCodec.decode(log.packets[0].codecConfiguration!)
    expect(configuration.sequenceParameterSet[0] & 0x1F == 7, "the configuration's first unit is an SPS")
    expect(configuration.pictureParameterSet[0] & 0x1F == 8, "the configuration's second unit is a PPS")
    return configuration.sequenceParameterSet
}

func testProfileFollowsTheViewerPreference() throws {
    for preference in [ViewerH264Profile.constrainedBaseline, nil] {
        let profile = LinuxEncoderProfile(viewerPreference: preference)
        expect(profile == .constrainedBaseline, "\(String(describing: preference)) maps to constrained baseline")
        let sps = try sequenceParameterSet(of: profile)
        expect(sps[1] == 66, "constrained baseline is profile_idc 66, got \(sps[1])")
        expect(sps[2] & 0x40 != 0, "constraint_set1_flag is set, got \(String(sps[2], radix: 2))")
    }
    let main = try sequenceParameterSet(of: .main)
    expect(main[1] == 77, "main is profile_idc 77, got \(main[1])")
    let high = try sequenceParameterSet(of: .high)
    expect(high[1] == 100, "high is profile_idc 100, got \(high[1])")
}

func testARequestedKeyFrameLandsOnTheNextFrameOnly() throws {
    let log = OutcomeLog()
    // A long interval, so only the request can produce a key frame.
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(
            width: 178, height: 98, keyFrameIntervalSeconds: 3600, backendPreference: .openH264
        ),
        outcomeHandler: { log.append($0) }
    )
    let requestedBefore: Set<Int> = [4, 9]
    for index in 0..<14 {
        if requestedBefore.contains(index) {
            encoder.requestKeyFrame()
            encoder.requestKeyFrame()  // asking twice is still one key frame
        }
        try encoder.encode(syntheticFrame(index: index, width: 178, height: 98))
    }
    let packets = log.packets
    expect(packets.count == 14, "every frame produced a packet")
    for (index, packet) in packets.enumerated() {
        let expected = index == 0 || requestedBefore.contains(index)
        expect(packet.isKeyFrame == expected, "frame \(index) key frame is \(packet.isKeyFrame), expected \(expected)")
        expect(
            (packet.codecConfiguration != nil) == expected,
            "frame \(index) carries parameter sets exactly when it is a key frame"
        )
    }
    expect(packets.map(\.sequence) == (0..<14).map { UInt64($0) }, "sequence numbers run on through key frames")
}

func testAKeyFrameFollowsWhenTheIntervalPassesInPresentationTime() throws {
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(
            width: 178, height: 98, keyFrameIntervalSeconds: 1, backendPreference: .openH264
        ),
        outcomeHandler: { log.append($0) }
    )
    // A quiet screen: three frames in the first half second, then nothing
    // until two and a half seconds on. Counted in frames this would be
    // minutes away; counted in time it is due.
    let times: [UInt64] = [0, 100_000_000, 200_000_000, 2_700_000_000, 2_800_000_000]
    for (index, time) in times.enumerated() {
        try encoder.encode(syntheticFrame(index: index, width: 178, height: 98, timeNanoseconds: time))
    }
    expect(log.packets.map(\.isKeyFrame) == [true, false, false, true, false], "the late frame is a key frame")
}

/// The slice types of an access unit's NAL units, from each slice header's
/// first two Exp-Golomb numbers. 0 and 5 are P, 1 and 6 are B, 2 and 7 are I.
private func sliceTypes(of payload: Data) -> [Int] {
    var types: [Int] = []
    var offset = 0
    let bytes = [UInt8](payload)
    while offset + 4 < bytes.count {
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let header = bytes[(offset + 4)]
        let nalType = header & 0x1F
        if nalType == 1 || nalType == 5 {
            var reader = BitReader(Array(bytes[(offset + 5)..<min(offset + 4 + length, bytes.count)]))
            _ = reader.exponentialGolomb()  // first_mb_in_slice
            types.append(reader.exponentialGolomb())
        }
        offset += 4 + length
    }
    return types
}

private struct BitReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() -> Int {
        guard position / 8 < bytes.count else { return 0 }
        let value = Int(bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
        position += 1
        return value
    }

    mutating func exponentialGolomb() -> Int {
        var zeros = 0
        while bit() == 0, zeros < 32 { zeros += 1 }
        var value = 1
        for _ in 0..<zeros { value = value << 1 | bit() }
        return value - 1
    }
}

func testThereAreNoBFramesSoPresentationOrderIsOutputOrder() throws {
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(width: 178, height: 98, backendPreference: .openH264),
        outcomeHandler: { log.append($0) }
    )
    for index in 0..<30 {
        try encoder.encode(syntheticFrame(index: index, width: 178, height: 98))
    }
    let packets = log.packets
    expect(packets.count == 30, "30 frames in, 30 packets out")
    let times = packets.map(\.presentationTimeNanoseconds)
    expect(times == times.sorted() && Set(times).count == times.count, "presentation times strictly increase in output order")
    for packet in packets {
        let types = sliceTypes(of: packet.payload)
        expect(!types.isEmpty, "a packet holds at least one slice")
        expect(types.allSatisfy { $0 % 5 != 1 }, "no slice is a B slice, got \(types)")
    }
}

func testAnEncodeThatCannotProceedFailsWithoutLosingAKeyFrameRequest() throws {
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(
            width: 178, height: 98, keyFrameIntervalSeconds: 3600, backendPreference: .openH264
        ),
        outcomeHandler: { log.append($0) }
    )
    try encoder.encode(syntheticFrame(index: 0, width: 178, height: 98))
    encoder.requestKeyFrame()
    var refused = false
    do {
        try encoder.encode(syntheticFrame(index: 1, width: 100, height: 98))
    } catch let error as LinuxVideoEncoderError {
        refused = error == .invalidFrame
    }
    expect(refused, "a frame of the wrong size is refused")
    expect(log.outcomes.count == 1, "a refused frame gets no outcome, since the encoder never accepted it")
    try encoder.encode(syntheticFrame(index: 2, width: 178, height: 98))
    expect(log.packets.last?.isKeyFrame == true, "the request survived the refused frame and landed on the next one")
    do {
        try encoder.encode(dmaBuf: LinuxDMABufFrame(
            width: 178, height: 98, drmFormat: 0, drmModifier: 0, planes: [], presentationTimeNanoseconds: 0
        ))
        expect(false, "DMA-BUF input is not built yet")
    } catch let error as LinuxVideoEncoderError {
        expect(error == .dmaBufInputNotSupported, "DMA-BUF input names itself as unsupported")
    }
    encoder.shutDown()
    var afterShutDown: LinuxVideoEncoderError?
    do {
        try encoder.encode(syntheticFrame(index: 3, width: 178, height: 98))
    } catch let error as LinuxVideoEncoderError {
        afterShutDown = error
    }
    expect(afterShutDown == .shutDown, "an encoder that was shut down refuses frames")
}

func testBitRateAndConfigurationFollowTheMacOSRule() throws {
    let full = LinuxEncoderConfiguration(width: 1920, height: 1200, framesPerSecond: 60)
    expect(full.averageBitRate == 12_000_000, "the 1920x1200 at 60 fps baseline is 12 Mbps, got \(full.averageBitRate)")
    let double = LinuxEncoderConfiguration(width: 3840, height: 2400, framesPerSecond: 60)
    expect(double.averageBitRate == 48_000_000, "four times the pixels is four times the bits")
    let soft = LinuxEncoderConfiguration(width: 1920, height: 1200, framesPerSecond: 30, qualityScale: 0.5)
    expect(soft.averageBitRate == 3_000_000, "half the rate and half the quality is a quarter of the bits")
    expect(LinuxEncoderConfiguration(width: 10, height: 10, qualityScale: .nan).qualityScale == 1, "NaN quality is full quality")
    expect(LinuxEncoderConfiguration(width: 10, height: 10, qualityScale: 0).qualityScale == 0.25, "quality is floored")
    var rejected = false
    do {
        _ = try LinuxH264Encoder(configuration: LinuxEncoderConfiguration(width: 177, height: 98), outcomeHandler: { _ in })
    } catch let error as LinuxVideoEncoderError {
        rejected = error == .invalidConfiguration
    }
    expect(rejected, "an odd width cannot be encoded as 4:2:0")
}

func testAutomaticFallsBackToOpenH264WhenTheRenderNodeCannotOpen() throws {
    let log = OutcomeLog()
    let configuration = LinuxEncoderConfiguration(
        width: 178, height: 98, backendPreference: .automatic, renderNodePath: "/nonexistent/renderD128"
    )
    let encoder = try LinuxH264Encoder(configuration: configuration, outcomeHandler: { log.append($0) })
    expect(encoder.backend == .openH264, "with no usable render node the software encoder runs")
    try encoder.encode(syntheticFrame(index: 0, width: 178, height: 98))
    expect(log.packets.count == 1 && log.packets[0].isKeyFrame, "and it encodes")
    var refused = false
    do {
        _ = try LinuxH264Encoder(
            configuration: LinuxEncoderConfiguration(
                width: 178, height: 98, backendPreference: .vaapi, renderNodePath: "/nonexistent/renderD128"
            ),
            outcomeHandler: { _ in }
        )
    } catch is LinuxVideoEncoderError {
        refused = true
    }
    expect(refused, "asking for VA-API outright does not fall back")
}

func testASecondOfStreamStaysNearTheBitRateBudget() throws {
    let log = OutcomeLog()
    let configuration = LinuxEncoderConfiguration(width: 640, height: 360, framesPerSecond: 60, backendPreference: .openH264)
    let encoder = try LinuxH264Encoder(configuration: configuration, outcomeHandler: { log.append($0) })
    for index in 0..<60 {
        try encoder.encode(syntheticFrame(index: index, width: 640, height: 360))
    }
    let bytes = log.packets.reduce(0) { $0 + $1.payload.count + ($1.codecConfiguration?.count ?? 0) }
    let budget = configuration.averageBitRate / 8
    // Order of magnitude only: the rate controller needs time to settle, and
    // OpenH264 without frame skipping cannot hold a rate exactly. A rate
    // controller that saw the pts timebase as the frame rate would be off by
    // orders of magnitude.
    expect(bytes > budget / 20 && bytes < budget * 4, "60 frames cost \(bytes) bytes against a \(budget) byte second")
}
#endif
