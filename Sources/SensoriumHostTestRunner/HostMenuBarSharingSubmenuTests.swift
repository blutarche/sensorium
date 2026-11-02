import AppKit
import Foundation
import SensoriumHost

/// Every machine allowed to share the host screen is listed in one submenu,
/// so the menu's own height does not grow with the number of paired machines.
/// `Mirror` reads `HostMenuBarPresence`'s private `statusItem`, as
/// `HostMenuBarStopMenuItemTests` does.
@MainActor
func runHostMenuBarSharingSubmenuTests() async {
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

    func lines(_ count: Int) -> [HostScreenArmingPresentation.DeviceLine] {
        (0..<count).map { index in
            HostScreenArmingPresentation.DeviceLine(
                devicePublicKey: Data([UInt8(index)]),
                deviceName: "Kestrel Laptop \(index + 1)"
            )
        }
    }

    /// A menu with `count` armed machines, and the keys `onTurnOffSharing`
    /// has been called with so far.
    final class Recorder {
        var keys: [Data] = []
    }

    func menu(armed count: Int, recorder: Recorder = Recorder()) -> NSMenu {
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            openSetup: {},
            onStop: {},
            onTurnOffSharing: { recorder.keys.append($0) },
            quit: {}
        )
        presence.install()
        presence.updateArming(lines(count))
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        // The presence owns the status item; keep it alive past this scope.
        retainedPresences.append(presence)
        return menu
    }

    func sharingItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title.hasPrefix("Sharing Host Screen") }
    }

    func click(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else {
            fatalError("the menu item \(item.title) has no target/action wired")
        }
        _ = target.perform(action, with: item)
    }

    do {
        let none = menu(armed: 0)
        expect(
            sharingItem(in: none) == nil,
            "with no machine armed the menu has no sharing item -- got titles \(none.items.map { $0.title })"
        )
        print("PASS: the menu lists no sharing item while no machine is armed")
    }

    do {
        let one = menu(armed: 1)
        let ten = menu(armed: 10)
        expect(
            ten.items.count == one.items.count,
            "ten armed machines must add nothing to the top-level menu over one -- one: \(one.items.count), "
                + "ten: \(ten.items.count)"
        )
        guard let item = sharingItem(in: ten), let submenu = item.submenu else {
            fatalError("the menu has no sharing item with a submenu -- got titles \(ten.items.map { $0.title })")
        }
        expect(item.title == "Sharing Host Screen (10)", "the sharing item counts the armed machines -- got \(item.title)")
        expect(sharingItem(in: one)?.title == "Sharing Host Screen (1)", "one armed machine reads (1)")

        let titles = submenu.items.map { $0.title }
        expect(
            submenu.items.count == 13,
            "the submenu is a caption, ten machines, a separator and Turn Off for All Machines -- got \(titles)"
        )
        expect(titles.first == "Choose a machine to turn off", "the caption comes first -- got \(titles)")
        expect(submenu.items.first?.isEnabled == false, "the caption is not clickable")
        let machines = Array(submenu.items.dropFirst().prefix(10))
        expect(
            machines.map { $0.title } == (1...10).map { "Kestrel Laptop \($0)" },
            "one item per armed machine, named for it -- got \(machines.map { $0.title })"
        )
        expect(machines.allSatisfy { $0.state == .on }, "each armed machine carries a checkmark")
        expect(submenu.items[11].isSeparatorItem, "a separator sits above Turn Off for All Machines")
        expect(titles.last == "Turn Off for All Machines", "the last item turns every machine off -- got \(titles)")

        print("PASS: ten armed machines share one bounded top-level item whose submenu lists them")
    }

    do {
        let recorder = Recorder()
        let ten = menu(armed: 10, recorder: recorder)
        guard let submenu = sharingItem(in: ten)?.submenu else {
            fatalError("the menu has no sharing submenu")
        }
        click(submenu.items[4])
        expect(
            recorder.keys == [Data([3])],
            "clicking a machine turns off sharing for that machine alone -- got \(recorder.keys)"
        )

        recorder.keys = []
        guard let all = submenu.items.last else {
            fatalError("the sharing submenu is empty")
        }
        click(all)
        expect(
            recorder.keys == (0..<10).map { Data([UInt8($0)]) },
            "Turn Off for All Machines turns sharing off once for each armed machine -- got \(recorder.keys)"
        )

        print("PASS: a machine item turns off that machine, and Turn Off for All Machines turns off every one")
    }
}

/// Keeps each `HostMenuBarPresence` this file builds alive, so its status
/// item and menu outlive the helper that made them.
@MainActor
private var retainedPresences: [HostMenuBarPresence] = []
