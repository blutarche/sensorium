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

/// The host's own menu-bar ping display's one field on the wire: session-wide,
/// carried on the same per-second message every other viewer telemetry rides
/// on, and skippable by a host that predates it.
func testViewerTelemetryRoundTripRoundTripsThePingFieldAndIsSkippableByAnOldHost() {
    let withPing = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: nil,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil,
            roundTripNanoseconds: 8_400_000
        )
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withPing)) == withPing,
        "the round trip field round-trips unchanged"
    )

    // An old host reads this exact frame with no such field in its own
    // decoded value; a new viewer talking to an old host would otherwise
    // have no way to know the field is silently dropped, which is the same
    // guarantee `testTelemetryCarriesTheAppliedFrameRateQualityAndLimit`
    // already checks in the other direction.
    let oldFormatFrame = viewerTelemetryFrame([
        "type": "viewerTelemetry",
        "viewerTelemetry": ["surfaceID": 0]
    ])
    guard case let .viewerTelemetry(oldSample) = try! SensoriumFrameCodec.decode(oldFormatFrame) else {
        expect(false, "an old-format viewer telemetry message still decodes as one")
        return
    }
    expect(oldSample.roundTripNanoseconds == nil, "a message that predates the field reports no ping")

    let withPingJSON = String(decoding: try! SensoriumFrameCodec.encode(withPing), as: UTF8.self)
    expect(withPingJSON.contains("roundTripNanoseconds"), "a viewer that measured a round trip sends it")

    let withoutPing = SensoriumMessage.viewerTelemetry(
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
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(withoutPing), as: UTF8.self).contains("roundTripNanoseconds"),
        "a viewer with no clock sync yet omits the field rather than sending a null"
    )
}

/// What a host one revision behind decodes a viewer telemetry message into:
/// the reading exactly as it was before the decoder fields existed. The
/// payload is synthesized `Codable` on both sides, so this is the old host's
/// own decoder, not an approximation of it.
private struct PreDecoderFieldsViewerTelemetrySample: Codable, Equatable {
    let surfaceID: UInt32
    let endToEnd: StageLatencySample?
    let receive: StageLatencySample?
    let decode: StageLatencySample?
    let presentedFramesPerSecond: Double?
    let decodedFramesPerSecond: Double?
    let receivedBitsPerSecond: Double?
    let roundTripNanoseconds: Int64?
}

private struct PreDecoderFieldsEnvelope: Codable {
    let type: String
    let viewerTelemetry: PreDecoderFieldsViewerTelemetrySample?
}

/// Which decoder the viewer is running and where its decode time goes, split
/// into the wait ahead of the decoder and the decoder itself. A diagnosis
/// only: an old host must read a new viewer's message as it always did, and
/// a new host must read an old viewer's as one that reported none of it.
func testViewerTelemetryCarriesTheDecoderFieldsAndStaysCompatibleBothWays() {
    let decoderOnly = StageLatencySample(p50Nanoseconds: 9_000_000, p95Nanoseconds: 14_000_000)
    let queueWait = StageLatencySample(p50Nanoseconds: 1_000_000, p95Nanoseconds: 31_000_000)
    let withDecoderFields = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: StageLatencySample(p50Nanoseconds: 12_000_000, p95Nanoseconds: 45_000_000),
            presentedFramesPerSecond: 28,
            decodedFramesPerSecond: 29,
            receivedBitsPerSecond: nil,
            decodesInHardware: false,
            decoderOnly: decoderOnly,
            decodeQueueWait: queueWait
        )
    )
    let frame = try! SensoriumFrameCodec.encode(withDecoderFields)
    expect(
        try! SensoriumFrameCodec.decode(frame) == withDecoderFields,
        "the decoder kind and both decode timings round-trip unchanged"
    )

    let oldHost = try! JSONDecoder().decode(PreDecoderFieldsEnvelope.self, from: frame.dropFirst(4))
    expect(
        oldHost.type == "viewerTelemetry"
            && oldHost.viewerTelemetry == PreDecoderFieldsViewerTelemetrySample(
                surfaceID: 0,
                endToEnd: nil,
                receive: nil,
                decode: StageLatencySample(p50Nanoseconds: 12_000_000, p95Nanoseconds: 45_000_000),
                presentedFramesPerSecond: 28,
                decodedFramesPerSecond: 29,
                receivedBitsPerSecond: nil,
                roundTripNanoseconds: nil
            ),
        "a host that predates the decoder fields reads every field it knows and skips the rest"
    )

    guard case let .viewerTelemetry(oldViewer) = try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
        "type": "viewerTelemetry",
        "viewerTelemetry": ["surfaceID": 0, "decodedFramesPerSecond": 30]
    ])) else {
        expect(false, "a viewer telemetry message without the decoder fields still decodes as one")
        return
    }
    expect(
        oldViewer.decodedFramesPerSecond == 30
            && oldViewer.decodesInHardware == nil
            && oldViewer.decoderOnly == nil
            && oldViewer.decodeQueueWait == nil,
        "a viewer that predates the decoder fields reports no decoder kind and no split, not a guess"
    )

    let unreported = SensoriumMessage.viewerTelemetry(
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
    let unreportedJSON = String(decoding: try! SensoriumFrameCodec.encode(unreported), as: UTF8.self)
    expect(
        !unreportedJSON.contains("decodesInHardware")
            && !unreportedJSON.contains("decoderOnly")
            && !unreportedJSON.contains("decodeQueueWait"),
        "a viewer with nothing to say about its decoder omits the fields rather than sending nulls"
    )
}

/// Frames that arrive together inside one display refresh can only show the
/// newest, so the viewer reports how many it replaced on time. An older viewer
/// omits the rate, and the host must read that as none.
func testViewerTelemetryCarriesTheSupersededOnTimeRateAndStaysCompatible() {
    let withRate = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: 33,
            decodedFramesPerSecond: 50,
            receivedBitsPerSecond: nil,
            supersededOnTimeFramesPerSecond: 9.5
        )
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withRate)) == withRate,
        "the on-time superseded rate round-trips unchanged"
    )

    guard case let .viewerTelemetry(oldViewer) = try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
        "type": "viewerTelemetry",
        "viewerTelemetry": ["surfaceID": 0, "presentedFramesPerSecond": 33, "decodedFramesPerSecond": 50]
    ])) else {
        expect(false, "a viewer telemetry message without the rate still decodes as one")
        return
    }
    expect(
        oldViewer.presentedFramesPerSecond == 33 && oldViewer.supersededOnTimeFramesPerSecond == nil,
        "a viewer that predates the rate reports none, not a zero"
    )

    let unreported = SensoriumMessage.viewerTelemetry(
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
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(unreported), as: UTF8.self)
            .contains("supersededOnTimeFramesPerSecond"),
        "a viewer with no rate to report omits the field rather than sending a null"
    )

    func reading(_ rate: Double) -> ViewerTelemetrySample {
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: 30,
            decodedFramesPerSecond: 60,
            receivedBitsPerSecond: nil,
            supersededOnTimeFramesPerSecond: rate
        )
    }
    var store = ViewerTelemetryStore()
    expect(store.record(reading(0), atSeconds: 1), "a rate of zero is kept")
    expect(!store.record(reading(-1), atSeconds: 1), "a negative rate drops the whole sample")
    expect(!store.record(reading(.nan), atSeconds: 1), "a rate that is not a number drops the whole sample")
    expect(!store.record(reading(.infinity), atSeconds: 1), "an infinite rate drops the whole sample")
}

/// What each of the viewer's draw callbacks did, so a stream decoded at 15
/// frames a second and presented at none can be told apart from a display that
/// was never asked to draw. An older viewer omits the report and a newer host
/// then has nothing to say about it.
func testViewerTelemetryCarriesTheDrawReportAndStaysCompatible() {
    let report = ViewerDrawReport(
        drawsPerSecond: 60,
        noDrawablePerSecond: 14,
        noCommandBufferPerSecond: 1,
        emptyDestinationPerSecond: 2,
        renderFailurePerSecond: 3
    )
    expect(report.notShownPerSecond == 20, "the frames not shown are the four reasons added together")

    let withReport = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: 5,
            decodedFramesPerSecond: 20,
            receivedBitsPerSecond: nil,
            drawReport: report
        )
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withReport)) == withReport,
        "the draw report round-trips unchanged"
    )

    guard case let .viewerTelemetry(oldViewer) = try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
        "type": "viewerTelemetry",
        "viewerTelemetry": ["surfaceID": 0, "decodedFramesPerSecond": 20]
    ])) else {
        expect(false, "a viewer telemetry message without the draw report still decodes as one")
        return
    }
    expect(oldViewer.drawReport == nil, "a viewer that predates the report sends none, not a report of zeroes")

    let unreported = SensoriumMessage.viewerTelemetry(
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
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(unreported), as: UTF8.self).contains("drawReport"),
        "a viewer with no report omits the field rather than sending a null"
    )

    func reading(_ report: ViewerDrawReport) -> ViewerTelemetrySample {
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: nil,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil,
            drawReport: report
        )
    }
    var store = ViewerTelemetryStore()
    expect(store.record(reading(report), atSeconds: 1), "an ordinary report is kept")
    expect(
        !store.record(reading(ViewerDrawReport(
            drawsPerSecond: 60, noDrawablePerSecond: -1, noCommandBufferPerSecond: 0,
            emptyDestinationPerSecond: 0, renderFailurePerSecond: 0
        )), atSeconds: 1),
        "a negative count drops the whole sample"
    )
    expect(
        !store.record(reading(ViewerDrawReport(
            drawsPerSecond: .nan, noDrawablePerSecond: 0, noCommandBufferPerSecond: 0,
            emptyDestinationPerSecond: 0, renderFailurePerSecond: 0
        )), atSeconds: 1),
        "a count that is not a number drops the whole sample"
    )
}

/// The stall evidence rides on the same report, and a viewer that predates it
/// sends the report without those keys.
func testViewerDrawReportCarriesStallEvidenceAndStaysCompatible() {
    guard case let .viewerTelemetry(oldViewer) = try! SensoriumFrameCodec.decode(viewerTelemetryFrame([
        "type": "viewerTelemetry",
        "viewerTelemetry": [
            "surfaceID": 0,
            "drawReport": [
                "drawsPerSecond": 2,
                "noDrawablePerSecond": 0,
                "noCommandBufferPerSecond": 0,
                "emptyDestinationPerSecond": 0,
                "renderFailurePerSecond": 0
            ]
        ]
    ])), let report = oldViewer.drawReport else {
        expect(false, "a draw report without the stall fields still decodes")
        return
    }
    expect(
        report.longestDrawGapMilliseconds == nil && report.longestMainThreadStallMilliseconds == nil
            && report.hiddenFraction == nil && report.preferredFramesPerSecond == nil,
        "a report from an older viewer carries none of the stall fields"
    )

    let full = SensoriumMessage.viewerTelemetry(
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: nil,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil,
            drawReport: ViewerDrawReport(
                drawsPerSecond: 2,
                noDrawablePerSecond: 0,
                noCommandBufferPerSecond: 0,
                emptyDestinationPerSecond: 0,
                renderFailurePerSecond: 0,
                longestDrawGapMilliseconds: 4210,
                longestMainThreadStallMilliseconds: 4180,
                hiddenFraction: 0.25,
                preferredFramesPerSecond: 60
            )
        )
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(full)) == full,
        "the stall fields round-trip unchanged"
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
        endToEnd: StageLatencySample? = StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_000_000),
        roundTripNanoseconds: Int64? = nil,
        decoderOnly: StageLatencySample? = nil,
        decodeQueueWait: StageLatencySample? = nil
    ) -> ViewerTelemetrySample {
        ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: endToEnd,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: presentedFramesPerSecond,
            decodedFramesPerSecond: decodedFramesPerSecond,
            receivedBitsPerSecond: receivedBitsPerSecond,
            roundTripNanoseconds: roundTripNanoseconds,
            decoderOnly: decoderOnly,
            decodeQueueWait: decodeQueueWait
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
        ),
        (
            "a round trip that ran backwards",
            reading(roundTripNanoseconds: -1)
        ),
        (
            "a decoder time that ran backwards",
            reading(decoderOnly: StageLatencySample(p50Nanoseconds: -1, p95Nanoseconds: 14_000_000))
        ),
        (
            "a queue wait that ran backwards",
            reading(decodeQueueWait: StageLatencySample(p50Nanoseconds: 1_000_000, p95Nanoseconds: -1))
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
