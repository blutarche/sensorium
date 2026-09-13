import AppKit
import Foundation
import SensoriumHost

/// The host window's cards -- a paired machine's own row, the Last Screen
/// Session card, and the status card `HostOperatorPanelView` draws -- must
/// all inset their text by the same amount. Reads each card's own leading
/// constraint constant directly, the same "read past `private` with
/// `Mirror`" route `PairedMachinesSharingToggleTests` already uses, rather than
/// forcing a real Auto Layout pass no window here ever gets.
@MainActor
func runPairedMachinesCardInsetTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    /// The constant of the constraint that pins `inner`'s leading edge to
    /// `card`'s own leading edge -- installed on `card` (or `inner` itself,
    /// when `card` and the constrained view are the same instance)
    /// regardless of which side of `equalTo:` built it.
    func leadingInset(of inner: NSView, in card: NSView) -> CGFloat? {
        for constraint in card.constraints {
            if constraint.firstAttribute == .leading, constraint.secondAttribute == .leading,
               (constraint.firstItem === inner && constraint.secondItem === card)
                    || (constraint.firstItem === card && constraint.secondItem === inner) {
                return constraint.constant >= 0 ? constraint.constant : -constraint.constant
            }
        }
        return nil
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
        // A paired machine's own card insets its text by 12pt, tighter
        // than the 16pt every other card in this window uses -- this row
        // was made to fit four lines compactly, not to match them.
        let row = HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel MacBook Pro",
            isSharingRealScreen: true,
            credentialSummary: "hardware-bound credential",
            blockedReason: nil
        )
        let hostController = controller(rows: [row])
        let pairedMachines: NSView = field("pairedMachines", of: hostController, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: pairedMachines, as: NSStackView.self)
        let rowView = rowsStack.arrangedSubviews[0]
        let innerStack: NSStackView = field("stack", of: rowView, as: NSStackView.self)

        expect(
            leadingInset(of: innerStack, in: rowView) == CanvasDesign.Space.sm,
            "a paired machine's own card insets its text by 12pt, tighter than the 16pt every other card in this "
                + "window uses -- got: \(String(describing: leadingInset(of: innerStack, in: rowView)))"
        )

        print("PASS: a paired machine's own card insets its text by 12pt")
    }

    do {
        // The Last Screen Session card insets its text by the same
        // 16pt too.
        let hostController = controller(rows: [])
        hostController.updateLastHostScreenSession(
            "Kestrel MacBook Pro saw Built-in Display on 15 Nov 2023, 05:13\u{2013}05:43."
        )
        let pairedMachines: NSView = field("pairedMachines", of: hostController, as: NSView.self)
        let lastSessionCard: NSView = field("lastSessionCard", of: pairedMachines, as: NSView.self)
        let lastSessionStack: NSStackView = field("lastSessionStack", of: pairedMachines, as: NSStackView.self)

        expect(
            leadingInset(of: lastSessionStack, in: lastSessionCard) == CanvasDesign.Space.md,
            "the Last Screen Session card insets its text by the same 16pt every other card in this window uses "
                + "-- got: \(String(describing: leadingInset(of: lastSessionStack, in: lastSessionCard)))"
        )

        print("PASS: the Last Screen Session card insets its text by 16pt")
    }
}
