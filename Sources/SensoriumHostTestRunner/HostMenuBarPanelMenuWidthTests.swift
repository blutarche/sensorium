import AppKit
import Foundation
import SensoriumHost

/// A menu-bar menu is as wide as its widest row. The status card hung in it
/// must fill that width, not sit at its own 288 points with the menu's
/// background showing past its right edge.
@MainActor
func runHostMenuBarPanelMenuWidthTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let presence = HostMenuBarPresence(
        status: HostOperatorStatus(
            connection: .serving(peerName: "Kestrel Laptop Pro"),
            permissions: granted
        ),
        onStop: {},
        quit: {}
    )
    presence.install()

    let widened = CanvasHostTestHooks.menuBarPanelAfterMenuWidens(presence, to: 420)
    expect(widened.stretches, "the menu is allowed to stretch the card to its own width")
    expect(widened.width == 420, "the card takes the menu's width")
    let rightmost = widened.textFrames.map(\.maxX).max() ?? 0
    expect(
        rightmost > 288,
        "text re-lays out across the wider card instead of staying in the first 288 points; got \(rightmost)"
    )

    print("PASS: the menu-bar status card fills a menu wider than itself")
}
