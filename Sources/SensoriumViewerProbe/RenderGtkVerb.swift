import Foundation
import SensoriumClient
import SensoriumCore

#if canImport(CGtk4)
import CGtk4

/// `render-gtk <output-dir>`: puts every window the Linux viewer shows on
/// screen, in each state a person meets it in, and writes what each one draws
/// to a PNG. Every window is the production type, driven through the same
/// calls the viewer makes; only the saved machines, the tailnet answer and
/// the pairing reply are fixtures, and they match the ones
/// `Scripts/render-ui-previews.swift` hands the macOS windows, so each render
/// here has a macOS one to be compared with.
///
/// The windows are real, so this needs a compositor. Run it against a nested,
/// headless one -- `kwin_wayland --virtual`, say -- never the desktop someone
/// is using: every window it opens is shown on whatever display it is given.
/// The PNGs are drawn at the scale that compositor's output has, and named
/// for it.
@MainActor
enum RenderGtkVerb {
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "render-gtk" else { return }
        guard arguments.count == 2 else {
            say("usage: SensoriumViewerProbe render-gtk <output-dir>")
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            say("could not create \(directory.path): \(error)")
            exit(1)
        }
        guard GLibMainLoop.attachMainQueue() else {
            say("The event loop could not take over this process's main queue, so no window can be driven from it.")
            exit(1)
        }
        GtkToolkit.start()
        let status = ExitCode()
        Task { @MainActor in
            status.value = await renderEveryFixture(into: directory)
            GLibMainLoop.stop()
        }
        GLibMainLoop.run()
        exit(status.value)
    }

    private final class ExitCode {
        var value: Int32 = 1
    }

    // MARK: - Fixtures

    private static let miniHost = SavedHost(
        displayName: "Workstation",
        host: "mini.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([1]),
        tlsCertificateHash: Data([1, 1]),
        lastConnectedAt: Date(timeIntervalSince1970: 9_000)
    )
    private static let studioHost = SavedHost(
        displayName: "Studio",
        host: "studio.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([2]),
        tlsCertificateHash: Data([2, 2]),
        lastConnectedAt: Date(timeIntervalSince1970: 1_000)
    )
    private static let unnamedHost = SavedHost(
        displayName: "100.64.1.9",
        host: "100.64.1.9",
        port: 7777,
        hostPublicKey: Data([3]),
        tlsCertificateHash: Data([3, 3]),
        lastConnectedAt: Date(timeIntervalSince1970: 500)
    )
    private static let longNamedHost = SavedHost(
        displayName: "Alexandria-Whitfield-Sinclairs-Laptop-16-inch-M4-Max",
        host: "alexandria-whitfield-sinclairs-laptop.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([4]),
        tlsCertificateHash: Data([4, 4]),
        lastConnectedAt: Date(timeIntervalSince1970: 500)
    )
    private static let tailnetRows = [
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "1", displayName: "Workstation", magicDNSName: "mini.tail1234.ts.net",
            tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        )),
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "2", displayName: "Studio", magicDNSName: "studio.tail1234.ts.net",
            tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        )),
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "3", displayName: "iPhone", magicDNSName: nil,
            tailnetIPv4: "100.64.1.3", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        ))
    ]

    /// One window in one state: `show` builds it and puts it on screen, and
    /// hands back the toplevel to draw and how to take it away again.
    private struct Fixture {
        let name: String
        let show: @MainActor () async -> (window: UnsafeMutableRawPointer, dismiss: @MainActor () -> Void)?
    }

    /// Kept alive until every fixture has been drawn: a window's own
    /// callbacks point back into these objects.
    private static var retained: [AnyObject] = []

    private static func machines(
        _ name: String,
        hosts: [SavedHost],
        withTailnet: Bool = false,
        _ drive: @escaping @MainActor (GtkYourMachinesWindow) async -> Void = { _ in }
    ) -> Fixture {
        Fixture(name: name) {
            let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: hosts))
            retained.append(window)
            if withTailnet {
                window.loadTailnet = { .devices(tailnetRows) }
            }
            window.show()
            // The tailnet answer arrives on a task of its own, and the rows
            // redraw once it has.
            await pause(milliseconds: 200)
            await drive(window)
            return (window.toplevel, { window.hide() })
        }
    }

    private static var fixtures: [Fixture] {
        [
            machines("viewer-machines-1-empty", hosts: []),
            machines("viewer-machines-2-list", hosts: [miniHost, studioHost], withTailnet: true),
            machines("viewer-machines-3-connecting", hosts: [miniHost, studioHost], withTailnet: true) { window in
                window.connectRequested(hostPublicKey: miniHost.hostPublicKey)
                window.connectStarted(hostPublicKey: miniHost.hostPublicKey)
            },
            machines("viewer-machines-4-failed", hosts: [miniHost, studioHost], withTailnet: true) { window in
                window.connectRequested(hostPublicKey: miniHost.hostPublicKey)
                window.connectStarted(hostPublicKey: miniHost.hostPublicKey)
                window.attemptFailed(reason: "no answer", offersConnectAsVirtualDisplayFallback: false)
            },
            machines("viewer-machines-5-one-unnamed", hosts: [unnamedHost]),
            machines(
                "viewer-machines-6-several-selected",
                hosts: [miniHost, studioHost, unnamedHost],
                withTailnet: true
            ) { window in
                window.select(hostPublicKey: studioHost.hostPublicKey)
            },
            machines("viewer-machines-7-long-name", hosts: [longNamedHost]),
            machines("viewer-add-1-picker", hosts: [miniHost]) { window in
                window.apply(deviceList: .devices(tailnetRows))
            },
            machines("viewer-add-1b-picker-loading", hosts: [miniHost]) { window in
                window.apply(deviceList: .loading)
            },
            machines("viewer-add-1c-picker-tailscaled-unreachable", hosts: [miniHost]) { window in
                window.apply(deviceList: .unreachable(reason: TailnetDevicePickerFetchError.tailscaledUnreachable.reason))
            },
            machines("viewer-add-1f-picker-no-other-devices", hosts: [miniHost]) { window in
                window.apply(deviceList: .noOtherDevices)
            },
            machines("viewer-add-2-code", hosts: [miniHost]) { window in
                window.showCodeStep(for: ViewerPairingDevice(address: "mini.tail1234.ts.net", name: "Workstation"))
            },
            machines("viewer-add-3-code-manual", hosts: [miniHost]) { window in
                window.showCodeStep(for: nil)
            },
            machines("viewer-add-4-pairing-failed", hosts: [miniHost]) { window in
                window.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
                window.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
                await pause(milliseconds: 100)
                let root = window.toplevel
                guard let code = descendant(of: root, where: { hasClass($0, GtkViewerStyle.Class.code) }),
                      let pair = descendant(of: root, where: { buttonLabel($0) == "Pair" }) else {
                    say("the code step has no code field or no Pair button")
                    return
                }
                gtk_editable_set_text(sensorium_gtk_editable(code), "418297")
                gtk_widget_activate(sensorium_gtk_widget(pair))
            },
            Fixture(name: "viewer-identity-1-key-unreadable") {
                let prompts = GtkViewerPrompts()
                retained.append(prompts)
                let prompt = ViewerStartupFailurePrompt.make(
                    for: .copy(for: .unreadable(reason: "the stored key is malformed"))
                )
                Task { @MainActor in _ = await prompts.showStartupFailure(prompt) }
                guard let window = await newestVisibleToplevel() else { return nil }
                return (window, { prompts.dismissStartupFailure() })
            },
            Fixture(name: "viewer-notice-software-decode") {
                let prompts = GtkViewerPrompts()
                retained.append(prompts)
                Task { @MainActor in await prompts.showNotice(ViewerFirstRunNotices.softwareDecode) }
                guard let window = await newestVisibleToplevel() else { return nil }
                return (window, { gtk_window_close(sensorium_gtk_window(window)) })
            }
        ]
    }

    // MARK: - Drawing

    private static func renderEveryFixture(into directory: URL) async -> Int32 {
        var failures = 0
        for fixture in fixtures {
            guard let shown = await fixture.show() else {
                say("FAILED \(fixture.name): no window came up")
                failures += 1
                continue
            }
            guard await settle(shown.window) else {
                say("FAILED \(fixture.name): the window was never laid out")
                failures += 1
                shown.dismiss()
                continue
            }
            // As it opens, then after one Tab: what a Tab press does, moving
            // focus to the next control and turning on the focus GTK draws
            // only once a key has been pressed.
            if !write(shown.window, name: fixture.name, into: directory) {
                failures += 1
            }
            gtk_window_set_focus_visible(sensorium_gtk_window(shown.window), 1)
            _ = gtk_widget_child_focus(sensorium_gtk_widget(shown.window), GTK_DIR_TAB_FORWARD)
            await pause(milliseconds: 300)
            if !write(shown.window, name: fixture.name + "-tab", into: directory) {
                failures += 1
            }
            shown.dismiss()
        }
        return failures == 0 ? 0 : 1
    }

    /// Draws `window` to `<name>@<scale>x.png` and checks its corner is the
    /// window background -- a corner in any other colour is a theme surface
    /// showing through. A window with a menu bar is checked just under it.
    private static func write(_ window: UnsafeMutableRawPointer, name: String, into directory: URL) -> Bool {
        let staging = directory.appendingPathComponent("\(name).staging.png").path
        let scale = sensorium_window_content_write_png(window, staging)
        guard scale > 0 else {
            say("FAILED \(name): nothing was drawn")
            return false
        }
        let path = directory.appendingPathComponent("\(name)@\(String(format: "%g", scale))x.png").path
        try? FileManager.default.removeItem(atPath: path)
        do {
            try FileManager.default.moveItem(atPath: staging, toPath: path)
        } catch {
            say("FAILED \(name): \(error)")
            return false
        }
        let hasMenuBar = descendant(of: window, where: { String(cString: gtk_widget_get_css_name(sensorium_gtk_widget($0))) == "menubar" }) != nil
        let cornerY = hasMenuBar ? Int32((Double(ViewerChromeMetrics.MenuBar.height) + 1) * scale) : 1
        let corner = sensorium_png_pixel(path, 1, cornerY)
        let background = Int64(hexValue(ViewerPalette.chromeBg))
        if corner != background {
            say("FAILED \(name): the corner is \(String(format: "#%06X", corner)), not the window background")
            return false
        }
        say("wrote \(path), focus on \(focusDescription(window))")
        if let wrong = focusMacOSWouldNotGive(window) {
            say("FAILED \(name): focus is on \(wrong)")
            return false
        }
        if let wrong = linkIconNotEmbedded(window) {
            say("FAILED \(name): \(wrong)")
            return false
        }
        if let wrong = moreDotsOffMacOS(window, png: path, scale: scale) {
            say("FAILED \(name): \(wrong)")
            return false
        }
        return true
    }

    /// Every row's "\u{2026}" button is the 24pt square macOS gives it, 8pt in
    /// from the row's right edge and centred on the row, and its three dots
    /// come out of the PNG alike: the same ink, evenly spaced, each centred
    /// in its own box, the middle one where macOS draws it.
    private static func moreDotsOffMacOS(_ window: UnsafeMutableRawPointer, png: String, scale: Double) -> String? {
        typealias Dots = GtkViewerStyle.MoreDots
        var buttons: [UnsafeMutableRawPointer] = []
        _ = descendant(of: window) { widget in
            if String(cString: gtk_widget_get_css_name(sensorium_gtk_widget(widget))) == "menubutton",
               hasClass(widget, GtkViewerStyle.Class.iconButton) {
                buttons.append(widget)
            }
            return false
        }
        guard let content = gtk_window_get_child(sensorium_gtk_window(window)) else { return nil }
        for button in buttons {
            guard let area = descendant(of: button, where: { sensorium_is_drawing_area($0) != 0 }),
                  let row = gtk_widget_get_parent(sensorium_gtk_widget(button)) else {
                return "a row's \u{2026} is not drawn from source"
            }
            let size = Int32(Dots.buttonSize)
            guard gtk_widget_get_width(sensorium_gtk_widget(button)) == size,
                  gtk_widget_get_height(sensorium_gtk_widget(button)) == size,
                  gtk_widget_get_width(sensorium_gtk_widget(area)) == size else {
                return "a row's \u{2026} button is not \(size)pt square"
            }
            guard let inRow = point(of: button, in: UnsafeMutableRawPointer(row)) else { return "a row's \u{2026} is not on its row" }
            let rowWidth = Double(gtk_widget_get_width(row))
            let rowHeight = Double(gtk_widget_get_height(row))
            if abs(inRow.x + Dots.buttonSize + ViewerChromeMetrics.Space.xs - rowWidth) > 0.01
                || abs(inRow.y + Dots.buttonSize / 2 - rowHeight / 2) > 0.5 {
                return "a row's \u{2026} button sits at \(inRow) in a \(rowWidth) by \(rowHeight) row, not "
                    + "\(ViewerChromeMetrics.Space.xs)pt in from its right edge and centred on it"
            }
            guard let areaInWindow = point(of: area, in: window),
                  let contentInWindow = point(of: UnsafeMutableRawPointer(content), in: window) else {
                return "a row's \u{2026} is not in the window"
            }
            let origin = (
                x: (areaInWindow.x - contentInWindow.x + Double(gtk_widget_get_margin_start(content))) * scale,
                y: (areaInWindow.y - contentInWindow.y + Double(gtk_widget_get_margin_top(content))) * scale
            )
            let box = (x: Int(origin.x.rounded(.down)), y: Int(origin.y.rounded(.down)), side: Int((Dots.buttonSize * scale).rounded(.up)) + 1)
            var pixels = [UInt32](repeating: 0, count: box.side * box.side)
            guard sensorium_png_region(png, Int32(box.x), Int32(box.y), Int32(box.side), Int32(box.side), &pixels) != 0 else {
                return "a row's \u{2026} lies outside the PNG"
            }
            let background = pixels[0]
            func ink(_ x: Int, _ y: Int) -> Double {
                let pixel = pixels[y * box.side + x]
                return Double(Int(pixel >> 16 & 0xFF) - Int(background >> 16 & 0xFF))
            }
            var blobs: [[Int]] = []
            for x in 0..<box.side where (0..<box.side).contains(where: { ink(x, $0) > 8 }) {
                if let last = blobs.last?.last, last == x - 1 {
                    blobs[blobs.count - 1].append(x)
                } else {
                    blobs.append([x])
                }
            }
            guard blobs.count == 3 else { return "a row's \u{2026} draws \(blobs.count) dots, not 3" }
            var measured: [(ink: Double, x: Double, y: Double, boxX: Double, boxY: Double)] = []
            for columns in blobs {
                var total = 0.0, sumX = 0.0, sumY = 0.0
                var rows: [Int] = []
                for x in columns {
                    for y in 0..<box.side {
                        let value = max(0, ink(x, y))
                        guard value > 0 else { continue }
                        total += value
                        sumX += (Double(x) + 0.5) * value
                        sumY += (Double(y) + 0.5) * value
                        if value > 8 { rows.append(y) }
                    }
                }
                let top = Double(rows.min() ?? 0), bottom = Double((rows.max() ?? 0) + 1)
                measured.append((
                    total, sumX / total, sumY / total,
                    (Double(columns.first!) + Double(columns.last! + 1)) / 2, (top + bottom) / 2
                ))
            }
            let inks = measured.map(\.ink)
            if (inks.max()! - inks.min()!) / inks.max()! > 0.02 {
                return "a row's \u{2026} dots carry uneven ink at \(scale)x: \(inks)"
            }
            if abs((measured[1].x - measured[0].x) - (measured[2].x - measured[1].x)) > 0.05
                || measured.map(\.y).max()! - measured.map(\.y).min()! > 0.05 {
                return "a row's \u{2026} dots are unevenly spaced at \(scale)x: \(measured.map { ($0.x, $0.y) })"
            }
            if measured.contains(where: { abs($0.x - $0.boxX) > 0.1 || abs($0.y - $0.boxY) > 0.1 }) {
                return "a row's \u{2026} dot is lopsided at \(scale)x: \(measured)"
            }
            let ideal = (
                x: origin.x - Double(box.x) + Dots.middle.x * scale,
                y: origin.y - Double(box.y) + Dots.middle.y * scale
            )
            if abs(measured[1].x - ideal.x) > 0.75 || abs(measured[1].y - ideal.y) > 0.75 {
                return "a row's \u{2026} middle dot is at \((measured[1].x, measured[1].y)) at \(scale)x, not \(ideal) where macOS draws it"
            }
        }
        return nil
    }

    /// Where `widget`'s top left falls in `target`, in points.
    private static func point(of widget: UnsafeMutableRawPointer, in target: UnsafeMutableRawPointer) -> (x: Double, y: Double)? {
        var from = graphene_point_t(x: 0, y: 0)
        var to = graphene_point_t()
        guard gtk_widget_compute_point(sensorium_gtk_widget(widget), sensorium_gtk_widget(target), &from, &to) != 0 else {
            return nil
        }
        return (Double(to.x), Double(to.y))
    }

    /// Every link draws the icon held in source, never an icon theme's.
    private static func linkIconNotEmbedded(_ window: UnsafeMutableRawPointer) -> String? {
        var links: [UnsafeMutableRawPointer] = []
        _ = descendant(of: window) { widget in
            if gtk_widget_has_css_class(sensorium_gtk_widget(widget), GtkViewerStyle.Class.link) != 0 {
                links.append(widget)
            }
            return false
        }
        for link in links {
            if descendant(of: link, where: { String(cString: gtk_widget_get_css_name(sensorium_gtk_widget($0))) == "image" }) != nil {
                return "a link draws a theme icon"
            }
            if descendant(of: link, where: { sensorium_is_drawing_area($0) != 0 }) == nil {
                return "a link has no icon of its own"
            }
        }
        return nil
    }

    /// With Full Keyboard Access off, as macOS ships, a button never takes
    /// keyboard focus and Return reaches the default one. Only a field a
    /// person can type into holds focus there, or here the selected machine,
    /// whose focus draws exactly its selected border.
    private static func focusMacOSWouldNotGive(_ window: UnsafeMutableRawPointer) -> String? {
        guard let focus = gtk_window_get_focus(sensorium_gtk_window(window)) else { return nil }
        let name = String(cString: gtk_widget_get_css_name(focus))
        if name == "text" {
            return gtk_editable_get_editable(sensorium_gtk_editable(focus)) != 0 ? nil : "a field that cannot be typed into"
        }
        if gtk_widget_has_css_class(focus, GtkViewerStyle.Class.rowSelected) != 0 {
            return nil
        }
        return focusDescription(window)
    }

    private static func hexValue(_ color: ViewerColor) -> UInt32 {
        UInt32(color.hexString.dropFirst(), radix: 16) ?? 0
    }

    /// Mapped, allocated, and given a moment for the frame after that to be
    /// drawn -- a snapshot taken earlier sees a window without its layout.
    private static func settle(_ window: UnsafeMutableRawPointer) async -> Bool {
        for _ in 0..<100 {
            let widget = sensorium_gtk_widget(window)
            if gtk_widget_get_mapped(widget) != 0, gtk_widget_get_width(widget) > 0 {
                await pause(milliseconds: 400)
                return true
            }
            await pause(milliseconds: 50)
        }
        return false
    }

    /// The prompts keep their windows to themselves, so the one a fixture
    /// just opened is found the way the desktop would: the visible toplevel
    /// that was not there before.
    private static func newestVisibleToplevel() async -> UnsafeMutableRawPointer? {
        for _ in 0..<100 {
            await pause(milliseconds: 50)
            if let window = visibleToplevels().last {
                return window
            }
        }
        return nil
    }

    private static func visibleToplevels() -> [UnsafeMutableRawPointer] {
        guard let list = gtk_window_get_toplevels() else { return [] }
        var windows: [UnsafeMutableRawPointer] = []
        for index in 0..<g_list_model_get_n_items(list) {
            guard let item = g_list_model_get_item(list, index) else { continue }
            if gtk_widget_get_visible(sensorium_gtk_widget(item)) != 0 {
                windows.append(item)
            }
            g_object_unref(item)
        }
        return windows
    }

    private static func descendant(
        of root: UnsafeMutableRawPointer,
        where matches: (UnsafeMutableRawPointer) -> Bool
    ) -> UnsafeMutableRawPointer? {
        var child = gtk_widget_get_first_child(sensorium_gtk_widget(root))
        while let current = child {
            let pointer = UnsafeMutableRawPointer(current)
            if matches(pointer) {
                return pointer
            }
            if let found = descendant(of: pointer, where: matches) {
                return found
            }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    /// The widget that has keyboard focus, named by its CSS node and classes.
    private static func focusDescription(_ window: UnsafeMutableRawPointer) -> String {
        guard let focus = gtk_window_get_focus(sensorium_gtk_window(window)) else { return "nothing" }
        var parts = [String(cString: gtk_widget_get_css_name(focus))]
        if let classes = gtk_widget_get_css_classes(focus) {
            var index = 0
            while let name = classes[index] {
                parts.append("." + String(cString: name))
                index += 1
            }
            g_strfreev(classes)
        }
        if let parent = gtk_widget_get_parent(focus), gtk_widget_has_css_class(parent, GtkViewerStyle.Class.iconButton) != 0 {
            parts.append(" inside the row's \u{2026}")
        }
        if parts[0] == "text", let entry = gtk_widget_get_parent(focus) {
            parts.append(" inside " + String(cString: gtk_widget_get_css_name(entry)))
            if let placeholder = gtk_entry_get_placeholder_text(sensorium_gtk_entry(entry)) {
                parts.append(" \"" + String(cString: placeholder) + "\"")
            }
        }
        return parts.joined()
    }

    private static func hasClass(_ widget: UnsafeMutableRawPointer, _ name: String) -> Bool {
        gtk_widget_has_css_class(sensorium_gtk_widget(widget), name) != 0
    }

    private static func buttonLabel(_ widget: UnsafeMutableRawPointer) -> String? {
        guard g_type_check_instance_is_a(
            widget.assumingMemoryBound(to: GTypeInstance.self), gtk_button_get_type()
        ) != 0, let label = gtk_button_get_label(sensorium_gtk_button(widget)) else { return nil }
        return String(cString: label)
    }

    private static func pause(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private static func say(_ line: String) {
        print(line)
        fflush(nil)
    }
}

#else

enum RenderGtkVerb {
    @MainActor
    static func runIfRequested() {}
}

#endif
