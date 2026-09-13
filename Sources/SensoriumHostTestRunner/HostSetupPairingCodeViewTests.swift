import AppKit
import Foundation
import SensoriumHost

/// docs/ux-spec.md's "Window contents" puts the pairing code outside the
/// status card, full width, in the "Show pairing code" button's own place --
/// not inset inside another card the way the menu-bar panel still draws it.
/// `Mirror` reads `HostSetupWindowController`'s private `pairingCodeView`
/// and `revealButton` past their own access level, casting each to `NSView`
/// (a public AppKit superclass, reachable regardless of the concrete type's
/// own access level) -- the same technique `HostSetupRevealButtonTests`
/// already uses for `revealButton` alone.
@MainActor
func runHostSetupPairingCodeViewTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func view(named label: String, in controller: HostSetupWindowController) -> NSView {
        for child in Mirror(reflecting: controller).children {
            if child.label == label, let view = child.value as? NSView {
                return view
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(label)")
    }

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    func controller(
        connection: HostConnectionState = .hosting(address: "203.0.113.42"),
        pairing: HostPairingState = .idle
    ) -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(connection: connection, pairing: pairing, permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        // No code yet: the button shows, the code view does not
        let controller = controller(connection: .hosting(address: "203.0.113.42"))
        expect(view(named: "revealButton", in: controller).isHidden == false, "nothing is on screen to read yet, so the button is what offers to fetch a code")
        expect(view(named: "pairingCodeView", in: controller).isHidden, "there is no code to show, so its own view stays out of the way")

        print("PASS: with no pairing code on screen, the Show pairing code button shows and the code view stays hidden")
    }

    do {
        // A code is on screen: the code view shows, the button does not
        let controller = controller(pairing: .showing(
            code: "418297",
            expiresAt: Date().addingTimeInterval(300)
        ))
        expect(view(named: "revealButton", in: controller).isHidden, "the code itself replaces the button the moment one is on screen")
        expect(view(named: "pairingCodeView", in: controller).isHidden == false, "a code on screen needs its own view to show it")

        print("PASS: once a pairing code is on screen, its own view replaces the Show pairing code button")
    }

    do {
        // The code view names where the digits go: whoever reads
        // them aloud needs to say which machine types them.
        let controller = controller(pairing: .showing(
            code: "418297",
            expiresAt: Date().addingTimeInterval(300)
        ))
        let pairingCodeView = view(named: "pairingCodeView", in: controller)
        let hintLabel: NSTextField = field("hintLabel", of: pairingCodeView, as: NSTextField.self)
        expect(
            hintLabel.isHidden == false && hintLabel.stringValue == HostOperatorPresentation.pairingCodeHint,
            "the code view's hint line reads the presentation model's own copy, shown whenever the countdown is -- "
                + "got hidden \(hintLabel.isHidden), text \(hintLabel.stringValue)"
        )
        expect(
            HostOperatorPresentation.pairingCodeHint == "Type it on the machine you are pairing.",
            "got: \(HostOperatorPresentation.pairingCodeHint)"
        )

        print("PASS: the code view's hint line names which machine the code is typed on")
    }

    do {
        // Only the six digits earn the mono face -- the hint and the
        // countdown sentence around them read in the sans body face,
        // the countdown's own digits tabular.
        let controller = controller(pairing: .showing(
            code: "418297",
            expiresAt: Date().addingTimeInterval(300)
        ))
        let pairingCodeView = view(named: "pairingCodeView", in: controller)
        let hintLabel: NSTextField = field("hintLabel", of: pairingCodeView, as: NSTextField.self)
        let hintFont = hintLabel.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect(
            hintFont == CanvasDesign.font(.primary, size: 12),
            "the hint sentence reads in the sans body face, not the mono face the six digits alone earn -- got \(String(describing: hintFont))"
        )
        let countdownLabel: NSTextField = field("countdownLabel", of: pairingCodeView, as: NSTextField.self)
        let countdownAttributed = countdownLabel.attributedStringValue
        let countdownString = countdownAttributed.string as NSString
        let wordFont = countdownAttributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect(
            wordFont == CanvasDesign.font(.primary, size: 12),
            "the countdown sentence itself reads in the sans body face -- got \(String(describing: wordFont))"
        )
        let digitRange = countdownString.rangeOfCharacter(from: .decimalDigits)
        expect(digitRange.location != NSNotFound, "the countdown carries a live minutes:seconds value -- got: \(countdownAttributed.string)")
        let digitFont = countdownAttributed.attribute(.font, at: digitRange.location, effectiveRange: nil) as? NSFont
        expect(
            digitFont == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            "the countdown's own digits carry tabular figures -- got \(String(describing: digitFont))"
        )

        print("PASS: the code view's hint and countdown read in the sans face, with the countdown's digits tabular")
    }
}
