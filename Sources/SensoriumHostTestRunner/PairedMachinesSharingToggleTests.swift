import AppKit
import Foundation
import SensoriumHost

/// The Paired machines row's own Share host screen toggle: on must read as on
/// from colour alone, not from `NSColor.controlAccentColor` -- a person can
/// set that to Graphite, at which point a system-drawn `NSSwitch`'s on and
/// off tracks are both the same grey. `Mirror` reaches every field here
/// (`pairedMachines`, `toggle`, `toggleLabel`), the same past-`private`,
/// past-module-boundary route `HostSetupTailscaleButtonTests` already uses.
@MainActor
func runPairedMachinesSharingToggleTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    func rowViews(in controller: HostSetupWindowController) -> [NSView] {
        let pairedMachines: NSView = field("pairedMachines", of: controller, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: pairedMachines, as: NSStackView.self)
        return rowsStack.arrangedSubviews
    }

    func controller(rows: [HostScreenArmingPresentation.PairedMachineRow]) -> HostSetupWindowController {
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .notHosting, permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        controller.updatePairedMachines(rows)
        return controller
    }

    do {
        // On: the toggle's own track is tinted with this app's
        // accent, independent of the system's own accent-colour
        // preference. The label keeps one colour regardless of on
        // or off -- the switch itself already carries the state.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil
        )
        let rows = rowViews(in: controller(rows: [sharingRow]))
        expect(rows.count == 1, "one row for one paired machine")
        let toggle: NSControl = field("toggle", of: rows[0], as: NSControl.self)
        let toggleLabel: NSTextField = field("toggleLabel", of: rows[0], as: NSTextField.self)
        let trackLayer: CALayer = field("trackLayer", of: toggle, as: CALayer.self)
        let isOn: Bool = field("isOn", of: toggle, as: Bool.self)

        expect(isOn, "a row for a device that is currently sharing starts its toggle on")
        expect(
            trackLayer.backgroundColor == CanvasDesign.accent.cgColor,
            "on, the track is tinted with this app's own accent colour, not left to NSColor.controlAccentColor -- which a person can set to Graphite, making on and off the same grey"
        )
        expect(
            toggleLabel.textColor == CanvasDesign.muted.nsColor,
            "on, the Share host screen label still reads muted -- one label colour regardless of state"
        )
        expect(
            toggle.alphaValue == 1 && toggleLabel.alphaValue == 1,
            "an enabled toggle and its label are drawn at full opacity"
        )

        print("PASS: a sharing row's toggle takes the app accent, and its label stays the same muted colour either way")
    }

    do {
        // Off: the track falls back to a plain dark fill, and the
        // label stays muted.
        let idleRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xCD]),
            deviceName: "Kestrel Laptop Air",
            isSharingRealScreen: false,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil
        )
        let rows = rowViews(in: controller(rows: [idleRow]))
        let toggle: NSControl = field("toggle", of: rows[0], as: NSControl.self)
        let toggleLabel: NSTextField = field("toggleLabel", of: rows[0], as: NSTextField.self)
        let trackLayer: CALayer = field("trackLayer", of: toggle, as: CALayer.self)
        let isOn: Bool = field("isOn", of: toggle, as: Bool.self)

        expect(!isOn, "a row for a device that is not currently sharing starts its toggle off")
        expect(
            trackLayer.backgroundColor != CanvasDesign.accent.cgColor,
            "off, the track is not tinted with the accent colour -- it must read as visibly different from on"
        )
        expect(
            toggleLabel.textColor == CanvasDesign.muted.nsColor,
            "off, the Share host screen label stays muted"
        )
        expect(
            toggle.alphaValue == 1 && toggleLabel.alphaValue == 1,
            "an enabled toggle and its label are drawn at full opacity"
        )

        print("PASS: an idle row's toggle track is not accent-tinted, and its label stays muted")
    }

    do {
        // Blocked: the toggle is disabled, but a disabled control
        // drawn at full opacity reads as an enabled off switch.
        // `NSSwitch` dims a disabled control to 0.4 alpha; this
        // custom control and its label must match.
        let blockedRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xEF]),
            deviceName: "Kestrel Laptop Air",
            isSharingRealScreen: false,
            credentialSummary: "hardware-bound credential",
            blockedReason: "Pair Kestrel Laptop Air again to turn this on."
        )
        let rows = rowViews(in: controller(rows: [blockedRow]))
        let toggle: NSControl = field("toggle", of: rows[0], as: NSControl.self)
        let toggleLabel: NSTextField = field("toggleLabel", of: rows[0], as: NSTextField.self)

        expect(!toggle.isEnabled, "a blocked row's toggle cannot be turned on")
        expect(
            toggle.alphaValue == 0.4 && toggleLabel.alphaValue == 0.4,
            "a disabled toggle and its label are dimmed to 0.4 alpha, the same as NSSwitch dims a disabled switch -- "
                + "got toggle alpha \(toggle.alphaValue), label alpha \(toggleLabel.alphaValue)"
        )

        print("PASS: a blocked row's toggle and label are dimmed to 0.4 alpha, not drawn like an enabled off switch")
    }

    do {
        // "Last Screen Session" is a section header outside its card,
        // the same form "Paired machines" already uses -- not a header
        // drawn inside the card underneath it.
        let hostController = controller(rows: [])
        let pairedMachines: NSView = field("pairedMachines", of: hostController, as: NSView.self)
        let outerStack: NSStackView = field("stack", of: pairedMachines, as: NSStackView.self)
        let lastSessionCard: NSView = field("lastSessionCard", of: pairedMachines, as: NSView.self)
        let lastSessionEyebrow: NSTextField = field("lastSessionEyebrow", of: pairedMachines, as: NSTextField.self)

        expect(
            outerStack.arrangedSubviews.contains(lastSessionEyebrow),
            "the Last Screen Session eyebrow sits directly in the same top-level stack Paired machines' own eyebrow does, not nested inside the card"
        )
        expect(
            lastSessionEyebrow.superview !== lastSessionCard,
            "the eyebrow's superview is the outer stack, not the card it used to sit inside"
        )

        hostController.updateLastHostScreenSession(nil)
        expect(lastSessionCard.isHidden && lastSessionEyebrow.isHidden, "with no session ever recorded, neither the header nor the card shows")

        hostController.updateLastHostScreenSession("Kestrel Laptop Pro saw Built-in Display on 15 Nov 2023, 05:13\u{2013}05:43.")
        expect(!lastSessionCard.isHidden && !lastSessionEyebrow.isHidden, "once a session is recorded, both the header and the card show together")

        print("PASS: Last Screen Session uses the same outside-header form Paired machines already uses, shown and hidden together with its card")
    }

    do {
        // The header names what it shows: a host screen, never the
        // session canvas every session already streams by default.
        let hostController = controller(rows: [])
        let pairedMachines: NSView = field("pairedMachines", of: hostController, as: NSView.self)
        let lastSessionEyebrow: NSTextField = field("lastSessionEyebrow", of: pairedMachines, as: NSTextField.self)

        expect(
            lastSessionEyebrow.attributedStringValue.string == "LAST HOST SCREEN SESSION",
            "the header names a host screen, not just any session -- got \(lastSessionEyebrow.attributedStringValue.string)"
        )

        print("PASS: the Last Host Screen Session header names a host screen")
    }

    do {
        // The "ask me first" checkbox sits under the sharing toggle,
        // visible only while this row is sharing -- the setting means
        // nothing for a device whose session could not otherwise
        // prompt at all.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil,
            asksWhenInUse: true
        )
        let idleRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xCD]),
            deviceName: "Kestrel Laptop Air",
            isSharingRealScreen: false,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil
        )
        let sharingRows = rowViews(in: controller(rows: [sharingRow]))
        let askFirstCheckbox: NSButton = field("askFirstCheckbox", of: sharingRows[0], as: NSButton.self)
        expect(!askFirstCheckbox.isHidden, "the checkbox shows for a row that is currently sharing")
        expect(askFirstCheckbox.state == .on, "the checkbox starts checked when the armed record's own flag is on")
        expect(
            askFirstCheckbox.title == HostScreenArmingPresentation.asksWhenInUseLabel,
            "the checkbox reads the shared label constant, not a second copy of the words"
        )

        let idleRows = rowViews(in: controller(rows: [idleRow]))
        let idleCheckbox: NSButton = field("askFirstCheckbox", of: idleRows[0], as: NSButton.self)
        expect(idleCheckbox.isHidden, "the checkbox is hidden for a row that is not currently sharing")

        print("PASS: the ask-first checkbox shows only while sharing, starts from the armed record's flag, and reads the shared label")
    }

    do {
        // Toggling the checkbox reports the device key and new state
        // through its own callback, distinct from the sharing toggle's.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil,
            asksWhenInUse: false
        )
        var reported: (Data, Bool)?
        let hostController = HostSetupWindowController(
            status: HostOperatorStatus(connection: .notHosting, permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            onToggleAskFirst: { key, isOn in reported = (key, isOn) }
        )
        hostController.updatePairedMachines([sharingRow])
        let rows = rowViews(in: hostController)
        let checkbox: NSButton = field("askFirstCheckbox", of: rows[0], as: NSButton.self)
        expect(checkbox.state == .off, "the checkbox starts unchecked, matching the row's own flag, before it is clicked")
        checkbox.performClick(nil)
        expect(reported?.0 == sharingRow.devicePublicKey, "the callback names the row's own device key")
        expect(reported?.1 == true, "a click that checks the box reports its new, checked state")

        print("PASS: toggling the ask-first checkbox reports the device key and new state through its own callback")
    }
}
