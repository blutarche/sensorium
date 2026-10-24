#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient
import SensoriumCore

/// What Your Machines puts on each step, and in what order, as the macOS window
/// does: the words, the links under them, which control comes first. Each case
/// builds the real window, so it needs a scratch Wayland display and runs only
/// when `SENSORIUM_GTK_WINDOW_TESTS=1` says the display it would open on is one.
@MainActor
func testGtkYourMachinesMatchesMacOSStructureTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' structure needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    let intro = "Every other machine on your tailnet appears here, whether or not Sensorium Host is running on it."
    let studio = ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio")

    func show(
        hosts: [SavedHost] = [],
        _ drive: (GtkYourMachinesWindow) -> Void
    ) -> (window: GtkYourMachinesWindow, root: UnsafeMutableRawPointer) {
        let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: hosts))
        window.show()
        drive(window)
        structurePump(seconds: 0.4)
        return (window, UnsafeMutableRawPointer(window.toplevel))
    }

    // The add steps.
    for (name, state) in [
        ("loading", TailnetDevicePickerState.loading),
        ("a list", .devices([
            TailnetDevicePickerRow(peer: TailnetPeer(
                id: "1", displayName: "Workstation", magicDNSName: "mini.tail1234.ts.net",
                tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
            ))
        ]))
    ] {
        let (window, root) = show { $0.apply(deviceList: state) }
        defer { window.hide() }
        let texts = visibleLabels(under: root).map(\.text)
        expect(texts.first == "Add a machine", "the add step is headed in sentence case with \(name), got \(texts.first ?? "nothing")")
        expect(texts.contains(intro), "the add step says what the list shows with \(name)")
    }

    let notInstalledReason = TailnetDevicePickerFetchError.tailscaleNotInstalled.reason
    var opened: String?
    do {
        let (window, root) = show {
            $0.onOpenURL = { opened = $0 }
            $0.apply(deviceList: .unreachable(reason: notInstalledReason))
        }
        defer { window.hide() }
        expect(
            !visibleLabels(under: root).map(\.text).contains(intro),
            "an error does not repeat the sentence about what the list will show"
        )
        expect(
            linkTitles(under: root) == ["Look Again", "Download Tailscale", "Enter Address Manually\u{2026}", "Back"],
            "with no Tailscale the add step offers Look Again, Download Tailscale, then the manual address and Back, got \(linkTitles(under: root))"
        )
        if let download = link(titled: "Download Tailscale", under: root) {
            gtk_widget_activate(sensorium_gtk_widget(download))
            // A button clicks a moment after it is activated, once it has shown it was pressed.
            structurePump(seconds: 0.6)
        }
        expect(opened == "https://tailscale.com/download", "Download Tailscale opens Tailscale's own page, got \(opened ?? "nothing")")
    }
    do {
        let (window, root) = show {
            $0.apply(deviceList: .unreachable(reason: TailnetDevicePickerFetchError.tailscaledUnreachable.reason))
        }
        defer { window.hide() }
        expect(
            linkTitles(under: root) == ["Look Again", "Enter Address Manually\u{2026}", "Back"],
            "a Tailscale that is installed but stopped has nothing to download, got \(linkTitles(under: root))"
        )
        expect(!visibleLabels(under: root).map(\.text).contains(intro), "and says nothing about the list")
    }
    do {
        let (window, root) = show { $0.apply(deviceList: .noOtherDevices) }
        defer { window.hide() }
        let labels = visibleLabels(under: root)
        expect(!labels.map(\.text).contains(intro), "an empty tailnet does not promise a list")
        expect(
            labels.contains { $0.text == "Nothing else is on your tailnet yet." && $0.classes.contains(Class.headline) },
            "an empty tailnet says what is empty in a heading of its own, got \(labels.map(\.text))"
        )
        expect(
            labels.map(\.text).contains("Sign in to Tailscale on the machine you want to work on, then choose Look Again."),
            "and then what to do about it"
        )
    }

    // The code step.
    do {
        let (window, root) = show { $0.showCodeStep(for: studio) }
        defer { window.hide() }
        let labels = visibleLabels(under: root).map(\.text)
        expect(labels.first == "Type the code shown on Studio", "the code step is headed in sentence case, got \(labels.first ?? "nothing")")
        expect(labels.contains("Pairing code"), "the code field is labelled, as every field is")
        guard let back = link(titled: "Back", under: root),
              let pair = firstDescendant(of: root, where: { widgetHasClass($0, Class.primary) }) else {
            expect(false, "the code step has Back and Pair")
            return
        }
        expect(
            horizontalPosition(of: back, in: root) < horizontalPosition(of: pair, in: root),
            "Back comes before Pair, as on macOS"
        )
        // The headline and the detail under it are one group, closer to each
        // other than to the fields around them.
        let headline = descendants(of: root, includeHidden: true).first { widgetHasClass($0, Class.headline) }
        let group = headline
            .flatMap { gtk_widget_get_parent(sensorium_gtk_widget($0)) }
            .flatMap { gtk_widget_get_parent($0) }
        expect(group != nil, "the message headline sits in a group of its own")
        if let group {
            let spacing = Int(gtk_box_get_spacing(sensorium_gtk_box(UnsafeMutableRawPointer(group))))
            expect(
                spacing == Int(ViewerChromeMetrics.Space.xxs),
                "the message headline and detail sit \(Int(ViewerChromeMetrics.Space.xxs)) apart, got \(spacing)"
            )
        }
    }
    do {
        let (window, root) = show { $0.showCodeStep(for: nil) }
        defer { window.hide() }
        expect(
            visibleLabels(under: root).first?.text == "Type the code shown on that machine",
            "the heading for an address typed by hand is sentence case"
        )
    }

    // The list: every machine has a status dot, the unknown one included.
    do {
        let hosts = [
            SavedHost(
                displayName: "Workstation", host: "mini.tail1234.ts.net", port: 7777,
                hostPublicKey: Data([1]), tlsCertificateHash: Data([1, 1]), lastConnectedAt: Date(timeIntervalSince1970: 9_000)
            ),
            SavedHost(
                displayName: "100.64.1.9", host: "100.64.1.9", port: 7777,
                hostPublicKey: Data([3]), tlsCertificateHash: Data([3, 3]), lastConnectedAt: Date(timeIntervalSince1970: 500)
            )
        ]
        let (window, root) = show(hosts: hosts) { _ in }
        defer { window.hide() }
        let rows = descendants(of: root).filter { widgetHasClass($0, Class.row) }
        expect(rows.count == 2, "both machines are listed, got \(rows.count)")
        for row in rows {
            let dotClasses = [Class.dotOnline, Class.dotOffline, Class.dotActivity, Class.dotUnknown]
            let dots = descendants(of: row).filter { node in dotClasses.contains { widgetHasClass(node, $0) } }
            expect(dots.count == 1, "every machine's row carries one status dot, got \(dots.count)")
            expect(
                dots.allSatisfy { widgetHasClass($0, Class.dotUnknown) },
                "a machine the tailnet has not been asked about shows the neutral dot"
            )
        }
    }

    print("PASS: Your Machines puts the same words, links and controls on each step in the order macOS does")
}

/// Every widget under `widget` in tree order, the hidden ones only when asked for.
@MainActor
private func descendants(of widget: UnsafeMutableRawPointer, includeHidden: Bool = false) -> [UnsafeMutableRawPointer] {
    var found: [UnsafeMutableRawPointer] = []
    var child = gtk_widget_get_first_child(sensorium_gtk_widget(widget))
    while let current = child {
        let pointer = UnsafeMutableRawPointer(current)
        if includeHidden || gtk_widget_get_visible(current) != 0 {
            found.append(pointer)
            found += descendants(of: pointer, includeHidden: includeHidden)
        }
        child = gtk_widget_get_next_sibling(current)
    }
    return found
}

@MainActor
private func widgetHasClass(_ widget: UnsafeMutableRawPointer, _ name: String) -> Bool {
    gtk_widget_has_css_class(sensorium_gtk_widget(widget), name) != 0
}

@MainActor
private func firstDescendant(
    of widget: UnsafeMutableRawPointer,
    where matches: (UnsafeMutableRawPointer) -> Bool
) -> UnsafeMutableRawPointer? {
    descendants(of: widget).first(where: matches)
}

/// Every label drawn under `widget`, top to bottom in tree order, with its CSS classes.
@MainActor
private func visibleLabels(under widget: UnsafeMutableRawPointer) -> [(text: String, classes: [String])] {
    let known = [
        Class.heading, Class.sentence, Class.muted, Class.bad, Class.headline, Class.detail, Class.hint,
        Class.rowName, Class.rowDetail, Class.deviceSubtitle
    ]
    return descendants(of: widget).compactMap { node in
        guard String(cString: gtk_widget_get_css_name(sensorium_gtk_widget(node))) == "label",
              widgetHasClass(node, Class.link) == false,
              let text = gtk_label_get_text(sensorium_gtk_label(sensorium_gtk_widget(node))) else { return nil }
        let value = String(cString: text)
        let classes = known.filter { widgetHasClass(node, $0) }
        guard !value.isEmpty, !classes.isEmpty else { return nil }
        return (value, classes)
    }
}

private typealias Class = GtkViewerStyle.Class

/// The title of each link, in tree order. A link's own label is the last
/// label inside its button.
@MainActor
private func linkTitles(under widget: UnsafeMutableRawPointer) -> [String] {
    descendants(of: widget).filter { widgetHasClass($0, Class.link) }.compactMap(linkTitle)
}

@MainActor
private func linkTitle(_ button: UnsafeMutableRawPointer) -> String? {
    descendants(of: button).reversed().compactMap { node -> String? in
        guard String(cString: gtk_widget_get_css_name(sensorium_gtk_widget(node))) == "label",
              let text = gtk_label_get_text(sensorium_gtk_label(sensorium_gtk_widget(node))) else { return nil }
        return String(cString: text)
    }.first
}

@MainActor
private func link(titled title: String, under widget: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    descendants(of: widget).first { widgetHasClass($0, Class.link) && linkTitle($0) == title }
}

@MainActor
private func horizontalPosition(of widget: UnsafeMutableRawPointer, in root: UnsafeMutableRawPointer) -> Double {
    var bounds = graphene_rect_t()
    _ = gtk_widget_compute_bounds(sensorium_gtk_widget(widget), sensorium_gtk_widget(root), &bounds)
    return Double(bounds.origin.x)
}

private func structurePump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(5_000)
    }
}
#else
@MainActor
func testGtkYourMachinesMatchesMacOSStructureTests() {}
#endif
