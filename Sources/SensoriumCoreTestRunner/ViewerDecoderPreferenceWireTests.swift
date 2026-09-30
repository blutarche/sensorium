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

func testViewerDecoderPreferenceRoundTripsAndRefusesMalformed() {
    let message = SensoriumMessage.viewerDecoderPreference(h264Profile: .constrainedBaseline)
    let encoded = try! SensoriumFrameCodec.encode(message)
    expect(
        try! SensoriumFrameCodec.decode(encoded) == message,
        "a viewer decoder preference round-trips through the versioned frame"
    )
    expect(
        String(decoding: encoded, as: UTF8.self).contains("\"h264Profile\":\"constrained-baseline\""),
        "the profile travels as its stable token"
    )

    func expectMalformed(_ object: [String: Any], _ reason: String) {
        do {
            _ = try SensoriumFrameCodec.decode(frame(object))
            expect(false, reason)
        } catch SensoriumProtocolError.malformedMessage {
        } catch {
            expect(false, "\(reason) -- reports malformedMessage, not a different error")
        }
    }
    expectMalformed(["type": "viewerDecoderPreference"], "a preference naming no profile is malformed")
    expectMalformed(
        ["type": "viewerDecoderPreference", "h264Profile": "high"],
        "an unrecognised profile on a recognised message type is malformed, not unrecognized"
    )
}
