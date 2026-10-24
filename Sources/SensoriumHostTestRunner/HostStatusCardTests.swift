import AppKit
import Foundation
import SensoriumHost

/// The status card at the top of the Host Setup window: its text sits the same
/// distance from both edges of the card, whatever width the window gives it.
@MainActor
func runHostStatusCardTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func controller(_ status: HostOperatorStatus) -> HostSetupWindowController {
        HostSetupWindowController(
            status: status,
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        let states: [(String, HostOperatorStatus)] = [
            (
                "a pairing finishing",
                HostOperatorStatus(connection: .pairingApproved(deviceName: "Kestrel Laptop"), permissions: granted)
            ),
            (
                "an unreadable key",
                HostOperatorStatus(connection: .notHosting, permissions: granted, identityProblem: .cannotReadKey)
            )
        ]
        for (name, status) in states {
            let card = CanvasHostTestHooks.hostSetupStatusCard(controller(status))
            expect(!card.textFrames.isEmpty, "the card for \(name) draws text")
            for frame in card.textFrames {
                let right = card.width - frame.maxX
                expect(
                    abs(frame.minX - right) < 0.5,
                    "the text of the card for \(name) is \(frame.minX)pt from the left edge and \(right)pt from the "
                        + "right, in a card \(card.width)pt wide; the two insets are equal"
                )
            }
        }
        print("PASS: the status card's text is inset the same on both sides at the window's width")
    }

    func panel(of subject: Any) -> NSView {
        for child in Mirror(reflecting: subject).children {
            if child.label == "panel", let view = child.value as? NSView {
                return view
            }
        }
        fatalError("\(type(of: subject)) no longer has a stored property named panel")
    }

    func buttons(in view: NSView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
    }

    do {
        // The menu's panel offers the Screen Recording settings itself, the
        // way the window's own button does.
        let screenRecordingURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        let missing = HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
        let connections: [(String, HostConnectionState)] = [
            ("a private desktop session", .serving(peerName: "Kestrel Laptop")),
            ("a host-screen session", .servingHostScreen(peerName: "Kestrel Laptop", displayLabel: "Built-in Display")),
            ("no session", .hosting(address: "203.0.113.42"))
        ]
        for (name, connection) in connections {
            var opened: [String] = []
            let presence = HostMenuBarPresence(
                status: HostOperatorStatus(connection: connection, permissions: missing),
                openSettings: { opened.append($0) },
                quit: {}
            )
            presence.install()
            let view = panel(of: presence)
            let shown = buttons(in: view)
            expect(
                shown.map { $0.attributedTitle.string } == ["Open Screen Recording Settings"],
                "the menu panel for \(name) with Screen Recording missing offers one button, Open Screen Recording "
                    + "Settings -- got \(shown.map { $0.attributedTitle.string })"
            )
            guard let button = shown.first else { continue }
            expect(
                button.frame.maxY <= view.bounds.height - CanvasDesign.Space.md + 0.5
                    && button.frame.minX == CanvasDesign.Space.md
                    && button.frame.maxX == view.bounds.width - CanvasDesign.Space.md,
                "the button sits inside the card at its text's inset -- button \(button.frame) in card \(view.bounds)"
            )
            button.sendAction(button.action, to: button.target)
            expect(
                opened == [screenRecordingURL],
                "pressing it opens the Screen Recording pane, as the window's button does -- got \(opened)"
            )
        }

        let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        let quiet = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            quit: {}
        )
        quiet.install()
        expect(buttons(in: panel(of: quiet)).isEmpty, "with the permission granted the panel offers no button")

        let window = controller(HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: missing))
        expect(
            buttons(in: panel(of: window)).isEmpty,
            "the window's card keeps its button below the card, so the card itself carries none"
        )
        print("PASS: the menu panel offers Open Screen Recording Settings while that permission is missing")
    }
}
