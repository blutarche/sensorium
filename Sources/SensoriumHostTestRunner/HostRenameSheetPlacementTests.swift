import AppKit
import Foundation
import SensoriumHost

/// The rename sheet drops from the top of the host window and covers
/// whatever is beneath it. Its bottom edge must fall in the gap between two
/// rows, never across one, and the window behind it must read as inactive.
@MainActor
func runHostRenameSheetPlacementTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    func controller(rows: Int) -> HostSetupWindowController {
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        controller.updatePairedMachines((0..<rows).map { index in
            HostScreenArmingPresentation.PairedMachineRow(
                devicePublicKey: Data([UInt8(index)]),
                deviceName: "Kestrel Laptop \(index + 1)",
                isSharingRealScreen: index == 0,
                sharedDisplaysLine: index == 0 ? "May share Built-in Display." : nil
            )
        })
        return controller
    }

    /// Every view a sheet's bottom edge must not cut: each direct section of
    /// the window's column and each paired-machine row, as the distance of its
    /// top and bottom from the top of the window's content.
    func rowSpans(of controller: HostSetupWindowController) -> [(top: CGFloat, bottom: CGFloat)] {
        let window = field("window", of: controller, as: NSWindow.self)
        guard let content = window.contentView else { fatalError("the host window has no content view") }
        content.layoutSubtreeIfNeeded()
        let root = field("root", of: controller, as: NSStackView.self)
        var views = root.arrangedSubviews.filter {
            !$0.isHidden && String(describing: Swift.type(of: $0)) != "PairedMachinesView"
        }
        func collectRows(in view: NSView) {
            for child in view.subviews {
                if String(describing: Swift.type(of: child)) == "PairedMachineRowView" {
                    views.append(child)
                } else {
                    collectRows(in: child)
                }
            }
        }
        collectRows(in: content)
        // The section's own heading, empty state and last-session card.
        let section = field("pairedMachines", of: controller, as: NSView.self)
        let sectionColumn = field("stack", of: section, as: NSStackView.self)
        let rowsColumn = field("rowsStack", of: section, as: NSStackView.self)
        views += sectionColumn.arrangedSubviews.filter { $0 !== rowsColumn }
        return views.filter { !$0.isHidden }.map { view in
            let frame = content.convert(view.bounds, from: view)
            return (content.bounds.height - frame.maxY, content.bounds.height - frame.minY)
        }
    }

    do {
        // The height a sheet reports before layout is the height it keeps
        // after it: a wrapping hint that measures one line first and two
        // later would push the sheet's bottom edge past the gap picked for it.
        // A long name wraps the heading to a second line, and the sheet must
        // report that line before layout too.
        let longName = "Kestrel Laptop Pro Max Studio Edition North Annex Workstation"
        for name in ["Kestrel Laptop", longName] {
            for minimum: CGFloat in [0, 260] {
                let sheet = PairedMachineRenameView(
                    currentName: name, minimumHeight: minimum, onRename: { _ in }, onCancel: {}
                )
                let reported = sheet.fittingSize
                sheet.frame = NSRect(origin: .zero, size: reported)
                sheet.layoutSubtreeIfNeeded()
                expect(
                    abs(sheet.frame.height - reported.height) < 0.5,
                    "a sheet reporting \(reported.height) must stay that tall once laid out, got \(sheet.frame.height)"
                )
            }
        }
        print("PASS: the rename view keeps the height it reports")
    }

    do {
        // The height the host picks a gap for is the height of the sheet it
        // will show: the one for a name that wraps is taller than the one for a
        // name that does not.
        let short = PairedMachineRenameView.naturalHeight(currentName: "Kestrel Laptop")
        let long = PairedMachineRenameView.naturalHeight(
            currentName: "Kestrel Laptop Pro Max Studio Edition North Annex Workstation"
        )
        expect(long > short, "a heading that wraps makes the sheet taller -- one line \(short), wrapped \(long)")
        let shown = PairedMachineRenameView(
            currentName: "Kestrel Laptop Pro Max Studio Edition North Annex Workstation",
            onRename: { _ in },
            onCancel: {}
        )
        expect(
            abs(shown.fittingSize.height - long) < 0.5,
            "the natural height for a name is the height its own sheet reports -- \(long) against \(shown.fittingSize.height)"
        )
        print("PASS: the rename sheet's natural height follows its heading")
    }

    do {
        let controller = controller(rows: 2)
        let natural: CGFloat = 156
        let height = controller.renameSheetHeight(atLeast: natural)
        expect(height >= natural, "the sheet is never shorter than its own content -- asked \(natural), got \(height)")
        let cut = rowSpans(of: controller).filter { $0.top < height && height < $0.bottom }
        expect(
            cut.isEmpty,
            "the sheet's bottom edge at \(height) falls in a gap, not across a row -- crosses \(cut)"
        )
        print("PASS: the rename sheet's bottom edge falls between rows, not across one")
    }

    do {
        // The same holds wherever the content's natural height lands, the
        // way it lands over the first row, the second, or between them.
        let controller = controller(rows: 2)
        for natural in stride(from: CGFloat(100), through: 520, by: 1) {
            let height = controller.renameSheetHeight(atLeast: natural)
            let cut = rowSpans(of: controller).filter { $0.top < height && height < $0.bottom }
            expect(
                height >= natural && cut.isEmpty,
                "a sheet needing \(natural) is \(height) tall and its bottom edge crosses no row -- crosses \(cut)"
            )
        }
        print("PASS: the sheet clears every row whatever height its own content needs")
    }

    do {
        let natural = PairedMachineRenameView(currentName: "Kestrel Laptop", onRename: { _ in }, onCancel: {})
        let tall = PairedMachineRenameView(
            currentName: "Kestrel Laptop", minimumHeight: 320, onRename: { _ in }, onCancel: {}
        )
        expect(
            tall.fittingSize.height >= 320 && tall.fittingSize.height > natural.fittingSize.height,
            "a sheet asked to reach a gap is that tall -- natural \(natural.fittingSize.height), got \(tall.fittingSize.height)"
        )
        print("PASS: the rename view grows to the height it is asked to reach")
    }

    do {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        guard let scrim = PairedMachineSheetScrim.cover(window) else {
            fatalError("the scrim found no content view to cover")
        }
        expect(
            scrim.superview === window.contentView && scrim.frame == window.contentView?.bounds,
            "the scrim covers the window's whole content while the sheet is up"
        )
        expect(
            scrim.hitTest(NSPoint(x: 10, y: 10)) === scrim,
            "the scrim takes clicks, so nothing behind the sheet answers one"
        )
        let color = scrim.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        expect(
            color != nil && abs((color?.alphaComponent ?? 0) - PairedMachineSheetScrim.opacity) < 0.001,
            "the scrim dims by its stated opacity -- got \(String(describing: color))"
        )
        expect(
            PairedMachineSheetScrim.opacity >= 0.5 && PairedMachineSheetScrim.opacity < 1,
            "the window behind reads as inactive, yet still reads as a window"
        )
        scrim.removeFromSuperview()
        expect(window.contentView?.subviews.isEmpty == true, "removing the scrim leaves the window as it was")
        print("PASS: the window behind the rename sheet is dimmed by a scrim that swallows clicks")
    }
}
