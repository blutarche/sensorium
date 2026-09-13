import AppKit
import Foundation
import SensoriumHost

/// The menu bar's own credit -- an "About Sensorium Host" item wired to the
/// same standard About panel the app's other surfaces use, reachable from
/// the physical machine's own menu bar the same way Quit already is.
@MainActor
func runHostMenuBarAboutMenuItemTests() async {
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

    let presence = HostMenuBarPresence(
        status: HostOperatorStatus(connection: .notHosting, permissions: granted),
        quit: {}
    )
    presence.install()
    let item = statusItem(in: presence)
    guard let menu = item.menu else {
        fatalError("the status item's menu was never installed")
    }
    guard let about = menu.items.first(where: { $0.title == "About Sensorium Host" }) else {
        fatalError("no menu item titled \u{2018}About Sensorium Host\u{2019} was found")
    }
    guard let action = about.action, let target = about.target as? NSObject else {
        fatalError("the About menu item has no target/action wired")
    }
    expect(target === presence, "the About item's target is the menu bar presence itself, not some other object")
    expect(
        NSStringFromSelector(action) == "openAboutPanel",
        "the About item's action is openAboutPanel, got \(NSStringFromSelector(action))"
    )

    print("PASS: the menu bar offers an About Sensorium Host item wired to the standard About panel")
}
