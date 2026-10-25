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

/// Every button on the strip -- ten actions and the pin -- draws its own
/// glyph in ink. The pinned pin is a filled glyph with nothing accented
/// behind it, and the confirm row leaves the host name and the pin where
/// they were.
@MainActor
func testShortcutStripGlyphsDrawTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-glyph-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "Studio"
    let width = 1100.0
    func render(_ name: String, _ visibility: ShortcutStripVisibility, pinned: Bool, scale: Double = 1) -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(
                .strip(visibility: visibility, hostName: hostName, isPinned: pinned), scale: scale, width: width, to: url
            ),
            "the \(name) strip renders"
        )
        return url
    }
    func inkCount(_ url: URL, _ rect: (title: String, x: Double, y: Double, width: Double, height: Double), scale: Double = 1) -> Int {
        var count = 0
        for y in Int(rect.y * scale)..<Int((rect.y + rect.height) * scale) {
            for x in Int(rect.x * scale)..<Int((rect.x + rect.width) * scale) {
                if matches(pngPixel(at: url, x: x, y: y), ViewerPalette.ink) { count += 1 }
            }
        }
        return count
    }
    func accentCount(_ url: URL, _ rect: (title: String, x: Double, y: Double, width: Double, height: Double)) -> Int {
        var count = 0
        for y in Int(rect.y)..<Int(rect.y + rect.height) {
            for x in Int(rect.x)..<Int(rect.x + rect.width) where matches(pngPixel(at: url, x: x, y: y), ViewerPalette.accent) {
                count += 1
            }
        }
        return count
    }

    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width)
    expect(rects.count == 11, "ten actions and the pin, and no gear, got \(rects.count)")
    expect(rects.last?.title == "Pin", "the pin is the last button")
    for scale in [1.0, 1.5, 2.0] {
        let shown = render("shown-\(scale)", .shown, pinned: false, scale: scale)
        for rect in rects {
            expect(inkCount(shown, rect, scale: scale) > Int(4 * scale * scale),
                   "\"\(rect.title)\" draws its glyph in ink at \(scale)x")
        }
    }

    let shown = render("shown", .shown, pinned: false)
    let pinned = render("pinned", .shown, pinned: true)
    if let pin = rects.last {
        expect(accentCount(pinned, pin) == 0, "the pinned pin has no accent fill behind it")
        expect(inkCount(pinned, pin) > inkCount(shown, pin), "the pinned pin is filled, the unpinned one an outline")
    }

    let confirming = ShortcutStripVisibility.confirming(.lockScreen)
    let confirmRects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width, visibility: confirming)
    let pinWhileConfirming = confirmRects.first(where: { $0.title == "Pin" })
    expect(pinWhileConfirming != nil, "the pin can still be pressed on the confirm row")
    if let pinWhileConfirming, let pin = rects.last {
        expect(pinWhileConfirming.x == pin.x && pinWhileConfirming.y == pin.y, "the pin stays put on the confirm row")
    }
    let confirmURL = render("confirming", confirming, pinned: false)
    var shownHostInk = 0
    var confirmHostInk = 0
    for y in 0..<40 {
        for x in 0..<80 {
            if matches(pngPixel(at: shown, x: x, y: y), ViewerPalette.muted) { shownHostInk += 1 }
            if matches(pngPixel(at: confirmURL, x: x, y: y), ViewerPalette.muted) { confirmHostInk += 1 }
        }
    }
    expect(shownHostInk > 0 && shownHostInk == confirmHostInk,
           "the host name stays put, in muted ink, on the confirm row (\(shownHostInk) vs \(confirmHostInk))")
    if let pin = rects.last {
        expect(inkCount(confirmURL, pin) == inkCount(shown, pin), "the confirm row draws the same pin")
    }

    print("PASS: every strip button draws its own glyph at 1x, 1.5x and 2x, the pin fills rather than accents, and the confirm row keeps the host name and pin")
}

/// The strip's glyphs read as one set: none is visibly smaller than the rest.
/// A glyph drawn wide and short, like the three-window Mission Control one,
/// leaves most of its height empty, so each is judged by the side of the
/// square with the same ink extent -- the square root of its ink width times
/// its ink height -- against the median of the set.
@MainActor
func testShortcutStripGlyphsShareOneOpticalSizeTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-optical-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "Studio"
    let width = 1100.0
    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width)
    expect(rects.count == 11, "ten actions and the pin, got \(rects.count)")
    for scale in [1.5, 2.0] {
        let url = directory.appendingPathComponent("strip-\(scale).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(
                .strip(visibility: .shown, hostName: hostName, isPinned: false), scale: scale, width: width, to: url
            ),
            "the strip renders at \(scale)x"
        )
        var sizes: [(title: String, side: Double)] = []
        for rect in rects {
            let left = Int(rect.x * scale)
            let right = Int((rect.x + rect.width) * scale)
            let top = Int(rect.y * scale)
            let bottom = Int((rect.y + rect.height) * scale)
            // The glyph is the ink colour on whatever the button sits on, so
            // a pixel is ink when it is most of the way from that to the ink.
            guard let ground = pngPixel(at: url, x: left + 1, y: (top + bottom) / 2) else {
                expect(false, "\"\(rect.title)\" can be read back at \(scale)x")
                return
            }
            let reach = ViewerPalette.ink.red - ground.r
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in top..<bottom {
                for x in left..<right {
                    guard let pixel = pngPixel(at: url, x: x, y: y), (pixel.r - ground.r) / reach > 0.4 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            expect(maxX >= 0, "\"\(rect.title)\" draws something at \(scale)x")
            let inkWidth = Double(maxX - minX + 1) / scale
            let inkHeight = Double(maxY - minY + 1) / scale
            sizes.append((rect.title, (inkWidth * inkHeight).squareRoot()))
        }
        let median = sizes.map(\.side).sorted()[sizes.count / 2]
        for entry in sizes {
            expect(
                (median * 0.9)...(median * 1.1) ~= entry.side,
                "\"\(entry.title)\" is within 10% of the median glyph's optical size at \(scale)x, got "
                    + "\(entry.side) pt against \(median) pt, of \(sizes.map { "\($0.title) \($0.side)" })"
            )
        }
    }
    print("PASS: no strip glyph's ink is visibly smaller or larger than the rest at 1.5x and 2x")
}

/// A host name too long for a narrow bar is truncated before the trailing
/// pin pill, never drawn under it. The host name is the only
/// strip text drawn in `ViewerPalette.muted`, so that colour reaching
/// under the pill is what a caller that forgot to cap it would draw.
@MainActor
func testShortcutStripLongHostNameNeverDrawsUnderPillTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-hostname-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "workshop-in-the-back-annex-that-never-gets-a-shorter-name-and-keeps-on-going-well-past-any-bar"
    let width = 420.0
    let url = directory.appendingPathComponent("strip-long-hostname.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: hostName, isPinned: false), scale: 1, width: width, to: url
        ),
        "the strip renders at a narrow width with a very long host name"
    )

    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width)
    let pin = rects.first(where: { $0.title == "Pin" })
    expect(pin != nil, "the pin still draws at a narrow width")
    guard let pin else { return }

    // The pill is opaque, so a name drawn under it would be hidden rather
    // than seen: what shows a missing cap is the name's ink in the gap before
    // the pill, which the layout keeps clear.
    let pillLeft = Int(pin.x - Double(ViewerChromeMetrics.Space.xxs))
    let gap = Int(ViewerChromeMetrics.Space.sm) - 2
    let top = Int(pin.y)
    let bottom = Int(pin.y + pin.height)
    var foundHostNameInkBeforePill = false
    for y in top..<bottom {
        for x in (pillLeft - gap)..<pillLeft {
            if matches(pngPixel(at: url, x: x, y: y), ViewerPalette.muted) {
                foundHostNameInkBeforePill = true
            }
        }
    }
    expect(!foundHostNameInkBeforePill, "the host name's own ink reaches into the gap before the pin pill at x=\(pillLeft)")

    print("PASS: a very long host name is truncated before the trailing pin pill, never drawn under it")
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

    // macOS draws the same cross in the ink its text uses, near white, not
    // in the muted grey of a secondary label. A pixel on the crossing of the
    // two strokes is covered by both, so it holds the stroke's own colour.
    let crossing = (-1...1).flatMap { dx in (-1...1).map { dy in pngPixel(at: url, x: centreX + dx, y: centreY + dy) } }
    expect(
        crossing.contains { matches($0, ViewerPalette.ink) },
        "the dismiss cross is the ink the macOS notice draws its \u{2715} in, not a muted one"
    )

    // A one-point border is a whole number of device pixels wide at any
    // backing scale, sitting on the pixel grid: at 1.5x a point is one and a
    // half pixels, and drawn as is it lights one row and half of the next.
    for hairlineScale in [1.0, 1.25, 1.5, 2.0] {
        let borderURL = directory.appendingPathComponent("notice-\(hairlineScale).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(.notice("A short refusal line."), scale: hairlineScale, to: borderURL),
            "the notice renders at \(hairlineScale)x"
        )
        guard let borderSize = pngSize(at: borderURL) else {
            expect(false, "the \(hairlineScale)x notice PNG could not be read back")
            continue
        }
        let thickness = max(1, Int(hairlineScale.rounded()))
        let middleX = borderSize.width / 2
        let middleY = borderSize.height / 2
        func isBorder(_ x: Int, _ y: Int) -> Bool { matches(pngPixel(at: borderURL, x: x, y: y), ViewerPalette.warn) }
        for offset in 0..<(thickness + 1) {
            let inside = offset < thickness
            expect(
                isBorder(middleX, offset) == inside && isBorder(middleX, borderSize.height - 1 - offset) == inside
                    && isBorder(offset, middleY) == inside && isBorder(borderSize.width - 1 - offset, middleY) == inside,
                "at \(hairlineScale)x the border is \(thickness) whole pixels wide on every edge, "
                    + "and the pixel \(offset) in from the edge is \(inside ? "" : "not ")border"
            )
        }
    }

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
/// and 800 -- no two of the strip's own buttons ever touch and none crosses
/// the bar's own edge: the toolbar-style overflow `stripClusters` drops
/// whole clusters for, rather than letting the host name, the action
/// clusters and the trailing pin pill crowd into each other.
@MainActor
func testShortcutStripOverflowNeverOverlapsTests() {
    for width in [1280.0, 1024.0, 800.0] {
        let rects = SessionChromeRenderPreview.stripButtonRects(hostName: "workshop", width: width)
        let context = "width \(Int(width))"
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

    print("PASS: the shortcut strip never overlaps its own buttons or overruns the bar at 1280, 1024 or 800")
}

@MainActor
private func testDiagnosticsViewportPixelTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sensorium-hud-scroll-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = SessionHUDLink(title: "Decoder help", url: "https://example.invalid/decoder")
    let blocks: [SessionHUDBlock] = (0..<12).map { index in
        .section(SessionHUDSection(title: "SECTION \(index)", rows: [
            SessionHUDRow(label: "VALUE", value: "\(index)", link: index == 11 ? link : nil)
        ]))
    }
    let full = directory.appendingPathComponent("full.png")
    let bottom = directory.appendingPathComponent("bottom.png")
    let height = 160.0
    let measured = SessionChromeRenderPreview.diagnosticsSize(blocks: blocks)
    let offset = floor(measured.height - height)
    expect(SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: blocks, isFlagged: false), scale: 1, to: full),
           "the full diagnostics reference renders")
    expect(SessionChromeRenderPreview.renderDiagnosticsViewport(blocks: blocks, width: 320, height: height, offset: offset, to: bottom),
           "the final diagnostics section renders inside a bounded scrolled viewport")
    expect(pngSize(at: bottom)?.height == Int(height), "the viewport bitmap fits the available height")
    var compared = 0
    for y in stride(from: 12, to: Int(height) - 12, by: 3) {
        for x in stride(from: 12, to: 300, by: 3) {
            if let actual = pngPixel(at: bottom, x: x, y: y),
               let expected = pngPixel(at: full, x: x, y: y + Int(offset)) {
                expect(abs(actual.r - expected.r) < 0.02 && abs(actual.g - expected.g) < 0.02 && abs(actual.b - expected.b) < 0.02,
                       "scrolled diagnostics draws the same content pixels at the translated position")
                compared += 1
            }
        }
    }
    expect(compared > 100, "the translated viewport was compared against the full content")
    let viewport = DiagnosticsViewport(contentHeight: measured.height, viewportHeight: height, offset: offset)
    let layouts = SessionChromeRenderPreview.diagnosticsLinkLayouts(blocks: blocks)
    if let target = layouts.first {
        let visibleY = target.rect.y + target.rect.height / 2 - viewport.offset
        expect(visibleY >= 0 && visibleY < height, "the last section's help link is visible after scrolling")
        expect(viewport.contentY(atViewportY: visibleY).flatMap {
            SessionHUDLinkHitTest.link(atX: target.rect.x + 1, y: $0, in: layouts)
        } == link, "the scrolled help link activates at its visible location")
    } else {
        expect(false, "the final section's help link was laid out")
    }
    print("PASS: diagnostics viewport paints translated content and hits the final help link")
}

/// A value too long for its column stays on one line and loses its end to
/// an ellipsis, as a truncating-tail value does on macOS, and its label still
/// draws whole.
@MainActor
func testSessionHUDLongValueStaysOnOneLineTests() {
    testDiagnosticsViewportPixelTests()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-one-line-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func stream(_ dropped: String) -> [SessionHUDBlock] {
        [.section(SessionHUDSection(title: "STREAM", rows: [
            SessionHUDRow(label: "VIDEO IN", value: "41.5 Mbit/s"),
            SessionHUDRow(label: "DROPPED HERE", value: dropped)
        ]))]
    }
    let longURL = directory.appendingPathComponent("hud-long.png")
    let shortURL = directory.appendingPathComponent("hud-short.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .diagnostics(blocks: stream("12840 before decode, 9075 before present"), isFlagged: false),
            scale: 1, to: longURL
        ),
        "the HUD renders with a value too long for one line"
    )
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: stream("0"), isFlagged: false), scale: 1, to: shortURL),
        "the same HUD renders with a short value"
    )
    if let longSize = pngSize(at: longURL), let shortSize = pngSize(at: shortURL) {
        expect(
            longSize.height == shortSize.height,
            "the long reading stays on one line (\(longSize.height) vs \(shortSize.height))"
        )
    } else {
        expect(false, "both HUD PNGs could be read back")
    }

    // "DROPPED HERE" is about 79pt at 11pt monospace; its label column is
    // 96, so ink near its end, at x = 12 + 74, proves it drew whole.
    if let size = pngSize(at: longURL) {
        var found = false
        for y in 0..<size.height {
            if let pixel = pngPixel(at: longURL, x: 12 + 74, y: y) {
                let luminance = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                if luminance > 0.3 { found = true; break }
            }
        }
        expect(found, "\"DROPPED HERE\" draws ink out near its own full width, not clipped")
    }

    print("PASS: a HUD value too long for its column stays on one line, and its label draws whole")
}

/// At the diagnostics panel's own 320pt width, each latency column is 140pt
/// wide with a 70pt label column, which holds "END-TO-END" and "INPUT RTT"
/// whole -- checked by comparing this render's own height against a control
/// section whose labels are short enough that nobody could dispute they fit
/// one line: an equal height proves neither real label grew a second line.
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

    // "INPUT RTT" is about 60pt at 11pt monospace, 72dpi: ink out near its
    // own full width proves it drew whole in its 70pt column.
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

    print("PASS: the narrow latency columns' own labels never wrap mid-word, and \"INPUT RTT\" fits its 70pt column whole")
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

/// Text the session window paints is drawn at its role's own weight, the
/// same token the GTK windows read.
@MainActor
func testChromeTextRoleWeightTests() {
    func pangoWidth(_ text: String, pointSize: Double, weight: Int) -> Double {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1) else { return 0 }
        defer { cairo_surface_destroy(surface) }
        guard let context = cairo_create(surface), let layout = pango_cairo_create_layout(context) else { return 0 }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)); cairo_destroy(context) }
        let layoutContext = pango_layout_get_context(layout)
        pango_cairo_context_set_resolution(layoutContext, 72)
        let options = cairo_font_options_create()
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
        pango_cairo_context_set_font_options(layoutContext, options)
        cairo_font_options_destroy(options)
        pango_context_set_round_glyph_positions(layoutContext, 0)
        let description = pango_font_description_new()
        pango_font_description_set_family(description, "sans-serif")
        pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(weight)))
        pango_font_description_set_size(description, sensorium_pango_units_from_points(pointSize))
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, text, -1)
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return Double(width)
    }
    typealias Weight = ViewerChromeMetrics.TextWeight
    let roles: [(String, Double, Int)] = [
        ("Cannot reach Workstation.", 16, Weight.headline),
        ("Try Again", 13, Weight.button),
        ("Check that it is awake.", 12, Weight.detail),
        ("Connected to Workstation.", 11, Weight.hudNote),
    ]
    for (text, size, weight) in roles {
        let painted = SessionChromeRenderPreview.measureChromeText(text, pointSize: size, mono: false, scale: 1, weight: weight)
        let expected = pangoWidth(text, pointSize: size, weight: weight)
        expect(painted == expected, "\"\(text)\" is painted at weight \(weight), \(expected)pt wide, got \(painted)pt")
    }
    print("PASS: painted text is drawn at its role's weight")
}

/// The HUD's labels and values are in the system's monospace family, as
/// they are mono on macOS: a narrow and a wide glyph measure the same.
@MainActor
func testChromeTextMonoIsMonospaceTests() {
    let narrow = SessionChromeRenderPreview.measureChromeText("iiiiiiiiii", pointSize: 11, mono: true, scale: 1)
    let wide = SessionChromeRenderPreview.measureChromeText("MMMMMMMMMM", pointSize: 11, mono: true, scale: 1)
    expect(abs(narrow - wide) < 0.5, "ten i and ten M measure the same in the HUD's mono face, got \(narrow) and \(wide)")
    print("PASS: the HUD's mono text is set in a monospace family")
}

/// Painted text sits on the lines AppKit sets a label's on macOS, whatever
/// the Linux face's own metrics: each line `TextLine.height` tall, its
/// baseline `TextLine.baseline` below the top.
@MainActor
func testChromeTextSitsOnMacLinesTests() {
    typealias Line = ViewerChromeMetrics.TextLine
    for (size, mono) in [(11.0, true), (12.0, true), (11.0, false), (12.0, false), (13.0, false), (16.0, false)] {
        let label = "\(Int(size))pt \(mono ? "mono" : "sans")"
        let line = Line.height(size: size, mono: mono)
        let one = SessionChromeRenderPreview.measureChromeTextHeight(
            "HELD", pointSize: size, mono: mono, maxWidth: 400, ellipsize: false
        )
        let three = SessionChromeRenderPreview.measureChromeTextHeight(
            "HELD\nHELD\nHELD", pointSize: size, mono: mono, maxWidth: 400, ellipsize: false
        )
        expect(one == line && three == 3 * line, "\(label) lines are \(line)pt tall, got \(one) and \(three) for three")
        for scale in [1.5, 2.0] {
            let bottom = SessionChromeRenderPreview.chromeTextInkBottom("HELD", pointSize: size, mono: mono, scale: scale)
            let baseline = Line.baseline(size: size, mono: mono)
            expect(
                abs(bottom - baseline) <= 1 / scale,
                "\(label) sits on a baseline \(baseline)pt below its top at \(scale)x, got \(bottom)"
            )
        }
    }
    print("PASS: painted text sits on the lines AppKit sets on macOS")
}

/// The panel ends 12pt below its last section, as `SessionHUDView` does:
/// no footer of chord lines under it, and no row gap after a section's last
/// row, which AppKit's stack view only puts between rows.
@MainActor
func testHUDHasNoFooterTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-footer-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let section = SessionHUDSection(title: "STREAM", rows: [SessionHUDRow(label: "FPS", value: "58")])
    let url = directory.appendingPathComponent("hud.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: [.section(section)], isFlagged: false), scale: 1, to: url),
        "a one-row HUD renders"
    )
    let height = Double(pngSize(at: url)?.height ?? 0)
    let title = SessionChromeRenderPreview.measureChromeTextHeight("STREAM", pointSize: 12, mono: true, maxWidth: 296, ellipsize: true)
    let row = SessionChromeRenderPreview.measureChromeTextHeight("58", pointSize: 11, mono: true, maxWidth: 296, ellipsize: true)
    // Top inset, title, gap, row, bottom inset.
    let expected = 12 + title + 4 + row + 12
    expect(
        abs(height - expected) < 1,
        "a one-row panel is \(expected)pt tall with nothing under its last section, got \(height)"
    )

    let twoURL = directory.appendingPathComponent("hud-two.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .diagnostics(blocks: [.section(section), .section(section)], isFlagged: false), scale: 1, to: twoURL
        ),
        "a two-section HUD renders"
    )
    let twoHeight = Double(pngSize(at: twoURL)?.height ?? 0)
    // The group gap alone between the two sections.
    let twoExpected = 12 + (title + 4 + row) + 16 + (title + 4 + row) + 12
    expect(
        abs(twoHeight - twoExpected) < 1,
        "two one-row sections stand 16pt apart in a \(twoExpected)pt panel, got \(twoHeight)"
    )
    print("PASS: the HUD has no footer under its last section")
}

/// The two latency columns' headers sit one size under the block's eyebrow,
/// as `SessionHUDView` sets them at 11.
@MainActor
func testHUDColumnHeadersStepDownTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-columns-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let left = SessionHUDSection(title: "THIS MACHINE", rows: [SessionHUDRow(label: "DECODE", value: "3 ms")])
    let right = SessionHUDSection(title: "MINI", rows: [SessionHUDRow(label: "ENCODE", value: "4 ms")])
    let url = directory.appendingPathComponent("hud-columns.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .diagnostics(blocks: [.columns(title: "LATENCY", left, right)], isFlagged: false), scale: 1, to: url
        ),
        "a HUD of two columns renders"
    )
    let height = Double(pngSize(at: url)?.height ?? 0)
    let line = ViewerChromeMetrics.TextLine.height
    // Top inset, block eyebrow, gap, column header, gap, row, bottom inset.
    let expected = 12 + line(12, true) + 4 + line(11, true) + 4 + line(11, true) + 12
    expect(
        abs(height - expected) < 1,
        "a columns block with 11pt headers is \(expected)pt tall, got \(height)"
    )
    print("PASS: the HUD's column headers sit one size under its eyebrows")
}

/// A last-known reading is drawn as `SessionHUDView` draws it: its label in
/// the same muted tone as any other label, and its value dimmed to that tone,
/// not below it.
@MainActor
func testHUDStaleRowToneTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-stale-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let section = SessionHUDSection(title: "FIDELITY", rows: [
        SessionHUDRow(label: "SIZE", value: "2880 × 1800", isStale: true),
        SessionHUDRow(label: "APPLIED", value: "1.50x", isStale: true)
    ])
    let url = directory.appendingPathComponent("hud-stale.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: [.section(section)], isFlagged: false), scale: 2, to: url),
        "a HUD of stale rows renders"
    )
    guard let surface = cairo_image_surface_create_from_png(url.path),
          cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS,
          let data = cairo_image_surface_get_data(surface) else {
        expect(false, "the stale HUD render reads back")
        return
    }
    defer { cairo_surface_destroy(surface) }
    let stride = Int(cairo_image_surface_get_stride(surface))
    var brightest = 0
    for y in 0..<Int(cairo_image_surface_get_height(surface)) {
        for x in 0..<Int(cairo_image_surface_get_width(surface)) {
            brightest = max(brightest, Int(data[y * stride + x * 4 + 1]))
        }
    }
    let muted = Int((ViewerPalette.muted.green * 255).rounded())
    expect(
        abs(brightest - muted) <= 2,
        "the brightest stale text is the muted tone, \(muted), got \(brightest)"
    )
    print("PASS: a stale HUD row draws its label and value in the muted tone, as on macOS")
}

/// VIDEO IN's trend draws a sparkline in the data-viz colour at the trailing
/// edge of its row, the way `SessionHUDSparklineView` draws it on macOS.
@MainActor
func testHUDSparklineDrawsTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-sparkline-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func render(_ trend: [Double]?, name: String) -> Int {
        let blocks: [SessionHUDBlock] = [.section(SessionHUDSection(title: "STREAM", rows: [
            SessionHUDRow(label: "VIDEO IN", value: "41.5 Mbit/s", trend: trend)
        ]))]
        let url = directory.appendingPathComponent(name)
        expect(
            SessionChromeRenderPreview.renderOverlay(.diagnostics(blocks: blocks, isFlagged: false), scale: 1, to: url),
            "the HUD renders \(name)"
        )
        guard let size = pngSize(at: url) else { return -1 }
        var pink = 0
        for y in 0..<size.height {
            for x in (12 + 227)..<(12 + 291) {
                if let p = pngPixel(at: url, x: x, y: y), p.r > 0.6, p.g < 0.8, p.b > 0.5, p.r > p.g + 0.15 {
                    pink += 1
                }
            }
        }
        return pink
    }
    let with = render([38, 40, 41.5, 39, 42, 41.5], name: "trend.png")
    let without = render(nil, name: "no-trend.png")
    expect(with > 20, "a trend draws pink ink in the row's trailing 64pt, got \(with) pixels")
    expect(without == 0, "a row without a trend draws none, got \(without) pixels")
    print("PASS: a HUD trend draws its sparkline at the row's trailing edge, and a row without one draws none")
}
/// The painted session menu bar is the metric height at every scale, on the
/// chrome surface, with the open menu's title on a lifted pill.
@MainActor
func testSessionMenuBarPaintsTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-menu-bar-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let titles = ["Sensorium", "Edit", "View"]
    for scale in [1.0, 1.5, 2.0] {
        let url = directory.appendingPathComponent("bar-\(scale).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(.menuBar(titles: titles, openIndex: 1), scale: scale, width: 400, to: url),
            "the menu bar renders at \(scale)x"
        )
        let expected = Int((Double(ViewerChromeMetrics.MenuBar.height) * scale).rounded())
        expect(pngSize(at: url)?.height == expected, "the bar is \(expected)px tall at \(scale)x, got \(String(describing: pngSize(at: url)))")
        let last = expected - 1
        expect(matches(pngPixel(at: url, x: 398, y: 2), ViewerPalette.chromeBg2), "the bar is the chrome surface at \(scale)x")
        expect(
            matches(pngPixel(at: url, x: 398, y: last), ViewerPalette.chromeBg2),
            "the bar draws no hairline, which GTK could only draw blurred at 1.5x, at \(scale)x"
        )
        let items = SessionChromeRenderPreview.menuBarItems(titles: titles)
        let open = Int(((items[1].x + 2) * scale).rounded())
        let closed = Int(((items[2].x + 2) * scale).rounded())
        let middle = expected / 2
        expect(matches(pngPixel(at: url, x: open, y: middle), ViewerPalette.bg4), "the open title sits on a pill at \(scale)x")
        let pillTop = Int((4 * scale).rounded())
        expect(
            matches(pngPixel(at: url, x: open + 4, y: pillTop), ViewerPalette.bg4)
                && matches(pngPixel(at: url, x: open + 4, y: pillTop - 1), ViewerPalette.chromeBg2),
            "the pill starts crisply 4pt down at \(scale)x"
        )
        expect(matches(pngPixel(at: url, x: closed, y: middle), ViewerPalette.chromeBg2), "a closed title has none at \(scale)x")
    }
    print("PASS: the painted menu bar is the metric height at 1x, 1.5x and 2x, with the open title on a pill")
}

/// Brightest pixel in a rect of a PNG, as the largest of its components --
/// light text on the dark chrome is never brighter than its own colour.
private func brightest(at url: URL, x: Range<Int>, y: Range<Int>) -> Double {
    var best = 0.0
    for py in y {
        for px in x {
            if let p = pngPixel(at: url, x: px, y: py) { best = max(best, p.r, p.g, p.b) }
        }
    }
    return best
}

/// A painted menu draws a checkmark only on the current choice, dims a
/// disabled row, fills the highlighted row with the accent, and names its
/// chords with Super standing in for Command.
@MainActor
func testSessionMenuPopupPaintsTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-menu-popup-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let menu = ViewerMenu(title: "View", items: [
        ViewerMenuItem(title: "Fit to Window", command: .setStreamScale(nil), isSelected: true),
        ViewerMenuItem(title: "Enter Full Screen", command: .toggleFullScreen, keyEquivalent: "f", modifiers: [.command, .control]),
        .separator,
        ViewerMenuItem(title: "Capture Pointer", command: .togglePointerCapture, isEnabled: false),
        ViewerMenuItem(title: "Start With", command: .submenu, submenu: ViewerMenu(title: "Start With", items: []))
    ])
    let url = directory.appendingPathComponent("popup.png")
    expect(SessionChromeRenderPreview.renderOverlay(.menuPopup(menu, highlighted: 1), scale: 1, to: url), "the menu renders")
    let layout = SessionChromeRenderPreview.menuPopupLayout(menu)
    expect(layout.width >= Double(ViewerChromeMetrics.MenuBar.minimumPopupWidth), "the menu is at least its minimum width")
    expect(pngSize(at: url)?.height == Int(layout.height.rounded()), "the PNG is the layout's height")

    let padding = Int(ViewerChromeMetrics.MenuBar.rowPaddingX)
    let check = padding..<(padding + Int(ViewerChromeMetrics.MenuBar.checkColumnWidth))
    func rows(_ index: Int) -> Range<Int> {
        let rect = layout.rect(ofRow: index)
        return Int(rect.y + 2)..<Int(rect.y + rect.height - 2)
    }
    expect(brightest(at: url, x: check, y: rows(0)) > 0.85, "the current choice draws a checkmark in ink")
    expect(brightest(at: url, x: check, y: rows(3)) < 0.3, "a row that is not chosen draws nothing in the check column")
    let text = (padding + check.count)..<(Int(layout.width) - padding)
    expect(brightest(at: url, x: text, y: rows(3)) < 0.45, "a disabled row is drawn dim, got \(brightest(at: url, x: text, y: rows(3)))")
    expect(brightest(at: url, x: text, y: rows(0)) > 0.85, "an enabled row is drawn in ink")
    let rect1 = layout.rect(ofRow: 1)
    expect(
        matches(pngPixel(at: url, x: Int(layout.width) / 2, y: Int(rect1.y + 2)), ViewerPalette.accent),
        "the highlighted row is filled with the accent"
    )
    expect(
        SessionChromeRenderPreview.menuChordLabel(for: menu.items[1]) == "Ctrl+Super+F",
        "the full screen chord reads Ctrl+Super+F"
    )
    print("PASS: a painted menu checks the current choice, dims disabled rows, highlights in accent, and labels chords with Super")
}
/// The scrim draws over the HUD, dimming it, and leaves the menu bar above
/// it undimmed; the HUD starts below the bar.
@MainActor
func testSessionCompositeStackingTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-composite-stacking-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "mini.local"
    var live = SessionChromeState()
    live.toggleDiagnosticsRequested()
    var lost = live
    var machine = ViewerSessionStateMachine(hostName: hostName)
    machine.handle(.canvasReady)
    machine.handle(.sessionEnded)
    lost.apply(status: machine.status, now: 0)
    let titles = ["Sensorium", "Edit", "View"]
    func render(_ state: SessionChromeState, _ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        expect(
            SessionChromeRenderPreview.renderComposite(
                state: state, hostName: hostName, menuTitles: titles, windowWidth: 900, windowHeight: 600, scale: 1, to: url
            ),
            "the \(name) composite renders"
        )
        return url
    }
    let liveURL = render(live, "live.png")
    let lostURL = render(lost, "lost.png")
    let bar = Int(ViewerChromeMetrics.MenuBar.height)
    let hudX = Int(ViewerChromeMetrics.Diagnostics.edgeInset) + 4
    let hudY = bar + Int(ViewerChromeMetrics.Diagnostics.edgeInset) + 4
    let above = pngPixel(at: liveURL, x: hudX, y: bar + 2)
    let hud = pngPixel(at: liveURL, x: hudX, y: hudY)
    expect(
        matches(above, ViewerColor(hex: 0x000000)) && !matches(hud, ViewerColor(hex: 0x000000)),
        "the HUD starts one inset below the bar"
    )
    let dimmed = pngPixel(at: lostURL, x: hudX, y: hudY)
    if let hud, let dimmed {
        expect(dimmed.r + dimmed.g + dimmed.b < (hud.r + hud.g + hud.b) * 0.6, "the scrim dims the HUD under it")
    } else {
        expect(false, "the HUD pixels read back")
    }
    expect(matches(pngPixel(at: lostURL, x: 898, y: 2), ViewerPalette.chromeBg2), "the scrim leaves the menu bar undimmed")
    print("PASS: the scrim dims the HUD and leaves the menu bar above it, and the HUD sits below the bar")
}

/// The largest red byte, as 0...1, of any pixel in the PNG at least `margin`
/// pixels inside every edge and with `x >= minX` and `y` within `rows`. Text
/// anti-aliasing only ever blends the text colour toward the fill, so the
/// brightest pixel of a run of text is bounded by the colour it was drawn in.
private func brightestRed(at url: URL, margin: Int = 4, minX: Int = 0, rows: ClosedRange<Int>? = nil) -> Double {
    guard let surface = cairo_image_surface_create_from_png(url.path),
          cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else {
        return 0
    }
    defer { cairo_surface_destroy(surface) }
    cairo_surface_flush(surface)
    guard let data = cairo_image_surface_get_data(surface) else { return 0 }
    let stride = Int(cairo_image_surface_get_stride(surface))
    let width = Int(cairo_image_surface_get_width(surface))
    let height = Int(cairo_image_surface_get_height(surface))
    var brightest = 0.0
    for y in margin..<max(margin, height - margin) where rows?.contains(y) ?? true {
        for x in max(margin, minX)..<max(margin, width - margin) {
            brightest = max(brightest, Double(data[y * stride + x * 4 + 2]) / 255)
        }
    }
    return brightest
}

/// Text the person has to read is `muted`, never `muted2`: that token is under
/// 4.5:1 on these panels' fills. Each case draws one kind of text alone on its
/// panel, so the brightest pixel is that text's own colour.
@MainActor
func testSessionChromeSecondaryTextIsReadableTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-chrome-muted-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func render(_ overlay: SessionChromeRenderPreview.Overlay, name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        expect(SessionChromeRenderPreview.renderOverlay(overlay, scale: 2, to: url), "\(name) renders")
        return url
    }

    // Empty labels and values draw nothing, leaving the title or note alone.
    let bareSection = SessionHUDSection(title: "", rows: [])
    let hudCases: [(String, [SessionHUDBlock])] = [
        ("a block title", [.columns(title: "Latency", bareSection, bareSection)]),
        ("a section title", [.section(SessionHUDSection(title: "Session", rows: []))]),
        ("a section note", [.section(SessionHUDSection(title: "", note: "Held while the link is down.", rows: []))]),
        ("a row note", [.section(SessionHUDSection(
            title: "", rows: [SessionHUDRow(label: "", value: "", note: "Connected to the host.")]
        ))])
    ]
    let readable = ViewerPalette.muted.red
    for (index, (name, blocks)) in hudCases.enumerated() {
        let url = render(.diagnostics(blocks: blocks, isFlagged: false), name: "hud-\(index).png")
        let brightest = brightestRed(at: url)
        expect(brightest > readable - 0.05, "\(name) is drawn in muted, got a brightest red of \(brightest)")
    }

    // The eyebrow is the only text in the panel's first row, right of the tone dot.
    let machine = ViewerSessionStateMachine(hostName: "Studio")
    let status = render(.statusPanel(machine.status), name: "status.png")
    let inset = Int(ViewerStatusPanelMetrics.panelInset) * 2
    let dotEnd = inset + Int(ViewerStatusPanelMetrics.dotSize + 4) * 2
    let eyebrowRows = inset...(inset + 16 * 2)
    let eyebrow = brightestRed(at: status, margin: 0, minX: dotEnd, rows: eyebrowRows)
    expect(eyebrow > readable - 0.05, "the status eyebrow is drawn in muted, got a brightest red of \(eyebrow)")

    print("PASS: eyebrows, section titles and notes are drawn in muted, not the under-contrast muted2")
}

/// A notice is as wide as macOS draws it whatever it says, so the dismiss
/// control sits in the same place the next time one shows, and as tall as its
/// text and the inset above and below it.
@MainActor
func testNoticeIsAsWideAsMacOSWhateverItSaysTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-notice-size-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let space = ViewerChromeMetrics.Space.self
    let width = Int(space.sm + ViewerChromeMetrics.Notice.maxTextWidth + space.xs + ViewerChromeMetrics.Notice.dismissHitSize + space.sm)
    let oneLine = Int(ViewerChromeMetrics.TextLine.height(size: 12, mono: false) + Double(space.sm) * 2)
    let lines = [
        "Short.",
        "A request the host could not carry out, with enough said about why that it runs onto a second line of the banner."
    ]
    for (index, line) in lines.enumerated() {
        let url = directory.appendingPathComponent("notice-\(index).png")
        expect(SessionChromeRenderPreview.renderOverlay(.notice(line), scale: 1, to: url), "the notice renders")
        guard let size = pngSize(at: url) else {
            expect(false, "the notice PNG could not be read back")
            return
        }
        expect(size.width == width, "a notice is \(width) wide however little it says, got \(size.width) for \"\(line.prefix(12))\"")
        if index == 0 {
            expect(size.height == oneLine, "a one-line notice is its line and the inset above and below, \(oneLine) tall, got \(size.height)")
        } else {
            expect(size.height > oneLine, "a notice that wraps grows taller, got \(size.height)")
        }
    }
    print("PASS: a notice is one width whatever it says, and as tall as its text")
}

/// The strip's pills are the lighter bg4 surface macOS fills them with, and
/// its confirm row reads question, Cancel, then the action that goes ahead:
/// that one filled with the accent, as the default button is on every other
/// step, and each button only as wide as its title and padding need.
@MainActor
func testShortcutStripConfirmRowMatchesMacOSTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-strip-confirm-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hostName = "Studio"
    let width = 1100.0
    let url = directory.appendingPathComponent("confirming.png")
    let confirming = ShortcutStripVisibility.confirming(.lockScreen)
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: confirming, hostName: hostName, isPinned: false), scale: 1, width: width, to: url
        ),
        "the confirm row renders"
    )
    let rects = SessionChromeRenderPreview.stripButtonRects(hostName: hostName, width: width, visibility: confirming)
    guard let cancel = rects.first(where: { $0.title == "Cancel" }),
          let lock = rects.first(where: { $0.title == "Lock" }),
          let pin = rects.first(where: { $0.title == "Pin" }) else {
        expect(false, "the confirm row has Cancel, Lock and the pin")
        return
    }
    expect(cancel.x + cancel.width <= lock.x, "Cancel is left of the action that goes ahead, as on macOS")
    expect(lock.width < 56, "a button is as wide as its title and padding need, with no minimum, got \(lock.width)")
    expect(cancel.width > lock.width, "Cancel, the longer title, is the wider button")

    func pixel(_ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double)? {
        pngPixel(at: url, x: Int(x), y: Int(y))
    }
    expect(
        matches(pixel(lock.x + 3, lock.y + lock.height / 2), ViewerPalette.accent),
        "the action that goes ahead is filled with the accent"
    )
    expect(
        matches(pixel(cancel.x + 3, cancel.y + cancel.height / 2), ViewerPalette.bg4),
        "Cancel is the quieter bg4 button"
    )
    // The pin's pill: inside its left padding, clear of the glyph.
    let pill = pixel(pin.x - 2, pin.y + pin.height / 2)
    expect(matches(pill, ViewerPalette.bg4), "a pill is filled with bg4, as on macOS")
    expect((pill?.a ?? 0) > 0.99, "and opaquely, so it reads lighter than the bar behind it")
    print("PASS: the strip's pills are bg4 and its confirm row is question, Cancel, then an accent default")
}

/// The scroll thumb sits where `SessionHUDView` draws it, and what the panel
/// holds ends at least 8 points short of it, so the two never read as one
/// mark. Content gets the same right margin the macOS panel gives it.
@MainActor
func testSessionHUDScrollThumbClearsContentTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-thumb-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let metrics = ViewerChromeMetrics.Diagnostics.self
    let thumbMinX = Int(metrics.width - metrics.scrollThumbTrailingInset - metrics.scrollThumbWidth)

    let sections: [SessionHUDBlock] = (0..<12).map { index in
        .section(SessionHUDSection(title: "SECTION \(index)", rows: [SessionHUDRow(label: "VALUE", value: "\(index)")]))
    }
    let scrolled = directory.appendingPathComponent("scrolled.png")
    let height = 160.0
    let measured = SessionChromeRenderPreview.diagnosticsSize(blocks: sections)
    expect(
        SessionChromeRenderPreview.renderDiagnosticsViewport(
            blocks: sections, width: Double(metrics.width), height: height, offset: 0, to: scrolled
        ),
        "a scrolling panel renders"
    )
    let viewport = DiagnosticsViewport(contentHeight: measured.height, viewportHeight: height, offset: 0)
    guard let thumb = viewport.thumb else {
        expect(false, "a panel taller than its viewport shows a thumb")
        return
    }
    let centreY = Int(thumb.y + thumb.height / 2)
    expect(
        matches(pngPixel(at: scrolled, x: thumbMinX + 1, y: centreY), ViewerPalette.muted),
        "the thumb is drawn from x=\(thumbMinX), as SessionHUDView.scrollThumbMinX has it"
    )
    expect(
        !matches(pngPixel(at: scrolled, x: thumbMinX - 2, y: centreY), ViewerPalette.muted)
            && !matches(pngPixel(at: scrolled, x: thumbMinX + Int(metrics.scrollThumbWidth) + 1, y: centreY), ViewerPalette.muted),
        "and is only \(Int(metrics.scrollThumbWidth)) wide"
    )

    // A panel that fits has no thumb; the nearest ink to where it goes is the
    // sparkline's stroke, which runs a point past the frame that holds it.
    let trend: [Double] = [38, 40, 41.5, 39, 42, 41.5]
    let tall = directory.appendingPathComponent("tall.png")
    expect(
        SessionChromeRenderPreview.renderOverlay(
            .diagnostics(
                blocks: [.section(SessionHUDSection(title: "STREAM", rows: [
                    SessionHUDRow(label: "VIDEO IN", value: "41.5 Mbit/s", trend: trend)
                ]))],
                isFlagged: false
            ),
            scale: 1, to: tall
        ),
        "a panel with a sparkline renders"
    )
    guard let size = pngSize(at: tall) else {
        expect(false, "the panel PNG could not be read back")
        return
    }
    var nearestInk = 0
    for y in 6..<(size.height - 6) {
        for x in stride(from: thumbMinX - 1, to: 200, by: -1) {
            guard let pixel = pngPixel(at: tall, x: x, y: y) else { continue }
            let fill = ViewerPalette.chromeBg2
            if abs(pixel.r - fill.red) > 0.02 || abs(pixel.g - fill.green) > 0.02 || abs(pixel.b - fill.blue) > 0.02 {
                nearestInk = max(nearestInk, x)
                break
            }
        }
    }
    let clearance = thumbMinX - nearestInk - 1
    expect(nearestInk > 230 && clearance >= 8, "ink ends \(clearance) pt short of the thumb (at x=\(nearestInk)), under the 8 that keeps them apart")
    print("PASS: the HUD's scroll thumb sits where macOS draws it, with 8 points of clear space before the content")
}

/// An address too wide for its row gives up characters from the middle of its
/// host and keeps ":port" whole, as the macOS panel shows it, instead of
/// letting the row's own truncation take the port off the end.
@MainActor
func testSessionHUDAddressKeepsItsPortTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-address-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let long = "render-node-west-wing-07.tail1234.ts.net:7777"
    let row = SessionHUDRow(label: "ADDRESS", value: long, truncation: .middleKeepingPort)
    let shown = SessionChromeRenderPreview.diagnosticsDisplayedValue(row)
    expect(shown != long, "an address wider than its row is shortened, got \(shown)")
    expect(shown.hasSuffix(":7777"), "the port stays whole, got \(shown)")
    expect(
        shown.contains(SessionHUDAddressFit.ellipsis) && shown.hasPrefix("render") && shown.contains("ts.net"),
        "the host loses its middle and both ends stay legible, got \(shown)"
    )
    expect(
        SessionChromeRenderPreview.diagnosticsDisplayedValue(
            SessionHUDRow(label: "ADDRESS", value: shown, truncation: .middleKeepingPort)
        ) == shown,
        "what is drawn fits the row, so a second pass has nothing left to cut"
    )
    let short = "mini.tail1234.ts.net:7777"
    expect(
        SessionChromeRenderPreview.diagnosticsDisplayedValue(
            SessionHUDRow(label: "ADDRESS", value: short, truncation: .middleKeepingPort)
        ) == short,
        "an address that fits is drawn whole"
    )
    expect(
        SessionChromeRenderPreview.diagnosticsDisplayedValue(SessionHUDRow(label: "ADDRESS", value: long)) == long,
        "a row that asks for ordinary truncation keeps its value as it is"
    )

    func render(_ name: String, _ row: SessionHUDRow) -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        expect(
            SessionChromeRenderPreview.renderOverlay(
                .diagnostics(blocks: [.section(SessionHUDSection(title: "SESSION", rows: [row]))], isFlagged: false),
                scale: 1, to: url
            ),
            "the \(name) panel renders"
        )
        return url
    }
    let drawn = render("drawn", row)
    let reference = render("reference", SessionHUDRow(label: "ADDRESS", value: shown))
    let cutAtTheEnd = render("cut-at-the-end", SessionHUDRow(label: "ADDRESS", value: long))
    func differences(_ a: URL, _ b: URL) -> Int {
        guard let size = pngSize(at: a), pngSize(at: b)?.height == size.height else { return Int.max }
        var count = 0
        for y in 10..<(size.height - 10) {
            for x in 112..<304 {
                guard let left = pngPixel(at: a, x: x, y: y), let right = pngPixel(at: b, x: x, y: y) else { return Int.max }
                if abs(left.r - right.r) > 0.02 || abs(left.g - right.g) > 0.02 || abs(left.b - right.b) > 0.02 { count += 1 }
            }
        }
        return count
    }
    expect(differences(drawn, reference) == 0, "the panel draws the shortened text, not the long one")
    expect(
        differences(drawn, cutAtTheEnd) > 0,
        "the port is what the shortened text keeps and a cut at the end loses, so the two draw differently"
    )
    print("PASS: a HUD address too long for its row is shortened in the middle and keeps its port whole")
}

/// A scrolled panel clips its readings at the same padding it keeps above its
/// first row, so no row ever touches the border however far it is scrolled.
@MainActor
func testSessionHUDScrollClipsAtThePanelPaddingPixelTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sensorium-hud-clip-tests-\(UUID().uuidString)", isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let metrics = ViewerChromeMetrics.Diagnostics.self
    let padding = Int(ViewerChromeMetrics.Space.sm)
    let blocks: [SessionHUDBlock] = (0..<12).map { index in
        .section(SessionHUDSection(title: "SECTION \(index)", rows: [SessionHUDRow(label: "VALUE", value: "\(index)")]))
    }
    let height = 160
    let measured = SessionChromeRenderPreview.diagnosticsSize(blocks: blocks)
    let furthest = Int(measured.height) - height
    expect(furthest > 70, "the fixture is taller than its viewport, by \(furthest)")

    // In points, past the border and the rounded corners, and clear of the
    // scroll thumb.
    let columns = 10...Int(metrics.width - metrics.scrollThumbTrailingInset - metrics.scrollThumbWidth - 6)
    var checked = 0
    for offset in stride(from: 0, through: furthest + 7, by: 7) {
        let url = directory.appendingPathComponent("scrolled-\(offset).png")
        expect(
            SessionChromeRenderPreview.renderDiagnosticsViewport(
                blocks: blocks, width: Double(metrics.width), height: Double(height), offset: Double(offset), to: url
            ),
            "the panel renders scrolled \(offset) points"
        )
        for band in [2...(padding - 1), (height - padding)...(height - 2)] {
            var stray = 0
            for y in band {
                for x in columns where !matches(pngPixel(at: url, x: x, y: y), ViewerPalette.chromeBg2) {
                    stray += 1
                }
            }
            expect(
                stray == 0,
                "scrolled \(offset) points down, \(stray) pixels of a row sit in the \(padding)-point padding "
                    + "(rows \(band.lowerBound)...\(band.upperBound))"
            )
        }
        if offset >= furthest {
            var ink = 0
            for y in (height - padding - 16)..<(height - padding) {
                for x in columns where !matches(pngPixel(at: url, x: x, y: y), ViewerPalette.chromeBg2) { ink += 1 }
            }
            expect(ink > 0, "scrolled to the end, the last reading is still in view above the bottom padding")
        }
        checked += 1
    }
    expect(checked >= 8, "the panel was checked at several scroll positions, got \(checked)")

    // A press in the padding hits nothing, as no reading is drawn there.
    func contains(_ y: Int) -> Bool {
        SessionChromeRenderPreview.diagnosticsReadingsContain(y: Double(y), panelHeight: Double(height))
    }
    expect(
        !contains(padding - 1) && contains(padding) && contains(height - padding - 1) && !contains(height - padding),
        "the readings are pressable from the top padding to the bottom padding, and not in either"
    )
    print("PASS: a scrolled HUD never draws a row into the padding between its readings and its border")
}

/// Pango, which sets every Linux overlay's text, treats the no-break space and
/// the non-breaking hyphen `ViewerCopyWrapping` writes as the no-break
/// characters they are: a line that has to wrap lets go of a plain space or
/// hyphen, and has nowhere to break at these, so it fills to the edge instead.
@MainActor
func testPangoHoldsNoBreakCharactersTests() {
    let size = 12.0
    func widest(_ text: String, within maxWidth: Double) -> Double {
        SessionChromeRenderPreview.measureChromeTextLineWidth(text, pointSize: size, maxWidth: maxWidth)
    }
    func whole(_ text: String) -> Double {
        SessionChromeRenderPreview.measureChromeText(text, pointSize: size, mono: false, scale: 1)
    }

    let spaced = "Kestrelstation Fieldnotebook"
    let held = spaced.replacingOccurrences(of: " ", with: "\u{00A0}")
    let spaceLimit = whole(spaced) * 0.75
    let longerWord = max(whole("Kestrelstation"), whole("Fieldnotebook"))
    expect(
        widest(spaced, within: spaceLimit) < longerWord + 1,
        "a plain space is where a wrapped line lets go"
    )
    expect(
        widest(held, within: spaceLimit) > longerWord + 8,
        "a no-break space is not: the line is carried past it, got \(widest(held, within: spaceLimit))"
    )

    let hyphenated = "Kestrelstation-Fieldnotebook"
    let fixed = hyphenated.replacingOccurrences(of: "-", with: "\u{2011}")
    let hyphenLimit = whole(hyphenated) * 0.75
    let longerPart = max(whole("Kestrelstation-"), whole("Fieldnotebook"))
    expect(
        widest(hyphenated, within: hyphenLimit) < longerPart + 1,
        "a plain hyphen is where a wrapped line lets go"
    )
    expect(
        widest(fixed, within: hyphenLimit) > longerPart + 8,
        "a non-breaking hyphen is not: the line is carried past it, got \(widest(fixed, within: hyphenLimit))"
    )
    print("PASS: Pango carries a wrapped line past a no-break space and a non-breaking hyphen, and lets go at the plain ones")
}

#else
@MainActor
func testSessionHUDScrollThumbClearsContentTests() {}
@MainActor
func testShortcutStripGlyphsShareOneOpticalSizeTests() {}
@MainActor
func testSessionHUDAddressKeepsItsPortTests() {}
@MainActor
func testSessionHUDScrollClipsAtThePanelPaddingPixelTests() {}
@MainActor
func testPangoHoldsNoBreakCharactersTests() {}
@MainActor
func testShortcutStripConfirmRowMatchesMacOSTests() {}
@MainActor
func testNoticeIsAsWideAsMacOSWhateverItSaysTests() {}
@MainActor
func testSessionChromeSecondaryTextIsReadableTests() {}
@MainActor
func testSessionChromePainterPixelTests() {}
@MainActor
func testShortcutStripGlyphsDrawTests() {}
@MainActor
func testShortcutStripLongHostNameNeverDrawsUnderPillTests() {}
@MainActor
func testNoticeBorderAndDismissGlyphTests() {}
@MainActor
func testShortcutStripOverflowNeverOverlapsTests() {}
@MainActor
func testSessionHUDLongValueStaysOnOneLineTests() {}
@MainActor
func testSessionHUDNarrowLatencyLabelsNeverWrapTests() {}
@MainActor
func testChromeTextScaleParityTests() {}
@MainActor
func testChromeTextMonoIsMonospaceTests() {}
@MainActor
func testHUDHasNoFooterTests() {}
@MainActor
func testHUDColumnHeadersStepDownTests() {}
@MainActor
func testHUDStaleRowToneTests() {}
func testChromeTextRoleWeightTests() {}
@MainActor
func testChromeTextSitsOnMacLinesTests() {}
func testHUDSparklineDrawsTests() {}
@MainActor
func testSessionMenuBarPaintsTests() {}
@MainActor
func testSessionMenuPopupPaintsTests() {}
@MainActor
func testSessionCompositeStackingTests() {}
@MainActor
func testScrimOpaqueBeforeFirstFrameTests() {}
#endif
