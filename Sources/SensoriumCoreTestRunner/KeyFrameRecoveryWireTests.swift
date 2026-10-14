import Foundation
import SensoriumCore

/// A viewer that asks for a key frame when it needs one says so once per
/// session, then asks for one per surface. Neither message carries a field an
/// older peer does not already parse, and an older peer has never heard of
/// either `type`, so it skips both.
func testKeyFrameRecoveryMessagesRoundTripAndAreIgnorableByAnOldPeer() {
    let messages: [(String, SensoriumMessage, String)] = [
        ("the declaration", .viewerKeyFrameRecovery, "viewerKeyFrameRecovery"),
        ("a request for the second canvas", .keyFrameRequest(surfaceID: 1), "keyFrameRequest"),
        ("a request for the first canvas", .keyFrameRequest(surfaceID: 0), "keyFrameRequest"),
        ("a request naming no surface", .keyFrameRequest(surfaceID: nil), "keyFrameRequest")
    ]
    for (name, message, type) in messages {
        guard let encoded = try? SensoriumFrameCodec.encode(message) else {
            expect(false, "\(name) encodes")
            return
        }
        expect(
            (try? SensoriumFrameCodec.decode(encoded)) == message,
            "\(name) round-trips unchanged"
        )
        let object = try? JSONSerialization.jsonObject(with: encoded.dropFirst(4)) as? [String: Any]
        expect(object?["type"] as? String == type, "\(name) travels as `\(type)`, got \(String(describing: object))")
        expect(
            Set(object?.keys.map { $0 } ?? []).isSubset(of: ["type", "surfaceID"]),
            "\(name) carries no field an older peer does not already parse, got \(String(describing: object))"
        )
    }

    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    // Exactly what a peer one protocol revision behind sees: fields it knows,
    // under a `type` it has never heard of. It skips the message rather than
    // throwing, because decoding switches on `type` before it reads a field.
    for object in [
        ["type": "viewerKeyFrameRecoveryV2"],
        ["type": "keyFrameRequestV2", "surfaceID": 1]
    ] as [[String: Any]] {
        let type = object["type"] as! String
        expect(
            (try? SensoriumFrameCodec.decode(frame(object))) == .unrecognized(type: type),
            "a peer that does not know `\(type)` decodes it as unrecognized rather than throwing"
        )
    }
}
