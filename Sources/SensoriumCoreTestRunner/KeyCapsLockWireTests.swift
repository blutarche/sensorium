import Foundation
import SensoriumCore

private func controlJSONText(_ message: SensoriumMessage) -> String {
    String(decoding: try! SensoriumFrameCodec.encode(message).dropFirst(4), as: UTF8.self)
}

private func decodedControl(json: String) -> SensoriumMessage? {
    let payload = Data(json.utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return try? SensoriumFrameCodec.decode(frame)
}

/// A key carries the viewer's Caps Lock state, on or off, so the host can
/// type capitals while it is on. A key without the field is one from a
/// viewer that does not say, and reads as exactly that.
func testKeyEventsCarryTheViewersCapsLockState() {
    for capsLock in [true, false] {
        let message = SensoriumMessage.input(
            .key(keyCode: 0, isDown: true, modifiers: [.shift], capsLock: capsLock),
            surfaceID: nil,
            sequence: 3
        )
        let json = controlJSONText(message)
        expect(json.contains("\"capsLock\":\(capsLock)"), "Caps Lock \(capsLock ? "on" : "off") goes on the wire, got \(json)")
        expect(decodedControl(json: json) == message, "a key with Caps Lock \(capsLock ? "on" : "off") round-trips, got \(json)")
    }

    let olderKey = "{\"input\":{\"isDown\":true,\"keyCode\":0,\"kind\":\"key\",\"modifiers\":1},\"inputSequence\":3,\"type\":\"input\"}"
    let withoutState = SensoriumMessage.input(.key(keyCode: 0, isDown: true, modifiers: [.shift]), surfaceID: nil, sequence: 3)
    expect(
        controlJSONText(withoutState) == olderKey,
        "a key that does not say encodes exactly as one from before the field existed, got \(controlJSONText(withoutState))"
    )
    let decoded = decodedControl(json: olderKey)
    expect(decoded == withoutState, "a key without the field decodes with no Caps Lock state, got \(String(describing: decoded))")

    // What lets a host that predates the field read a newer viewer's keys:
    // a field the decoder does not know inside `input` is skipped.
    let newerKey = "{\"input\":{\"aFieldFromANewerViewer\":7,\"isDown\":true,\"keyCode\":0,\"kind\":\"key\",\"modifiers\":1},\"inputSequence\":3,\"type\":\"input\"}"
    expect(
        decodedControl(json: newerKey) == withoutState,
        "a key carrying a field this build does not know still decodes, got \(String(describing: decodedControl(json: newerKey)))"
    )
}
