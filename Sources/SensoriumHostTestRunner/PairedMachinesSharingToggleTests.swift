import AppKit
import Foundation
import SensoriumHost

/// The Paired machines row's own Share host screen toggle: on must read as on
/// from colour alone, not from `NSColor.controlAccentColor` -- a person can
/// set that to Graphite, at which point a system-drawn `NSSwitch`'s on and
/// off tracks are both the same grey. `Mirror` reaches every field here
/// (`pairedMachines`, `toggle`, `actionsMenu`), the same past-`private`,
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
        // preference. The name keeps one colour regardless of on
        // or off -- the switch itself already carries the state.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true

        )
        let rows = rowViews(in: controller(rows: [sharingRow]))
        expect(rows.count == 1, "one row for one paired machine")
        let toggle: NSControl = field("toggle", of: rows[0], as: NSControl.self)
        let nameLabel: NSTextField = field("nameLabel", of: rows[0], as: NSTextField.self)
        let trackLayer: CALayer = field("trackLayer", of: toggle, as: CALayer.self)
        let isOn: Bool = field("isOn", of: toggle, as: Bool.self)

        expect(isOn, "a row for a device that is currently sharing starts its toggle on")
        expect(
            trackLayer.backgroundColor == CanvasDesign.accent.cgColor,
            "on, the track is tinted with this app's own accent colour, not left to NSColor.controlAccentColor -- which a person can set to Graphite, making on and off the same grey"
        )
        expect(
            nameLabel.textColor == CanvasDesign.ink.nsColor,
            "on, the machine's name reads in ink -- one name colour regardless of state"
        )
        expect(
            toggle.alphaValue == 1 && nameLabel.alphaValue == 1,
            "an enabled toggle and the name beside it are drawn at full opacity"
        )

        print("PASS: a sharing row's toggle takes the app accent, and its name stays the same ink either way")
    }

    do {
        // Off: the track falls back to a plain dark fill, and the
        // name stays in ink.
        let idleRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xCD]),
            deviceName: "Kestrel Laptop Air",
            isSharingRealScreen: false
        )
        let rows = rowViews(in: controller(rows: [idleRow]))
        let toggle: NSControl = field("toggle", of: rows[0], as: NSControl.self)
        let nameLabel: NSTextField = field("nameLabel", of: rows[0], as: NSTextField.self)
        let trackLayer: CALayer = field("trackLayer", of: toggle, as: CALayer.self)
        let isOn: Bool = field("isOn", of: toggle, as: Bool.self)

        expect(!isOn, "a row for a device that is not currently sharing starts its toggle off")
        expect(
            trackLayer.backgroundColor != CanvasDesign.accent.cgColor,
            "off, the track is not tinted with the accent colour -- it must read as visibly different from on"
        )
        expect(
            nameLabel.textColor == CanvasDesign.ink.nsColor,
            "off, the machine's name stays in ink"
        )
        expect(
            toggle.alphaValue == 1 && nameLabel.alphaValue == 1,
            "an enabled toggle and the name beside it are drawn at full opacity"
        )

        print("PASS: an idle row's toggle track is not accent-tinted, and its name stays in ink")
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
        // The "ask me first" item in the row's menu is offered only while
        // this row is sharing -- the setting means nothing for a device
        // whose session could not otherwise prompt at all.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true,
            asksWhenInUse: true
        )
        let idleRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xCD]),
            deviceName: "Kestrel Laptop Air",
            isSharingRealScreen: false
        )
        func askFirstItem(in row: NSView) -> NSMenuItem? {
            let menu: NSMenu = field("actionsMenu", of: row, as: NSMenu.self)
            return menu.items.first { $0.action != nil && $0.title == HostScreenArmingPresentation.asksWhenInUseLabel }
        }
        let sharingRows = rowViews(in: controller(rows: [sharingRow]))
        let askFirst = askFirstItem(in: sharingRows[0])
        expect(askFirst?.isEnabled == true, "ask first is offered for a row that is currently sharing")
        expect(askFirst?.state == .on, "ask first starts checked when the armed record's own flag is on")
        expect(
            askFirst?.title == HostScreenArmingPresentation.asksWhenInUseLabel,
            "the item reads the shared label constant, not a second copy of the words"
        )

        let idleRows = rowViews(in: controller(rows: [idleRow]))
        expect(askFirstItem(in: idleRows[0])?.isEnabled == false, "ask first is not offered for a row that is not sharing")

        print("PASS: ask first is offered only while sharing, starts from the armed record's flag, and reads the shared label")
    }

    do {
        // Choosing ask first reports the device key and new state
        // through its own callback, distinct from the sharing toggle's.
        let sharingRow = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel Laptop Pro",
            isSharingRealScreen: true,
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
        let menu: NSMenu = field("actionsMenu", of: rows[0], as: NSMenu.self)
        guard let index = menu.items.firstIndex(where: { $0.title == HostScreenArmingPresentation.asksWhenInUseLabel }) else {
            expect(false, "the row's menu has no ask-first item -- got \(menu.items.map(\.title))")
            return
        }
        expect(menu.items[index].state == .off, "the item starts unchecked, matching the row's own flag, before it is chosen")
        menu.performActionForItem(at: index)
        expect(reported?.0 == sharingRow.devicePublicKey, "the callback names the row's own device key")
        expect(reported?.1 == true, "choosing an unchecked item reports its new, checked state")

        print("PASS: choosing ask first reports the device key and new state through its own callback")
    }
}
