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
    let measure: (String) -> Double = { Double($0.count) * 9 }
    let fullWidth = 320.0 - 12.0 * 2
    let narrowWidth = (fullWidth - 16.0) / 2

    func assertNoOverlap(_ row: SessionHUDRow, columnWidth: Double, isNarrow: Bool) {
        let layout = SessionHUDRowLayout.layout(
            valueWidth: measure(row.value), columnWidth: columnWidth, isNarrow: isNarrow,
            showsSparkline: (row.trend?.count ?? 0) >= 2
        )
        expect(
            layout.label.x + layout.label.width <= layout.value.x,
            "\"\(row.label)\" overlaps its own value \"\(row.value)\""
        )
        if let sparkline = layout.sparkline {
            expect(
                layout.value.x + layout.value.width <= sparkline.x,
                "\"\(row.label)\"'s value \"\(row.value)\" runs into its own sparkline"
            )
        }
        expect(
            layout.value.x + layout.value.width <= columnWidth,
            "\"\(row.label)\"'s value \"\(row.value)\" runs past its own column"
        )
    }

    let blocks = SessionHUDPanel.blocks(telemetry: fixtureSnapshot(), session: nil)
    var checked = 0
    for block in blocks {
        switch block {
        case let .section(section):
            for row in section.rows {
                assertNoOverlap(row, columnWidth: fullWidth, isNarrow: false)
                checked += 1
            }
        case let .columns(_, left, right):
            for section in [left, right] {
                for row in section.rows {
                    assertNoOverlap(row, columnWidth: narrowWidth, isNarrow: true)
                    checked += 1
                }
            }
        }
    }
    expect(checked > 0, "the fixture actually carried rows to check")

    print("PASS: no HUD row's label, value or sparkline draws over another, full width or in a column")
}

/// `SessionHUDRowView`'s own geometry: a fixed label column (96, or 70 in a
/// column), the value left-aligned 8 after it, a 64 by 14 sparkline at the
/// column's trailing edge that takes its width plus 8 from the value only
/// when it is drawn, and notes indented 8.
func testSessionHUDRowLayoutMatchesMacOSGeometryTests() {
    let full = 320.0 - 12.0 * 2
    let narrow = (full - 16.0) / 2

    let plain = SessionHUDRowLayout.layout(valueWidth: 80, columnWidth: full, isNarrow: false, showsSparkline: false)
    expect(plain.label.x == 0 && plain.label.width == 96, "a full-width label column is 96, got \(plain.label)")
    expect(plain.value.x == 104 && plain.value.width == 80, "the value starts at 104, left-aligned, got \(plain.value)")
    expect(plain.sparkline == nil, "a row without a trend has no sparkline")

    let long = SessionHUDRowLayout.layout(valueWidth: 400, columnWidth: full, isNarrow: false, showsSparkline: false)
    expect(long.value.width == 192, "a long value is cut at the column's end, 192 wide, got \(long.value)")

    let trend = SessionHUDRowLayout.layout(valueWidth: 400, columnWidth: full, isNarrow: false, showsSparkline: true)
    expect(trend.value.width == 120, "a sparkline takes 64 plus 8 from the value, leaving 120, got \(trend.value)")
    expect(
        trend.sparkline.map { $0.x == 232 && $0.width == 64 && $0.height == 14 } == true,
        "the sparkline is 64 by 14 at the column's trailing edge, got \(String(describing: trend.sparkline))"
    )

    let column = SessionHUDRowLayout.layout(valueWidth: 400, columnWidth: narrow, isNarrow: true, showsSparkline: true)
    expect(column.label.width == 70, "a column's label column is 70, got \(column.label)")
    expect(column.value.x == 78 && column.value.width == 62, "a column's value starts at 78, at most 62 wide, got \(column.value)")
    expect(column.sparkline == nil, "a column never draws a sparkline")

    expect(plain.noteIndent == 8 && plain.noteWidth == full - 8, "a row's note is indented 8, got \(plain.noteIndent)")

    print("PASS: a HUD row lays out on SessionHUDRowView's own label column, value start, sparkline and note indent")
}

#if canImport(AppKit)
import AppKit

/// The macOS panel itself lands where `SessionHUDRowLayout` says the Linux
/// one draws: the VIDEO IN value and its sparkline.
@MainActor
func testSessionHUDViewMatchesRowLayoutTests() {
    let view = SessionHUDView()
    view.apply(telemetry: fixtureSnapshot())
    view.layoutSubtreeIfNeeded()

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let all = descendants(view)
    guard
        let label = all.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "VIDEO IN" }),
        let row = label.superview?.superview?.superview,
        let value = all.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.hasSuffix("Mbit/s") })
    else {
        expect(false, "the macOS HUD shows a VIDEO IN row")
        return
    }
    let inset = ViewerChromeMetrics.Space.sm
    let columnWidth = Double(SessionHUDView.panelWidth - inset * 2)
    let expected = SessionHUDRowLayout.layout(
        valueWidth: Double(value.intrinsicContentSize.width), columnWidth: columnWidth,
        isNarrow: false, showsSparkline: true
    )
    let rowOrigin = row.convert(NSPoint.zero, to: view).x
    // An NSTextField label draws its text 2pt inside its frame; its
    // alignment rect is where the text starts.
    let valueX = value.convert(value.alignmentRect(forFrame: value.bounds).origin, to: view).x - rowOrigin
    expect(abs(Double(valueX) - expected.value.x) < 0.5, "VIDEO IN's value starts at \(expected.value.x), got \(valueX)")
    let sparklines = row.subviews.filter { !($0 is NSStackView) && !$0.isHidden }
    expect(sparklines.count == 1, "VIDEO IN carries one sparkline, got \(sparklines.count)")
    if let sparkline = sparklines.first, let rect = expected.sparkline {
        let frame = sparkline.frame
        expect(
            abs(Double(frame.minX) - rect.x) < 0.5 && Double(frame.width) == rect.width && Double(frame.height) == rect.height,
            "VIDEO IN's sparkline sits at \(rect), got \(frame)"
        )
    }
    print("PASS: the macOS HUD's VIDEO IN value and sparkline sit where the shared row layout puts them")
}
#endif
