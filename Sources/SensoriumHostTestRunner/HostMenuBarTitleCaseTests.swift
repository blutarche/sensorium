import AppKit
import Foundation
import SensoriumHost

/// macOS menu convention: every action item reads in Title Case; a status
/// line that names no action of its own stays sentence case. `Mirror` reads
/// `HostMenuBarPresence`'s private `statusItem`, the same past-access-level
/// route `HostMenuBarStopMenuItemTests` already uses.
@MainActor
func runHostMenuBarTitleCaseTests() async {
    func statusItem(in presence: HostMenuBarPresence) -> NSStatusItem {
        for child in Mirror(reflecting: presence).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem? {
                if let item {
                    return item
                }
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named statusItem, or install() left it nil")
    }

    do {
        // A device sharing its host screen: the status line stays
        // sentence case, but turning it off is an action and reads
        // in Title Case -- and names what it actually does: revoke
        // the permission, not end the live session, which the plain
        // Stop item already does.
        let notGranted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(
                connection: .servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
                permissions: notGranted
            ),
            onStop: {},
            onTurnOffSharing: { _ in },
            quit: {}
        )
        presence.install()
        presence.updateArming([
            HostScreenArmingPresentation.DeviceLine(
                devicePublicKey: Data([0xAB]),
                deviceName: "Kestrel Laptop Pro"

            )
        ])
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        expect(
            menu.items.contains { $0.title == "Sharing host screen with Kestrel Laptop Pro" },
            "the status line for an armed device stays sentence case -- it names no action of its own"
        )
        expect(
            menu.items.contains { $0.title == "Turn Off Share Host Screen for Kestrel Laptop Pro" },
            "turning off sharing is an action, in Title Case, and names what it actually does: "
                + "revoking the permission, which armingStore.disarm confirms -- got titles "
                + "\(menu.items.map { $0.title })"
        )

        print("PASS: an armed device's status line stays sentence case, and turning off its sharing reads in Title Case naming what it does")
    }

    do {
        // Every other action item in the menu reads in Title Case.
        let notGranted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .approvalRequired)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .notHosting, permissions: notGranted),
            openSetup: {},
            onStop: {},
            quit: {}
        )
        presence.install()
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        expect(
            menu.items.contains { $0.title == "Open Accessibility Settings" },
            "the Accessibility alert's own action item reads in Title Case -- got titles \(menu.items.map { $0.title })"
        )
        expect(
            menu.items.contains { $0.title == "Host Setup\u{2026}" },
            "Host Setup already reads in Title Case"
        )
        expect(
            menu.items.contains { $0.title == "Quit Sensorium Host" },
            "Quit Sensorium Host already reads in Title Case"
        )

        print("PASS: the Accessibility alert's action item reads in Title Case alongside Host Setup and Quit")
    }

    /// The panel's own button, when it is showing one.
    func shownPanelButtonTitles(in presence: HostMenuBarPresence) -> [String] {
        for child in Mirror(reflecting: presence).children where child.label == "panel" {
            if let panel = child.value as? NSView {
                return panel.subviews
                    .compactMap { $0 as? NSButton }
                    .filter { !$0.isHidden }
                    .map { $0.attributedTitle.string }
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named panel")
    }

    do {
        // Screen Recording missing: the panel carries the gold button, so the
        // menu does not offer the same title a second time.
        let missing = HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .notHosting, permissions: missing),
            openSetup: {},
            onStop: {},
            quit: {}
        )
        presence.install()
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        let title = "Open Screen Recording Settings"
        let inMenu = menu.items.filter { $0.title == title }.count
        let inPanel = shownPanelButtonTitles(in: presence).filter { $0 == title }.count
        expect(inPanel == 1, "the panel shows the Screen Recording button once, got \(inPanel)")
        expect(
            inMenu + inPanel == 1,
            "\(title) appears exactly once across the panel and the menu items -- panel \(inPanel), menu \(inMenu)"
        )
        print("PASS: Open Screen Recording Settings appears once, on the panel's button, not again in the menu")
    }

    do {
        // Both permissions missing: only the alert the panel has a button for
        // loses its menu item. The Accessibility alert has no button, so it
        // keeps its item.
        let bothMissing = HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .approvalRequired)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .notHosting, permissions: bothMissing),
            openSetup: {},
            onStop: {},
            quit: {}
        )
        presence.install()
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        let titles = menu.items.map { $0.title }
        expect(
            titles.filter { $0 == "Open Screen Recording Settings" }.isEmpty
                && shownPanelButtonTitles(in: presence) == ["Open Screen Recording Settings"],
            "Screen Recording is offered by the panel's button alone -- menu \(titles)"
        )
        expect(
            titles.filter { $0 == "Open Accessibility Settings" }.count == 1,
            "Accessibility, which the panel has no button for, keeps its menu item -- menu \(titles)"
        )
        print("PASS: only the alert the panel has a button for loses its menu item")
    }

    do {
        // Screen Recording alone, with no menu item left for any alert, adds
        // no separator for a list that is empty.
        let missing = HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .notHosting, permissions: missing),
            quit: {}
        )
        presence.install()
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        var previousWasSeparator = false
        var doubled = false
        for item in menu.items {
            doubled = doubled || (item.isSeparatorItem && previousWasSeparator)
            previousWasSeparator = item.isSeparatorItem
        }
        expect(!doubled, "no two separators sit side by side once the alert's item is left out")
        print("PASS: leaving out the alert's item leaves no empty section behind")
    }
}
