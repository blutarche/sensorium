import AppKit
import Foundation
import SensoriumHost

/// **Install updates automatically** and the update line, under **Open at
/// login**, and **Check for Updates…** in both menus.
@MainActor
func runHostUpdateWindowTests() {
    func stored<T>(_ name: String, in controller: HostSetupWindowController, as type: T.Type) -> T {
        for child in Mirror(reflecting: controller).children where child.label == name {
            if let value = child.value as? T {
                return value
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(name)")
    }

    func controller(
        installsUpdatesAutomatically: (@MainActor () -> Bool)?,
        onToggleAutomaticUpdates: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .hosting(address: "100.64.1.2"),
                permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
            ),
            onRevealPairingCode: {},
            onStop: {},
            tailscaleAppURLLookup: { nil },
            onOpenTailscaleApp: { _ in },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            installsUpdatesAutomatically: installsUpdatesAutomatically,
            onToggleAutomaticUpdates: onToggleAutomaticUpdates
        )
    }

    do {
        let window = controller(installsUpdatesAutomatically: nil)
        let checkbox = stored("automaticUpdatesCheckbox", in: window, as: NSButton.self)
        let line = stored("updateLineLabel", in: window, as: NSTextField.self)
        window.setUpdateLine("Sensorium Host 0.4.0, up to date.")
        expect(checkbox.isHidden, "a build with no updater shows no update checkbox")
        expect(line.isHidden, "and no update line, whatever it is given")
        print("PASS: a build with no updater shows neither the checkbox nor the line")
    }

    do {
        var saved = true
        var toggles: [Bool] = []
        let window = controller(
            installsUpdatesAutomatically: { saved },
            onToggleAutomaticUpdates: { isOn in
                toggles.append(isOn)
                saved = isOn
            }
        )
        let checkbox = stored("automaticUpdatesCheckbox", in: window, as: NSButton.self)
        expect(!checkbox.isHidden, "a packaged host shows the checkbox")
        expect(checkbox.title == "Install updates automatically", "the checkbox's words, got \(checkbox.title)")
        expect(checkbox.state == .on, "on by default")

        checkbox.state = .off
        _ = checkbox.target?.perform(checkbox.action, with: checkbox)
        expect(toggles == [false], "clicking it off asks to turn automatic updates off, got \(toggles)")
        expect(checkbox.state == .off, "and reads back off once saved")

        let stack = stored("root", in: window, as: NSStackView.self)
        let views = stack.arrangedSubviews
        let autoLoginLabel = stored("autoLoginStatusLabel", in: window, as: NSTextField.self)
        let line = stored("updateLineLabel", in: window, as: NSTextField.self)
        guard let below = views.firstIndex(of: autoLoginLabel),
              let checkboxIndex = views.firstIndex(of: checkbox),
              let lineIndex = views.firstIndex(of: line) else {
            expect(false, "the checkbox and line are in the window's stack")
            return
        }
        expect(checkboxIndex == below + 1, "the checkbox sits under Open at login")
        expect(lineIndex == checkboxIndex + 1, "the update line sits under the checkbox")
        print("PASS: Install updates automatically sits under Open at login, on by default, and reports a click")
    }

    do {
        final class Saved {
            var value = true
        }
        let saved = Saved()
        let window = controller(installsUpdatesAutomatically: { saved.value }, onToggleAutomaticUpdates: { _ in })
        let checkbox = stored("automaticUpdatesCheckbox", in: window, as: NSButton.self)
        checkbox.state = .off
        _ = checkbox.target?.perform(checkbox.action, with: checkbox)
        expect(checkbox.state == .on, "a choice that could not be saved reads back as it still is")
        saved.value = false
        window.update(HostOperatorStatus(
            connection: .hosting(address: "100.64.1.2"),
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        ))
        expect(checkbox.state == .off, "the checkbox follows the saved preference on every refresh")
        print("PASS: the checkbox shows what is saved, not what was clicked")
    }

    do {
        let window = controller(installsUpdatesAutomatically: { true })
        let line = stored("updateLineLabel", in: window, as: NSTextField.self)
        expect(line.isHidden, "no line until the updater gives one")
        window.setUpdateLine("Sensorium Host 0.5.0 will install when no machine is connected.")
        expect(!line.isHidden, "the line shows once given")
        expect(
            line.stringValue == "Sensorium Host 0.5.0 will install when no machine is connected.",
            "the line shows the updater's words exactly, got \(line.stringValue)"
        )
        window.setUpdateLine(nil)
        expect(line.isHidden, "nil hides it")
        print("PASS: the update line shows the updater's words under the checkbox")
    }
}

@MainActor
func runHostUpdateMenuItemTests() {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func menu(of presence: HostMenuBarPresence) -> NSMenu {
        for child in Mirror(reflecting: presence).children where child.label == "statusItem" {
            if let item = child.value as? NSStatusItem?, let menu = item?.menu {
                return menu
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named statusItem, or install() left it nil")
    }

    do {
        var checks = 0
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .hosting(address: "100.64.1.2"), permissions: granted),
            openSetup: {},
            onCheckForUpdates: { checks += 1 },
            quit: {}
        )
        presence.install()
        let titles = menu(of: presence).items.map(\.title)
        guard let about = titles.firstIndex(of: "About Sensorium Host"),
              let check = titles.firstIndex(of: "Check for Updates\u{2026}") else {
            expect(false, "the menu bar item offers Check for Updates…, got \(titles)")
            return
        }
        expect(check == about + 1, "Check for Updates… follows About, got \(titles)")
        let item = menu(of: presence).items[check]
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        expect(checks == 1, "choosing it checks for updates, got \(checks)")
        print("PASS: the menu bar item's menu offers Check for Updates… after About")
    }

    do {
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .hosting(address: "100.64.1.2"), permissions: granted),
            quit: {}
        )
        presence.install()
        expect(
            !menu(of: presence).items.map(\.title).contains("Check for Updates\u{2026}"),
            "a host with no updater offers no Check for Updates…"
        )
        print("PASS: a host with no updater offers no Check for Updates…")
    }

    do {
        var checks = 0
        let controller = HostMainMenuController(quit: {}, checkForUpdates: { checks += 1 })
        controller.install(into: NSApplication.shared)
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu else {
            expect(false, "the App menu exists")
            return
        }
        let titles = appMenu.items.map(\.title)
        expect(
            titles == [
                "About Sensorium Host", "Check for Updates\u{2026}", "", "Hide Sensorium Host", "Hide Others", "Show All", "",
                "Quit Sensorium Host"
            ],
            "the App menu offers Check for Updates… after About, got \(titles)"
        )
        let item = appMenu.items[1]
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        expect(checks == 1, "choosing it checks for updates, got \(checks)")
        print("PASS: the App menu offers Check for Updates… after About")
    }
}
