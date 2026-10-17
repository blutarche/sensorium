import Foundation
import SensoriumCore

/// A tag-0 transport packet carrying `innerPayload` as its control message.
/// `declaredInnerLength` overrides the control frame's own 4-byte length, so
/// a test can build a control frame whose prefix disagrees with its bytes.
private func controlTransportPacket(innerPayload: Data, declaredInnerLength: Int? = nil) -> Data {
    var inner = Data()
    var innerLength = UInt32(declaredInnerLength ?? innerPayload.count).bigEndian
    withUnsafeBytes(of: &innerLength) { inner.append(contentsOf: $0) }
    inner.append(innerPayload)
    var packet = Data([0])
    var outerLength = UInt32(inner.count).bigEndian
    withUnsafeBytes(of: &outerLength) { packet.append(contentsOf: $0) }
    packet.append(inner)
    return packet
}

/// The JSON a real encoder writes for `message`, with `original` replaced by
/// `replacement`: how a newer peer's message looks to this build, without
/// hand-writing the rest of the message.
private func controlJSON(for message: SensoriumMessage, replacing original: String, with replacement: String) -> Data {
    let frame = try! SensoriumFrameCodec.encode(message)
    let json = String(decoding: frame.dropFirst(4), as: UTF8.self)
    expect(json.contains(original), "the encoded message contains \(original) to replace, got \(json)")
    return Data(json.replacingOccurrences(of: original, with: replacement).utf8)
}

func testAnUndecodableControlMessageIsDistinctFromAFramingFailure() {
    let button = SensoriumMessage.input(
        .pointerButton(button: .left, isDown: true, x: 10, y: 10),
        surfaceID: nil,
        sequence: nil
    )
    let unreadable: [(String, Data)] = [
        ("a payload that is not JSON", Data("not json at all".utf8)),
        ("an input naming a button this build has no case for",
         controlJSON(for: button, replacing: "\"left\"", with: "\"sideways\"")),
        ("an input of a kind this build has no case for",
         controlJSON(for: button, replacing: "\"kind\":\"pointerButton\"", with: "\"kind\":\"pointerSqueezed\"")),
        ("a known message missing a field it requires", Data("{\"type\":\"hello\"}".utf8))
    ]
    for (label, payload) in unreadable {
        do {
            let decoded = try SensoriumTransportPacketCodec.decode(controlTransportPacket(innerPayload: payload))
            expect(false, "\(label) is not decoded into a message, got \(decoded)")
        } catch SensoriumProtocolError.undecodableControlMessage {
        } catch {
            expect(false, "\(label) is reported as an undecodable control message, got \(error)")
        }
    }

    // The control frame's own length prefix is framing, not content: a
    // prefix that disagrees with its bytes means the stream itself is
    // broken, and that still ends the connection.
    let hello = Data("{\"protocolVersion\":1,\"deviceName\":\"Laptop\",\"type\":\"hello\"}".utf8)
    do {
        _ = try SensoriumTransportPacketCodec.decode(
            controlTransportPacket(innerPayload: hello, declaredInnerLength: hello.count + 1)
        )
        expect(false, "a control frame whose length prefix disagrees with its bytes is rejected")
    } catch SensoriumProtocolError.frameLengthMismatch {
    } catch {
        expect(false, "a control frame whose length prefix disagrees with its bytes reports frameLengthMismatch, got \(error)")
    }

    // The control codec on its own keeps the errors it always had, so a
    // caller that reads a bare control frame still learns what was wrong.
    do {
        var bare = Data()
        var length = UInt32(9).bigEndian
        withUnsafeBytes(of: &length) { bare.append(contentsOf: $0) }
        bare.append(Data("not json!".utf8))
        _ = try SensoriumFrameCodec.decode(bare)
        expect(false, "a bare control frame that is not JSON is rejected")
    } catch is DecodingError {
    } catch {
        expect(false, "a bare control frame that is not JSON still reports a decoding error, got \(error)")
    }
}

/// A modifier bit this build does not know is masked off rather than failing
/// the event: refusing a newer viewer's key-up over it would leave the key
/// held down on the host.
func testAKeyEventWithAnUnknownModifierBitDecodesWithTheBitMasked() {
    for isDown in [true, false] {
        let key = SensoriumMessage.input(
            .key(keyCode: 0, isDown: isDown, modifiers: .shift),
            surfaceID: nil,
            sequence: nil
        )
        let payload = controlJSON(for: key, replacing: "\"modifiers\":1", with: "\"modifiers\":49")
        let decoded = try? SensoriumTransportPacketCodec.decode(controlTransportPacket(innerPayload: payload))
        expect(
            decoded == .control(key),
            "a key \(isDown ? "down" : "up") carrying shift and two bits this build does not know decodes as shift alone, got \(String(describing: decoded))"
        )
    }
}

/// Input arrives at well over a hundred events a second, so a peer sending
/// something this build cannot read gets one log line per ten seconds, and
/// that line counts every message dropped since the one before it.
func testUndecodableMessageLogPacerWritesOneLinePerTenSecondsCountingTheDrops() {
    var pacer = UndecodableMessageLogPacer()
    let second: Int64 = 1_000_000_000
    let start: Int64 = 500 * second
    expect(pacer.noteDrop(atNanoseconds: start) == 1, "the first drop is reported at once, as one message")
    for offset in 1...200 {
        let reported = pacer.noteDrop(atNanoseconds: start + Int64(offset) * second / 25)
        expect(reported == nil, "a drop \(offset) twenty-fifths of a second after the last line writes no line, got \(String(describing: reported))")
    }
    expect(
        pacer.noteDrop(atNanoseconds: start + 10 * second - 1) == nil,
        "a drop just short of ten seconds after the last line writes no line"
    )
    expect(
        pacer.noteDrop(atNanoseconds: start + 10 * second) == 202,
        "the first drop ten seconds after the last line reports every drop since that line, itself included"
    )
    expect(
        pacer.noteDrop(atNanoseconds: start + 11 * second) == nil,
        "the window starts again from the line just written"
    )
    expect(
        pacer.noteDrop(atNanoseconds: start + 60 * second) == 2,
        "a drop long after the last line reports the drops since it"
    )
}
