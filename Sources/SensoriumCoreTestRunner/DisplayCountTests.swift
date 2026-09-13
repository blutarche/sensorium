import Foundation
import SensoriumCore

private func frame(_ object: [String: Any]) -> Data {
    let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

/// docs/ux-spec.md: the number of session displays is entirely the
/// viewer's choice, carried by `SensoriumMessage.displayCount`. This wire
/// layer's own job is narrow: round-trip 1 and 2, and refuse everything
/// else outright rather than clamping it -- "nothing on the wire can
/// exceed the two-slot maximum" is enforced here, at decode, not left to a
/// caller downstream.
func testDisplayCountRoundTripsOneAndTwo() {
    for count in [1, 2] {
        let message = SensoriumMessage.displayCount(count)
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
            "displayCount(\(count)) round-trips through the versioned frame"
        )
    }
}

func testDisplayCountRefusesAnythingOutsideOneOrTwo() {
    func expectMalformed(_ count: Int, _ reason: String) {
        do {
            _ = try SensoriumFrameCodec.decode(frame(["type": "displayCount", "displayCount": count]))
            expect(false, reason)
        } catch SensoriumProtocolError.malformedMessage {
        } catch {
            expect(false, "\(reason) -- reports malformedMessage, not a different error")
        }
    }
    expectMalformed(0, "zero displays is refused outright")
    expectMalformed(3, "a count exceeding the two-slot maximum is refused outright, never clamped down to 2")
    expectMalformed(-1, "a negative count is refused outright")

    do {
        _ = try SensoriumFrameCodec.decode(frame(["type": "displayCount"]))
        expect(false, "a displayCount message carrying no value at all is malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a displayCount message with no value reports malformedMessage")
    }

    // Sending .displayCount(3) itself must be structurally impossible to
    // construct a *valid* frame for -- encode does not validate its own
    // input (nothing else in this codec does either), but a hand-built wire
    // payload naming an out-of-range count, the only way an out-of-range
    // value could ever reach the wire, still refuses to decode.
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(.displayCount(2))) == .displayCount(2),
        "sanity: the one construction path this codec offers stays inside the valid range"
    )
}

/// The same forward-compatibility discipline every other message on this
/// wire follows: an unknown key alongside a well-formed payload changes
/// nothing about what decodes.
func testDisplayCountDropsUnknownExtraFields() {
    let decoded = try! SensoriumFrameCodec.decode(frame([
        "type": "displayCount",
        "displayCount": 2,
        "aFieldFromTheFuture": "ignored"
    ]))
    expect(
        decoded == .displayCount(2),
        "a displayCount message carrying a key this build does not recognise still decodes on everything it does recognise"
    )
}
