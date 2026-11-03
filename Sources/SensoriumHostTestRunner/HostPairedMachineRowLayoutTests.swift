import AppKit
import Foundation
import SensoriumHost

/// How the paired machines section lays out: each row's text against its
/// controls, and the gaps between the section's parts.
/// Reads each private view with `Mirror`, the route
/// `PairedMachinesCardInsetTests` already uses.
@MainActor
func runHostPairedMachineRowLayoutTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    func controller(
        status: HostOperatorStatus? = nil,
        rows: [HostScreenArmingPresentation.PairedMachineRow]
    ) -> HostSetupWindowController {
        let controller = HostSetupWindowController(
            status: status ?? HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        controller.updatePairedMachines(rows)
        return controller
    }

    func row(_ name: String, sharing: Bool = false) -> HostScreenArmingPresentation.PairedMachineRow {
        HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: name,
            keyFingerprintLine: "Key AB000000",
            isSharingRealScreen: sharing
        )
    }

    func firstRow(of host: HostSetupWindowController) -> NSView {
        let pairedMachines: NSView = field("pairedMachines", of: host, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: pairedMachines, as: NSStackView.self)
        return rowsStack.arrangedSubviews[0]
    }

    do {
        // The name and the line under it are centred on the switch and the
        // more button, all on the row's own middle.
        let host = controller(rows: [row("Kestrel Laptop")])
        field("window", of: host, as: NSWindow.self).contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let text: NSView = field("stack", of: rowView, as: NSStackView.self)
        let toggle: NSControl = field("toggle", of: rowView, as: NSControl.self)
        let more: NSButton = field("moreButton", of: rowView, as: NSButton.self)
        // One device pixel: a 1x screen snaps the stack to whole points.
        let pixel = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        let bound = max(0.5, pixel)
        expect(
            abs(text.frame.midY - toggle.frame.midY) <= bound && abs(toggle.frame.midY - more.frame.midY) <= bound,
            "the machine's text is centred on its switch and more button -- text \(text.frame), switch \(toggle.frame), "
                + "more \(more.frame)"
        )
        print("PASS: a paired machine's text is centred on its switch and more button")
    }

    do {
        // Inset like every sibling card, a row still holds its widest content
        // inside the card: a long name truncates on one line before the
        // switch rather than running under it, and the more button stays
        // inside the card's trailing edge.
        let longName = "Kestrel Laptop Pro Max Studio Edition North Annex Workstation"
        let host = controller(rows: [row(longName, sharing: true)])
        field("window", of: host, as: NSWindow.self).contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let name: NSTextField = field("nameLabel", of: rowView, as: NSTextField.self)
        let toggle: NSControl = field("toggle", of: rowView, as: NSControl.self)
        let more: NSButton = field("moreButton", of: rowView, as: NSButton.self)
        func frame(of view: NSView) -> NSRect {
            rowView.convert(view.bounds, from: view)
        }
        expect(
            frame(of: name).maxX <= frame(of: toggle).minX
                && name.frame.height < (name.font?.boundingRectForFont.height ?? 0) * 1.5,
            "a long name stays on one line before it reaches the switch -- name \(frame(of: name)), switch \(frame(of: toggle))"
        )
        expect(
            frame(of: more).maxX <= rowView.bounds.width - CanvasDesign.Space.xs + 0.5,
            "the more button stays inside the card's trailing inset in a \(rowView.bounds.width)pt-wide row"
                + " -- more \(frame(of: more))"
        )
        print("PASS: a paired machine's long name and controls stay inside the card's inset")
    }

    do {
        // The line under a sharing machine says what its display list is
        // ("May share"), and the key fingerprint sits in the row's menu.
        let key = Data([0xEE, 0x47, 0x92, 0xC1])
        let mainDisplay = DisplaySnapshot(
            id: 1, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            online: true, builtin: true, main: true, vendorNumber: 0x01, modelNumber: 0x01
        )
        let leftDisplay = DisplaySnapshot(
            id: 2, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x02, modelNumber: 0x02
        )
        let rightDisplay = DisplaySnapshot(
            id: 3, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x03, modelNumber: 0x03
        )
        let rows = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(key, "Kestrel Laptop")],
            arming: HostScreenArming(devices: [
                HostScreenDeviceArming(devicePublicKey: key, deviceName: "Kestrel Laptop", armedAt: Date())
            ]),
            activeDisplays: [mainDisplay, leftDisplay, rightDisplay]
        )
        let rowView = firstRow(of: controller(rows: rows))
        let subtitle: NSTextField = field("subtitleLabel", of: rowView, as: NSTextField.self)
        let menu: NSMenu = field("actionsMenu", of: rowView, as: NSMenu.self)
        expect(
            subtitle.stringValue == "May share Built-in Display, External Display (left), and External Display (right)",
            "the line reads May share and the displays, without the closing full stop -- got \(subtitle.stringValue)"
        )
        expect(
            menu.items.contains { $0.title == "Key EE4792C1" },
            "the key moves to the row's menu -- got \(menu.items.map(\.title))"
        )
        print("PASS: a paired machine's display line keeps May share, and its key is in the row's menu")
    }

    do {
        // In a narrower window the row keeps its height: the name truncates
        // further and the controls stay inside the card.
        let host = controller(rows: [row("Kestrel Laptop Pro Max Studio Edition", sharing: true)])
        let root: NSStackView = field("root", of: host, as: NSStackView.self)
        let window: NSWindow = field("window", of: host, as: NSWindow.self)
        guard let widthConstraint = root.constraints.first(where: {
            $0.firstItem === root && $0.firstAttribute == .width && $0.secondItem == nil
        }) else {
            expect(false, "the window's content has no fixed width to narrow")
            return
        }
        widthConstraint.constant = 240
        window.contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let name: NSTextField = field("nameLabel", of: rowView, as: NSTextField.self)
        let toggle: NSControl = field("toggle", of: rowView, as: NSControl.self)
        let more: NSButton = field("moreButton", of: rowView, as: NSButton.self)
        func frame(of view: NSView) -> NSRect {
            rowView.convert(view.bounds, from: view)
        }
        expect(
            rowView.bounds.height <= 52 && frame(of: name).maxX <= frame(of: toggle).minX
                && frame(of: more).maxX <= rowView.bounds.width + 0.5,
            "in a card \(rowView.bounds.width)pt wide the row stays \(rowView.bounds.height)pt tall, the name ends before"
                + " the switch and the more button stays inside -- name \(frame(of: name)), more \(frame(of: more))"
        )
        print("PASS: a narrow card keeps the row short and its controls inside")
    }

    do {
        // One gap between the sections of the window, whichever follows the
        // machines.
        let section: NSView = field("pairedMachines", of: controller(rows: []), as: NSView.self)
        let stack: NSStackView = field("stack", of: section, as: NSStackView.self)
        let rows: NSView = field("rowsStack", of: section, as: NSView.self)
        let emptySubtext: NSView = field("emptySubtext", of: section, as: NSView.self)
        expect(
            stack.customSpacing(after: rows) == CanvasDesign.Space.lg
                && stack.customSpacing(after: emptySubtext) == CanvasDesign.Space.lg,
            "the gap above Last Host Screen Session is the window's section gap, after the rows and after the "
                + "empty state alike -- got \(stack.customSpacing(after: rows)) and "
                + "\(stack.customSpacing(after: emptySubtext))"
        )
        print("PASS: the gap above the last session is the window's section gap")
    }

    do {
        // A pairing finishing is already said by the status card, so the
        // section says nothing, its heading included, until it ends.
        let finishing = HostOperatorStatus(connection: .pairingApproved(deviceName: "Kestrel Laptop"), permissions: granted)
        let host = controller(status: finishing, rows: [])
        let section: NSView = field("pairedMachines", of: host, as: NSView.self)
        let heading: NSTextField = field("emptyHeading", of: section, as: NSTextField.self)
        let subtext: NSTextField = field("emptySubtext", of: section, as: NSTextField.self)
        let eyebrow: NSTextField = field("eyebrow", of: section, as: NSTextField.self)
        expect(
            heading.isHidden && subtext.isHidden && eyebrow.isHidden,
            "while a pairing finishes the section is empty -- heading hidden \(heading.isHidden), "
                + "subtext hidden \(subtext.isHidden), eyebrow hidden \(eyebrow.isHidden)"
        )
        // With nothing in it the section also takes no room, so the window's
        // section gap is not paid twice around it.
        expect(section.isHidden, "a section with nothing to show is hidden, not an empty view between two gaps")
        host.updateLastHostScreenSession("Kestrel Laptop used Built-in Display from 15 Nov 2023, 05:13 to 05:43.")
        expect(!section.isHidden, "a last session to show brings the section back")
        host.updateLastHostScreenSession(nil)
        expect(section.isHidden, "and taking it away hides the section again")
        host.update(HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted))
        expect(
            !section.isHidden && !heading.isHidden && !subtext.isHidden && !eyebrow.isHidden,
            "once the pairing has ended with no machine paired, the empty state and its heading are back"
        )
        print("PASS: the empty state stays hidden only while a pairing finishes")
    }
}
