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
            linkTitles(under: root) == ["Download Tailscale", "Look Again", "Enter Address Manually\u{2026}", "Back"],
            "with no Tailscale the add step offers Download Tailscale before Look Again, as its sentence reads, then the manual address and Back, got \(linkTitles(under: root))"
        )
        if let download = link(titled: "Download Tailscale", under: root) {
            gtk_widget_activate(sensorium_gtk_widget(download))
            // A button clicks a moment after it is activated, once it has shown it was pressed.
            structurePump(seconds: 0.6)
        }
        expect(opened == "https://tailscale.com/download", "Download Tailscale opens Tailscale's own page, got \(opened ?? "nothing")")
        expect(
            visibleLabels(under: root).map(\.text).contains(
                "Tailscale is not installed. Download\u{00A0}Tailscale and sign in, then choose Look\u{00A0}Again."
            ),
            "the not-installed sentence holds both control names whole, got \(visibleLabels(under: root).map(\.text))"
        )
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
        expect(
            visibleLabels(under: root).map(\.text).contains(
                "Tailscale is not running. Start Tailscale and sign in, then choose Look\u{00A0}Again."
            ),
            "the not-running sentence holds Look Again whole, got \(visibleLabels(under: root).map(\.text))"
        )
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
            labels.map(\.text).contains("Sign in to Tailscale on the machine you want to work on, then choose Look\u{00A0}Again."),
            "and then what to do about it"
        )
    }

    // The empty list says what is empty, in the heading style the add step uses
    // for an empty tailnet, and then what to do about it.
    do {
        let (window, root) = show { _ in }
        defer { window.hide() }
        let labels = visibleLabels(under: root)
        expect(
            labels.map(\.text) == [
                YourMachinesWindowModel.heading, YourMachinesWindowModel.emptyHeading, YourMachinesWindowModel.emptySentence
            ],
            "the empty list is headed, says what is empty, then what to do, got \(labels.map(\.text))"
        )
        expect(
            labels.contains { $0.text == YourMachinesWindowModel.emptyHeading && $0.classes.contains(Class.headline) },
            "what is empty is in the headline style, got \(labels.map(\.classes))"
        )
        expect(
            labels.contains { $0.text == YourMachinesWindowModel.emptySentence && $0.classes.contains(Class.muted) },
            "and what to do stays in the muted line under it"
        )
    }

    // The code step.
    do {
        let (window, root) = show { $0.showCodeStep(for: studio) }
        defer { window.hide() }
        let labels = visibleLabels(under: root).map(\.text)
        expect(labels.first == "Type the code shown on Studio.", "the code step is headed in sentence case, got \(labels.first ?? "nothing")")
        expect(labels.contains("Pairing code"), "the code field is labelled, as every field is")
        expect(
            labels.contains("The six digits Sensorium Host shows on that machine."),
            "the code hint names the digits, not a button the host has already replaced, got \(labels)"
        )
        let placeholders = descendants(of: root)
            .filter { String(cString: gtk_widget_get_css_name(sensorium_gtk_widget($0))) == "entry" }
            .compactMap { gtk_entry_get_placeholder_text(sensorium_gtk_entry($0)).map { String(cString: $0) } }
        expect(
            placeholders.contains("Uses its address") && !placeholders.contains("Studio"),
            "an empty name field says it will use the address, instead of a sample that reads as a name already typed, got \(placeholders)"
        )
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
            visibleLabels(under: root).first?.text == "Type the machine\u{2019}s address and code.",
            "the heading for an address typed by hand asks for the address too, in sentence case"
        )
        expect(
            visibleLabels(under: root).map(\.text).contains("Address"),
            "the address field is labelled with a noun, like the other fields, got \(visibleLabels(under: root).map(\.text))"
        )
    }

    // The rename step is headed with the machine it renames.
    do {
        let host = SavedHost(
            displayName: "Workstation", host: "mini.tail1234.ts.net", port: 7777,
            hostPublicKey: Data([1]), tlsCertificateHash: Data([1, 1]), lastConnectedAt: Date(timeIntervalSince1970: 9_000)
        )
        let (window, root) = show(hosts: [host]) { $0.beginRename(hostPublicKey: host.hostPublicKey) }
        defer { window.hide() }
        let first = visibleLabels(under: root).first?.text
        expect(first == "Rename Workstation", "the rename step is headed with the machine it renames, got \(first ?? "nothing")")
        guard let rename = firstDescendant(of: root, where: { widgetHasClass($0, Class.primary) }),
              let cancel = firstDescendant(of: root, where: { widgetHasClass($0, Class.secondary) }) else {
            expect(false, "the rename step has Cancel and Rename")
            return
        }
        expect(
            horizontalPosition(of: cancel, in: root) < horizontalPosition(of: rename, in: root),
            "Cancel comes before Rename, as on macOS"
        )
    }

    // The picker's rows carry the same status dot as the list, and an offline
    // device is not dimmed.
    do {
        func device(_ id: String, _ name: String, online: Bool) -> TailnetDevicePickerRow {
            TailnetDevicePickerRow(peer: TailnetPeer(
                id: id, displayName: name, magicDNSName: "\(name.lowercased()).tail1234.ts.net",
                tailnetIPv4: "100.64.1.\(id)", tailnetIPv6: nil, isOnline: online, isThisMachine: false
            ))
        }
        let (window, root) = show {
            $0.apply(deviceList: .devices([device("2", "Workstation", online: true), device("3", "Studio", online: false)]))
        }
        defer { window.hide() }
        let rows = descendants(of: root).filter { widgetHasClass($0, Class.row) }
        expect(rows.count == 2, "both devices are listed, got \(rows.count)")
        let dotClasses = [Class.dotOnline, Class.dotOffline, Class.dotActivity, Class.dotUnknown]
        for (row, expected) in zip(rows, [Class.dotOnline, Class.dotOffline]) {
            let dots = descendants(of: row).filter { node in dotClasses.contains { widgetHasClass(node, $0) } }
            expect(
                dots.count == 1 && dots.allSatisfy { widgetHasClass($0, expected) },
                "each device's row carries the one dot Your Machines draws for it, got \(dots.count)"
            )
        }
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

    // A machine whose attempt failed and is being retried keeps the pulsing
    // dot, and says so, with Cancel beside it to stop the retries.
    do {
        let host = SavedHost(
            displayName: "Workstation", host: "mini.tail1234.ts.net", port: 7777,
            hostPublicKey: Data([1]), tlsCertificateHash: Data([1, 1]), lastConnectedAt: Date(timeIntervalSince1970: 9_000)
        )
        let (window, root) = show(hosts: [host]) {
            $0.connectRequested(hostPublicKey: host.hostPublicKey)
            $0.connectStarted(hostPublicKey: host.hostPublicKey)
            $0.attemptFailed(
                reason: ViewerSessionFailureCopy.rowLine(for: .unreachable, hostLabel: "Workstation"),
                offersConnectAsVirtualDisplayFallback: false
            )
        }
        defer { window.hide() }
        let rows = descendants(of: root).filter { widgetHasClass($0, Class.row) }
        expect(rows.count == 1, "the machine is listed, got \(rows.count)")
        if let row = rows.first {
            expect(
                descendants(of: row).contains { widgetHasClass($0, Class.dotActivity) },
                "a failed attempt that will be retried draws the pulsing dot"
            )
            expect(
                visibleLabels(under: row).map(\.text).contains("mini.tail1234.ts.net \u{2014}\u{00A0}could not reach it, trying\u{00A0}again\u{2026}"),
                "and the line reads as the shared model words it, got \(visibleLabels(under: row).map(\.text))"
            )
            expect(
                descendants(of: root).contains { widgetHasClass($0, Class.rowAction) && linkTitle($0) == "Cancel" },
                "and offers Cancel for the retries, over the row"
            )
        }
    }

    print("PASS: Your Machines puts the same words, links and controls on each step in the order macOS does")
}

/// The steps of Your Machines that finish only when an answer arrives: what is
/// said while a machine is asked and after it refuses, and where the caret goes.
/// The answer is a task, so these wait on the main actor instead of pumping the
/// display alone. They need the same scratch Wayland display as the structure
/// tests above.
@MainActor
func testGtkYourMachinesPairingFlowTests() async {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' pairing flow needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    let studio = ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio")

    func show(
        _ drive: (GtkYourMachinesWindow) -> Void
    ) -> (window: GtkYourMachinesWindow, root: UnsafeMutableRawPointer) {
        let window = GtkYourMachinesWindow(store: InMemorySavedHostStore())
        window.show()
        drive(window)
        structurePump(seconds: 0.4)
        return (window, UnsafeMutableRawPointer(window.toplevel))
    }

    // A machine's name is held whole in the code step's heading and in the
    // lines shown while it is asked, never broken at its hyphen or space.
    do {
        let held = "west\u{2011}annex\u{00A0}studio"
        let gate = PairingGate()
        let (window, root) = show {
            $0.pair = { _, _ in
                await gate.wait()
                return .failed(.refused(reason: "invalid-code"))
            }
            $0.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "west-annex studio"))
        }
        defer { window.hide() }
        expect(
            visibleLabels(under: root).first?.text == "Type the code shown on \(held).",
            "the code step's heading holds the machine's name whole, got \(visibleLabels(under: root).first?.text ?? "nothing")"
        )
        guard let code = firstDescendant(of: root, where: { widgetHasClass($0, Class.code) }),
              let pair = firstDescendant(of: root, where: { widgetHasClass($0, Class.primary) }) else {
            expect(false, "the code step has a code field and Pair")
            return
        }
        gtk_editable_set_text(sensorium_gtk_editable(code), "418297")
        gtk_widget_activate(sensorium_gtk_widget(pair))
        await structureWait(seconds: 0.6)
        let asking = visibleLabels(under: root).map(\.text)
        expect(
            asking.contains("Asking \(held) to accept this machine\u{2026}"),
            "the line shown while the machine is asked holds its name whole, got \(asking)"
        )
        expect(
            asking.contains { $0.contains("the code on \(held)\u{2019}s screen") },
            "and so does the line telling the person to leave the code up, got \(asking)"
        )
        gate.open()
        await structureWait(seconds: 0.6)
        expect(
            visibleLabels(under: root).map(\.text).contains("Check the six digits on \(held), then choose Pair."),
            "a refused code names the machine whole as well, got \(visibleLabels(under: root).map(\.text))"
        )
    }

    // After a refused code the caret sits at the end of the code with nothing
    // selected, as on macOS: focusing a field selects everything in it, and a
    // person correcting a code edits it where it ends.
    do {
        let (window, root) = show {
            $0.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
            $0.showCodeStep(for: studio)
        }
        defer { window.hide() }
        guard let code = firstDescendant(of: root, where: { widgetHasClass($0, Class.code) }),
              let pair = firstDescendant(of: root, where: { widgetHasClass($0, Class.primary) }) else {
            expect(false, "the code step has a code field and Pair")
            return
        }
        let editable = sensorium_gtk_editable(code)
        gtk_editable_set_text(editable, "418297")
        gtk_widget_activate(sensorium_gtk_widget(pair))
        await structureWait(seconds: 1.0)
        expect(
            visibleLabels(under: root).map(\.text).contains("Wrong code."),
            "the refused code is reported, got \(visibleLabels(under: root).map(\.text))"
        )
        var start: gint = 0
        var end: gint = 0
        let hasSelection = gtk_editable_get_selection_bounds(editable, &start, &end) != 0
        expect(!hasSelection, "nothing in the kept code is selected, got \(start)..<\(end)")
        let length = String(cString: gtk_editable_get_text(editable)).count
        expect(
            Int(gtk_editable_get_position(editable)) == length,
            "the caret sits after the code, at \(length), got \(gtk_editable_get_position(editable))"
        )
    }

    print("PASS: Your Machines names the machine whole while it is asked and after it refuses, and leaves the caret after the kept code")
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

/// Holds a pairing attempt open until the test lets it end, so the line shown
/// while the other machine is asked can be read before the answer replaces it.
@MainActor
private final class PairingGate {
    private var waiting: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }
}

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
/// Runs the display's events and lets main-actor tasks run, for `seconds`.
@MainActor
private func structureWait(seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
#else
@MainActor
func testGtkYourMachinesMatchesMacOSStructureTests() {}

@MainActor
func testGtkYourMachinesPairingFlowTests() async {}
#endif
