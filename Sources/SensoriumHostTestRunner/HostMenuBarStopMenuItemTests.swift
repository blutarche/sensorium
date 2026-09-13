import AppKit
import Foundation
import SensoriumHost

/// docs/ux-spec.md's menu-bar section promises "offers Stop" -- the same
/// immediate end-of-session action the setup window's own Stop button
/// gives, reachable without opening it. `Mirror` reads
/// `HostMenuBarPresence`'s private `statusItem` past its own access level,
/// and the item's real `target`/`action` fire the tap exactly as AppKit's
/// own menu tracking would, so none of this needs `NSApplication` running.
@MainActor
func runHostMenuBarStopMenuItemTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func statusItem(in presence: HostMenuBarPresence) -> NSStatusItem {
        for child in Mirror(reflecting: presence).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem? {
                if let item {
                    return item
                }
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named statusItem, or install() left it nil")
    }

    func stopMenuItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == "Stop" }
    }

    do {
        // Connected: the Stop item is present and fires onStop
        var stopped = false
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .serving(peerName: "Kestrel MacBook Pro"), permissions: granted),
            onStop: { stopped = true },
            quit: {}
        )
        presence.install()
        let item = statusItem(in: presence)
        guard let menu = item.menu else {
            fatalError("the status item's menu was never installed")
        }
        guard let stop = stopMenuItem(in: menu) else {
            fatalError("no menu item titled Stop was found while a session is connected")
        }
        guard let action = stop.action, let target = stop.target as? NSObject else {
            fatalError("the Stop menu item has no target/action wired")
        }
        _ = target.perform(action, with: stop)
        expect(stopped, "tapping the Stop menu item must call the onStop closure the same way the setup window's Stop button does")

        print("PASS: the serving panel's status item offers a Stop menu item that ends the session")
    }

    do {
        // Not connected: no Stop item to tap
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onStop: {},
            quit: {}
        )
        presence.install()
        let item = statusItem(in: presence)
        guard let menu = item.menu else {
            fatalError("the status item's menu was never installed")
        }
        expect(stopMenuItem(in: menu) == nil, "nothing is connected yet, so there is nothing for a Stop item to end")

        print("PASS: the status item offers no Stop menu item while nothing is connected")
    }
}
