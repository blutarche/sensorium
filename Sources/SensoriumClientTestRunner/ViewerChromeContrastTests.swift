#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer's small grey text is judged on the pixels it draws, as the
/// host's menu-panel eyebrow is: thin glyphs only ever reach a fraction of
/// their nominal colour, so a token that passes on paper can still fall under
/// 4.5:1 on screen.
private let contrastFloor = 4.5

private func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Double {
    func channel(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
}

private func contrast(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// What a region of a rendered view reaches against its own background.
private struct DrawnText {
    let ratio: Double
    let luminance: Double
    let peak: (Int, Int, Int)
    let background: (Int, Int, Int)
}

/// `view` drawn at two pixels to the point, the density of the screens it is
/// shown on, in the colour space its tokens are written in.
@MainActor
private func renderAtTwoX(_ view: NSView) -> NSBitmapImageRep? {
    view.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width * 2),
        pixelsHigh: Int(view.bounds.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { return nil }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// The brightest pixel inside `field`'s frame, measured against the pixel at
/// the frame's top-left corner, which no glyph reaches.
@MainActor
private func drawnText(_ field: NSView, in view: NSView, of rep: NSBitmapImageRep) -> DrawnText? {
    guard let data = rep.bitmapData else { return nil }
    let frame = field.convert(field.bounds, to: view)
    let top = view.isFlipped ? frame.minY : view.bounds.height - frame.maxY
    let x0 = max(0, Int((frame.minX * 2).rounded(.down)))
    let x1 = min(rep.pixelsWide, Int((frame.maxX * 2).rounded(.up)))
    let y0 = max(0, Int((top * 2).rounded(.down)))
    let y1 = min(rep.pixelsHigh, Int(((top + frame.height) * 2).rounded(.up)))
    guard x1 > x0, y1 > y0 else { return nil }
    let bytesPerPixel = rep.bitsPerPixel / 8
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = y * rep.bytesPerRow + x * bytesPerPixel
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }
    let background = pixel(x0, y0)
    let backgroundLuminance = luminance(background.0, background.1, background.2)
    var worst = 1.0
    var peak = background
    var peakLuminance = backgroundLuminance
    for y in y0..<y1 {
        for x in x0..<x1 {
            let candidate = pixel(x, y)
            let candidateLuminance = luminance(candidate.0, candidate.1, candidate.2)
            let ratio = contrast(candidateLuminance, backgroundLuminance)
            if ratio > worst {
                worst = ratio
                peak = candidate
                peakLuminance = candidateLuminance
            }
        }
    }
    return DrawnText(ratio: worst, luminance: peakLuminance, peak: peak, background: background)
}

/// Every eyebrow the status panel can draw is the muted token on the panel's
/// own surface, and reads at AA as drawn.
@MainActor
func testViewerStatusEyebrowContrastTests() {
    var machine = ViewerSessionStateMachine(hostName: "Workstation")
    machine.handle(.connectStarted)
    machine.handle(.canvasReady)
    let statuses = [
        machine.handle(.sessionEnded),
        machine.handle(.connectStarted),
        machine.handle(.gaveUp)
    ]
    expect(statuses.allSatisfy(\.isOverlayVisible), "the statuses this checks all show the overlay")

    for status in statuses {
        guard let shown = ViewerClientTestHooks.statusOverlay(showing: status, size: NSSize(width: 760, height: 460)),
              let rep = renderAtTwoX(shown.overlay),
              let eyebrow = drawnText(shown.eyebrow, in: shown.overlay, of: rep) else {
            expect(false, "the \(status.eyebrow) status draws an eyebrow")
            continue
        }
        expect(
            eyebrow.ratio >= contrastFloor,
            "the \(status.eyebrow) eyebrow's brightest pixel \(eyebrow.peak) on \(eyebrow.background) is "
                + "\(eyebrow.ratio):1, under the \(contrastFloor):1 AA floor"
        )
    }

    print("PASS: the status panel's eyebrows reach AA contrast as drawn")
}

/// The diagnostics panel's section heads and notes read at AA as drawn, and
/// the readings stay brighter than the labels beside them.
@MainActor
func testSessionHUDSmallTextContrastTests() {
    var clientMetrics = SessionMetrics()
    clientMetrics.record(stage: .receive, startedAtNanoseconds: 0, endedAtNanoseconds: 3_200_000)
    clientMetrics.record(stage: .decode, startedAtNanoseconds: 0, endedAtNanoseconds: 4_100_000)
    clientMetrics.record(stage: .present, startedAtNanoseconds: 0, endedAtNanoseconds: 6_800_000)
    clientMetrics.record(stage: .endToEnd, startedAtNanoseconds: 0, endedAtNanoseconds: 18_500_000)
    let sample = SurfaceTelemetrySample(
        surfaceID: 1,
        capture: StageLatencySample(p50Nanoseconds: 1_800_000, p95Nanoseconds: 3_100_000),
        encode: StageLatencySample(p50Nanoseconds: 5_400_000, p95Nanoseconds: 9_200_000),
        send: StageLatencySample(p50Nanoseconds: 1_100_000, p95Nanoseconds: 2_000_000),
        framesPerSecond: 29.8,
        encoderInputDropped: 0,
        globalAdmissionDropped: 0,
        sendQueueDropped: 0,
        appliedStreamScale: 1.5,
        sustainableScaleCeiling: 1.5,
        appliedFramesPerSecond: 30,
        qualityScale: 0.75,
        fidelityLimitReason: FidelityLimitReason.link
    )
    let snapshot = SessionHUDSnapshot(
        surfaceID: 1,
        availability: .fresh(sample),
        clientMetrics: clientMetrics,
        stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
        requestedStreamScale: 2.0,
        streamScalePreference: .automatic,
        decoder: .hardwareAccelerated,
        presentCompletionP50Nanoseconds: 900_000,
        presentationHoldNanoseconds: 800_000,
        hostName: "Workstation"
    )
    let view = SessionHUDView()
    view.apply(telemetry: snapshot)
    view.layoutSubtreeIfNeeded()
    view.frame = NSRect(origin: .zero, size: NSSize(width: SessionHUDView.panelWidth, height: view.fittingSize.height))
    guard let rep = renderAtTwoX(view) else {
        expect(false, "the diagnostics panel draws a bitmap")
        return
    }

    func descendants(_ root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants)
    }
    let fields = descendants(view).compactMap { $0 as? NSTextField }
    func field(showing text: String) -> NSTextField? {
        fields.first { unbound($0.stringValue) == unbound(text) }
    }

    let sections = SessionHUDPanel.sections(telemetry: snapshot, session: nil)
    var judged = 0
    for section in sections {
        var targets: [(String, String)] = [("head", section.title)]
        if let note = section.note { targets.append(("note", note)) }
        for row in section.rows {
            if let note = row.note { targets.append(("row note", note)) }
        }
        for (kind, text) in targets {
            guard let target = field(showing: text) else { continue }
            guard let drawn = drawnText(target, in: view, of: rep) else { continue }
            judged += 1
            expect(
                drawn.ratio >= contrastFloor,
                "the \(section.title) \(kind) \"\(text)\" peaks at \(drawn.peak) on \(drawn.background), "
                    + "\(drawn.ratio):1, under the \(contrastFloor):1 AA floor"
            )
        }
    }
    expect(judged >= 6, "the panel shows enough heads and notes to judge, got \(judged)")

    var rowsCompared = 0
    for section in sections {
        for row in section.rows where row.tone == nil && !row.isStale && row.note == nil {
            guard let label = field(showing: row.label), let line = label.superview as? NSStackView,
                  line.arrangedSubviews.count == 2,
                  let value = line.arrangedSubviews[1] as? NSTextField,
                  let labelText = drawnText(label, in: view, of: rep),
                  let valueText = drawnText(value, in: view, of: rep) else { continue }
            rowsCompared += 1
            expect(
                valueText.luminance > labelText.luminance,
                "the \(row.label) reading peaks at \(valueText.peak), no brighter than its label at \(labelText.peak)"
            )
        }
    }
    expect(rowsCompared >= 3, "the panel shows enough rows to compare, got \(rowsCompared)")

    print("PASS: the diagnostics panel's heads and notes reach AA contrast, below its readings")
}
#endif
