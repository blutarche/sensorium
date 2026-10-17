import Foundation
import SensoriumCore

private func controlJSONText(_ message: SensoriumMessage) -> String {
    String(decoding: try! SensoriumFrameCodec.encode(message).dropFirst(4), as: UTF8.self)
}

private func controlFrame(json: String) -> Data {
    let payload = Data(json.utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

/// A line-based mouse wheel's scroll carries its lines next to the points
/// every host already reads, so a host that knows about lines scrolls by
/// them and one that does not keeps scrolling by points.
func testScrollEventsCarryAWheelsLinesNextToItsPoints() {
    let wheel = SensoriumMessage.input(
        .scrolled(
            deltaX: -15, deltaY: 30, x: 100, y: 200, phase: nil, momentumPhase: nil,
            lineDeltaX: -1.5, lineDeltaY: 3
        ),
        surfaceID: nil,
        sequence: 4
    )
    let json = controlJSONText(wheel)
    expect(
        json.contains("\"lineDeltaX\":-1.5") && json.contains("\"lineDeltaY\":3"),
        "a wheel scroll puts its lines on the wire, got \(json)"
    )
    expect(
        json.contains("\"deltaX\":-15") && json.contains("\"deltaY\":30"),
        "and its points stay exactly as they were, got \(json)"
    )
    expect((try? SensoriumFrameCodec.decode(controlFrame(json: json))) == wheel, "a wheel scroll round-trips, got \(json)")

    let olderScroll = "{\"input\":{\"deltaX\":-15,\"deltaY\":30,\"kind\":\"scrolled\",\"x\":100,\"y\":200},\"inputSequence\":4,\"type\":\"input\"}"
    let pointsOnly = SensoriumMessage.input(
        .scrolled(deltaX: -15, deltaY: 30, x: 100, y: 200, phase: nil, momentumPhase: nil),
        surfaceID: nil,
        sequence: 4
    )
    expect(
        controlJSONText(pointsOnly) == olderScroll,
        "a scroll without lines encodes exactly as one from before the fields existed, got \(controlJSONText(pointsOnly))"
    )
    expect(
        (try? SensoriumFrameCodec.decode(controlFrame(json: olderScroll))) == pointsOnly,
        "and one without the fields decodes with no lines"
    )

    for unreadable in ["1e999", "-1e999"] {
        let json = olderScroll.replacingOccurrences(of: "\"kind\"", with: "\"lineDeltaY\":\(unreadable),\"kind\"")
        expect(
            (try? SensoriumFrameCodec.decode(controlFrame(json: json))) == nil,
            "a scroll whose lines are not a finite number is refused, as its points would be: \(json)"
        )
    }
}
