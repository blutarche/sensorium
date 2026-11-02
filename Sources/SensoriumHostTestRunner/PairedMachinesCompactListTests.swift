import AppKit
import Foundation
import SensoriumHost

/// The paired machines list stays usable with many machines: one grouped
/// card, one short line per machine, its rarer actions behind a "more"
/// menu. Reads each private view with `Mirror`, the route
/// `PairedMachinesCardInsetTests` already uses.
@MainActor
func runPairedMachinesCompactListTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let longName = "Kestrel Laptop Pro Max Studio Edition North Annex Workstation"

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    struct Reports {
        var sharing: [(Data, Bool)] = []
        var removed: [Data] = []
        var askFirst: [(Data, Bool)] = []
        var renamePrompts: [String] = []
    }

    final class Box { var reports = Reports() }

    func controller(_ rows: [HostScreenArmingPresentation.PairedMachineRow], box: Box = Box()) -> HostSetupWindowController {
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { key, isOn in box.reports.sharing.append((key, isOn)) },
            onRemovePairedDevice: { key in box.reports.removed.append(key) },
            onToggleAskFirst: { key, isOn in box.reports.askFirst.append((key, isOn)) },
            presentRenamePrompt: { _, currentName, _ in box.reports.renamePrompts.append(currentName) }
        )
        controller.updatePairedMachines(rows)
        field("window", of: controller, as: NSWindow.self).contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    func rowViews(of host: HostSetupWindowController) -> [NSView] {
        let section: NSView = field("pairedMachines", of: host, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: section, as: NSStackView.self)
        return rowsStack.arrangedSubviews
    }

    func row(
        _ index: Int,
        name: String? = nil,
        sharing: Bool = false,
        asksWhenInUse: Bool = false
    ) -> HostScreenArmingPresentation.PairedMachineRow {
        HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([UInt8(index), 0xAB]),
            deviceName: name ?? "Heron Desktop \(index + 1)",
            keyFingerprintLine: "Key AB00000\(index % 10)",
            isSharingRealScreen: sharing,
            sharedDisplaysLine: sharing ? "May share Built-in Display." : nil,
            sharedDisplayLabels: sharing ? ["Built-in Display"] : [],
            asksWhenInUse: asksWhenInUse
        )
    }

    let tenRows = (0..<10).map { row($0, sharing: $0.isMultiple(of: 2)) }

    do {
        // Ten machines take no more than ten short lines and the heading.
        let host = controller(tenRows)
        let section: NSView = field("pairedMachines", of: host, as: NSView.self)
        let eyebrow: NSView = field("eyebrow", of: section, as: NSView.self)
        let budget = 10 * 52 + eyebrow.frame.height + CanvasDesign.Space.xs
        expect(
            section.frame.height <= budget,
            "ten paired machines fit in \(budget)pt, heading included -- the section is \(section.frame.height)pt"
        )
        print("PASS: ten paired machines take at most ten short lines and the heading")
    }

    do {
        // Each machine is one row of its own, at most 52pt tall, and every
        // row sits inside the one card that groups them.
        let host = controller(tenRows)
        let rows = rowViews(of: host)
        let section: NSView = field("pairedMachines", of: host, as: NSView.self)
        let card: NSStackView = field("rowsStack", of: section, as: NSStackView.self)
        expect(rows.count == 10, "one row per paired machine -- got \(rows.count)")
        expect(
            rows.allSatisfy { $0.frame.height > 0 && $0.frame.height <= 52 },
            "every row is at most 52pt tall -- got \(rows.map(\.frame.height))"
        )
        expect(card.spacing == 0, "rows meet edge to edge inside the card, parted by hairlines, not by gaps")
        expect(
            card.layer?.cornerRadius == CanvasDesign.Radius.base
                && card.layer?.backgroundColor == CanvasDesign.bg2.cgColor
                && (card.layer?.borderWidth ?? 0) == 0 && (card.layer?.shadowOpacity ?? 0) == 0,
            "the rows share one flat bg2 card with the base radius, no border and no shadow"
        )
        let rowFills = rows.compactMap { $0.layer?.backgroundColor }
        expect(rowFills.isEmpty, "no row draws a card of its own -- \(rowFills.count) rows have a fill")
        let separators = rows.map { field("separator", of: $0, as: NSView.self) }
        expect(separators[0].isHidden, "the first row has no hairline above it")
        expect(
            separators.dropFirst().allSatisfy { !$0.isHidden && $0.frame.height == 1 },
            "every later row has a 1pt hairline above it -- got \(separators.map(\.frame.height))"
        )
        expect(
            separators.dropFirst().allSatisfy {
                abs($0.frame.minX - CanvasDesign.Space.md) < 0.5 && abs($0.frame.maxX - card.bounds.width) < 0.5
            },
            "each hairline starts at the text's inset and runs to the card's trailing edge -- got \(separators.map(\.frame))"
        )
        print("PASS: each paired machine is one short row inside one grouped card, parted by inset hairlines")
    }

    do {
        // The row reads its machine's name over one muted line: what it may
        // share while it shares, and that sharing is off when it does not.
        let rows = rowViews(of: controller([row(0, sharing: true), row(1)]))
        let sharingName: NSTextField = field("nameLabel", of: rows[0], as: NSTextField.self)
        let sharingSubtitle: NSTextField = field("subtitleLabel", of: rows[0], as: NSTextField.self)
        let idleSubtitle: NSTextField = field("subtitleLabel", of: rows[1], as: NSTextField.self)
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: HostTextFlow.noBreakSpace, with: " ")
                .replacingOccurrences(of: HostTextFlow.nonBreakingHyphen, with: "-")
        }
        expect(sharingName.stringValue == "Heron Desktop 1", "the row shows the machine's name -- got \(sharingName.stringValue)")
        expect(
            plain(sharingSubtitle.stringValue) == "May share Built-in Display",
            "a sharing row says what it may share, without the closing full stop -- got \(sharingSubtitle.stringValue)"
        )
        expect(
            idleSubtitle.stringValue == "Host screen sharing off",
            "a row that is not sharing says so -- got \(idleSubtitle.stringValue)"
        )
        expect(
            sharingName.textColor == CanvasDesign.ink.nsColor && sharingSubtitle.textColor == CanvasDesign.muted.nsColor
                && idleSubtitle.textColor == CanvasDesign.muted.nsColor,
            "the name reads in ink, the line under it in muted"
        )
        print("PASS: a row shows the machine's name over what it may share, or that sharing is off")
    }

    do {
        // The more button opens the row's rarer actions, in this order.
        let box = Box()
        let sharing = row(0, name: "Kestrel Laptop Pro", sharing: true, asksWhenInUse: true)
        let idle = row(1, name: "Heron Desktop")
        let rows = rowViews(of: controller([sharing, idle], box: box))
        let more: NSButton = field("moreButton", of: rows[0], as: NSButton.self)
        let menu: NSMenu = field("actionsMenu", of: rows[0], as: NSMenu.self)
        expect(
            more.accessibilityLabel() == "More actions for Kestrel Laptop Pro",
            "the more button names its machine for VoiceOver -- got \(String(describing: more.accessibilityLabel()))"
        )
        expect(more.frame.size == NSSize(width: 24, height: 24), "the more button is 24pt square -- got \(more.frame.size)")
        expect(
            menu.items.map(\.title) == [
                "Rename\u{2026}", HostScreenArmingPresentation.asksWhenInUseLabel, "Key AB000000", "", "Remove"
            ] && menu.items[3].isSeparatorItem,
            "the menu reads Rename, ask first, the key, a separator, Remove -- got \(menu.items.map(\.title))"
        )
        expect(!menu.autoenablesItems, "the menu's enabled states are the row's own, not AppKit's guess")
        expect(menu.items[0].isEnabled && menu.items[4].isEnabled, "Rename and Remove are always offered")
        expect(menu.items[1].isEnabled && menu.items[1].state == .on, "ask first is offered while sharing, checked from the row's flag")
        expect(!menu.items[2].isEnabled, "the key line is information, not an action")
        var range = NSRange()
        let removeInk = menu.items[4].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor
        expect(removeInk == CanvasDesign.bad.nsColor, "Remove reads in the design system's bad colour")

        menu.performActionForItem(at: 0)
        expect(box.reports.renamePrompts == ["Kestrel Laptop Pro"], "Rename asks for a new name for this row's machine")
        menu.performActionForItem(at: 1)
        expect(
            box.reports.askFirst.count == 1 && box.reports.askFirst[0].0 == sharing.devicePublicKey
                && box.reports.askFirst[0].1 == false,
            "choosing ask first reports this row's key and the opposite of its current flag"
        )
        menu.performActionForItem(at: 4)
        expect(box.reports.removed == [sharing.devicePublicKey], "Remove reports this row's key")

        let idleMenu: NSMenu = field("actionsMenu", of: rows[1], as: NSMenu.self)
        let idleAskFirst = idleMenu.items.first { $0.title == HostScreenArmingPresentation.asksWhenInUseLabel }
        expect(
            idleAskFirst?.isEnabled == false && idleAskFirst?.state == .off,
            "ask first is not offered for a row that is not sharing"
        )
        print("PASS: the more menu holds Rename, ask first, the key and Remove, each for its own machine")
    }

    do {
        // A row with no key line leaves the key item out of its menu.
        let bare = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0x01]), deviceName: "Heron Desktop", isSharingRealScreen: false
        )
        let menu: NSMenu = field("actionsMenu", of: rowViews(of: controller([bare]))[0], as: NSMenu.self)
        expect(
            menu.items.map(\.title) == ["Rename\u{2026}", HostScreenArmingPresentation.asksWhenInUseLabel, "", "Remove"],
            "with no key to show, the menu has no key item -- got \(menu.items.map(\.title))"
        )
        print("PASS: a row with no key line shows no key item")
    }

    do {
        // The switch still turns sharing on and off for its own machine.
        let box = Box()
        let target = row(1)
        let rows = rowViews(of: controller([row(0, sharing: true), target], box: box))
        let toggle: NSControl = field("toggle", of: rows[1], as: NSControl.self)
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            expect(false, "AppKit made no mouse event to click with")
            return
        }
        toggle.mouseDown(with: click)
        expect(
            box.reports.sharing.count == 1 && box.reports.sharing[0].0 == target.devicePublicKey
                && box.reports.sharing[0].1 == true,
            "clicking an off switch turns sharing on for that row's machine -- got \(box.reports.sharing)"
        )
        print("PASS: a row's switch reports its own machine and the new state")
    }

    do {
        // A very long name truncates on one line before the switch, and the
        // switch and the more button stay inside the card.
        let host = controller([row(0, name: longName, sharing: true)])
        let rowView = rowViews(of: host)[0]
        let name: NSTextField = field("nameLabel", of: rowView, as: NSTextField.self)
        let subtitle: NSTextField = field("subtitleLabel", of: rowView, as: NSTextField.self)
        let toggle: NSControl = field("toggle", of: rowView, as: NSControl.self)
        let more: NSButton = field("moreButton", of: rowView, as: NSButton.self)
        let section: NSView = field("pairedMachines", of: host, as: NSView.self)
        let card: NSView = field("rowsStack", of: section, as: NSView.self)
        func frame(of view: NSView) -> NSRect { rowView.convert(view.bounds, from: view) }
        let oneLine = (name.font?.boundingRectForFont.height ?? 0) * 1.5
        expect(
            name.lineBreakMode == .byTruncatingTail && name.maximumNumberOfLines == 1 && name.frame.height < oneLine,
            "a long name truncates on one line -- frame \(name.frame)"
        )
        expect(
            frame(of: name).maxX <= frame(of: toggle).minX && frame(of: subtitle).maxX <= frame(of: toggle).minX,
            "neither text line reaches the switch -- name \(frame(of: name)), subtitle \(frame(of: subtitle)), switch \(frame(of: toggle))"
        )
        expect(
            frame(of: toggle).maxX <= frame(of: more).minX && frame(of: more).maxX <= rowView.bounds.width + 0.5,
            "the switch sits before the more button, both inside the row -- switch \(frame(of: toggle)), more \(frame(of: more))"
        )
        let cardFrame = section.convert(card.bounds, from: card)
        let rowInCard = card.convert(rowView.bounds, from: rowView)
        expect(
            abs(rowInCard.width - card.bounds.width) < 0.5 && cardFrame.maxX <= section.bounds.width + 0.5,
            "the row fills the card and the card stays inside the window's column -- row \(rowInCard), card \(cardFrame)"
        )
        expect(
            abs(frame(of: toggle).midY - rowView.bounds.midY) < 0.5 && abs(frame(of: more).midY - rowView.bounds.midY) < 0.5,
            "the switch and the more button are centred on the row"
        )
        print("PASS: a long machine name truncates before the switch, and the controls stay inside the card")
    }
}
