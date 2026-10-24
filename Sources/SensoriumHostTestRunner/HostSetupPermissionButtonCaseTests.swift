import AppKit
import Foundation
import SensoriumHost

/// `HostSetupWindowController`'s permission button is Title Case, like every
/// other button in the window ("Download Tailscale", "Show Pairing Code") and
/// like the status-item menu's equivalent entry, which
/// `HostMenuBarTitleCaseTests` pins.
@MainActor
func runHostSetupPermissionButtonCaseTests() async {
    func permissionButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "permissionButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named permissionButton")
    }

    func controller(permissions: HostPermissionRequestResult) -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(connection: .notHosting, permissions: permissions, problem: nil),
            onRevealPairingCode: {},
            onStop: {},
            tailscaleAppURLLookup: { nil },
            onOpenTailscaleApp: { _ in },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        // Screen Recording missing
        let button = permissionButton(in: controller(
            permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
        ))
        expect(
            button.attributedTitle.string == "Open Screen Recording Settings",
            "the window button is Title Case, as every button is -- got: \(button.attributedTitle.string)"
        )

        print("PASS: the Screen Recording permission button in the host window reads Title Case")
    }

    do {
        // Accessibility missing
        let button = permissionButton(in: controller(
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .approvalRequired)
        ))
        expect(
            button.attributedTitle.string == "Open Accessibility Settings",
            "the Accessibility case reads Title Case like Screen Recording -- got: \(button.attributedTitle.string)"
        )

        print("PASS: the Accessibility permission button in the host window reads Title Case")
    }
}
