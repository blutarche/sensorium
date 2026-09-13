import Foundation
import SensoriumCore

func testEncodedVideoFramePacketRoundTripsAndBoundsPayload() {
    let packet = EncodedVideoFramePacket(
        sequence: 9,
        presentationTimeNanoseconds: 123_456,
        isKeyFrame: true,
        codecConfiguration: Data([0x67, 0x42, 0x00, 0x1F, 0x68, 0xCE]),
        payload: Data([1, 2, 3, 4])
    )
    let encoded = try! EncodedVideoFrameCodec.encode(packet)
    expect(try! EncodedVideoFrameCodec.decode(encoded) == packet, "encoded video frame packet round-trips")

    let oversized = EncodedVideoFramePacket(
        sequence: 1,
        presentationTimeNanoseconds: 1,
        isKeyFrame: false,
        payload: Data(repeating: 0, count: EncodedVideoFrameCodec.maximumPayloadLength + 1)
    )
    do {
        _ = try EncodedVideoFrameCodec.encode(oversized)
        expect(false, "oversized encoded video frame is rejected")
    } catch SensoriumProtocolError.frameTooLarge {
    } catch {
        expect(false, "oversized encoded video frame reports frameTooLarge")
    }
}

func testTaggedTransportPacketDemultiplexesControlAndVideo() {
    let packets: [SensoriumTransportPacket] = [
        .control(.hello(protocolVersion: 1, deviceName: "MacBook")),
        .video(EncodedVideoFramePacket(sequence: 2, presentationTimeNanoseconds: 3, isKeyFrame: false, payload: Data([8, 9]))),
    ]
    for packet in packets {
        let encoded = try! SensoriumTransportPacketCodec.encode(packet)
        expect(try! SensoriumTransportPacketCodec.decode(encoded) == packet, "tagged transport packet round-trips")
    }
}

func testTag2VideoForSurfaceRoundTripsAndMatchesTag1Payload() {
    let frame = EncodedVideoFramePacket(
        sequence: 5,
        presentationTimeNanoseconds: 42,
        isKeyFrame: true,
        codecConfiguration: Data([1, 2]),
        payload: Data([3, 4, 5])
    )
    let plainVideoEncoded = try! SensoriumTransportPacketCodec.encode(.video(frame))
    let plainVideoPayload = plainVideoEncoded.dropFirst(5)
    for surfaceID: UInt32 in [0, 1] {
        let packet = SensoriumTransportPacket.videoForSurface(surfaceID: surfaceID, frame: frame)
        let encoded = try! SensoriumTransportPacketCodec.encode(packet)
        expect(encoded[0] == 2, "video-for-surface encodes under transport tag 2")
        expect(
            try! SensoriumTransportPacketCodec.decode(encoded) == packet,
            "tag-2 video-for-surface round-trips for surfaceID \(surfaceID)"
        )
        expect(
            encoded.dropFirst(5 + 4) == plainVideoPayload,
            "tag-2's payload after the surfaceID prefix is byte-identical to what tag 1 would carry"
        )
    }
}

func testTag2RejectsSurfaceIDOutsideCapAndTooShortPayload() {
    let frame = EncodedVideoFramePacket(sequence: 1, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([1]))
    do {
        _ = try SensoriumTransportPacketCodec.encode(.videoForSurface(surfaceID: 2, frame: frame))
        expect(false, "encoding tag-2 with a surfaceID outside {0,1} is rejected")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "an out-of-range surfaceID on encode reports malformedMessage")
    }

    // Hand-build a tag-2 frame with surfaceID 2 straight on the wire, bypassing encode's own guard.
    var raw = Data([2])
    let framePayload = try! EncodedVideoFrameCodec.encode(frame)
    var surfaceID = UInt32(2).bigEndian
    var innerPayload = Data()
    withUnsafeBytes(of: &surfaceID) { innerPayload.append(contentsOf: $0) }
    innerPayload.append(framePayload)
    var length = UInt32(innerPayload.count).bigEndian
    withUnsafeBytes(of: &length) { raw.append(contentsOf: $0) }
    raw.append(innerPayload)
    do {
        _ = try SensoriumTransportPacketCodec.decode(raw)
        expect(false, "decoding tag-2 with a surfaceID outside {0,1} is rejected")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "an out-of-range surfaceID on decode reports malformedMessage")
    }

    // A tag-2 payload shorter than the 4-byte surfaceID prefix must throw, not read garbage.
    var shortRaw = Data([2])
    var shortLength = UInt32(3).bigEndian
    withUnsafeBytes(of: &shortLength) { shortRaw.append(contentsOf: $0) }
    shortRaw.append(Data([0, 0, 0]))
    do {
        _ = try SensoriumTransportPacketCodec.decode(shortRaw)
        expect(false, "a tag-2 frame shorter than the surfaceID prefix is rejected")
    } catch SensoriumProtocolError.frameTooShort {
    } catch {
        expect(false, "a too-short tag-2 payload reports frameTooShort")
    }
}

func testTag2EncodesAndDecodesAtMaximumFrameSize() {
    // The boundary case for the cap arithmetic: maximumPayloadLength is
    // EncodedVideoFrameCodec.maximumPayloadLength + 64, so a maximal 4 MB
    // encoded frame plus the 4-byte surfaceID prefix must still fit.
    let codecConfiguration = Data(repeating: 0xAA, count: EncodedVideoFrameCodec.maximumCodecConfigurationLength)
    let payload = Data(repeating: 0xBB, count: EncodedVideoFrameCodec.maximumPayloadLength - codecConfiguration.count)
    let frame = EncodedVideoFramePacket(
        sequence: 1,
        presentationTimeNanoseconds: 1,
        isKeyFrame: true,
        codecConfiguration: codecConfiguration,
        payload: payload
    )
    let packet = SensoriumTransportPacket.videoForSurface(surfaceID: 1, frame: frame)
    let encoded = try! SensoriumTransportPacketCodec.encode(packet)
    expect(
        try! SensoriumTransportPacketCodec.decode(encoded) == packet,
        "a maximal-size frame under tag 2 still encodes and decodes"
    )
}

func testUnrecognizedTransportTagIsSkippableNotFatal() {
    // Tag 9 does not exist yet: this is exactly what an older build sees from
    // a newer peer's future message kind.
    var raw = Data([9])
    let payload = Data([0xAA, 0xBB, 0xCC])
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { raw.append(contentsOf: $0) }
    raw.append(payload)

    let decoded = try! SensoriumTransportPacketCodec.decode(raw)
    expect(
        decoded == .unrecognized(tag: 9, payload: payload),
        "an unrecognised transport tag decodes to .unrecognized with the tag and payload intact, rather than throwing"
    )

    let reEncoded = try! SensoriumTransportPacketCodec.encode(decoded)
    expect(reEncoded == raw, "an unrecognized packet re-encodes to the same bytes it was decoded from")
}

func testMalformedTransportFramesAreStillFatal() {
    do {
        _ = try SensoriumTransportPacketCodec.decode(Data([0, 0, 0]))
        expect(false, "a transport frame shorter than the 5-byte header is rejected")
    } catch SensoriumProtocolError.frameTooShort {
    } catch {
        expect(false, "a too-short transport frame reports frameTooShort")
    }

    var oversizedHeader = Data([0])
    var oversizedLength = UInt32(SensoriumTransportPacketCodec.maximumPayloadLength + 1).bigEndian
    withUnsafeBytes(of: &oversizedLength) { oversizedHeader.append(contentsOf: $0) }
    do {
        _ = try SensoriumTransportPacketCodec.decode(oversizedHeader)
        expect(false, "a transport frame declaring an over-limit payload length is rejected")
    } catch SensoriumProtocolError.frameTooLarge {
    } catch {
        expect(false, "an oversized transport frame reports frameTooLarge")
    }

    var mismatchedHeader = Data([0])
    var declaredLength = UInt32(4).bigEndian
    withUnsafeBytes(of: &declaredLength) { mismatchedHeader.append(contentsOf: $0) }
    mismatchedHeader.append(Data([1, 2]))
    do {
        _ = try SensoriumTransportPacketCodec.decode(mismatchedHeader)
        expect(false, "a transport frame whose declared length does not match its actual bytes is rejected")
    } catch SensoriumProtocolError.frameLengthMismatch {
    } catch {
        expect(false, "a mismatched transport frame reports frameLengthMismatch")
    }
}

func testUnrecognizedMessageTypeIsSkippableNotFatal() {
    // "futureFocusSignal" does not exist yet: this is exactly what an older
    // build sees from a newer peer's future control message.
    let payload = Data("{\"type\":\"futureFocusSignal\"}".utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)

    let decoded = try! SensoriumFrameCodec.decode(frame)
    expect(
        decoded == .unrecognized(type: "futureFocusSignal"),
        "an unrecognized control message type decodes to .unrecognized with the type intact, rather than throwing"
    )

    do {
        _ = try SensoriumFrameCodec.encode(.unrecognized(type: "futureFocusSignal"))
        expect(false, "encoding .unrecognized must throw -- fabricating wire bytes for it would itself be inventing a new message type")
    } catch SensoriumProtocolError.unsupportedMessage {
    } catch {
        expect(false, "encoding .unrecognized reports the expected error")
    }
}

func testMalformedControlJSONStillThrows() {
    let payload = Data("not json at all".utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)

    do {
        _ = try SensoriumFrameCodec.decode(frame)
        expect(false, "a genuinely malformed (non-JSON) control payload is still rejected, not tolerated like an unknown type")
    } catch is DecodingError {
    } catch {
        expect(false, "malformed control JSON reports a decoding error")
    }
}

func testH264CodecConfigurationRoundTripsParameterSets() {
    let configuration = H264CodecConfiguration(
        sequenceParameterSet: Data([0x67, 0x42, 0x00, 0x1F]),
        pictureParameterSet: Data([0x68, 0xCE, 0x06, 0xE2])
    )
    let encoded = try! H264CodecConfigurationCodec.encode(configuration)
    expect(try! H264CodecConfigurationCodec.decode(encoded) == configuration, "H.264 codec configuration round-trips SPS/PPS")
}

func testMalformedFramesAreRejected() {
    let encoded = try! SensoriumFrameCodec.encode(.hello(protocolVersion: 1, deviceName: "Mini"))
    var mismatchedLength = encoded
    mismatchedLength[3] &+= 1
    do {
        _ = try SensoriumFrameCodec.decode(mismatchedLength)
        expect(false, "mismatched frame length is rejected")
    } catch SensoriumProtocolError.frameLengthMismatch {
    } catch {
        expect(false, "mismatched frame length reports the expected error")
    }

    let oversizedLength: [UInt8] = [0x00, 0x01, 0x00, 0x01]
    do {
        _ = try SensoriumFrameCodec.decode(Data(oversizedLength))
        expect(false, "oversized frame is rejected")
    } catch SensoriumProtocolError.frameTooLarge {
    } catch {
        expect(false, "oversized frame reports the expected error")
    }
}

func testTransportFramesDecodeFromASliceThatDoesNotStartAtZero() {
    // Every caller today hands `decode` a fresh `Data`, so its indexing has
    // never met a slice -- and a receive path that reads a buffer once and
    // splits it into frames is the obvious next caller.
    let packets: [SensoriumTransportPacket] = [
        .clipboard(.text("hello")),
        .control(.hello(protocolVersion: 1, deviceName: "MacBook")),
        .unrecognized(tag: 200, payload: Data([9, 9, 9]))
    ]
    for packet in packets {
        var buffer = Data([0xAA, 0xBB, 0xCC])
        buffer.append(try! SensoriumTransportPacketCodec.encode(packet))
        let slice = buffer.dropFirst(3)
        expect(slice.startIndex == 3, "the frame really does start past index zero")
        expect(
            try! SensoriumTransportPacketCodec.decode(slice) == packet,
            "a frame decodes identically whether it arrives as its own Data or as a slice of a larger buffer"
        )
    }
}

/// A presentation time is a monotonic nanosecond count, so nothing this host
/// sends ever has the top bit set. The viewer turns the field into a signed
/// `CMTime` value, and a number past `Int64.max` is not an odd timestamp there
/// but one it cannot express at all. It is refused here, at the boundary where
/// the bytes stop being bytes, rather than saturated into a timestamp nobody
/// measured.
func testEncodedVideoFrameRefusesAPresentationTimePastInt64Max() {
    let unrepresentable = EncodedVideoFramePacket(
        sequence: 7,
        presentationTimeNanoseconds: UInt64(Int64.max) + 1,
        isKeyFrame: true,
        payload: Data([1, 2, 3])
    )
    do {
        let decoded = try EncodedVideoFrameCodec.decode(EncodedVideoFrameCodec.encode(unrepresentable))
        expect(
            false,
            "a presentation time past Int64.max is refused, got \(decoded.presentationTimeNanoseconds)"
        )
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "and refused as a malformed frame, got \(error)")
    }

    // The largest value that is expressible is still a frame, so the check is
    // a boundary and not a new ceiling on how long a session may run.
    let largest = EncodedVideoFramePacket(
        sequence: 8,
        presentationTimeNanoseconds: UInt64(Int64.max),
        isKeyFrame: true,
        payload: Data([4, 5, 6])
    )
    expect(
        (try? EncodedVideoFrameCodec.decode(EncodedVideoFrameCodec.encode(largest))) == largest,
        "the largest presentation time a viewer can express still decodes"
    )
}
