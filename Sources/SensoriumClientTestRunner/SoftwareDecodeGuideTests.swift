import Foundation
import SensoriumClient
import SensoriumCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func decoderRow(_ decoder: DecoderHardwareAccelerationStatus?, guide: String?) -> SessionHUDRow? {
    let snapshot = SessionHUDSnapshot(
        surfaceID: 1,
        availability: .unavailable,
        clientMetrics: SessionMetrics(),
        stream: ClientStreamReading(pixelWidth: 1920, pixelHeight: 1080, bitsPerSecond: nil, decodedFrameCount: 0),
        requestedStreamScale: nil,
        streamScalePreference: .automatic,
        decoder: decoder,
        softwareDecodeGuide: guide
    )
    let sections = SessionHUDPanel.blocks(telemetry: snapshot, session: nil).flatMap { block -> [SessionHUDSection] in
        switch block {
        case let .section(section): return [section]
        case let .columns(_, left, right): return [left, right]
        }
    }
    return sections.flatMap(\.rows).first { $0.label == "DECODER" }
}

/// A packaged build links to its release; an unpackaged development build
/// links to the default branch.
func testViewerReleaseMatchesVersionFileTests() {
    let versionFile = (try? String(contentsOf: repositoryRoot.appendingPathComponent("VERSION"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    expect(ViewerRelease.version == "development" || versionFile == ViewerRelease.version, "the packaged version matches VERSION, got \(ViewerRelease.version)")
    let reference = ViewerRelease.version == "development" ? "main" : "v" + (versionFile ?? "")
    expect(
        ViewerRelease.fasterVideoGuide
            == "https://github.com/blutarche/sensorium/blob/\(reference)/docs/install.md#faster-video-on-fedora",
        "the guide link names this release's tag, got \(ViewerRelease.fasterVideoGuide)"
    )
    let installGuide = (try? String(
        contentsOf: repositoryRoot.appendingPathComponent("docs/install.md"), encoding: .utf8
    )) ?? ""
    expect(
        installGuide.contains("\n### Faster video on Fedora\n"),
        "docs/install.md has the heading the link's anchor points at"
    )
    #if os(Linux)
    expect(
        ViewerRelease.platformSoftwareDecodeGuide == ViewerRelease.fasterVideoGuide,
        "the Linux viewer offers the Fedora guide"
    )
    #else
    expect(ViewerRelease.platformSoftwareDecodeGuide == nil, "the macOS viewer offers no Fedora guide")
    #endif
    print("PASS: the viewer links to its packaged release or development documentation")
}

/// A viewer decoding on the CPU says so on the DECODER row and links to the
/// steps that fix it -- only where a guide is offered, and only while it is
/// actually decoding in software.
func testSoftwareDecodeGuideRowTests() {
    let guide = ViewerRelease.fasterVideoGuide

    let offered = decoderRow(.softwareFallback, guide: guide)
    expect(offered?.note == "Video decoded on the CPU.", "the row says where video is decoded, got \(String(describing: offered?.note))")
    expect(
        offered?.link == SessionHUDLink(title: "Faster video", url: guide),
        "the row links to the guide, got \(String(describing: offered?.link))"
    )
    expect(offered?.tone == .warn, "the row keeps its warn tone")

    let notOffered = decoderRow(.softwareFallback, guide: nil)
    expect(notOffered?.link == nil, "no guide, no link")
    expect(
        notOffered?.note == "No hardware decoder was available; this machine is decoding in software.",
        "without a guide the row keeps its own note"
    )

    let hardware = decoderRow(.hardwareAccelerated, guide: guide)
    expect(hardware?.link == nil && hardware?.note == nil, "a hardware decoder needs no guide")

    let unknown = decoderRow(nil, guide: guide)
    expect(unknown?.link == nil, "no decoder yet, no link")
    print("PASS: the DECODER row links to the faster-video guide only while decoding on the CPU")
}

/// Which link a press on the diagnostics panel landed on. A point outside
/// every link's own rectangle is no link at all.
func testSessionHUDLinkHitTestTests() {
    let first = SessionHUDLink(title: "Faster video", url: "https://example.com/a")
    let second = SessionHUDLink(title: "Other", url: "https://example.com/b")
    let layouts = [
        SessionHUDLinkLayout(rect: ViewerChromeRect(x: 20, y: 100, width: 60, height: 14), link: first),
        SessionHUDLinkLayout(rect: ViewerChromeRect(x: 20, y: 140, width: 40, height: 14), link: second)
    ]
    expect(SessionHUDLinkHitTest.link(atX: 20, y: 100, in: layouts) == first, "the top-left corner is inside")
    expect(SessionHUDLinkHitTest.link(atX: 79.5, y: 113.5, in: layouts) == first, "the far corner is inside")
    expect(SessionHUDLinkHitTest.link(atX: 30, y: 145, in: layouts) == second, "the second link is found")
    expect(SessionHUDLinkHitTest.link(atX: 80, y: 105, in: layouts) == nil, "just right of a link is outside")
    expect(SessionHUDLinkHitTest.link(atX: 30, y: 120, in: layouts) == nil, "between links is outside")
    expect(SessionHUDLinkHitTest.link(atX: 30, y: 105, in: []) == nil, "no links, no hit")
    print("PASS: a press on the diagnostics panel hits a link only inside its rectangle")
}

#if canImport(CCairo)
import CCairo

/// The Linux panel draws the link in the accent colour on its own line under
/// the note, grows to hold it, and reports the rectangle a press has to land
/// in -- from the same walk that drew it.
@MainActor
func testSessionHUDLinkDrawsWhereItHitsTests() {
    let link = SessionHUDLink(title: "Faster video", url: ViewerRelease.fasterVideoGuide)
    let plain = SessionHUDSection(title: "STREAM", rows: [
        SessionHUDRow(label: "DECODER", value: "software", tone: .warn, note: "Video decoded on the CPU.")
    ])
    let linked = SessionHUDSection(title: "STREAM", rows: [
        SessionHUDRow(label: "DECODER", value: "software", tone: .warn, note: "Video decoded on the CPU.", link: link)
    ])
    let plainSize = SessionChromeRenderPreview.diagnosticsSize(blocks: [.section(plain)])
    let linkedSize = SessionChromeRenderPreview.diagnosticsSize(blocks: [.section(linked)])
    expect(linkedSize.height > plainSize.height, "the panel grows to hold the link line")
    expect(
        SessionChromeRenderPreview.diagnosticsLinkLayouts(blocks: [.section(plain)]).isEmpty,
        "a row without a link reports no link"
    )

    let layouts = SessionChromeRenderPreview.diagnosticsLinkLayouts(blocks: [.section(linked)])
    expect(layouts.count == 1 && layouts.first?.link == link, "the one link is reported, got \(layouts)")
    guard let rect = layouts.first?.rect else { return }
    expect(
        rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0
            && rect.x + rect.width <= linkedSize.width && rect.y + rect.height <= linkedSize.height,
        "the link sits inside the panel, got \(rect) in \(linkedSize)"
    )

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sensorium-hud-link-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: [.section(linked)], isFlagged: false), scale: 1, to: url),
        "the linked panel renders"
    )
    guard let surface = cairo_image_surface_create_from_png(url.path),
          cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS,
          let data = cairo_image_surface_get_data(surface) else {
        expect(false, "the linked panel reads back")
        return
    }
    defer { cairo_surface_destroy(surface) }
    let stride = Int(cairo_image_surface_get_stride(surface))
    func isAccent(_ x: Int, _ y: Int) -> Bool {
        let offset = y * stride + x * 4
        let accent = ViewerPalette.accent
        return abs(Double(data[offset + 2]) / 255 - accent.red) <= 0.03
            && abs(Double(data[offset + 1]) / 255 - accent.green) <= 0.03
            && abs(Double(data[offset]) / 255 - accent.blue) <= 0.03
    }
    let width = Int(cairo_image_surface_get_width(surface))
    let height = Int(cairo_image_surface_get_height(surface))
    var inside = 0
    var outside = 0
    for y in 0..<height {
        for x in 0..<width where isAccent(x, y) {
            if rect.contains(x: Double(x) + 0.5, y: Double(y) + 0.5) { inside += 1 } else { outside += 1 }
        }
    }
    expect(inside > 0, "the link's text is drawn in the accent colour")
    expect(outside == 0, "every accent pixel lies inside the link's hit rectangle, \(outside) outside")
    print("PASS: the diagnostics link draws in the accent colour inside the rectangle a press hits")
}
#else
func testSessionHUDLinkDrawsWhereItHitsTests() {}
#endif
