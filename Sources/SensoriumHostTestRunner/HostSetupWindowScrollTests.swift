import AppKit
import Foundation
import SensoriumHost

/// The Host Setup window grows with its paired machines. It must stop at the
/// screen's edge and scroll from there, so the controls at the bottom stay
/// reachable however many machines are paired.
@MainActor
func runHostSetupWindowScrollTests() async {
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

    func scrollView(in window: NSWindow) -> NSScrollView? {
        func search(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            for child in view.subviews {
                if let found = search(child) {
                    return found
                }
            }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    guard let screen = NSScreen.main else {
        print("SKIP: no main screen, so the Host Setup window's fit to the screen is not measured")
        return
    }

    do {
        // Enough machines to overflow any screen however compact a row is.
        let manyRows = controller(rows: 100)
        let window = field("window", of: manyRows, as: NSWindow.self)
        window.contentView?.layoutSubtreeIfNeeded()
        expect(
            window.frame.height <= screen.visibleFrame.height,
            "a hundred paired machines must not make the window taller than the screen's visible height "
                + "\(screen.visibleFrame.height) -- got \(window.frame.height)"
        )
        expect(
            screen.visibleFrame.contains(window.frame),
            "the window must sit fully inside the screen's visible frame -- window \(window.frame), "
                + "screen \(screen.visibleFrame)"
        )
        guard let scroll = scrollView(in: window), let document = scroll.documentView else {
            fatalError("the Host Setup window has no scroll view with a document")
        }
        expect(
            document.frame.height > scroll.contentView.bounds.height,
            "a hundred paired machines are taller than the window, so the document must overflow its clip view "
                + "-- document \(document.frame.height), clip \(scroll.contentView.bounds.height)"
        )
        expect(!scroll.hasHorizontalScroller, "the window is pinned to one width, so it has no horizontal scroller")
        expect(scroll.hasVerticalScroller, "the overflow is reached with a vertical scroller")
        expect(scroll.scrollerStyle == .overlay, "the scroller is the overlay style, out of the way until used")
        expect(scroll.borderType == .noBorder, "the scroll view draws no border of its own")
        expect(
            window.contentMinSize.width == window.contentMaxSize.width,
            "the window resizes vertically only -- min width \(window.contentMinSize.width), "
                + "max width \(window.contentMaxSize.width)"
        )
        expect(window.styleMask.contains(.resizable), "the person can resize the window vertically")

        // Scrolling to the end reaches the last row's controls.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        expect(
            scroll.contentView.bounds.maxY >= document.frame.height - 0.5,
            "scrolling to the end shows the bottom of the content"
        )

        print("PASS: a hundred paired machines cap the Host Setup window at the screen and scroll the rest")
    }

    do {
        let oneRow = controller(rows: 1)
        let window = field("window", of: oneRow, as: NSWindow.self)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let scroll = scrollView(in: window), let document = scroll.documentView else {
            fatalError("the Host Setup window has no scroll view with a document")
        }
        expect(
            document.frame.height <= scroll.contentView.bounds.height + 0.5,
            "one paired machine fits, so nothing scrolls -- document \(document.frame.height), "
                + "clip \(scroll.contentView.bounds.height)"
        )
        expect(
            document.frame.width == scroll.contentView.bounds.width,
            "the content is laid out at the window's full width"
        )

        print("PASS: one paired machine fits the Host Setup window with no scrolling")
    }

    do {
        // A window that grew past the screen is brought back inside it, with
        // its top edge still in view.
        let rows = controller(rows: 100)
        let window = field("window", of: rows, as: NSWindow.self)
        var frame = window.frame
        frame.origin.y = screen.visibleFrame.minY - 200
        window.setFrame(frame, display: false)
        rows.updatePairedMachines([])
        rows.updatePairedMachines((0..<100).map { index in
            HostScreenArmingPresentation.PairedMachineRow(
                devicePublicKey: Data([UInt8(index)]),
                deviceName: "Kestrel Laptop \(index + 1)",
                isSharingRealScreen: false,
                sharedDisplaysLine: nil
            )
        })
        expect(
            screen.visibleFrame.contains(window.frame),
            "after a resize the window is clamped inside the screen's visible frame -- window "
                + "\(window.frame), screen \(screen.visibleFrame)"
        )

        print("PASS: a resize leaves the Host Setup window inside the screen's visible frame")
    }
}
