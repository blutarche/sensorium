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
        // The line under a sharing machine says what its display list is
        // ("May share"), and keeps each display name on one line whatever
        // the width: a break may fall between names, never inside one.
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
        let meta: NSTextField = field("metaLabel", of: rowView, as: NSTextField.self)
        let shown = meta.stringValue
        let labels = ["Built-in Display", "External Display (left)", "External Display (right)"]
        let plainText = shown
            .replacingOccurrences(of: HostTextFlow.noBreakSpace, with: " ")
            .replacingOccurrences(of: HostTextFlow.nonBreakingHyphen, with: "-")
        expect(
            plainText == "Key EE4792C1 \u{00B7} May share Built-in Display, External Display (left), and External Display (right)",
            "the line reads the key, then May share and the displays, without the closing full stop -- got \(plainText)"
        )
        expect(
            labels.allSatisfy { shown.contains(HostTextFlow.whole($0)) },
            "every display name is held whole, so no line break can fall inside one -- got \(shown.debugDescription)"
        )
        print("PASS: a paired machine's display line keeps May share and never splits a display name")
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
        // The ask-first checkbox belongs to Share host screen, so its box
        // starts where that label's text does, not at the card's own inset.
        // Measured on the drawn row: the first column of ink in each, since a
        // frame says nothing about the padding a control draws inside it.
        let host = controller(rows: [row("Kestrel Laptop", sharing: true)])
        field("window", of: host, as: NSWindow.self).contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let label: NSTextField = field("toggleLabel", of: rowView, as: NSTextField.self)
        let askFirst: NSButton = field("askFirstCheckbox", of: rowView, as: NSButton.self)
        guard let rep = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else {
            expect(false, "AppKit gave no bitmap to measure the row in")
            return
        }
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        let pixelsPerPoint = CGFloat(rep.pixelsWide) / rowView.bounds.width
        let background = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)

        /// The left edge, in points from the row's own left edge, of the first
        /// column inside `frame` that is not the card's fill.
        func firstInk(in frame: NSRect) -> CGFloat? {
            guard let background else { return nil }
            let top = Int(((rowView.bounds.height - frame.maxY) * pixelsPerPoint).rounded(.down))
            let bottom = Int(((rowView.bounds.height - frame.minY) * pixelsPerPoint).rounded(.up))
            let first = Int((frame.minX * pixelsPerPoint).rounded(.down))
            let last = min(rep.pixelsWide - 1, Int((frame.maxX * pixelsPerPoint).rounded(.up)))
            for x in first...last {
                for y in max(0, top)..<min(rep.pixelsHigh, bottom) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let difference = abs(color.redComponent - background.redComponent)
                        + abs(color.greenComponent - background.greenComponent)
                        + abs(color.blueComponent - background.blueComponent)
                    if difference > 0.3 {
                        return CGFloat(x) / pixelsPerPoint
                    }
                }
            }
            return nil
        }

        let labelFrame = rowView.convert(label.bounds, from: label)
        let checkboxFrame = rowView.convert(askFirst.bounds, from: askFirst)
        if let labelInk = firstInk(in: labelFrame), let boxInk = firstInk(in: checkboxFrame) {
            expect(
                abs(labelInk - boxInk) <= 1,
                "the checkbox's box starts where the Share host screen text does -- text at \(labelInk), box at \(boxInk), "
                    + "label frame \(labelFrame), checkbox frame \(checkboxFrame)"
            )
        } else {
            expect(false, "no ink found to measure -- label frame \(labelFrame), checkbox frame \(checkboxFrame)")
        }
        print("PASS: the ask-first checkbox sits under the Share host screen text")
    }

    do {
        // Indented under the label, the checkbox's title still wraps inside the
        // card when the card is too narrow for it on one line.
        let host = controller(rows: [row("Kestrel Laptop", sharing: true)])
        let root: NSStackView = field("root", of: host, as: NSStackView.self)
        let window: NSWindow = field("window", of: host, as: NSWindow.self)
        guard let widthConstraint = root.constraints.first(where: {
            $0.firstItem === root && $0.firstAttribute == .width && $0.secondItem == nil
        }) else {
            expect(false, "the window's content has no fixed width to narrow")
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let rowView = firstRow(of: host)
        let askFirst: NSButton = field("askFirstCheckbox", of: rowView, as: NSButton.self)
        let oneLine = askFirst.frame.height
        widthConstraint.constant = 240
        window.contentView?.layoutSubtreeIfNeeded()
        let frame = rowView.convert(askFirst.bounds, from: askFirst)
        expect(
            frame.maxX <= rowView.bounds.width - CanvasDesign.Space.md + 0.5 && frame.height > oneLine * 1.5,
            "in a card \(rowView.bounds.width)pt wide the checkbox wraps to a second line inside the card's trailing inset"
                + " -- frame \(frame), one line is \(oneLine)pt"
        )
        print("PASS: the ask-first checkbox wraps inside a narrow card")
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
