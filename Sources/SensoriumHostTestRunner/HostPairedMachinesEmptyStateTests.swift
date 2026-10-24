import AppKit
import Foundation
import SensoriumHost

/// docs/design-system.md: an empty state carries two lines, a heading that says
/// what is empty and subtext that says what to do. And the last-session line
/// the same section shows breaks only where a reader can follow it.
@MainActor
func runHostPairedMachinesEmptyStateTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    func controller() -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        let controller = controller()
        controller.updatePairedMachines([])
        let section = field("pairedMachines", of: controller, as: NSView.self)
        let heading = field("emptyHeading", of: section, as: NSTextField.self)
        let subtext = field("emptySubtext", of: section, as: NSTextField.self)
        expect(
            heading.stringValue == "No machine is paired.",
            "the heading says what is empty, and stays true after the last machine is removed -- got "
                + "\(heading.stringValue.debugDescription)"
        )
        expect(
            subtext.stringValue == "Show a\u{00A0}pairing code, then type it on the machine you are\u{00A0}pairing.",
            "the subtext says what to do, its last two words held together -- got \(subtext.stringValue.debugDescription)"
        )
        expect(!heading.isHidden && !subtext.isHidden, "with nothing paired both lines show")
        expect(
            heading.textColor != subtext.textColor,
            "the heading and the subtext are two different weights of voice, not one grey paragraph"
        )

        controller.updatePairedMachines([
            HostScreenArmingPresentation.PairedMachineRow(
                devicePublicKey: Data([0xAB]),
                deviceName: "Kestrel Laptop",
                isSharingRealScreen: false
            )
        ])
        expect(heading.isHidden && subtext.isHidden, "once a machine is paired neither empty-state line shows")

        print("PASS: an empty Paired machines section carries a heading and a line of what to do")
    }

    do {
        // The subtext follows what the window can do now: no button to show a
        // code means the line must not tell anyone to show one, and a code
        // already on screen is typed, not shown again.
        let issued = Date(timeIntervalSince1970: 1_700_000_000)
        func subtext(of controller: HostSetupWindowController) -> String {
            let section = field("pairedMachines", of: controller, as: NSView.self)
            return field("emptySubtext", of: section, as: NSTextField.self).stringValue
        }
        let canPair = "Show a\u{00A0}pairing code, then type it on the machine you are\u{00A0}pairing."
        let codeShowing = "The machine appears here once the code is typed on\u{00A0}it."
        let notReady = "Machines appear here once they\u{00A0}pair."

        let ready = controller()
        ready.updatePairedMachines([])
        expect(subtext(of: ready) == canPair, "pairing is possible and no code shows: the line names showing one -- got \(subtext(of: ready).debugDescription)")

        var clock = issued
        let showing = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                pairing: .showing(code: "418297", expiresAt: issued.addingTimeInterval(60)),
                permissions: granted
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            now: { clock }
        )
        showing.updatePairedMachines([])
        expect(subtext(of: showing) == codeShowing, "a code is on screen: the line says what typing it does, not the card's instruction again -- got \(subtext(of: showing).debugDescription)")

        clock = issued.addingTimeInterval(61)
        CanvasHostTestHooks.fireHostSetupWindowPairingTick(showing)
        expect(
            subtext(of: showing) == canPair,
            "a code that expired between ticks hands the line back to showing one -- got \(subtext(of: showing).debugDescription)"
        )

        let tailscaleDown = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: granted,
                problem: HostStartupProblemCopy.noTailnetAddress
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        tailscaleDown.updatePairedMachines([])
        expect(
            subtext(of: tailscaleDown) == notReady,
            "this machine cannot host yet, so there is no button to show a code: the line says when machines appear -- got "
                + "\(subtext(of: tailscaleDown).debugDescription)"
        )

        let approving = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .pairingApproved(deviceName: "Kestrel Laptop"),
                permissions: granted
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        approving.updatePairedMachines([])
        expect(
            subtext(of: approving) == notReady,
            "a machine finishing its pairing leaves no button to show a code either -- got \(subtext(of: approving).debugDescription)"
        )

        ready.update(HostOperatorStatus(connection: .notHosting, permissions: granted, problem: "Could not start hosting."))
        expect(subtext(of: ready) == notReady, "the line follows the window when hosting stops -- got \(subtext(of: ready).debugDescription)")

        print("PASS: the empty Paired machines subtext follows whether a code can be shown and whether one is on screen")
    }

    do {
        let controller = controller()
        controller.updatePairedMachines([])
        controller.updateLastHostScreenSession(
            "Kestrel Laptop used Built-in Display from 15 Nov 2023, 05:13. Sensorium Host stopped before the "
                + "session ended, so the end time is unknown."
        )
        let section = field("pairedMachines", of: controller, as: NSView.self)
        let label = field("lastSessionLabel", of: section, as: NSTextField.self)
        expect(
            label.stringValue.contains("15\u{00A0}Nov\u{00A0}2023,"),
            "the date in the last-session line never splits -- got \(label.stringValue.debugDescription)"
        )
        expect(
            label.stringValue.hasSuffix("is\u{00A0}unknown."),
            "the last two words of the last-session line stay together -- got \(label.stringValue.debugDescription)"
        )

        print("PASS: the last-session line keeps its date whole and its last two words together")
    }
}
