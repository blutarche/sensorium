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

/// Every line of text Your Machines draws, on every step, sits on the line
/// AppKit sets it on: the line's baseline `TextLine.baseline` below the top of
/// the space the text is given, and each further line of wrapped text one
/// `TextLine.height` lower, whatever the Linux face's own ascent and descent.
@MainActor
func testGtkYourMachinesTextSitsOnMacLinesTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' text lines need a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check them")
        return
    }
    let short = SavedHost(
        displayName: "Workstation", host: "mini.tail1234.ts.net", port: 7777,
        hostPublicKey: Data([1]), tlsCertificateHash: Data([1, 1]), lastConnectedAt: Date(timeIntervalSince1970: 9_000)
    )
    // An address long enough that the row's detail wraps onto a second line.
    let long = SavedHost(
        displayName: "Alexandria-Whitfield-Sinclairs-Laptop-16-inch-M4-Max",
        host: "alexandria-whitfield-sinclairs-laptop.tail1234.ts.net", port: 7777,
        hostPublicKey: Data([4]), tlsCertificateHash: Data([4, 4]), lastConnectedAt: Date(timeIntervalSince1970: 500)
    )
    let devices = [
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "1", displayName: "Workstation", magicDNSName: "mini.tail1234.ts.net",
            tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        )),
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "2", displayName: "Studio", magicDNSName: nil,
            tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        ))
    ]
    var wrapped = false
    func check(_ step: String, hosts: [SavedHost], _ drive: (GtkYourMachinesWindow) -> Void) {
        let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: hosts))
        defer { window.hide() }
        window.show()
        drive(window)
        rowNamePump(seconds: 0.4)
        guard let root = sensorium_gtk_widget(window.toplevel) else { return }
        let labels = textLabels(under: UnsafeMutableRawPointer(root))
        expect(!labels.isEmpty, "\(step) draws text")
        for (label, size, mono) in labels {
            guard let slot = gtk_widget_get_parent(sensorium_gtk_widget(label)) else { continue }
            var slotBounds = graphene_rect_t()
            var labelBounds = graphene_rect_t()
            _ = gtk_widget_compute_bounds(slot, root, &slotBounds)
            _ = gtk_widget_compute_bounds(sensorium_gtk_widget(label), root, &labelBounds)
            let layout = gtk_label_get_layout(sensorium_gtk_label(label))
            let text = String(cString: gtk_label_get_text(sensorium_gtk_label(label)))
            let lines = Int(pango_layout_get_line_count(layout))
            wrapped = wrapped || lines > 1
            let line = ViewerChromeMetrics.TextLine.self
            let iterator = pango_layout_get_iter(layout)
            defer { pango_layout_iter_free(iterator) }
            for index in 0..<lines {
                let baseline = Double(labelBounds.origin.y - slotBounds.origin.y)
                    + Double(pango_layout_iter_get_baseline(iterator)) / Double(PANGO_SCALE)
                let expected = line.baseline(size: size, mono: mono) + Double(index) * line.height(size: size, mono: mono)
                expect(
                    abs(baseline - expected) < 0.05,
                    "\(step): line \(index + 1) of \"\(text)\" has its baseline \(expected)pt below the top of its space, got \(baseline)"
                )
                _ = pango_layout_iter_next_line(iterator)
            }
            let height = Double(slotBounds.size.height)
            let expectedHeight = Double(lines) * line.height(size: size, mono: mono)
            expect(abs(height - expectedHeight) < 0.05, "\(step): \"\(text)\" is given \(expectedHeight)pt, got \(height)")
        }
    }
    check("the list", hosts: [short, long]) { _ in }
    check("an empty list", hosts: []) { _ in }
    check("the device picker", hosts: [short]) { $0.apply(deviceList: .devices(devices)) }
    check("an empty picker", hosts: [short]) { $0.apply(deviceList: .noOtherDevices) }
    check("a picker still looking", hosts: [short]) { $0.apply(deviceList: .loading) }
    check("a picker that cannot reach Tailscale", hosts: [short]) {
        $0.apply(deviceList: .unreachable(reason: TailnetDevicePickerFetchError.tailscaledUnreachable.reason))
    }
    check("the code step", hosts: [short]) { $0.showCodeStep(for: nil) }
    check("pairing again", hosts: [short]) { $0.showCodeStep(for: nil, isPairingAgain: true) }
    check("a failed pairing", hosts: [short]) { window in
        window.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
        window.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
        rowNamePump(seconds: 0.2)
        let root = UnsafeMutableRawPointer(window.toplevel)
        let styled = { (name: String) in
            firstDescendant(of: root, where: { gtk_widget_has_css_class(sensorium_gtk_widget($0), name) != 0 })
        }
        guard let code = styled(GtkViewerStyle.Class.code), let pair = styled(GtkViewerStyle.Class.primary) else {
            expect(false, "the code step has a code field and a Pair button")
            return
        }
        gtk_editable_set_text(sensorium_gtk_editable(code), "418297")
        gtk_widget_activate(sensorium_gtk_widget(pair))
        rowNamePump(seconds: 0.3)
    }
    expect(wrapped, "some text wraps onto a second line")
    print("PASS: every line of Your Machines' text sits on the macOS line")
}

/// The visible labels under `widget` set in one of the text styles, each with
/// the point size and face the stylesheet gives that style.
@MainActor
private func textLabels(under widget: UnsafeMutableRawPointer) -> [(UnsafeMutableRawPointer, Double, Bool)] {
    let styles: [(String, Double, Bool)] = [
        (GtkViewerStyle.Class.hint, 12, false),
        (GtkViewerStyle.Class.heading, 20, false),
        (GtkViewerStyle.Class.muted, 13, false),
        (GtkViewerStyle.Class.bad, 13, false),
        (GtkViewerStyle.Class.headline, 13, false),
        (GtkViewerStyle.Class.detail, 12, false),
        (GtkViewerStyle.Class.rowName, 14, false),
        (GtkViewerStyle.Class.rowDetail, 12, false),
        (GtkViewerStyle.Class.deviceSubtitle, 11, true)
    ]
    var found: [(UnsafeMutableRawPointer, Double, Bool)] = []
    var child = gtk_widget_get_first_child(sensorium_gtk_widget(widget))
    while let current = child {
        let pointer = UnsafeMutableRawPointer(current)
        if gtk_widget_get_visible(current) != 0 {
            if String(cString: gtk_widget_get_css_name(current)) == "label",
               let style = styles.first(where: { gtk_widget_has_css_class(current, $0.0) != 0 }) {
                found.append((pointer, style.1, style.2))
            }
            found += textLabels(under: pointer)
        }
        child = gtk_widget_get_next_sibling(current)
    }
    return found
}

@MainActor
private func firstDescendant(
    of widget: UnsafeMutableRawPointer,
    where matches: (UnsafeMutableRawPointer) -> Bool
) -> UnsafeMutableRawPointer? {
    var child = gtk_widget_get_first_child(sensorium_gtk_widget(widget))
    while let current = child {
        let pointer = UnsafeMutableRawPointer(current)
        if matches(pointer) { return pointer }
        if let found = firstDescendant(of: pointer, where: matches) { return found }
        child = gtk_widget_get_next_sibling(current)
    }
    return nil
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
@MainActor
func testGtkYourMachinesTextSitsOnMacLinesTests() {}
#endif
