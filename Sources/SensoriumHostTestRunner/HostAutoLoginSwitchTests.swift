import AppKit
import Foundation
import SensoriumHost

/// `HostSetupWindowController`'s "Open at login" checkbox reads
/// `HostAutoLoginStatus` fresh on every refresh, the same way the Tailscale
/// button re-reads whether Tailscale is installed -- see
/// `HostSetupTailscaleButtonTests`.
@MainActor
func runHostAutoLoginSwitchTests() async {
    func autoLoginCheckbox(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "autoLoginCheckbox", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named autoLoginCheckbox")
    }

    func autoLoginStatusLabel(in controller: HostSetupWindowController) -> NSTextField {
        for child in Mirror(reflecting: controller).children {
            if child.label == "autoLoginStatusLabel", let label = child.value as? NSTextField {
                return label
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named autoLoginStatusLabel")
    }

    func controller(
        autoLoginStatus: @escaping @MainActor () -> HostAutoLoginStatus,
        onToggleAutoLogin: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted),
                problem: nil
            ),
            onRevealPairingCode: {},
            onStop: {},
            tailscaleAppURLLookup: { nil },
            onOpenTailscaleApp: { _ in },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            autoLoginStatus: autoLoginStatus,
            onToggleAutoLogin: onToggleAutoLogin
        )
    }

    do {
        let checkbox = autoLoginCheckbox(in: controller(autoLoginStatus: { .notRegistered }))
        expect(checkbox.state == .off, "not registered reads as off")
        expect(checkbox.isEnabled, "not registered leaves the checkbox enabled, so the owner can turn it on")
        print("PASS: not registered reads as an off, enabled checkbox")
    }

    do {
        let checkbox = autoLoginCheckbox(in: controller(autoLoginStatus: { .enabled }))
        expect(checkbox.state == .on, "enabled reads as on")
        expect(checkbox.isEnabled, "enabled leaves the checkbox enabled")
        print("PASS: enabled reads as an on, enabled checkbox")
    }

    do {
        let ctrl = controller(autoLoginStatus: { .requiresApproval })
        let checkbox = autoLoginCheckbox(in: ctrl)
        let label = autoLoginStatusLabel(in: ctrl)
        expect(checkbox.state == .on, "requiresApproval is registered, so the checkbox reads on")
        expect(!label.isHidden, "requiresApproval shows text distinct from a plain on, not silently read as on")
        print("PASS: requiresApproval reads as on with its own explanatory text, not a silent on")
    }

    do {
        let ctrl = controller(autoLoginStatus: { .notFound })
        let checkbox = autoLoginCheckbox(in: ctrl)
        let label = autoLoginStatusLabel(in: ctrl)
        expect(checkbox.state == .off, "notFound reads as off")
        expect(!checkbox.isEnabled, "notFound disables the checkbox: nothing here can turn login items on")
        expect(!label.isHidden, "notFound shows text explaining why, not silently doing nothing when clicked")
        print("PASS: notFound reads as an off, disabled checkbox with its own explanatory text")
    }

    do {
        var toggledTo: [Bool] = []
        let ctrl = controller(autoLoginStatus: { .notRegistered }, onToggleAutoLogin: { toggledTo.append($0) })
        let checkbox = autoLoginCheckbox(in: ctrl)
        expect(checkbox.state == .off, "starts off, as notRegistered reads")
        // A checkbox-style `NSButton` flips its own state as part of the
        // click, before its action runs -- clicking the off checkbox from
        // the fixture above is what reports turning it on.
        checkbox.performClick(nil)
        expect(toggledTo == [true], "turning the checkbox on reports true to the owner")
        print("PASS: turning the checkbox on reports the new state to onToggleAutoLogin")
    }
}
