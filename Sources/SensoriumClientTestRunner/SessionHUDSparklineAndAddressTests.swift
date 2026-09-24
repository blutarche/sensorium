#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore

/// The HUD's own address line and the trend data behind its three
/// sparklines -- the ring buffer that keeps them, the pure mapping that
/// turns a trend into points a sparkline view can stroke, and where the
/// laid-out view actually puts them.
@MainActor
func runSessionHUDSparklineAndAddressTests() {
    trendKeepsAtMostSixtySamplesDroppingOldest()
    hudNamesTheHostsAddressUnderState()
    sparklineLayoutNeedsAtLeastTwoSamples()
    sparklineLayoutHandlesAFlatSeries()
    sparklineLayoutScalesMinToMaxOldestFirst()
    sparklinesShareOneTrailingColumn()
    print("PASS: the HUD names the host's address and maps its trends to sparkline points")
}

private func trendKeepsAtMostSixtySamplesDroppingOldest() {
    var trend = SessionHUDTrend()
    for value in 1...70 {
        trend.append(Double(value))
    }
    expect(trend.samples.count == 60, "a trend past capacity is trimmed, not left to grow forever")
    expect(trend.samples.first == 11, "the oldest sample is the one a full trend drops")
    expect(trend.samples.last == 70, "the newest sample is always kept")
}

private func hudNamesTheHostsAddressUnderState() {
    func hudRow(_ rows: [SessionHUDRow], _ label: String) -> SessionHUDRow? {
        rows.first { $0.label == label }
    }

    func sessionSectionRows(hostAddress: String?) -> [SessionHUDRow] {
        let sections = SessionHUDPanel.sections(
            telemetry: SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil,
                hostName: "Studio",
                hostAddress: hostAddress
            ),
            session: nil
        )
        return sections.first { $0.title == "SESSION" }?.rows ?? []
    }

    let rows = sessionSectionRows(hostAddress: "mini.tail1234.ts.net:7777")
    expect(
        hudRow(rows, "ADDRESS")?.value == "mini.tail1234.ts.net:7777",
        "the address row states the host exactly as dialled"
    )
    expect(
        hudRow(rows, "STATE") != nil && rows.firstIndex(where: { $0.label == "ADDRESS" }) ==
            (rows.firstIndex(where: { $0.label == "STATE" })! + 1),
        "the address sits directly under the state line"
    )

    let noAddress = sessionSectionRows(hostAddress: nil)
    expect(
        hudRow(noAddress, "ADDRESS")?.value == SessionHUDPanel.unavailable,
        "a session with no known address says so rather than showing nothing"
    )
}

private func sparklineLayoutNeedsAtLeastTwoSamples() {
    expect(
        SessionHUDSparklineLayout.points(for: [], in: CGRect(x: 0, y: 0, width: 64, height: 14)).isEmpty,
        "no samples is no line"
    )
    expect(
        SessionHUDSparklineLayout.points(for: [5], in: CGRect(x: 0, y: 0, width: 64, height: 14)).isEmpty,
        "one sample is not yet a trend"
    )
    expect(
        SessionHUDSparklineLayout.points(for: [5, 6], in: CGRect(x: 0, y: 0, width: 64, height: 14)).count == 2,
        "two samples is the least that draws a line"
    )
}

private func sparklineLayoutHandlesAFlatSeries() {
    let rect = CGRect(x: 0, y: 0, width: 64, height: 14)
    let points = SessionHUDSparklineLayout.points(for: [3, 3, 3], in: rect)
    expect(points.count == 3, "a flat series is still a series")
    expect(
        points.allSatisfy { $0.y == rect.midY },
        "a series with no range at all draws flat at mid-height rather than dividing by zero"
    )
}

private func sparklineLayoutScalesMinToMaxOldestFirst() {
    let rect = CGRect(x: 0, y: 0, width: 60, height: 20)
    let points = SessionHUDSparklineLayout.points(for: [0, 10, 5], in: rect)
    expect(points.count == 3, "every sample gets a point")
    expect(points[0].x < points[1].x && points[1].x < points[2].x, "oldest sample plots leftmost")
    expect(points[0].y == rect.minY, "the minimum sample sits at the bottom of its own rect")
    expect(points[1].y == rect.maxY, "the maximum sample sits at the top of its own rect")
    expect(
        points[2].y > rect.minY && points[2].y < rect.maxY,
        "a sample between the series' own min and max lands between them"
    )
}

/// VIDEO IN's and FPS's values are different widths, which used to carry
/// their sparklines to different x positions -- each floated right after its
/// own value instead of sharing a column. Real geometry, not the pure
/// layout helper: this is `SessionHUDRowView`'s own placement decision.
@MainActor
private func sparklinesShareOneTrailingColumn() {
    let hud = SessionHUDView()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
    container.addSubview(hud)
    NSLayoutConstraint.activate([
        hud.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        hud.topAnchor.constraint(equalTo: container.topAnchor)
    ])

    hud.apply(telemetry: SessionHUDSnapshot(
        surfaceID: 0,
        availability: .fresh(SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: 59,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: 2.0,
            sustainableScaleCeiling: nil,
            appliedFramesPerSecond: nil,
            qualityScale: nil,
            fidelityLimitReason: nil
        )),
        clientMetrics: SessionMetrics(),
        stream: ClientStreamReading(pixelWidth: 3840, pixelHeight: 2400, bitsPerSecond: 41_800_000),
        requestedStreamScale: 2.0,
        streamScalePreference: .automatic,
        decoder: .hardwareAccelerated,
        hostName: "Studio",
        hostAddress: "mini.tail1234.ts.net:7777",
        videoInBitrateTrend: SessionHUDTrend(samples: [40_000_000, 41_000_000, 42_000_000]),
        fpsTrend: SessionHUDTrend(samples: [58, 59, 60])
    ))
    container.layoutSubtreeIfNeeded()

    // A sparkline is the only 64x14pt view in this tree; a hidden one (every
    // row with no trend of its own) is skipped, since it keeps its reserved
    // frame even while invisible.
    // `SessionHUDSparklineView` is private to its own file, so it is found
    // here by its type name rather than by size alone: an ordinary value
    // field's own resolved frame can coincidentally land on 64x14 too.
    func sparklineFrames(in root: NSView, convertingTo target: NSView) -> [NSRect] {
        var frames: [NSRect] = []
        for sub in root.subviews {
            if !sub.isHidden, String(describing: type(of: sub)) == "SessionHUDSparklineView" {
                frames.append(sub.convert(sub.bounds, to: target))
            }
            frames.append(contentsOf: sparklineFrames(in: sub, convertingTo: target))
        }
        return frames
    }

    let frames = sparklineFrames(in: container, convertingTo: container)
    expect(frames.count == 2, "VIDEO IN and FPS each show one sparkline, got \(frames.count)")
    // The panel's own fixed width less its one inset: not just that the two
    // agree with each other, which a pair of rows that both happen to fall
    // short of the column would still satisfy, but that they land at the
    // column the panel actually reserves for one.
    let expectedTrailingColumn = SessionHUDView.panelWidth - ViewerDesign.Space.sm
    for frame in frames {
        expect(
            abs(frame.maxX - expectedTrailingColumn) < 0.5,
            "a sparkline sits at the panel's own trailing column (\(expectedTrailingColumn)), got \(frame.maxX)"
        )
    }

    // A row with no sparkline of its own -- ADDRESS -- must not pay for one:
    // its value keeps the full column, so a long address is not clipped
    // behind an ellipsis to make room for a view that is not there.
    func textField(stringValue: String, in root: NSView) -> NSTextField? {
        for sub in root.subviews {
            if let field = sub as? NSTextField, field.stringValue == stringValue {
                return field
            }
            if let found = textField(stringValue: stringValue, in: sub) {
                return found
            }
        }
        return nil
    }

    let address = "mini.tail1234.ts.net:7777"
    guard let addressField = textField(stringValue: address, in: container) else {
        expect(false, "the address row's value field is found in the laid-out tree")
        return
    }
    let expansion = addressField.cell?.expansionFrame(withFrame: addressField.bounds, in: addressField) ?? .zero
    expect(
        expansion == .zero,
        "the address is not truncated behind an ellipsis, got expansion frame \(expansion) over bounds \(addressField.bounds)"
    )
}
#endif
