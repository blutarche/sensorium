import AppKit
import Foundation
import SensoriumHost

/// How the paired machines section lays out: each row's name against its
/// buttons, the ink of its labels, and the gaps between the section's parts.
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
        // The name's middle is the buttons' middle.
        let host = controller(rows: [row("Kestrel Laptop")])
        let rowView = firstRow(of: host)
        let name: NSTextField = field("nameLabel", of: rowView, as: NSTextField.self)
        let rename: NSButton = field("renameButton", of: rowView, as: NSButton.self)
        let remove: NSButton = field("removeButton", of: rowView, as: NSButton.self)
        expect(
            abs(name.frame.midY - rename.frame.midY) < 0.5 && abs(rename.frame.midY - remove.frame.midY) < 0.5,
            "the machine name is centred on Rename and Remove -- name \(name.frame), Rename \(rename.frame), "
                + "Remove \(remove.frame)"
        )
        print("PASS: a paired machine's name is centred on its Rename and Remove buttons")
    }

    do {
        // Inset like every sibling card, a row still holds its widest content
        // inside the card: a long name wraps beside Rename and Remove rather
        // than running under them, and the ask-first checkbox and the key
        // line stay inside the card's trailing inset.
        let longName = "Kestrel Laptop Pro Max Studio Edition North Annex Workstation"
        let host = controller(rows: [row(longName, sharing: true)])
        field("window", of: host, as: NSWindow.self).contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let name: NSTextField = field("nameLabel", of: rowView, as: NSTextField.self)
        let rename: NSButton = field("renameButton", of: rowView, as: NSButton.self)
        let remove: NSButton = field("removeButton", of: rowView, as: NSButton.self)
        let askFirst: NSButton = field("askFirstCheckbox", of: rowView, as: NSButton.self)
        let meta: NSTextField = field("metaLabel", of: rowView, as: NSTextField.self)
        let trailingLimit = rowView.bounds.width - CanvasDesign.Space.md + 0.5
        func rightEdge(of view: NSView) -> CGFloat {
            rowView.convert(view.bounds, from: view).maxX
        }
        expect(
            name.frame.maxX <= rename.frame.minX && name.frame.height > (name.font?.boundingRectForFont.height ?? 0) * 1.5,
            "a long name wraps before it reaches Rename -- name \(name.frame), Rename \(rename.frame)"
        )
        expect(
            rightEdge(of: remove) <= trailingLimit && rightEdge(of: askFirst) <= trailingLimit
                && rightEdge(of: meta) <= trailingLimit,
            "the row's widest content stays inside the card's 16pt trailing inset in a \(rowView.bounds.width)pt-wide row"
                + " -- Remove \(rightEdge(of: remove)), checkbox \(rightEdge(of: askFirst)), key line \(rightEdge(of: meta))"
        )
        print("PASS: a paired machine's long name and controls stay inside the card's inset")
    }

    do {
        // The label of a switch that is on reads as live, in the same ink as
        // the checkbox under it.
        let host = controller(rows: [row("Kestrel Laptop", sharing: true)])
        let rowView = firstRow(of: host)
        let label: NSTextField = field("toggleLabel", of: rowView, as: NSTextField.self)
        let askFirst: NSButton = field("askFirstCheckbox", of: rowView, as: NSButton.self)
        var range = NSRange()
        let askFirstInk = askFirst.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor
        expect(
            label.textColor == CanvasDesign.ink.nsColor && askFirstInk == CanvasDesign.ink.nsColor,
            "Share host screen and Ask me first read in the same ink -- label \(String(describing: label.textColor)), "
                + "checkbox \(String(describing: askFirstInk))"
        )
        print("PASS: Share host screen reads in the same ink as the ask-first checkbox")
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
