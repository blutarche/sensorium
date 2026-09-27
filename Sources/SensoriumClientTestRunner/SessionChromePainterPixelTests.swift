import Foundation
import SensoriumClient

#if canImport(CCairo)
import CCairo

/// One pixel read back from a PNG `SessionChromeRenderPreview` wrote, in
/// straight (not premultiplied) 0...1 components. Every colour this file
/// checks is opaque except the shortcut strip's own bar fill, which only
/// checks its alpha byte -- cairo's PNG writer un-premultiplies an opaque
/// pixel back to its original colour, so premultiplication never enters the
/// other comparisons.
private func pngPixel(at url: URL, x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double)? {
    guard let surface = cairo_image_surface_create_from_png(url.path),
          cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else {
        return nil
    }
    defer { cairo_surface_destroy(surface) }
    cairo_surface_flush(surface)
    guard let data = cairo_image_surface_get_data(surface) else { return nil }
    let stride = Int(cairo_image_surface_get_stride(surface))
    let offset = y * stride + x * 4
    // ARGB32 on this machine's byte order is stored B, G, R, A.
    return (
        r: Double(data[offset + 2]) / 255,
        g: Double(data[offset + 1]) / 255,
        b: Double(data[offset]) / 255,
        a: Double(data[offset + 3]) / 255
    )
}

private func pngSize(at url: URL) -> (width: Int, height: Int)? {
    guard let surface = cairo_image_surface_create_from_png(url.path),
          cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else {
        return nil
    }
    defer { cairo_surface_destroy(surface) }
    return (Int(cairo_image_surface_get_width(surface)), Int(cairo_image_surface_get_height(surface)))
}

private func closeEnough(_ a: Double, _ b: Double, tolerance: Double = 0.02) -> Bool {
    abs(a - b) <= tolerance
}

private func matches(_ pixel: (r: Double, g: Double, b: Double, a: Double)?, _ color: ViewerColor) -> Bool {
    guard let pixel else { return false }
    return closeEnough(pixel.r, color.red) && closeEnough(pixel.g, color.green) && closeEnough(pixel.b, color.blue)
}

/// Whether any pixel in `ys` at `x` matches `color` -- a small scan rather
/// than one exact row, so a hairline or a stroke's own anti-aliasing landing
/// a row either way from where the math says does not fail a test that is
/// checking the colour, not the rounding.
private func anyMatches(at url: URL, x: Int, ys: [Int], _ color: ViewerColor) -> Bool {
    ys.contains { matches(pngPixel(at: url, x: x, y: $0), color) }
}

/// Colours and fills `SessionChromePainter`'s Linux-only drawing puts down,
/// read back from the PNGs `SessionChromeRenderPreview` -- its one public
/// seam -- writes, since `SessionChromePainter` itself is internal to
/// `SensoriumClient` and unreachable directly from this test runner.
@MainActor
func testSessionChromePainterPixelTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-chrome-pixel-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func render(_ overlay: SessionChromeRenderPreview.Overlay, name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        expect(SessionChromeRenderPreview.renderOverlay(overlay, scale: 1, to: url), "\(name) renders")
        return url
    }

    let section = SessionHUDSection(title: "Link", rows: [SessionHUDRow(label: "rtt", value: "12ms")])
    let flagged = render(.diagnostics(blocks: [.section(section)], isFlagged: true), name: "hud-flagged.png")
    let unflagged = render(.diagnostics(blocks: [.section(section)], isFlagged: false), name: "hud.png")

    if let size = pngSize(at: unflagged) {
        // The top-right corner: past the left-aligned eyebrow and rows, and
        // clear of the border stroke's own inset.
        expect(
            matches(pngPixel(at: unflagged, x: size.width - 6, y: 6), ViewerPalette.chromeBg2),
            "the diagnostics panel fills with chrome-bg-2"
        )
        expect(
            anyMatches(at: unflagged, x: size.width / 2, ys: [0, 1, 2], ViewerPalette.chromeBorder2),
            "an unflagged diagnostics panel's border is the ordinary chrome-border-2"
        )
        expect(
            anyMatches(at: flagged, x: size.width / 2, ys: [0, 1, 2], ViewerPalette.warn),
            "a flagged diagnostics panel's border is the warn colour instead"
        )
    } else {
        expect(false, "the diagnostics PNG could not be read back")
    }

    let strip = render(.strip(visibility: .shown, hostName: "Test", isPinned: false), name: "strip.png")
    if let size = pngSize(at: strip) {
        // Above every button's own top (`(stripHeight - actionButtonHeight) / 2`
        // clears it), where only the bar's own translucent fill shows.
        if let barPixel = pngPixel(at: strip, x: 2, y: 1) {
            expect(
                closeEnough(barPixel.a, 0.88, tolerance: 0.02),
                "the strip's own bar is 0.88 translucent, got alpha \(barPixel.a)"
            )
        } else {
            expect(false, "the strip's bar fill could not be sampled")
        }
        expect(
            anyMatches(at: strip, x: 2, ys: [size.height - 1], ViewerPalette.chromeBorder2),
            "the strip's bottom row is a hairline separator, chrome-border-2"
        )
    } else {
        expect(false, "the strip PNG could not be read back")
    }

    print("PASS: the diagnostics panel and shortcut strip sample the fills, borders and alpha the design system records")
}

/// With every icon lookup forced to answer nothing, every button on the
/// strip -- ten actions, the gear and the pin -- must still draw its own
/// short word rather than a blank square: `FreedesktopIconLookup`'s own
/// reason for existing, verified end to end through the PNG this actually
/// writes.
@MainActor
func testShortcutStripIconFallbackDrawsInkTests() {
    FreedesktopIconLookup.forceNotFound = true
    defer { FreedesktopIconLookup.forceNotFound = false }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-fallback-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("strip-no-icons.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: "Test", isPinned: false), scale: 1, to: url
        ),
        "the strip renders with every icon lookup forced to nil"
    )

    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: "Test")
    expect(rects.count == 12, "ten actions, the gear and the pin, got \(rects.count)")

    for rect in rects {
        expect(!rect.title.isEmpty, "every entry still carries a title")
        var foundInk = false
        var y = Int(rect.y) + 2
        while y < Int(rect.y + rect.height) - 2 && !foundInk {
            var x = Int(rect.x) + 2
            while x < Int(rect.x + rect.width) - 2 && !foundInk {
                if let pixel = pngPixel(at: url, x: x, y: y) {
                    let luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                    if luminance > 0.5 { foundInk = true }
                }
                x += 2
            }
            y += 2
        }
        expect(foundInk, "\"\(rect.title)\"'s own button draws visible ink rather than a blank square")
    }

    let gear = rects.first(where: { $0.title == "Settings" })
    let pin = rects.first(where: { $0.title == "Pin" })
    expect(gear != nil, "the gear fell back to its own word, \"Settings\"")
    expect(pin != nil, "the pin fell back to its own word, \"Pin\"")
    if let gear, let pin {
        expect(gear.x < pin.x, "the gear sits immediately before the pin in the trailing cluster")
    }

    print("PASS: every strip button draws its own fallback word when no icon theme has it")
}

/// A host name too long for a narrow bar is truncated before the trailing
/// gear-and-pin pill, never drawn under it. The host name is the only
/// strip text drawn in `ViewerPalette.muted`, so that colour reaching
/// under the pill is what a caller that forgot to cap it would draw.
@MainActor
func testShortcutStripLongHostNameNeverDrawsUnderPillTests() {
    FreedesktopIconLookup.forceNotFound = true
    defer { FreedesktopIconLookup.forceNotFound = false }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-hostname-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "workshop-in-the-back-annex-that-never-gets-a-shorter-name"
    let width = 420.0
    let url = directory.appendingPathComponent("strip-long-hostname.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: hostName, isPinned: false), scale: 1, width: width, to: url
        ),
        "the strip renders at a narrow width with a very long host name"
    )

    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width)
    let gear = rects.first(where: { $0.title == "Settings" })
    let pin = rects.first(where: { $0.title == "Pin" })
    expect(gear != nil, "the gear still draws at a narrow width")
    expect(pin != nil, "the pin still draws at a narrow width")
    guard let gear, let pin else { return }

    let pillLeft = Int(min(gear.x, pin.x))
    let top = Int(gear.y)
    let bottom = Int(gear.y + gear.height)
    var foundHostNameInkUnderPill = false
    for y in top..<bottom {
        for x in pillLeft..<Int(width) {
            if matches(pngPixel(at: url, x: x, y: y), ViewerPalette.muted) {
                foundHostNameInkUnderPill = true
            }
        }
    }
    expect(!foundHostNameInkUnderPill, "the host name's own ink reaches under the gear/pin pill at x=\(pillLeft)")

    print("PASS: a very long host name is truncated before the trailing gear/pin pill, never drawn under it")
}

/// The transient notice's own warn-coloured border and its stroke-drawn
/// dismiss cross, both read back from the PNG rather than assumed from the
/// drawing code -- `drawNotice` already strokes `ViewerPalette.warn`
/// unconditionally, but only the render proves a stale build never shipped
/// with the plain-border look this checks against.
@MainActor
func testNoticeBorderAndDismissGlyphTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-notice-pixel-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Rendered at 2x so the 8-unit cross spans 16 physical pixels -- enough
    // room to tell a crossing diagonal stroke apart from a blank hit area or
    // a fallback glyph's own solid box, not just detect ink anywhere in it.
    let scale = 2.0
    let url = directory.appendingPathComponent("notice.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.notice("A short refusal line."), scale: scale, to: url),
        "the notice renders"
    )

    guard let size = pngSize(at: url) else {
        expect(false, "the notice PNG could not be read back")
        return
    }

    expect(
        anyMatches(at: url, x: size.width / 2, ys: [0, 1, 2], ViewerPalette.warn),
        "the notice's own border is the warn colour, top-centre"
    )

    // The dismiss button's own hit rect, in the same corner
    // `noticeDismissRect` always places it: `Space.sm` in from the right
    // edge, vertically centred. `SessionChromePainter` itself is internal to
    // `SensoriumClient`, so this is read off the same public metrics it
    // draws from, not the painter's own private constants.
    let dismissSize = Double(ViewerChromeMetrics.Notice.dismissHitSize) * scale
    let dismissRight = Double(size.width) - Double(ViewerChromeMetrics.Space.sm) * scale
    let dismissTop = (Double(size.height) - dismissSize) / 2
    let centreX = Int((dismissRight - dismissSize / 2).rounded())
    let centreY = Int((dismissTop + dismissSize / 2).rounded())

    func luminance(_ x: Int, _ y: Int) -> Double {
        guard let pixel = pngPixel(at: url, x: x, y: y) else { return 0 }
        return 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
    }
    func hasInk(_ x: Int, _ y: Int) -> Bool { luminance(x, y) > 0.3 }

    // Two crossing diagonal strokes meet at the centre and pass through the
    // corners a `strokeCross(size: 8)` draws them between -- a box glyph's
    // own outline leaves the centre blank, and a filled square lights every
    // edge midpoint too, so both are told apart from the real cross below.
    expect(hasInk(centreX, centreY), "the dismiss control's own centre is ink, where its two strokes cross")
    let cornerOffset = Int((4 * scale).rounded()) - 1
    expect(
        hasInk(centreX - cornerOffset, centreY - cornerOffset) && hasInk(centreX + cornerOffset, centreY + cornerOffset),
        "the diagonal stroke reaches both corners of its own 8-unit cross"
    )
    let midOffset = Int((3 * scale).rounded())
    expect(
        !hasInk(centreX, centreY - midOffset) && !hasInk(centreX - midOffset, centreY),
        "no vertical or horizontal stroke crosses the midpoints -- a filled box or square glyph would leave ink there"
    )

    print("PASS: the notice draws its warn border and a genuine stroked cross, not a box or blank")
}

/// Before a first frame ever arrives, the status panel's scrim is the
/// opaque chrome-bg fill, not the translucent black `ViewerSessionStatusOverlay`
/// uses once a frozen picture needs marking stale -- there is no picture
/// there yet to mark. Read back from a corner of each composite, well away
/// from the centred panel itself.
@MainActor
func testScrimOpaqueBeforeFirstFrameTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-scrim-pixel-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "workshop"
    let windowWidth = 400.0
    let windowHeight = 300.0

    var connectingState = SessionChromeState()
    connectingState.apply(status: ViewerSessionStateMachine(hostName: hostName).status, now: 0)
    let connectingURL = directory.appendingPathComponent("composite-connecting.png")
    expect(
        SessionChromeRenderPreview.renderComposite(
            state: connectingState, hostName: hostName, windowWidth: windowWidth, windowHeight: windowHeight,
            scale: 1, to: connectingURL
        ),
        "the connecting composite renders"
    )

    var lostState = SessionChromeState()
    var lostMachine = ViewerSessionStateMachine(hostName: hostName)
    lostMachine.handle(.canvasReady)
    lostMachine.handle(.sessionEnded)
    lostState.apply(status: lostMachine.status, now: 0)
    let lostURL = directory.appendingPathComponent("composite-lost.png")
    expect(
        SessionChromeRenderPreview.renderComposite(
            state: lostState, hostName: hostName, windowWidth: windowWidth, windowHeight: windowHeight,
            scale: 1, to: lostURL
        ),
        "the lost composite renders"
    )

    // A corner, well outside the centred panel, where only the scrim itself
    // is drawn.
    expect(
        matches(pngPixel(at: connectingURL, x: 5, y: 5), ViewerPalette.chromeBg),
        "before a first frame, the scrim is the opaque chrome-bg fill"
    )
    expect(
        !matches(pngPixel(at: lostURL, x: 5, y: 5), ViewerPalette.chromeBg),
        "once a session has been live, the scrim is the translucent one, not the opaque chrome-bg fill"
    )

    print("PASS: the scrim is opaque before a first frame and translucent once a frozen picture needs marking stale")
}

/// At every width a real session window might give the strip -- 1280, 1024
/// and 800 -- and whether an icon theme is found, no two of the strip's own
/// buttons ever touch and none crosses the bar's own edge: the toolbar-style
/// overflow `stripClusters` drops whole clusters for, rather than letting
/// the host name, the action clusters and the trailing gear-and-pin pill
/// crowd into each other.
@MainActor
func testShortcutStripOverflowNeverOverlapsTests() {
    defer { FreedesktopIconLookup.forceNotFound = false }
    for width in [1280.0, 1024.0, 800.0] {
        for iconsPresent in [true, false] {
            FreedesktopIconLookup.forceNotFound = !iconsPresent
            let rects = SessionChromeRenderPreview.stripButtonRects(hostName: "workshop", width: width)
            let context = "width \(Int(width)), icons \(iconsPresent ? "present" : "missing")"
            expect(!rects.isEmpty, "the strip still draws at least one button, \(context)")
            for rect in rects {
                expect(
                    rect.x >= -0.01 && rect.x + rect.width <= width + 0.01,
                    "\"\(rect.title)\" stays within the bar, \(context) (x \(rect.x), width \(rect.width))"
                )
            }
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    let a = rects[i]
                    let b = rects[j]
                    let overlapsX = a.x < b.x + b.width && b.x < a.x + a.width
                    let overlapsY = a.y < b.y + b.height && b.y < a.y + a.height
                    expect(
                        !(overlapsX && overlapsY),
                        "\"\(a.title)\" and \"\(b.title)\" never overlap, \(context)"
                    )
                }
            }
        }
    }

    print("PASS: the shortcut strip never overlaps its own buttons or overruns the bar at 1280, 1024 or 800, with or without icons")
}

/// The real "DROPPED HERE" reading -- a sentence long enough to overrun even
/// a widened label column's own value width -- wraps onto a second line
/// rather than losing its own end to an ellipsis, and its own label draws
/// whole rather than clipped.
@MainActor
func testSessionHUDLabelWrapNotTruncatedTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-wrap-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let latency = SessionHUDSection(title: "THIS MACHINE", rows: [
        SessionHUDRow(label: "RECEIVE", value: "3.2 ms"),
        SessionHUDRow(label: "END-TO-END", value: "18.5 ms"),
        SessionHUDRow(label: "INPUT RTT", value: "22.0 ms")
    ])
    let stream = SessionHUDSection(title: "STREAM", rows: [
        SessionHUDRow(label: "VIDEO IN", value: "41.5 Mbit/s"),
        // A long session's own real drop counts, not "4 before decode, 1
        // before present": at 11pt JetBrains Mono and 72dpi, that shorter
        // reading measures 178pt, whole inside the section's own 206pt value
        // column, so it does not demonstrate a wrap. This one measures 222pt,
        // wider than the column, so it does.
        SessionHUDRow(label: "DROPPED HERE", value: "12840 before decode, 9075 before present")
    ])
    let blocks: [SessionHUDBlock] = [.columns(title: "LATENCY", latency, latency), .section(stream)]

    let withLongRow = directory.appendingPathComponent("hud-wrap.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: blocks, isFlagged: false), scale: 1, to: withLongRow),
        "the HUD renders with its widest real labels and a value too long for one line"
    )

    // A section with the same labels but a short value in "DROPPED HERE"'s
    // place, so its rendered height is the single-line height every row
    // this fixture otherwise shares -- the wrapped render is taller only if
    // the long value actually grew a second line rather than being clipped
    // to fit the first.
    let shortStream = SessionHUDSection(title: "STREAM", rows: [
        SessionHUDRow(label: "VIDEO IN", value: "41.5 Mbit/s"),
        SessionHUDRow(label: "DROPPED HERE", value: "0")
    ])
    let shortBlocks: [SessionHUDBlock] = [.columns(title: "LATENCY", latency, latency), .section(shortStream)]
    let withShortRow = directory.appendingPathComponent("hud-no-wrap.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: shortBlocks, isFlagged: false), scale: 1, to: withShortRow),
        "the same HUD renders with a value short enough for one line"
    )

    if let longSize = pngSize(at: withLongRow), let shortSize = pngSize(at: withShortRow) {
        expect(
            longSize.height > shortSize.height,
            "the long \"DROPPED HERE\" reading wraps to a second line and grows the panel, "
                + "rather than staying the same height a truncated single line would (\(longSize.height) vs \(shortSize.height))"
        )
    } else {
        expect(false, "both HUD PNGs could be read back")
    }

    // "DROPPED HERE" measures 82pt at 11pt JetBrains Mono -- comfortably
    // under half the 296pt-wide stream section even before it is widened,
    // so ink at its own rightmost stroke, x=88 (panel inset 12 plus 76),
    // proves it drew whole rather than being clipped partway through the
    // word.
    if let labelWidth = pngSize(at: withLongRow) {
        var foundInkNearFullLabelWidth = false
        let x = 12 + 76
        for y in 0..<labelWidth.height {
            if let pixel = pngPixel(at: withLongRow, x: x, y: y) {
                let luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                if luminance > 0.3 { foundInkNearFullLabelWidth = true; break }
            }
        }
        expect(foundInkNearFullLabelWidth, "\"DROPPED HERE\" draws ink out near its own full measured width, not clipped")
    }

    print("PASS: a HUD value too long for its column wraps to a second line, and its own label draws whole rather than clipped")
}

/// At the diagnostics panel's own 320pt width, each latency column is 140pt
/// wide. Every value in this section ("18.5 ms", "22.0 ms"...) is far short
/// of the value-width ceiling, so the label column widens past that fixed
/// floor to fit "END-TO-END" and "INPUT RTT" whole -- checked by comparing
/// this render's own height against a control section whose labels are
/// short enough that nobody could dispute they fit one line: an equal
/// height proves neither real label grew a second line. At this chrome's
/// own 72dpi (see `CairoChromeText`), "END-TO-END" (67pt) plus its own value
/// (41pt) plus the column gap (8pt) is 116pt, well inside the 140pt column,
/// so it draws whole with room to spare.
@MainActor
func testSessionHUDNarrowLatencyLabelsNeverWrapTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-latency-wrap-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let realLatency = SessionHUDSection(title: "THIS MACHINE", rows: [
        SessionHUDRow(label: "RECEIVE", value: "3.2 ms"),
        SessionHUDRow(label: "END-TO-END", value: "18.5 ms"),
        SessionHUDRow(label: "INPUT RTT", value: "22.0 ms")
    ])
    let controlLatency = SessionHUDSection(title: "THIS MACHINE", rows: [
        SessionHUDRow(label: "RECV", value: "3.2 ms"),
        SessionHUDRow(label: "E2E", value: "18.5 ms"),
        SessionHUDRow(label: "RTT", value: "22.0 ms")
    ])
    // The same 320pt width, and the same two-column split, `RenderChromeVerb`
    // renders the real diagnostics panel at.
    let realBlocks: [SessionHUDBlock] = [.columns(title: "LATENCY", realLatency, realLatency)]
    let controlBlocks: [SessionHUDBlock] = [.columns(title: "LATENCY", controlLatency, controlLatency)]

    let realURL = directory.appendingPathComponent("latency-real.png")
    let controlURL = directory.appendingPathComponent("latency-control.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: realBlocks, isFlagged: false), scale: 1, to: realURL),
        "the real latency labels render"
    )
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: controlBlocks, isFlagged: false), scale: 1, to: controlURL),
        "the control's short latency labels render"
    )

    if let realSize = pngSize(at: realURL), let controlSize = pngSize(at: controlURL) {
        expect(
            realSize.height == controlSize.height,
            "\"END-TO-END\" and \"INPUT RTT\" cost no extra height beside short labels that unarguably fit one "
                + "line -- a mid-word wrap would have grown this panel (\(realSize.height) vs \(controlSize.height))"
        )
    } else {
        expect(false, "both latency PNGs could be read back")
    }

    // "INPUT RTT" (56pt at 11pt JetBrains Mono, 72dpi) fits its own widened
    // column whole at 140pt once its own short value ("22.0 ms", 41pt) is
    // reserved rather than a flat 64pt: ink out near its own full measured
    // width proves it drew whole rather than being clipped.
    if let size = pngSize(at: realURL) {
        var foundInkNearFullLabelWidth = false
        let x = 12 + 50 // panel inset + close to "INPUT RTT"'s own full measured width
        for y in 0..<size.height {
            if let pixel = pngPixel(at: realURL, x: x, y: y) {
                let luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                if luminance > 0.3 { foundInkNearFullLabelWidth = true; break }
            }
        }
        expect(foundInkNearFullLabelWidth, "\"INPUT RTT\" draws ink out near its own full measured width, not clipped")
    }

    print("PASS: the narrow latency columns' own labels never wrap mid-word, and \"INPUT RTT\" fits its widened column whole")
}

/// Every action's own icon name, plus the gear's and the pin's, resolves to
/// a real SVG under the icon themes actually installed, so every button
/// draws icon-only rather than its own fallback word.
@MainActor
func testFreedesktopIconLookupResolvesRealThemeTests() {
    FreedesktopIconLookup.forceNotFound = false
    var names = ShortcutStripAction.allCases.map { $0.freedesktopIconNames[0] }
    names.append("emblem-system-symbolic")
    names.append("view-pin-symbolic")
    for name in names {
        expect(
            FreedesktopIconLookup.svgPath(named: name) != nil,
            "\"\(name)\" resolves to a real SVG under the installed icon themes"
        )
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-icon-lookup-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("strip-icons.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: "workshop", isPinned: false), scale: 1, to: url
        ),
        "the strip renders with the real icon theme"
    )
    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: "workshop")
    for rect in rects {
        expect(
            abs(rect.width - 28) < 0.5,
            "\"\(rect.title)\" draws as a 28pt icon-only square rather than falling back to its own word (got width \(rect.width))"
        )
    }

    // A 5x5 grid of luminance samples over the icon glyph itself -- 18pt
    // drawn centred in the 28pt hit square, so the inner 70% of the square
    // is where the ink actually falls -- coarse enough to ignore
    // anti-aliasing but dense enough over both axes that two different
    // glyphs never land on the same fingerprint by chance, and narrow
    // enough to stay off the square's own padding, where a thin glyph (a
    // chevron, an outlined window) leaves no ink to sample.
    func fingerprint(_ rect: (title: String, x: Double, y: Double, width: Double, height: Double)) -> [Double] {
        var samples: [Double] = []
        for yStep in 0..<5 {
            for xStep in 0..<5 {
                let x = Int(rect.x + rect.width * (0.15 + 0.7 * Double(xStep) / 4))
                let y = Int(rect.y + rect.height * (0.15 + 0.7 * Double(yStep) / 4))
                let pixel = pngPixel(at: url, x: x, y: y)
                let luminance = pixel.map { 0.299 * $0.r + 0.587 * $0.g + 0.114 * $0.b }
                samples.append(luminance ?? -1)
            }
        }
        return samples
    }
    let fingerprints = rects.map { (title: $0.title, samples: fingerprint($0)) }
    for i in 0..<fingerprints.count {
        for j in (i + 1)..<fingerprints.count {
            let a = fingerprints[i]
            let b = fingerprints[j]
            let identical = zip(a.samples, b.samples).allSatisfy { abs($0 - $1) < 0.02 }
            expect(!identical, "\"\(a.title)\" and \"\(b.title)\" draw the same icon")
        }
    }

    print("PASS: every strip action's icon resolves on the real installed theme, every button draws icon-only, and no two draw the same icon")
}

/// A fixed mono-11 string measures the same logical width whether the
/// context it is measured on carries a 1x or a 1.5x backing-scale
/// `cairo_scale` -- what a label sized against the unscaled
/// `measuringContext` needs to still fit once actually drawn on a real,
/// scaled overlay context. Anchored near 67pt, the real measured width of
/// "END-TO-END" in JetBrains Mono 11 at the 72dpi this chrome pins Pango to.
@MainActor
func testChromeTextScaleParityTests() {
    let text = "END-TO-END"
    let atOnex = SessionChromeRenderPreview.measureChromeText(text, pointSize: 11, mono: true, scale: 1)
    let atOnePointFivex = SessionChromeRenderPreview.measureChromeText(text, pointSize: 11, mono: true, scale: 1.5)
    expect(
        abs(atOnex - atOnePointFivex) < 1,
        "\"\(text)\" measures \(atOnex)pt at 1x and \(atOnePointFivex)pt at 1.5x, more than 1pt apart"
    )
    expect(
        abs(atOnex - 67) < 3,
        "\"\(text)\" measures \(atOnex)pt, not near the 67pt a 72dpi context gives it"
    )
    print("PASS: a chrome string measures the same logical width at 1x and 1.5x, near its real 72dpi width")
}

/// An empty diagnostics panel draws nothing but its own footer -- `gap`
/// above, one line per chord, `gap` below -- so its own three rows are the
/// whole render. A total-height check alone cannot tell a whole chord line
/// from a split one: a sentence long enough to wrap at this width can still
/// land on three rows in total, just not the three rows this test means.
/// What only a split changes is how far each row's own ink reaches -- a
/// chord broken onto the row below leaves the row above short of that
/// chord's own full width, and the row below overruns its own -- so each
/// row's own ink is checked against its own line's own full measured width,
/// at both 1x and 1.5x.
@MainActor
func testHUDFooterKeyChordsNeverSplitTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-footer-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let gap: Double = 12
    let diagnosticsWidth: Double = 320
    let rowSize: Double = 11
    let lines = [
        "Session controls: \(ViewerKeyNames.sessionControls)",
        "Shortcut strip: \(ViewerKeyNames.shortcutStrip)",
        "Back to this machine: \(ViewerKeyNames.escapeGesture)"
    ]

    // Each line's own single-line height and full natural width, measured
    // independently of the footer render below -- `ellipsize` forces
    // exactly one line by contract, so this is what a whole, unsplit line
    // costs and how far its own ink reaches.
    let lineHeights = lines.map {
        SessionChromeRenderPreview.measureChromeTextHeight(
            $0, pointSize: rowSize, maxWidth: diagnosticsWidth - gap * 2, ellipsize: true
        )
    }
    let naturalWidths = lines.map {
        SessionChromeRenderPreview.measureChromeText($0, pointSize: rowSize, mono: false, scale: 1)
    }
    let expectedHeight = gap * 2 + lineHeights.reduce(0, +)

    for scale in [1.0, 1.5] {
        let url = directory.appendingPathComponent("footer-\(scale).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: [], isFlagged: false), scale: scale, to: url),
            "an empty diagnostics panel, which is only its own footer, renders at \(scale)x"
        )
        guard let size = pngSize(at: url) else {
            expect(false, "the footer PNG at \(scale)x could be read back")
            continue
        }
        let renderedHeight = Double(size.height) / scale
        expect(
            abs(renderedHeight - expectedHeight) < 1,
            "the footer rendered \(renderedHeight)pt tall at \(scale)x, not near the \(expectedHeight)pt three "
                + "whole chord lines cost -- a chord split across two lines would grow this past that"
        )

        var rowTop = gap
        for row in 0..<3 {
            let pixelTop = Int((rowTop * scale).rounded())
            let pixelBottom = Int(((rowTop + lineHeights[row]) * scale).rounded())
            var maxInkX = -1
            for py in pixelTop..<min(pixelBottom, size.height) {
                for px in stride(from: size.width - 1, through: 0, by: -1) {
                    if let pixel = pngPixel(at: url, x: px, y: py) {
                        let luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                        if luminance > 0.3 { maxInkX = max(maxInkX, px); break }
                    }
                }
            }
            let expectedInkX = naturalWidths[row] * scale
            // A whole line's own last glyph still overshoots its own
            // measured advance by ~9pt logical (an ordinary hinting/ink
            // overshoot this font gives every one of these three lines
            // alike, not a defect) -- 30pt is generous past that and still
            // an order of magnitude under the ~100-180pt logical a chord
            // split onto the wrong row moves a row's own ink by.
            expect(
                Double(maxInkX) > expectedInkX - 30 * scale && Double(maxInkX) < expectedInkX + 30 * scale,
                "row \(row) at \(scale)x draws ink out to \(maxInkX)px, not the \(expectedInkX)px "
                    + "\"\(lines[row])\" draws whole -- a chord split onto the row below would fall short "
                    + "here, and overrun the row above"
            )
            rowTop += lineHeights[row]
        }
    }

    print("PASS: the HUD footer's three key-chord lines never split across two lines, at 1x or 1.5x")
}
#else
@MainActor
func testSessionChromePainterPixelTests() {}
@MainActor
func testShortcutStripIconFallbackDrawsInkTests() {}
@MainActor
func testShortcutStripLongHostNameNeverDrawsUnderPillTests() {}
@MainActor
func testNoticeBorderAndDismissGlyphTests() {}
@MainActor
func testShortcutStripOverflowNeverOverlapsTests() {}
@MainActor
func testSessionHUDLabelWrapNotTruncatedTests() {}
@MainActor
func testSessionHUDNarrowLatencyLabelsNeverWrapTests() {}
@MainActor
func testFreedesktopIconLookupResolvesRealThemeTests() {}
@MainActor
func testChromeTextScaleParityTests() {}
@MainActor
func testHUDFooterKeyChordsNeverSplitTests() {}
@MainActor
func testScrimOpaqueBeforeFirstFrameTests() {}
#endif
