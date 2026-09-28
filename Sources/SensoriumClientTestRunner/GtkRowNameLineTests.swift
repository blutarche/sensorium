#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient
import SensoriumCore

/// A saved machine's name sits on the line AppKit sets it on, 14pt below the
/// top of its 17pt line, whether it fits its row or is cut short with an
/// ellipsis.
@MainActor
func testGtkRowNameSitsOnMacLineTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: a row name's line needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    func host(_ name: String, key: UInt8) -> SavedHost {
        SavedHost(
            displayName: name,
            host: "mini.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([key]),
            tlsCertificateHash: Data([key, key]),
            lastConnectedAt: Date(timeIntervalSince1970: Double(1_000 * Int(key)))
        )
    }
    // No descenders, so each name's ink ends on its baseline.
    let short = "Workstation"
    let long = Array(repeating: "Workstation", count: 6).joined(separator: "-")
    let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: [host(short, key: 2), host(long, key: 1)]))
    defer { window.hide() }
    window.show()
    rowNamePump(seconds: 0.4)

    guard let root = sensorium_gtk_widget(window.toplevel),
          let pixels = rowNameRender(root, scale: 2) else {
        expect(false, "Your Machines renders")
        return
    }
    let scale = 2.0
    let expected = (Double(ViewerChromeMetrics.Space.sm) + ViewerChromeMetrics.TextLine.baseline(size: 14, mono: false)) * scale
    let rows = rowButtons(under: UnsafeMutableRawPointer(root))
    expect(rows.count == 2, "both saved machines draw a row, got \(rows.count)")
    for row in rows {
        var bounds = graphene_rect_t()
        _ = gtk_widget_compute_bounds(sensorium_gtk_widget(row), root, &bounds)
        let top = Int((Double(bounds.origin.y) * scale).rounded())
        let left = Int(((Double(bounds.origin.x) + 16) * scale).rounded())
        // The name's own line: below the row's top inset, above the detail.
        var inkBottom = -1
        for y in (top + Int(4 * scale))..<(top + Int(30 * scale)) {
            let bright = (left..<(left + Int(200 * scale))).contains { pixels.green(x: $0, y: y) > 200 }
            if bright { inkBottom = y + 1 - top }
        }
        expect(
            abs(Double(inkBottom) - expected) <= 1,
            "a row name sits \(expected / scale)pt below its row's top, got \(Double(inkBottom) / scale)"
        )
    }
    print("PASS: a row name sits on the macOS line, cut short or not")
}

private struct RowNamePixels {
    let bytes: [UInt8]
    let stride: Int
    /// GDK's default download layout is B, G, R, A.
    func green(x: Int, y: Int) -> UInt8 { bytes[y * stride + x * 4 + 1] }
}

/// `root` drawn at `scale` with GSK's cairo renderer, which needs no GPU
/// context of the window's own.
@MainActor
private func rowNameRender(_ root: UnsafeMutablePointer<GtkWidget>, scale: Double) -> RowNamePixels? {
    let width = Double(gtk_widget_get_width(root)), height = Double(gtk_widget_get_height(root))
    let paintable = gtk_widget_paintable_new(root)
    let snapshot = gtk_snapshot_new()
    gdk_paintable_snapshot(paintable, snapshot, width * scale, height * scale)
    g_object_unref(UnsafeMutableRawPointer(paintable))
    guard let node = gtk_snapshot_free_to_node(snapshot) else { return nil }
    defer { gsk_render_node_unref(node) }
    let renderer = gsk_cairo_renderer_new()
    defer { g_object_unref(UnsafeMutableRawPointer(renderer)) }
    guard gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), nil) != 0 else { return nil }
    defer { gsk_renderer_unrealize(renderer) }
    var viewport = graphene_rect_t()
    graphene_rect_init(&viewport, 0, 0, Float(width * scale), Float(height * scale))
    guard let texture = gsk_renderer_render_texture(renderer, node, &viewport) else { return nil }
    defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
    let stride = Int(gdk_texture_get_width(texture)) * 4
    var bytes = [UInt8](repeating: 0, count: stride * Int(gdk_texture_get_height(texture)))
    gdk_texture_download(texture, &bytes, gsize(stride))
    return RowNamePixels(bytes: bytes, stride: stride)
}

@MainActor
private func rowButtons(under widget: UnsafeMutableRawPointer) -> [UnsafeMutableRawPointer] {
    var found: [UnsafeMutableRawPointer] = []
    var child = gtk_widget_get_first_child(sensorium_gtk_widget(widget))
    while let current = child {
        let pointer = UnsafeMutableRawPointer(current)
        if gtk_widget_has_css_class(current, GtkViewerStyle.Class.row) != 0 {
            found.append(pointer)
        } else {
            found += rowButtons(under: pointer)
        }
        child = gtk_widget_get_next_sibling(current)
    }
    return found
}

private func rowNamePump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(5_000)
    }
}
#else
@MainActor
func testGtkRowNameSitsOnMacLineTests() {}
#endif
