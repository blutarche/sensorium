import Foundation
import SensoriumCore

private func viewerTelemetryFrame(_ object: [String: Any]) -> Data {
    let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

/// The host measures its own stages and cannot see any of the viewer's. Until
/// this message existed the only evidence a host had about the far end was the
/// absence of complaints, so a link that could not carry what the host was
/// producing looked, from the host, exactly like a link that could.
func testViewerTelemetryRoundTripsAndIsSkippableByAnOldHost() {
    let full = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 1,
            endToEnd: StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_000_000),
            receive: StageLatencySample(p50Nanoseconds: 8_000_000, p95Nanoseconds: 15_000_000),
            decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 5_000_000),
            presentedFramesPerSecond: 44.5,
            decodedFramesPerSecond: 59.9,
            receivedBitsPerSecond: 41_800_000
        )
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(full)) == full,
        "every stage the viewer measured round-trips unchanged"
    )

    // The honest shape of a viewer that has measured nothing yet: absent
    // stages, never zeroes, which a host would otherwise read as a link with
    // no latency at all.
    let empty = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: nil,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil
        )
    )
    let emptyJSON = String(decoding: try! SensoriumFrameCodec.encode(empty), as: UTF8.self)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(empty)) == empty,
        "a viewer with nothing measured round-trips as nothing measured"
    )
    expect(
        !emptyJSON.contains("endToEnd") && !emptyJSON.contains("presentedFramesPerSecond"),
        "an unmeasured stage is an absent field, not a null or a zero on the wire"
    )
    // The viewer measures its own input round trip and shows it, but does not
    // send it: nothing the host does about a stream it is producing follows
    // from how long a keystroke took to come back.
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(full), as: UTF8.self).contains("inputRoundTrip"),
        "the input round trip stays a local reading and never travels"
    )

    // A host one protocol revision behind sees a `type` it has never heard of.
    // It must skip the message, exactly as `viewerFocus` and `telemetry`
    // already are by every peer that predates them.
    expect(
        try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
            "type": "viewerTelemetryV2",
            "viewerTelemetry": ["surfaceID": 0]
        ])) == .unrecognized(type: "viewerTelemetryV2"),
        "a host that does not know this message skips it rather than throwing"
    )
    expect(
        (try? SensoriumFrameCodec.decode(viewerTelemetryFrame(["type": "viewerTelemetry"]))) == nil,
        "a viewer telemetry message carrying no reading at all is rejected"
    )

    // Nothing else on this wire grows a field because the message exists.
    let canvasRequest = SensoriumMessage.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(canvasRequest), as: UTF8.self)
            .contains("viewerTelemetry"),
        "messages that carry no viewer telemetry are byte-identical to what they were"
    )
}

/// The other half of the same conversation: what the host applied, and why it
/// is below what the viewer asked for. Absent from a host that predates the
/// fields, which the viewer must read as "unknown" rather than as a limit.
func testTelemetryCarriesTheAppliedFrameRateQualityAndLimit() {
    let message = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: 29.8,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: 1.5,
            sustainableScaleCeiling: 1.5,
            appliedFramesPerSecond: 30,
            qualityScale: 0.75,
            fidelityLimitReason: "link"
        )
    ])
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "the applied frame rate, the quality scale and the limit reason round-trip unchanged"
    )

    let oldHost = try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
        "type": "telemetry",
        "telemetry": [[
            "surfaceID": 0,
            "encoderInputDropped": 0,
            "globalAdmissionDropped": 0,
            "sendQueueDropped": 0
        ]]
    ]))
    guard case let .telemetry(oldSurfaces) = oldHost, let oldSample = oldSurfaces.first else {
        expect(false, "an old host's telemetry still decodes as telemetry")
        return
    }
    expect(
        oldSample.appliedFramesPerSecond == nil
            && oldSample.qualityScale == nil
            && oldSample.fidelityLimitReason == nil,
        "a host that predates the three fields reports no frame rate, no quality and no reason"
    )

    let quiet = SensoriumMessage.telemetry(surfaces: [
        SurfaceTelemetrySample(
            surfaceID: 0,
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
        !quietJSON.contains("appliedFramesPerSecond")
            && !quietJSON.contains("qualityScale")
            && !quietJSON.contains("fidelityLimitReason"),
        "a host holding nothing back does not pay for the fields that would say so"
    )
}

/// A reading that stopped arriving must stop being an answer. The store keeps
/// the last one per surface and refuses to hand it back once it is older than
/// the same three send intervals every other telemetry reading is judged by.
func testViewerTelemetryStoreForgetsAReadingThatStoppedArriving() {
    var store = ViewerTelemetryStore()
    let reading = ViewerTelemetrySample(
        surfaceID: 0,
        endToEnd: StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_000_000),
        receive: nil,
        decode: nil,
        presentedFramesPerSecond: 58,
        decodedFramesPerSecond: 60,
        receivedBitsPerSecond: 41_800_000
    )

    expect(
        store.latest(surfaceID: 0, atSeconds: 0) == nil,
        "a store nothing has ever reached to reports nothing, not a default reading"
    )

    store.record(reading, atSeconds: 100)
    expect(
        store.latest(surfaceID: 0, atSeconds: 100.5) == reading,
        "the reading that arrived is the reading the host reads back"
    )
    expect(
        store.latest(surfaceID: 1, atSeconds: 100.5) == nil,
        "one surface's reading is never handed back for the other"
    )
    expect(
        store.latest(surfaceID: 0, atSeconds: 100 + TelemetryPolicy.staleAfterSeconds - 0.01) == reading,
        "a reading still inside the staleness window is still current"
    )
    expect(
        store.latest(surfaceID: 0, atSeconds: 100 + TelemetryPolicy.staleAfterSeconds + 0.01) == nil,
        "a reading older than three send intervals is gone, not a flattering last-known number"
    )

    let newer = ViewerTelemetrySample(
        surfaceID: 0,
        endToEnd: nil,
        receive: nil,
        decode: nil,
        presentedFramesPerSecond: 22,
        decodedFramesPerSecond: nil,
        receivedBitsPerSecond: nil
    )
    store.record(newer, atSeconds: 110)
    expect(
        store.latest(surfaceID: 0, atSeconds: 110) == newer,
        "the newest reading replaces the one before it"
    )

    // A surfaceID outside the two this session can have names no slot to
    // keep, and telemetry is a measurement rather than a routing key -- so it
    // is dropped, never stored under a slot it does not belong to.
    store.record(
        ViewerTelemetrySample(
            surfaceID: 7,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: 1,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil
        ),
        atSeconds: 110
    )
    expect(
        store.latest(surfaceID: 7, atSeconds: 110) == nil && store.latest(surfaceID: 0, atSeconds: 110) == newer,
        "a reading naming a surface this session cannot have is dropped and displaces nothing"
    )
}

/// A viewer's reading is data from the far end of a wire, and everything the
/// host will eventually decide from it -- how many frames to encode, at what
/// quality -- is a decision an impossible number can steer. A rate that is
/// not a number at all, or a duration that ran backwards, is refused at the
/// door rather than clamped into something plausible: clamping a negative
/// latency to zero fabricates the most flattering reading there is, which is
/// exactly the answer a host must never be handed. `LatencySamples.record`
/// already refuses a negative duration for the same reason.
func testViewerTelemetryStoreRefusesImpossibleNumbers() {
    func reading(
        presentedFramesPerSecond: Double? = 30,
        decodedFramesPerSecond: Double? = 60,
        receivedBitsPerSecond: Double? = 41_800_000,
        endToEnd: StageLatencySample? = StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_000_000)
    ) -> ViewerTelemetrySample {
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: endToEnd,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: presentedFramesPerSecond,
            decodedFramesPerSecond: decodedFramesPerSecond,
            receivedBitsPerSecond: receivedBitsPerSecond
        )
    }

    var store = ViewerTelemetryStore()
    let good = reading()
    expect(
        store.record(good, atSeconds: 100) && store.latest(surfaceID: 0, atSeconds: 100) == good,
        "an ordinary reading is accepted and kept"
    )

    let impossible: [(String, ViewerTelemetrySample)] = [
        ("a rate that is not a number", reading(presentedFramesPerSecond: .nan)),
        ("an infinite rate", reading(decodedFramesPerSecond: .infinity)),
        ("a negative bitrate", reading(receivedBitsPerSecond: -1)),
        ("a negative presented rate", reading(presentedFramesPerSecond: -30)),
        (
            "a duration that ran backwards",
            reading(endToEnd: StageLatencySample(p50Nanoseconds: -1, p95Nanoseconds: 34_000_000))
        ),
        (
            "a p95 that ran backwards",
            reading(endToEnd: StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: -34_000_000))
        )
    ]
    for (label, sample) in impossible {
        expect(
            !store.record(sample, atSeconds: 101),
            "\(label) is refused"
        )
        expect(
            store.latest(surfaceID: 0, atSeconds: 101) == good,
            "\(label) leaves the last reading the host could trust exactly as it was"
        )
    }

    // Zero is not impossible. A session that presented no frames in the last
    // second is reporting something true and alarming, and refusing it would
    // hide the one reading a host most needs.
    let stalled = reading(presentedFramesPerSecond: 0, decodedFramesPerSecond: 0, receivedBitsPerSecond: 0)
    expect(
        store.record(stalled, atSeconds: 102) && store.latest(surfaceID: 0, atSeconds: 102) == stalled,
        "a viewer reporting that nothing arrived at all is telling the truth, not sending a bad number"
    )
}
