import Foundation
import SensoriumClient

/// Where each of the four pieces of session chrome sits inside a window of a
/// given logical size, and what that is in real pixels once the compositor's
/// fractional scale is applied. Pure geometry: no compositor, no cairo.
func testWaylandOverlayLayoutTests() {
    let panel = WaylandOverlayLayout.statusPanel(
        windowWidth: 1280, windowHeight: 800, contentWidth: 400, contentHeight: 200
    )
    expect(panel.x == 440 && panel.y == 300, "the status panel is centred on both axes")
    expect(panel.width == 400 && panel.height == 200, "a panel that fits keeps the size it asked for")

    let wide = WaylandOverlayLayout.statusPanel(
        windowWidth: 320, windowHeight: 200, contentWidth: 400, contentHeight: 240
    )
    expect(
        wide.x == WaylandOverlayLayout.edgeMargin && wide.width == 320 - WaylandOverlayLayout.edgeMargin * 2,
        "a panel wider than the window is held to the window's margins rather than hanging off it"
    )
    expect(
        wide.y == WaylandOverlayLayout.edgeMargin && wide.height == 200 - WaylandOverlayLayout.edgeMargin * 2,
        "a panel taller than the window is held the same way"
    )

    let notice = WaylandOverlayLayout.transientNotice(
        windowWidth: 1280, contentWidth: 400, contentHeight: 60
    )
    expect(notice.x == 440, "the transient notice is centred across the window")
    expect(notice.y == WaylandOverlayLayout.edgeMargin, "the transient notice sits one margin below the top edge")

    let hud = WaylandOverlayLayout.diagnosticsHUD(
        windowWidth: 1280, contentWidth: 320, contentHeight: 500
    )
    expect(
        hud.x == 1280 - 320 - WaylandOverlayLayout.edgeMargin,
        "the diagnostics panel hangs off the right edge, one margin in"
    )
    expect(hud.y == WaylandOverlayLayout.edgeMargin, "the diagnostics panel starts one margin below the top edge")

    let strip = WaylandOverlayLayout.shortcutStrip(
        windowWidth: 1280, contentWidth: 600, contentHeight: 44
    )
    expect(strip.x == 340, "the shortcut strip is centred across the window")
    expect(strip.y == 0, "the shortcut strip hangs from the top edge of the session window")

    let handle = WaylandOverlayLayout.stripHandle(
        windowWidth: 1280, contentWidth: 60, contentHeight: 8
    )
    expect(handle.x == 610, "the handle tab is centred across the window")
    expect(handle.y == 0, "the handle tab is flush with the top edge, under the strip it opens")

    expect(WaylandOverlayLayout.pixelSize(logical: 400, scale: 1) == 400, "at scale 1 a logical size is its pixel size")
    expect(WaylandOverlayLayout.pixelSize(logical: 400, scale: 1.5) == 600, "a fractional scale multiplies the pixels")
    expect(
        WaylandOverlayLayout.pixelSize(logical: 401, scale: 1.5) == 602,
        "a fraction of a pixel is rounded up, so no drawn edge falls outside the buffer"
    )
    expect(WaylandOverlayLayout.pixelSize(logical: 0, scale: 2) == 1, "a buffer is never zero pixels wide")

    print("PASS: the four session overlays sit where the window's logical size puts them, in whole pixels at any scale")
}

/// What a pinned strip takes from the picture. Pinning gives the strip its
/// own band across the top; the picture and the diagnostics panel move down
/// below it, so neither is covered. An unpinned strip opened by a hover or
/// the chord floats over the picture and takes nothing.
func testShortcutStripBandTests() {
    let stripHeight = 44.0

    expect(
        WaylandOverlayLayout.topInset(isPinned: false, isStripOpen: true, stripHeight: stripHeight) == 0,
        "an unpinned strip, open or not, claims no band"
    )
    expect(
        WaylandOverlayLayout.topInset(isPinned: true, isStripOpen: false, stripHeight: stripHeight) == 0,
        "and neither does a pinned strip that is closed"
    )
    let inset = WaylandOverlayLayout.topInset(isPinned: true, isStripOpen: true, stripHeight: stripHeight)
    expect(inset == stripHeight, "a pinned, open strip claims exactly its own height")

    let floatingNotice = WaylandOverlayLayout.transientNotice(
        windowWidth: 1280, contentWidth: 400, contentHeight: 60, topInset: 0
    )
    let pushedNotice = WaylandOverlayLayout.transientNotice(
        windowWidth: 1280, contentWidth: 400, contentHeight: 60, topInset: inset
    )
    expect(
        pushedNotice.y == floatingNotice.y + inset,
        "a transient notice moves down by the band too, rather than reading over the strip"
    )
    expect(pushedNotice.x == floatingNotice.x, "and stays centred across the window")

    let floating = WaylandOverlayLayout.diagnosticsHUD(
        windowWidth: 1280, contentWidth: 320, contentHeight: 500, topInset: 0
    )
    let pushed = WaylandOverlayLayout.diagnosticsHUD(
        windowWidth: 1280, contentWidth: 320, contentHeight: 500, topInset: inset
    )
    expect(
        pushed.y == floating.y + inset,
        "the diagnostics panel moves down by the band, so the strip never covers it"
    )
    expect(pushed.x == floating.x, "and stays on the right edge where it was")

    // Pixel units: what the EGL presenter draws into, with the band taken off
    // the top of the drawable rather than off the window's logical size.
    let full = CanvasPresentationLayout.videoRect(
        sourceWidth: 1920, sourceHeight: 1200,
        viewportWidth: 1280, viewportHeight: 800,
        topInset: 0
    )
    let banded = CanvasPresentationLayout.videoRect(
        sourceWidth: 1920, sourceHeight: 1200,
        viewportWidth: 1280, viewportHeight: 800,
        topInset: 88
    )
    expect(banded.y >= 88, "the picture starts below the band, never under it")
    expect(banded.height < full.height, "and is drawn smaller for it, rather than being cropped")
    expect(
        abs(banded.width / banded.height - full.width / full.height) < 0.0001,
        "the picture keeps its aspect ratio inside the band it was left"
    )
    expect(
        CanvasPresentationLayout.videoRect(
            sourceWidth: 1920, sourceHeight: 1200,
            viewportWidth: 1280, viewportHeight: 800
        ) == full,
        "a caller that names no band gets the whole drawable, as before"
    )

    print("PASS: a pinned strip pushes the picture and the diagnostics panel down, an unpinned one pushes nothing")
}

/// The status panel's own width, measured the way the macOS panel measures
/// it, with the text measurement handed in rather than taken from a font
/// engine that only exists on one of the two platforms.
func testViewerStatusPanelMetricsTests() {
    // Every title the same width, so the arithmetic below is the rule and not
    // the font.
    let measure: (String) -> Double = { _ in 100 }

    expect(
        ViewerStatusPanelMetrics.width(forButtonTitles: [], measure: measure)
            == ViewerStatusPanelMetrics.defaultWidth,
        "a status with no buttons is the default width"
    )
    expect(
        ViewerStatusPanelMetrics.buttonWidth("anything", measure: measure)
            == 100 + ViewerStatusPanelMetrics.buttonHorizontalInset * 2,
        "a button is its measured title plus equal insets on both sides"
    )
    expect(
        ViewerStatusPanelMetrics.buttonWidth("anything", measure: { _ in 4 })
            == ViewerStatusPanelMetrics.buttonMinimumWidth,
        "a button never measures below its own minimum width"
    )
    expect(
        ViewerStatusPanelMetrics.width(forButtonTitles: ["one"], measure: measure)
            == ViewerStatusPanelMetrics.defaultWidth,
        "a row narrower than the default width does not shrink the panel"
    )
    let three = ViewerStatusPanelMetrics.width(forButtonTitles: ["one", "two", "three"], measure: measure)
    let expected = 3 * (100 + ViewerStatusPanelMetrics.buttonHorizontalInset * 2)
        + 2 * ViewerStatusPanelMetrics.buttonSpacing
        + ViewerStatusPanelMetrics.panelInset * 2
    expect(three == expected, "a row wider than the default is the row plus the panel's own insets")

    let session = ViewerStatusPanelMetrics.sessionPanelWidth(measure: measure)
    let widest = ViewerSessionStateMachine.buttonRows
        .map { ViewerStatusPanelMetrics.width(forButtonTitles: $0, measure: measure) }
        .max() ?? 0
    expect(session == widest, "one width for the whole session: the widest row any state can carry")

    print("PASS: the status panel measures its width from the widest button row, with the text measurement handed in")
}

/// Which button a click on the status panel landed on. The row is laid out
/// right to left, the way the primary action sits rightmost on both
/// platforms, and a point between two buttons belongs to neither.
func testViewerStatusPanelHitTestTests() {
    let measure: (String) -> Double = { _ in 100 }
    let panel = ViewerChromeRect(x: 200, y: 100, width: 500, height: 220)
    // A refused host-screen connect is the state whose row is exactly two
    // buttons, taken from the state machine rather than made up here.
    var machine = ViewerSessionStateMachine(hostName: "studio")
    let buttons = machine.handle(.hostScreenConnectEnded(reasonLine: "No.")).buttons
    let layouts = ViewerStatusPanelHitTest.buttonRow(buttons: buttons, panel: panel, measure: measure)
    expect(layouts.count == 2, "one rect per button")
    expect(
        layouts.map(\.action) == [.yourMachines, .connectAsVirtualDisplay],
        "the rects come back in the order the status named them"
    )

    let buttonWidth = ViewerStatusPanelMetrics.buttonWidth(buttons[1].title, measure: measure)
    let rightEdge = panel.x + panel.width - ViewerStatusPanelMetrics.panelInset
    expect(
        layouts[1].rect.x + layouts[1].rect.width == rightEdge,
        "the last button's right edge is the panel's own inset edge"
    )
    expect(
        layouts[0].rect.x + layouts[0].rect.width
            == rightEdge - buttonWidth - ViewerStatusPanelMetrics.buttonSpacing,
        "the button before it is one spacing further left"
    )
    expect(
        layouts[0].rect.y + layouts[0].rect.height
            == panel.y + panel.height - ViewerStatusPanelMetrics.panelInset,
        "the row sits one inset above the panel's bottom edge"
    )

    func hit(_ x: Double, _ y: Double) -> ViewerSessionAction? {
        ViewerStatusPanelHitTest.action(atX: x, y: y, in: layouts)
    }
    let middle = layouts[0].rect.y + layouts[0].rect.height / 2
    expect(hit(layouts[0].rect.x + 5, middle) == .yourMachines, "a point inside the first button is that button's action")
    expect(hit(layouts[1].rect.x + 5, middle) == .connectAsVirtualDisplay, "a point inside the second button is that button's action")
    expect(
        hit(layouts[0].rect.x + layouts[0].rect.width + 2, middle) == nil,
        "a point in the gap between two buttons is no action at all"
    )
    expect(hit(panel.x + 2, panel.y + 2) == nil, "a point on the panel but off every button is no action at all")

    print("PASS: a click on the status panel maps to the button it landed on, and to nothing in the gaps")
}
