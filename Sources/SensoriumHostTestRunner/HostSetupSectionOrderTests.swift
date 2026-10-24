import AppKit
import Foundation
import SensoriumHost

/// docs/ux-spec.md's "Window contents" lists the host window top to bottom:
/// status, pairing code, paired machines with the last screen session, then
/// the four checkboxes. The window's stack must keep that order.
@MainActor
func runHostSetupSectionOrderTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let controller = HostSetupWindowController(
        status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
        onRevealPairingCode: {},
        onStop: {},
        onToggleSharing: { _, _ in },
        onRemovePairedDevice: { _ in },
        installsUpdatesAutomatically: { true }
    )

    func stored<T>(_ name: String, as type: T.Type) -> T {
        for child in Mirror(reflecting: controller).children where child.label == name {
            if let value = child.value as? T {
                return value
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(name) of type \(T.self)")
    }

    let arranged = stored("root", as: NSStackView.self).arrangedSubviews
    func position(_ name: String) -> Int {
        let view = stored(name, as: NSView.self)
        guard let index = arranged.firstIndex(of: view) else {
            fatalError("\(name) is not an arranged subview of the window's stack")
        }
        return index
    }

    let order = [
        "panel", "revealButton", "pairingCodeView", "hideCodeButton", "pairedMachines",
        "autoLoginCheckbox", "automaticUpdatesCheckbox", "privateDesktopCheckbox", "localNetworkCheckbox"
    ]
    let positions = order.map(position)
    expect(
        positions == positions.sorted(),
        "the window runs status, pairing code, paired machines, then Open at login, Install updates automatically, "
            + "Offer a private desktop and Allow connections -- got positions \(zip(order, positions).map { "\($0)=\($1)" })"
    )

    print("PASS: the host window lists its sections in docs/ux-spec.md's order")
}
