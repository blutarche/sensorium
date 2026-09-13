import Foundation
import SensoriumCore

func testViewerFocusRoundTripsEveryStateAndIsIgnorableByAnOldPeer() {
    let states: [(String, SensoriumMessage)] = [
        ("the second canvas", .viewerFocus(surfaceID: 1, hasViewerFocus: true)),
        ("the default canvas", .viewerFocus(surfaceID: 0, hasViewerFocus: true)),
        ("no canvas at all", .viewerFocus(surfaceID: nil, hasViewerFocus: false))
    ]
    for (name, message) in states {
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
            "viewer focus on \(name) round-trips unchanged"
        )
    }

    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(.viewerFocus(surfaceID: nil, hasViewerFocus: false)), as: UTF8.self)
            .contains("surfaceID"),
        "a focus report naming no surface omits the key entirely instead of encoding null"
    )
    expect(
        SensoriumMessage.viewerFocus(surfaceID: nil, hasViewerFocus: false)
            != SensoriumMessage.viewerFocus(surfaceID: nil, hasViewerFocus: true),
        "no viewer focus is a distinct state from focus on the canvas an absent surfaceID names"
    )

    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    expect(
        (try? SensoriumFrameCodec.decode(frame(["type": "viewerFocus", "surfaceID": 1]))) == nil,
        "a focus report that never says whether the viewer has focus at all is rejected"
    )

    // Exactly what a peer one protocol revision behind sees: the same fields,
    // under a `type` it has never heard of. It must skip the message, not
    // throw -- decoding switches on `type` before it reads any field, so an
    // unknown revision of this message can never become a fatal decode error.
    let futureRevision = try! SensoriumFrameCodec.decode(frame([
        "type": "viewerFocusV2",
        "surfaceID": 1,
        "hasViewerFocus": true
    ]))
    expect(
        futureRevision == .unrecognized(type: "viewerFocusV2"),
        "a peer that does not know this message decodes it as unrecognized rather than throwing"
    )

    // `canvasRefused` is the other answer to a canvasRequest. It takes the same
    // forward-compatibility path: its own `type`, which a peer that predates it
    // decodes as `.unrecognized` and skips.
    for (label, refusal) in [
        ("the second canvas", SensoriumMessage.canvasRefused(reason: "canvas-creation-in-progress", surfaceID: 1)),
        ("the primary canvas", SensoriumMessage.canvasRefused(reason: "canvas-creation-in-progress", surfaceID: 0)),
        ("a request that named no surface", SensoriumMessage.canvasRefused(reason: "canvas-creation-in-progress", surfaceID: nil))
    ] {
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(refusal)) == refusal,
            "a refusal of \(label) round-trips unchanged"
        )
    }
    expect(
        !String(
            decoding: try! SensoriumFrameCodec.encode(.canvasRefused(reason: "r", surfaceID: nil)),
            as: UTF8.self
        ).contains("surfaceID"),
        "a refusal without a surfaceID omits the key entirely instead of encoding null"
    )
    // The hazard this message shape exists to avoid: a refusal must never
    // arrive under a `type` that makes a peer treat it as a canvas it may draw
    // on. It is a distinct type, so an older peer skips it instead.
    let refusalFrame = try! SensoriumFrameCodec.encode(
        .canvasRefused(reason: "canvas-creation-in-progress", surfaceID: 1)
    )
    expect(
        String(decoding: refusalFrame, as: UTF8.self).contains("\"type\":\"canvasRefused\""),
        "a refusal goes out under its own wire type"
    )
    if case .canvasReady = try! SensoriumFrameCodec.decode(refusalFrame) {
        expect(false, "a refusal must never decode as a canvasReady")
    }
    expect(
        (try? SensoriumFrameCodec.decode(frame(["type": "canvasRefused", "surfaceID": 1]))) == nil,
        "a refusal that carries no reason is rejected rather than decoded as a reasonless one"
    )

    // A peer that never sends focus at all must be byte-identical to before.
    let input = SensoriumMessage.input(.pointerMoved(x: 4, y: 8), surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(input)) == input,
        "input is unaffected by the new message"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(input), as: UTF8.self).contains("ViewerFocus"),
        "messages that carry no focus report do not grow a new wire field"
    )
}

/// Host-measured telemetry is per-surface, forward-compatible like every
/// other addition to this wire, and must never grow the payload of a message
/// that carries none of it.
func testTelemetryRoundTripsPerSurfaceAndIsIgnorableByAnOldPeer() {
    let message = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 2_400_000, p95Nanoseconds: 4_100_000),
            encode: StageLatencySample(p50Nanoseconds: 6_500_000, p95Nanoseconds: 9_300_000),
            send: StageLatencySample(p50Nanoseconds: 100_000, p95Nanoseconds: 200_000),
            framesPerSecond: 59.8,
            encoderInputDropped: 3,
            globalAdmissionDropped: 1,
            sendQueueDropped: 0
        ),
        SurfaceTelemetrySample(
            surfaceID: 1,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: nil,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
    ])
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "telemetry round-trips every surface's values, including absent stages, unchanged"
    )

    // A peer one protocol revision behind sees the same fields under a `type`
    // it has never heard of, exactly like `viewerFocus`'s own forward-
    // compatibility test above: it must skip the message, not throw or end
    // the session.
    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
    let futureRevision = try! SensoriumFrameCodec.decode(frame(["type": "telemetryV2", "telemetry": []]))
    expect(
        futureRevision == .unrecognized(type: "telemetryV2"),
        "a future revision of telemetry is likewise skippable, not fatal"
    )

    // Every other message must stay byte-identical: telemetry off, or no
    // viewer showing it, must cost nothing on the wire for anything else.
    let canvasRequest = SensoriumMessage.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(canvasRequest)) == canvasRequest,
        "the canvas request is unaffected by telemetry existing as a message kind"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(canvasRequest), as: UTF8.self)
            .contains("telemetry"),
        "messages that carry no telemetry do not grow a new wire field"
    )
}

/// The viewer cannot see the resolution it is actually receiving unless the
/// host says so: `viewerDrawableSize` travels one way and the host re-derives
/// the scale itself, so a measured backoff from 2.00x to 1.50x is invisible to
/// the client that asked for 2.00x. These two fields are that answer, and they
/// must be as omittable as every other addition to this wire.
func testTelemetryCarriesTheAppliedScaleAndTheLearnedCeiling() {
    let message = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: 59.8,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: 1.5,
            sustainableScaleCeiling: 1.75
        )
    ])
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "the applied scale and the learned ceiling round-trip unchanged"
    )

    func frame(_ object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    // An older host that predates both fields. It must decode into a sample
    // that says it does not know, never into a fabricated 1.0.
    let oldPeer = try! SensoriumFrameCodec.decode(frame([
        "type": "telemetry",
        "telemetry": [[
            "surfaceID": 0,
            "encoderInputDropped": 0,
            "globalAdmissionDropped": 0,
            "sendQueueDropped": 0
        ]]
    ]))
    guard case let .telemetry(oldSurfaces) = oldPeer, let oldSample = oldSurfaces.first else {
        expect(false, "an old host's telemetry still decodes as telemetry")
        return
    }
    expect(
        oldSample.appliedStreamScale == nil && oldSample.sustainableScaleCeiling == nil,
        "a host that never sends the new fields yields no scale at all, not a guessed one"
    )
    expect(
        oldSample.encoderInputDropped == 0 && oldSample.framesPerSecond == nil,
        "everything an old host does send is unaffected by the two new fields"
    )

    // A host with nothing measured yet must not grow the payload either.
    let quiet = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 1,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: nil,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
    ])
    let quietJSON = String(decoding: try! SensoriumFrameCodec.encode(quiet), as: UTF8.self)
    expect(
        !quietJSON.contains("appliedStreamScale") && !quietJSON.contains("sustainableScaleCeiling"),
        "an absent scale is an absent field, not a null or a zero on the wire"
    )
}

/// Stands in for `NSPasteboard` so every clipboard decision is testable
/// without AppKit. `changeCount` moves exactly like the real one: only a
/// write to the pasteboard advances it.
