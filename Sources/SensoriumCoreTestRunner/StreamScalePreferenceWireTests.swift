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

/// A viewer's stream-scale choice, `.automatic` or `.fixed`, round-trips
/// through the wire in both directions, with and without a surfaceID -- the
/// same forward-compatibility rule every other surface-tagged message on
/// this wire already follows.
func testStreamScalePreferenceMessageRoundTripsBothDirections() {
    let messages: [SensoriumMessage] = [
        .streamScalePreference(.automatic, surfaceID: nil),
        .streamScalePreference(.automatic, surfaceID: 1),
        .streamScalePreference(.fixed(1.5), surfaceID: nil),
        .streamScalePreference(.fixed(1.5), surfaceID: 0)
    ]
    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        expect(
            try! SensoriumFrameCodec.decode(encoded) == message,
            "\(message) round-trips through the versioned frame"
        )
    }
    expect(
        !String(
            decoding: try! SensoriumFrameCodec.encode(.streamScalePreference(.automatic, surfaceID: nil)),
            as: UTF8.self
        ).contains("surfaceID"),
        "a preference without a surfaceID omits the key entirely instead of encoding null"
    )
}

/// A `streamScalePreference` sent wrong is refused as malformed, never read
/// as a message this build has simply never heard of -- the wire type is
/// known, only the shape is bad.
func testStreamScalePreferenceMessageMalformedRefusesAsMalformed() {
    func expectMalformed(_ object: [String: Any], _ reason: String) {
        do {
            _ = try SensoriumFrameCodec.decode(frame(object))
            expect(false, reason)
        } catch SensoriumProtocolError.malformedMessage {
        } catch {
            expect(false, "\(reason) -- reports malformedMessage, not a different error")
        }
    }

    expectMalformed(["type": "streamScalePreference"], "a preference with no kind at all is malformed")
    expectMalformed(
        ["type": "streamScalePreference", "streamScalePreferenceKind": "fixed"],
        "a fixed preference with no value is malformed"
    )
    expectMalformed(
        ["type": "streamScalePreference", "streamScalePreferenceKind": "sideways"],
        "an unrecognised kind on a recognised message type is malformed, not unrecognized"
    )
}

/// An off-quantum or out-of-range fixed value is not refused at the wire --
/// `StreamScalePreference.normalized` (via `resolve`) is what brings it onto
/// a real step, downstream of decode.
func testStreamScalePreferenceMessageDoesNotRejectOffQuantumOrOutOfRangeValues() {
    let decoded = try! SensoriumFrameCodec.decode(frame([
        "type": "streamScalePreference",
        "streamScalePreferenceKind": "fixed",
        "streamScalePreferenceValue": 5.0
    ]))
    expect(
        decoded == .streamScalePreference(.fixed(5.0), surfaceID: nil),
        "an out-of-range fixed value decodes as asked, unnormalized -- normalization is StreamScalePreference's own job"
    )
}

/// A key this codec has never heard of, alongside a perfectly good
/// `streamScalePreference` payload, is ignored -- `JSONDecoder` already
/// drops unknown keys, and this is the message that proves it for the new
/// field pair rather than merely asserting the codec's general behaviour.
func testStreamScalePreferenceMessageDropsUnknownExtraFields() {
    let decoded = try! SensoriumFrameCodec.decode(frame([
        "type": "streamScalePreference",
        "streamScalePreferenceKind": "fixed",
        "streamScalePreferenceValue": 1.5,
        "surfaceID": 1,
        "aFieldFromTheFuture": "ignored"
    ]))
    expect(
        decoded == .streamScalePreference(.fixed(1.5), surfaceID: 1),
        "a message carrying a key this build does not recognise still decodes on everything it does recognise"
    )
}

/// `SurfaceTelemetrySample.clampedFromUserChoice` -- what a fixed choice a
/// learned ceiling held back -- rides the existing `telemetry` message
/// rather than a new one, round-trips, and is absent (never a fabricated
/// value) from a host that predates it.
func testTelemetryCarriesClampedFromUserChoice() {
    let message = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: nil,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: 1.75,
            sustainableScaleCeiling: 1.75,
            clampedFromUserChoice: 2.0
        )
    ])
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "a clamped user choice round-trips unchanged"
    )

    let oldPeer = try! SensoriumFrameCodec.decode(frame([
        "type": "telemetry",
        "telemetry": [[
            "surfaceID": 0,
            "encoderInputDropped": 0,
            "globalAdmissionDropped": 0,
            "sendQueueDropped": 0
        ]]
    ]))
    guard case let .telemetry(surfaces) = oldPeer, let sample = surfaces.first else {
        expect(false, "an old-shape telemetry payload still decodes")
        return
    }
    expect(
        sample.clampedFromUserChoice == nil,
        "a sample from a host that predates the field says it does not know, never a fabricated value"
    )
}
