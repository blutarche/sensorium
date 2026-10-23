import Foundation
import SensoriumClient

func testDiagnosticsViewportTests() {
    let rect = WaylandOverlayLayout.diagnosticsHUD(
        windowWidth: 800, windowHeight: 480, contentWidth: 320, contentHeight: 1000, topInset: 70
    )
    expect(rect.y == 78 && rect.height == 394 && rect.y + rect.height == 472,
           "diagnostics stays below the pinned strip and above the short window's bottom edge")
    let empty = WaylandOverlayLayout.diagnosticsHUD(
        windowWidth: 80, windowHeight: 50, contentWidth: 320, contentHeight: 1000, topInset: 70
    )
    expect(empty.height == 0, "a strip taller than its window leaves no negative viewport")

    var viewport = DiagnosticsViewport(contentHeight: 1000, viewportHeight: rect.height)
    expect(viewport.offset == 0 && viewport.thumb?.y == 0, "diagnostics starts at its first section")
    expect(!viewport.consumeScroll(deltaY: -120, isOverDiagnostics: false) && viewport.offset == 0,
           "scroll outside diagnostics is left for its original destination")
    expect(viewport.consumeScroll(deltaY: -120, isOverDiagnostics: true),
           "scroll over diagnostics is consumed locally rather than sent to the host")
    expect(viewport.offset == 120, "a downward wheel or trackpad motion scrolls local diagnostics down")
    expect(viewport.contentY(atViewportY: 20) == 140,
           "a visible link at y=20 is hit in the same content coordinates the scrolled drawing uses")
    expect(viewport.contentY(atViewportY: -1) == nil && viewport.contentY(atViewportY: rect.height) == nil,
           "clipped links above or below the viewport are not clickable")
    expect(viewport.consumeScroll(deltaY: -10000, isOverDiagnostics: true),
           "diagnostics keeps consuming scroll even at the content boundary")
    expect(viewport.offset == 606, "scrolling down reaches the final section without overshooting")
    expect(viewport.contentY(atViewportY: 393) == 999, "the last content pixel is reachable")
    if let thumb = viewport.thumb {
        expect(abs(thumb.y + thumb.height - rect.height) < 0.001, "the scroll thumb reaches the bottom with the content")
    } else {
        expect(false, "an overflowing panel shows a scroll thumb")
    }
    let taller = DiagnosticsViewport(contentHeight: 1000, viewportHeight: 900, offset: viewport.offset)
    expect(taller.offset == 100, "resizing taller clamps the old scroll position to the new bottom")
    let fits = DiagnosticsViewport(contentHeight: 1000, viewportHeight: 1200, offset: viewport.offset)
    expect(fits.offset == 0 && fits.thumb == nil, "a panel that fits resets scroll and hides its thumb")
    viewport.scroll(deltaY: 10000)
    expect(viewport.offset == 0, "scrolling up reaches the first section without overshooting")
    print("PASS: bounded diagnostics scrolls to both ends, clamps after resize and maps visible links")
}
