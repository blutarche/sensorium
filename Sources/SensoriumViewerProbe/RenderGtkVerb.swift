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
            },
            Fixture(name: "viewer-session-settings") {
                let window = GtkSessionControlsWindow(activate: { _ in })
                retained.append(window)
                window.present(model: sessionSettingsModel)
                return (window.toplevel, { window.close() })
            }
        ]
    }

    /// A live host-screen session on a two-display host, sharing the
    /// clipboard: every group has rows, and one row in each is chosen.
    private static var sessionSettingsModel: SessionControlsWindowModel {
        var model = SessionControlsWindowModel()
        model.hostScreens = [
            HostScreenListEntry(
                opaqueToken: Data([0x09]), label: "Built-in Display",
                logicalWidth: 1512, logicalHeight: 982, backingScale: 2, isBuiltin: true,
                displayIdentity: "00000610-0000a038"
            ),
            HostScreenListEntry(
                opaqueToken: Data([0x0A]), label: "Studio Display",
                logicalWidth: 2560, logicalHeight: 1440, backingScale: 2, isBuiltin: false,
                displayIdentity: "00000610-0000ae3b"
            )
        ]
        model.selectedScreenToken = Data([0x09])
        model.canvasAvailable = false
        model.isHostScreenSession = true
        model.hostScreenModes = [
            HostScreenModeEntry(
                modeID: "3024x1964@1512x982@60", width: 1512, height: 982,
                pixelWidth: 3024, pixelHeight: 1964, refreshRate: 60, isHiDPI: true
            ),
            HostScreenModeEntry(
                modeID: "3024x1964@1800x1169@60", width: 1800, height: 1169,
                pixelWidth: 3600, pixelHeight: 2338, refreshRate: 60, isHiDPI: true
            )
        ]
        model.currentHostScreenModeID = "3024x1964@1512x982@60"
        model.clipboardSharingEnabled = true
        return model
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
            let staging = directory.appendingPathComponent("\(fixture.name).staging.png").path
            let scale = sensorium_window_content_write_png(shown.window, staging)
            shown.dismiss()
            guard scale > 0 else {
                say("FAILED \(fixture.name): nothing was drawn")
                failures += 1
                continue
            }
            let path = directory.appendingPathComponent("\(fixture.name)@\(scale)x.png").path
            try? FileManager.default.removeItem(atPath: path)
            do {
                try FileManager.default.moveItem(atPath: staging, toPath: path)
            } catch {
                say("FAILED \(fixture.name): \(error)")
                failures += 1
                continue
            }
            // The one colour every window here is drawn on. A corner in any
            // other colour is a theme surface showing through.
            let corner = sensorium_png_pixel(path, 1, 1)
            let background = Int64(hexValue(ViewerPalette.chromeBg))
            if corner != background {
                say("FAILED \(fixture.name): the corner is \(String(format: "#%06X", corner)), not the window background")
                failures += 1
                continue
            }
            say("wrote \(path)")
        }
        return failures == 0 ? 0 : 1
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
