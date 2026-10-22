import AppKit
import Foundation
import SensoriumHost

/// `HostSetupWindowController`'s permission button sits in a window, where
/// every other button reads sentence case ("Download Tailscale", "Reveal pairing
/// code"). The status-item menu's equivalent entry is Title Case instead --
/// `HostMenuBarTitleCaseTests` pins that half. Both read the same
/// `HostOperatorPermissionAlert`, so the alert must carry its two casings
/// separately rather than let one surface dictate the other's style.
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
        // Screen Recording missing: window button reads sentence case
        let button = permissionButton(in: controller(
            permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
        ))
        expect(
            button.attributedTitle.string == "Open Screen Recording settings",
            "the window button is sentence case like every other button in this window, unlike the status-item "
                + "menu's Title Case entry -- got: \(button.attributedTitle.string)"
        )

        print("PASS: the Screen Recording permission button in the host window reads sentence case")
    }

    do {
        // Accessibility missing: window button reads sentence case
        let button = permissionButton(in: controller(
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .approvalRequired)
        ))
        expect(
            button.attributedTitle.string == "Open Accessibility settings",
            "the Accessibility case gets the same sentence-case treatment as Screen Recording -- got: "
                + "\(button.attributedTitle.string)"
        )

        print("PASS: the Accessibility permission button in the host window reads sentence case")
    }
}
