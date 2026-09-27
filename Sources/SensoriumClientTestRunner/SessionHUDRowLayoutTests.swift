import Foundation
import SensoriumClient
import SensoriumCore

/// The same reading `RenderChromeVerb`'s own diagnostics fixture builds, so
/// this checks the labels and values a real render actually carries rather
/// than an invented row.
private func fixtureSnapshot() -> SessionHUDSnapshot {
    var clientMetrics = SessionMetrics()
    clientMetrics.record(stage: .receive, startedAtNanoseconds: 0, endedAtNanoseconds: 3_200_000)
    clientMetrics.record(stage: .decode, startedAtNanoseconds: 0, endedAtNanoseconds: 4_100_000)
    clientMetrics.record(stage: .present, startedAtNanoseconds: 0, endedAtNanoseconds: 6_800_000)
    clientMetrics.record(stage: .endToEnd, startedAtNanoseconds: 0, endedAtNanoseconds: 18_500_000)
    clientMetrics.record(stage: .inputRoundTrip, startedAtNanoseconds: 0, endedAtNanoseconds: 22_000_000)

    let sample = SurfaceTelemetrySample(
        surfaceID: 1,
        capture: StageLatencySample(p50Nanoseconds: 1_800_000, p95Nanoseconds: 3_100_000),
        encode: StageLatencySample(p50Nanoseconds: 5_400_000, p95Nanoseconds: 9_200_000),
        send: StageLatencySample(p50Nanoseconds: 1_100_000, p95Nanoseconds: 2_000_000),
        framesPerSecond: 58.4,
        encoderInputDropped: 2,
        globalAdmissionDropped: 0,
        sendQueueDropped: 1,
        appliedStreamScale: 1.0,
        sustainableScaleCeiling: 1.0,
        clampedFromUserChoice: nil,
        hostRequestedStreamScale: 1.5,
        appliedFramesPerSecond: 30,
        qualityScale: 0.72,
        fidelityLimitReason: FidelityLimitReason.encoder
    )

    return SessionHUDSnapshot(
        surfaceID: 1,
        availability: .fresh(sample),
        clientMetrics: clientMetrics,
        stream: ClientStreamReading(pixelWidth: 1920, pixelHeight: 1080, bitsPerSecond: 41_500_000, decodedFrameCount: 9_812),
        requestedStreamScale: 1.5,
        requestedDrawablePixelWidth: 2560,
        requestedDrawablePixelHeight: 1600,
        streamScalePreference: .automatic,
        decoder: .hardwareAccelerated,
        isAttentionWorthy: true,
        isPointerCaptured: true,
        presentCompletionP50Nanoseconds: 4_600_000,
        presentationHoldNanoseconds: 2_300_000,
        hostName: "workshop",
        hostAddress: "workshop.tail1234.ts.net:7777",
        endToEndLatencyTrend: SessionHUDTrend(samples: [14, 16, 15, 19, 18.5, 17, 18.5]),
        videoInBitrateTrend: SessionHUDTrend(samples: [38, 40, 41.5, 39, 42, 41.5]),
        fpsTrend: SessionHUDTrend(samples: [59, 58, 60, 57, 58.4]),
        viewerDroppedBeforeDecode: 4,
        viewerDroppedBeforePresent: 1,
        viewerDropsGrew: true
    )
}

/// Every row a real HUD reading carries, checked against `SessionHUDRowLayout`
/// so a label -- "END-TO-END" in the narrow latency columns, "DROPPED HERE"
/// in the full-width stream section -- never draws over its own value,
/// whatever font actually measures it. A fake measurer stands in for pango,
/// so this runs on macOS even though `CairoChromeText` itself is Linux-only.
func testSessionHUDRowLayoutNoOverlapTests() {
    // Wide enough that "END-TO-END" (10 characters) and "DROPPED HERE" (12)
    // both exceed their own column at this width, the same way a fallback
    // monospace face wider than JetBrains Mono overran them in a real render.
    let measure: (String) -> Double = { Double($0.count) * 9 }
    let columnGap = 8.0
    let diagnosticsWidth = 320.0
    let edgeInset = 12.0
    let columnGutter = 16.0
    let fullWidth = diagnosticsWidth - edgeInset * 2
    let narrowWidth = (fullWidth - columnGutter) / 2

    func assertNoOverlap(label: String, value: String, rowWidth: Double, labelColumnWidth: Double) {
        let layout = SessionHUDRowLayout.layout(
            label: label, value: value, rowWidth: rowWidth, labelColumnWidth: labelColumnWidth,
            columnGap: columnGap, measureLabel: measure, measureValue: measure
        )
        expect(
            layout.label.x + layout.label.width <= layout.value.x,
            "\"\(label)\" overlaps its own value \"\(value)\" at a \(Int(labelColumnWidth))-wide label column"
        )
    }

    let blocks = SessionHUDPanel.blocks(telemetry: fixtureSnapshot(), session: nil)
    var checked = 0
    for block in blocks {
        switch block {
        case let .section(section):
            for row in section.rows {
                assertNoOverlap(label: row.label, value: row.value, rowWidth: fullWidth, labelColumnWidth: 96)
                checked += 1
            }
        case let .columns(_, left, right):
            for section in [left, right] {
                for row in section.rows {
                    assertNoOverlap(label: row.label, value: row.value, rowWidth: narrowWidth, labelColumnWidth: 70)
                    checked += 1
                }
            }
        }
    }
    expect(checked > 0, "the fixture actually carried rows to check")

    print("PASS: no HUD row's label draws over its own value, at either the 96 or the 70 column")
}

/// A section's own label column widens to whatever its own widest label
/// needs, capped so the value beside it never drops under the smaller of
/// that section's own widest measured value and a fixed ceiling -- not a
/// flat reservation for that ceiling regardless of how wide the values
/// actually are, so "END-TO-END" and "INPUT RTT" fit whole in the narrow
/// latency columns even though every value there ("18.5 ms", "22.0 ms") is
/// far short of the ceiling.
func testSessionHUDSectionLabelColumnWidensToFitTests() {
    // Two different scales, so a wrong test that fed the label measurer's
    // numbers to the value side (or back) would be caught here rather than
    // by a coincidence of matching digits.
    let measureLabel: (String) -> Double = { Double($0.count) * 6 }
    let measureValue: (String) -> Double = { Double($0.count) * 7 }
    let columnGap = 8.0
    let valueWidthCap = 64.0

    // "END-TO-END" measures 60, its own value "18.5 ms" measures 49 -- far
    // under the 64pt ceiling, so the column reserves only the value's own
    // 49 and leaves the label its full 60, rather than a flat 64 that would
    // cut the label column to 130-8-64=58.
    let latencyColumn = SessionHUDRowLayout.sectionLabelColumnWidth(
        labels: ["END-TO-END", "RECEIVE"], values: ["18.5 ms", "3.2 ms"], rowWidth: 130, columnGap: columnGap,
        valueWidthCap: valueWidthCap, measureLabel: measureLabel, measureValue: measureValue
    )
    expect(latencyColumn == 60, "\"END-TO-END\"'s own full 60pt fits once the value's own 49pt is reserved, not a flat 64, got \(latencyColumn)")

    // An outlying long value -- "DROPPED HERE"'s own reading -- still never
    // gives up more than the 64pt ceiling to the label, even though the
    // value itself measures far past it: the cap still protects the room
    // that value needs to wrap into.
    let streamColumn = SessionHUDRowLayout.sectionLabelColumnWidth(
        labels: ["DROPPED HERE"], values: ["4 before decode, 1 before present"], rowWidth: 300, columnGap: columnGap,
        valueWidthCap: valueWidthCap, measureLabel: measureLabel, measureValue: measureValue
    )
    expect(streamColumn == 72, "\"DROPPED HERE\"'s own full 72pt fits with room to spare even after reserving the 64pt ceiling, got \(streamColumn)")

    // A section of short labels never pays for room none of them need.
    let short = SessionHUDRowLayout.sectionLabelColumnWidth(
        labels: ["FPS", "SIZE"], values: ["58", "1920x1080"], rowWidth: 300, columnGap: columnGap,
        valueWidthCap: valueWidthCap, measureLabel: measureLabel, measureValue: measureValue
    )
    expect(short == 24, "a section of short labels only takes \"SIZE\"'s own 24pt, got \(short)")

    // The real fixture too: whatever a genuine HUD reading's own sections
    // cost their widest label, the value column beside it never drops under
    // that section's own widest measured value (or the ceiling, whichever
    // is smaller) -- narrow (140pt) and full-width (296pt) columns alike,
    // the real diagnostics panel's own geometry.
    let fullWidth = 320.0 - 12.0 * 2
    let narrowWidth = (fullWidth - 16.0) / 2
    let blocks = SessionHUDPanel.blocks(telemetry: fixtureSnapshot(), session: nil)
    var checked = 0
    func assertValueFloorHolds(_ section: SessionHUDSection, rowWidth: Double) {
        let labelColumnWidth = SessionHUDRowLayout.sectionLabelColumnWidth(
            labels: section.rows.map(\.label), values: section.rows.map(\.value), rowWidth: rowWidth, columnGap: columnGap,
            valueWidthCap: valueWidthCap, measureLabel: measureLabel, measureValue: measureValue
        )
        let widestValue = section.rows.map(\.value).reduce(0.0) { max($0, measureValue($1)) }
        let expectedFloor = min(widestValue, valueWidthCap)
        expect(
            rowWidth - labelColumnWidth - columnGap >= expectedFloor - 0.01,
            "\"\(section.title)\"'s value column never drops under its own widest value or \(valueWidthCap), whichever is smaller"
        )
        checked += 1
    }
    for block in blocks {
        switch block {
        case let .section(section):
            assertValueFloorHolds(section, rowWidth: fullWidth)
        case let .columns(_, left, right):
            assertValueFloorHolds(left, rowWidth: narrowWidth)
            assertValueFloorHolds(right, rowWidth: narrowWidth)
        }
    }
    expect(checked > 0, "the fixture actually carried sections to check")

    print("PASS: a HUD section's label column widens past a fixed floor when its own values are short, and stays capped when one is not")
}
