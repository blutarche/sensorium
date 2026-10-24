import AppKit
import Foundation
import SensoriumHost

/// `HostSetupWindowController`'s "Show Pairing Code" button while a pairing
/// is in progress -- `Mirror` reads the button's own `isHidden`, the same
/// technique `HostSetupTailscaleButtonTests` uses, so none of this needs
/// `NSApplication` running or a window actually on screen.
@MainActor
func runHostSetupRevealButtonTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func revealButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "revealButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named revealButton")
    }

    do {
        // A pairing already approved, waiting on the device to confirm: hidden
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .pairingApproved(deviceName: "Kestrel Laptop Pro"),
                permissions: granted
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let button = revealButton(in: controller)
        expect(button.isHidden, "a device already confirming the code has nothing left for a fresh reveal to do -- offering the button here only invites a second, redundant code")

        print("PASS: the Show Pairing Code button stays hidden while a pairing is approved and waiting on the device")
    }

    do {
        // While a session is live, Stop must dominate: Show pairing
        // code drops to a plain bordered button rather than
        // competing with it as a second filled button.
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .serving(peerName: "Kestrel Laptop Pro"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let button = revealButton(in: controller)
        expect(!button.isHidden, "a live session still offers to show the code, beside the Stop button that dominates it")
        expect(
            button.attributedTitle.string == "Show Pairing Code",
            "the plain style reads Title Case too -- got \(button.attributedTitle.string)"
        )
        expect(!button.isBordered, "while a session is live, Show Pairing Code drops its fill but stays layer-drawn, not a second filled button")
        expect(
            button.layer?.backgroundColor == nil,
            "a plain button carries no fill of its own -- got \(String(describing: button.layer?.backgroundColor))"
        )
        expect(
            button.constraints.first(where: { $0.firstAttribute == .height })?.constant == 32,
            "the button keeps its usual 32pt height even with its fill dropped -- only the fill changes"
        )

        print("PASS: while a session is live, Show Pairing Code is a plain button, still 32pt tall, so Stop dominates")
    }

    do {
        // With no session live, Show Pairing Code keeps its current
        // filled, emphasised style.
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let button = revealButton(in: controller)
        expect(
            button.attributedTitle.string == "Show Pairing Code",
            "a button is Title Case -- got \(button.attributedTitle.string)"
        )
        expect(!button.isBordered, "with nobody connected, Show Pairing Code stays the filled, layer-drawn button it already was")
        expect(
            button.layer?.backgroundColor == CanvasDesign.accent.cgColor,
            "and keeps its accent fill -- got \(String(describing: button.layer?.backgroundColor))"
        )
        expect(
            button.constraints.first(where: { $0.firstAttribute == .height })?.constant == 32,
            "the filled style is 32pt tall -- the same height the plain style keeps"
        )

        print("PASS: with no session live, Show Pairing Code keeps its filled style")
    }

    do {
        // The gold "Open Screen Recording Settings" button also
        // dominates: Show Pairing Code must not compete with it as a
        // second filled button either, even with no session live.
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let button = revealButton(in: controller)
        expect(!button.isHidden, "the Screen Recording alert does not stop this button from offering the code")
        expect(!button.isBordered, "the gold Open Screen Recording Settings button sits above this one -- Show Pairing Code must drop its fill, staying layer-drawn")
        expect(
            button.layer?.backgroundColor == nil,
            "a plain button carries no fill of its own -- got \(String(describing: button.layer?.backgroundColor))"
        )
        expect(
            button.constraints.first(where: { $0.firstAttribute == .height })?.constant == 32,
            "the button keeps its usual 32pt height even with its fill dropped -- only the fill changes"
        )

        print("PASS: with the Screen Recording alert showing, Show Pairing Code is a plain button, still 32pt tall")
    }
}
