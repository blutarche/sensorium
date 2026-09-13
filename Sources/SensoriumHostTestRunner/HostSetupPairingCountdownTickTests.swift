import AppKit
import Foundation
import SensoriumHost

/// The Host Setup window's own "Expires in mm:ss" line, live: unlike the menu
/// bar's pairing panel, which already re-renders itself once a second, this
/// window's pairing section only ever moved when something else on it
/// changed. `CanvasHostTestHooks.fireHostSetupWindowPairingTick` fires the
/// same tick the window's real one-second `Timer` calls, against an injected
/// clock this test moves on its own terms, so nothing here waits on a real
/// clock.
@MainActor
func runHostSetupPairingCountdownTickTests() async {
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

    do {
        // A tick, with the clock moved forward, updates the
        // countdown label without waiting on a real Timer.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = start
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                pairing: .showing(code: "418297", expiresAt: start.addingTimeInterval(300)),
                permissions: granted
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            now: { clock }
        )
        let pairingCodeView = view(named: "pairingCodeView", in: controller)
        let countdownLabel: NSTextField = field("countdownLabel", of: pairingCodeView, as: NSTextField.self)
        let before = countdownLabel.stringValue
        expect(before == "Expires in 5:00", "the code view starts from the fixed clock's own remaining time -- got: \(before)")

        clock = start.addingTimeInterval(61)
        CanvasHostTestHooks.fireHostSetupWindowPairingTick(controller)

        let after = countdownLabel.stringValue
        expect(after != before, "a fired tick re-reads the injected clock and moves the countdown label -- still: \(after)")
        expect(after == "Expires in 3:59", "a minute and a second later, five minutes reads down to 3:59 -- got: \(after)")

        print("PASS: firing the Host Setup window's pairing countdown tick against a moved clock updates the countdown label")
    }

    do {
        // No code showing: a tick changes nothing, since the pairing
        // section has no countdown label on screen to move.
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        expect(view(named: "pairingCodeView", in: controller).isHidden, "no code is showing, so its view starts out of the way")

        CanvasHostTestHooks.fireHostSetupWindowPairingTick(controller)

        expect(view(named: "pairingCodeView", in: controller).isHidden, "a tick with nothing showing leaves the code view exactly as hidden as it started")
        expect(view(named: "revealButton", in: controller).isHidden == false, "and leaves the Show pairing code button exactly as offered as it started")

        print("PASS: firing the pairing countdown tick with no code showing changes nothing")
    }

    do {
        // A tick that finds the code already expired stops the
        // ticker itself, the same as `HostMenuBarPresence`'s own does
        // -- not only the label, which a tick no longer fires to move.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = start
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                pairing: .showing(code: "418297", expiresAt: start.addingTimeInterval(2)),
                permissions: granted
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            now: { clock }
        )
        expect(
            CanvasHostTestHooks.isHostSetupWindowPairingTickerRunning(controller),
            "a code counting down starts the ticker, at construction just as `refresh()` does at any other time"
        )

        clock = start.addingTimeInterval(10)
        CanvasHostTestHooks.fireHostSetupWindowPairingTick(controller)

        expect(
            !CanvasHostTestHooks.isHostSetupWindowPairingTickerRunning(controller),
            "a tick that finds the code already expired stops the ticker -- nothing is left for a further tick to count down"
        )
        expect(view(named: "pairingCodeView", in: controller).isHidden, "the expired code's own view comes off screen the same tick")
        expect(view(named: "revealButton", in: controller).isHidden == false, "and the Show pairing code button returns")

        print("PASS: a pairing countdown tick that finds the code already expired stops the ticker itself")
    }
}
