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

/// `canvasReady` and `hostScreenReady` are the two replies that admit a
/// session, so they are where a host says which input it accepts beyond
/// what every host does. The list is plain strings: a token this build does
/// not know is carried, never a reason to refuse the reply.
func testHostInputFeaturesRideOnBothRepliesThatAdmitASession() {
    let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2)
    let features = [HostInputFeature.backForwardButtons, "aFeatureFromANewerHost"]
    let withFeatures: [SensoriumMessage] = [
        .canvasReady(
            displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: Data([1, 2, 3]),
            surfaceID: 0, hostName: "Studio", inputFeatures: features
        ),
        .hostScreenReady(geometry: geometry, resumeTicket: Data([9, 9]), inputFeatures: features)
    ]
    for message in withFeatures {
        let json = controlJSONText(message)
        expect(
            json.contains("\"inputFeatures\":[\"backForwardButtons\",\"aFeatureFromANewerHost\"]"),
            "the features go on the wire as a list of plain strings, got \(json)"
        )
        expect(decodedControl(json: json) == message, "a reply carrying input features round-trips, got \(json)")
    }

    // What a host that predates the field writes: byte-identical to what a
    // reply with no features encodes to now, and read as no features.
    let olderCanvasReady = "{\"displayID\":7,\"hostName\":\"Studio\",\"logicalHeight\":1200,\"logicalWidth\":1920,\"signature\":\"AQID\",\"surfaceID\":0,\"type\":\"canvasReady\"}"
    let olderHostScreenReady = "{\"backingScale\":2,\"logicalHeight\":982,\"logicalWidth\":1512,\"resumeTicket\":\"CQk=\",\"type\":\"hostScreenReady\"}"
    let withoutFeatures: [(String, SensoriumMessage)] = [
        (olderCanvasReady, .canvasReady(
            displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: Data([1, 2, 3]),
            surfaceID: 0, hostName: "Studio"
        )),
        (olderHostScreenReady, .hostScreenReady(geometry: geometry, resumeTicket: Data([9, 9])))
    ]
    for (olderJSON, message) in withoutFeatures {
        expect(
            controlJSONText(message) == olderJSON,
            "a reply with no features encodes exactly as one from before the field existed, got \(controlJSONText(message))"
        )
        let decoded = decodedControl(json: olderJSON)
        expect(decoded == message, "a reply without the field decodes, got \(String(describing: decoded))")
        switch decoded {
        case let .canvasReady(_, _, _, _, _, _, inputFeatures), let .hostScreenReady(_, _, inputFeatures):
            expect(inputFeatures.isEmpty, "a reply without the field decodes with no input features, got \(inputFeatures)")
        default:
            expect(false, "a reply without the field still decodes as the reply it is, got \(String(describing: decoded))")
        }
    }
}

/// The back and forward mouse buttons travel as their own names, which a
/// host that predates them cannot read; `HostInputFeature.backForwardButtons`
/// is what tells a viewer it may send them.
func testBackAndForwardButtonsRoundTripByName() {
    for name in ["back", "forward"] {
        guard let button = CanvasPointerButton(rawValue: name) else {
            expect(false, "\"\(name)\" names a pointer button")
            return
        }
        for isDown in [true, false] {
            let message = SensoriumMessage.input(
                .pointerButton(button: button, isDown: isDown, x: 12, y: 34),
                surfaceID: nil,
                sequence: 5
            )
            let json = controlJSONText(message)
            expect(json.contains("\"button\":\"\(name)\""), "the \(name) button is named on the wire, got \(json)")
            expect(decodedControl(json: json) == message, "a \(name) \(isDown ? "press" : "release") round-trips, got \(json)")
        }
    }
}
