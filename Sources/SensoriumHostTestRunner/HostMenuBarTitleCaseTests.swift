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
                connection: .servingHostScreen(peerName: "Kestrel MacBook Pro", displayLabel: "Built-in Display"),
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
                deviceName: "Kestrel MacBook Pro",
                credentialSummary: "hardware-bound credential"
            )
        ])
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        expect(
            menu.items.contains { $0.title == "Sharing host screen with Kestrel MacBook Pro" },
            "the status line for an armed device stays sentence case -- it names no action of its own"
        )
        expect(
            menu.items.contains { $0.title == "Turn Off Share Host Screen for Kestrel MacBook Pro" },
            "turning off sharing is an action, in Title Case, and names what it actually does: "
                + "revoking the permission, which armingStore.disarm confirms -- got titles "
                + "\(menu.items.map { $0.title })"
        )

        print("PASS: an armed device's status line stays sentence case, and turning off its sharing reads in Title Case naming what it does")
    }

    do {
        // Every other action item in the menu reads in Title Case.
        let notGranted = HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
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
            menu.items.contains { $0.title == "Open Screen Recording Settings" },
            "the Screen Recording alert's own action item reads in Title Case -- got titles \(menu.items.map { $0.title })"
        )
        expect(
            menu.items.contains { $0.title == "Host Setup\u{2026}" },
            "Host Setup already reads in Title Case"
        )
        expect(
            menu.items.contains { $0.title == "Quit Sensorium Host" },
            "Quit Sensorium Host already reads in Title Case"
        )

        print("PASS: the Screen Recording alert's action item reads in Title Case alongside Host Setup and Quit")
    }
}
