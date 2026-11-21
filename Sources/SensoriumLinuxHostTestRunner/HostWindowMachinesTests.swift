#if os(Linux)
import Foundation
import SensoriumLinuxHost

private let epoch = Date(timeIntervalSince1970: 1_000)

private func present(_ state: HostWindowState) -> HostWindowPresentation {
    HostWindowPresentation(state, now: epoch)
}

private let armed = HostWindowMachine(
    id: "a", name: "Kestrel Laptop", isArmed: true,
    sharedDisplaysLine: "May share Built-in Display.", keyFingerprintLine: "Key AB127C4E"
)
private let disarmed = HostWindowMachine(
    id: "b", name: "workstation-west-annex-render-node-07", isArmed: false, keyFingerprintLine: "Key CD349A61"
)

/// The Paired machines section, the two switches under it, and what each
/// control does to the machine it belongs to.
@MainActor
enum HostWindowMachinesTests {
    static let all: [(String, () async -> Void)] = [
        ("an armed machine's row names what it may share, a disarmed one says sharing is off", testRowSubtitles),
        ("a row's switch is on exactly while the machine is armed and says whose it is", testRowSwitch),
        ("a row's menu offers Rename, Ask first, the key line and Remove in that order", testRowMenuOrder),
        ("Ask first is available only while sharing is on and shows its checkmark", testAskFirstFollowsSharing),
        ("an unnamed machine starts its rename from an empty name", testUnnamedMachineRenamesFromEmpty),
        ("the empty section says what to do, as the host can or cannot show a code", testEmptySectionCopy),
        ("a pairing in progress leaves the section without lines or heading", testPairingInProgressHidesTheSection),
        ("rows keep the order given and the last session shows only when there was one", testRowOrderAndLastSession),
        ("a row with no displays line says why, and a row with neither has no line", testRowWithoutDisplaysLine),
        ("Open at login follows its state and a machine that cannot do it says so", testOpenAtLogin),
        ("the local network switch carries its explanation", testLocalNetwork),
        ("an unsupported desktop keeps the paired list and drops the switches", testUnsupportedDesktopKeepsOnlyTheList),
        ("the rename step names the machine and says the name stays on this machine", testRenameCopy)
    ]

    static func testRowSubtitles() async {
        let rows = present(HostWindowState(status: .waiting, machines: [armed, disarmed])).machines.rows
        expect(rows[0].subtitle == "May share Built-in Display", "the closing full stop is dropped from the displays line")
        expect(rows[1].subtitle == "Host screen sharing off", "a disarmed machine says sharing is off")
        expect(rows[1].name == "workstation-west-annex-render-node-07", "a long name is kept whole for the view to truncate")
    }

    static func testRowSwitch() async {
        let rows = present(HostWindowState(status: .waiting, machines: [armed, disarmed])).machines.rows
        expect(rows[0].switchIsOn && !rows[1].switchIsOn, "the switch follows arming")
        expect(rows[0].switchLabel == "Share host screen with Kestrel Laptop", "the switch names its machine")
        expect(rows[0].moreLabel == "More actions for Kestrel Laptop", "the more button names its machine")
        expect(rows[0].id == "a" && rows[1].id == "b", "a row hands back its own machine's id")
    }

    static func testRowMenuOrder() async {
        let menu = present(HostWindowState(status: .waiting, machines: [armed])).machines.rows[0].menu
        expect(menu == [
            .rename(title: "Rename\u{2026}"),
            .askFirst(title: "Ask me first if this machine is in use", isChecked: false, isEnabled: true),
            .keyLine("Key AB127C4E"),
            .separator,
            .remove(title: "Remove")
        ], "the menu is Rename, Ask first, the key line, a separator and Remove, got \(menu)")
        let bare = HostWindowMachine(id: "c", name: "Studio", isArmed: true)
        let bareMenu = present(HostWindowState(status: .waiting, machines: [bare])).machines.rows[0].menu
        expect(!bareMenu.contains { if case .keyLine = $0 { return true } else { return false } }, "no key line, no item")
    }

    static func testAskFirstFollowsSharing() async {
        var checked = armed
        checked.asksFirst = true
        var off = disarmed
        off.asksFirst = true
        let rows = present(HostWindowState(status: .waiting, machines: [checked, off])).machines.rows
        expect(rows[0].menu[1] == .askFirst(title: HostWindowCopy.askFirstMenuItem, isChecked: true, isEnabled: true), "an armed machine's choice is checked and available")
        expect(rows[1].menu[1] == .askFirst(title: HostWindowCopy.askFirstMenuItem, isChecked: true, isEnabled: false), "it means nothing for a machine not allowed to share, so it is unavailable")
    }

    static func testUnnamedMachineRenamesFromEmpty() async {
        let unnamed = HostWindowMachine(id: "u", name: HostWindowCopy.unnamedMachine, isArmed: true)
        let rows = present(HostWindowState(status: .waiting, machines: [unnamed, armed])).machines.rows
        expect(rows[0].renameCurrentName.isEmpty, "the placeholder title is not a name to start from")
        expect(rows[1].renameCurrentName == "Kestrel Laptop", "a named machine starts from its name")
    }

    static func testEmptySectionCopy() async {
        let ready = present(HostWindowState(status: .waiting)).machines
        expect(ready.emptyHeading == "No machine is paired.", "the heading says what is empty")
        expect(ready.emptySubtext == "Show a pairing code, then type it on the machine you are pairing.", "a host that can show a code says to")
        expect(ready.showsEyebrow, "the section is headed Paired machines")
        expect(ready.eyebrow == "Paired machines", "the heading's words")

        var withCode = HostWindowState(status: .waiting)
        withCode.pairing = .showing(code: "418297", expiresAt: epoch.addingTimeInterval(60), requestingDeviceName: nil)
        expect(present(withCode).machines.emptySubtext == "The machine appears here once the code is typed on it.", "a code on screen carries its own instruction")

        expect(present(HostWindowState(status: .notHosting)).machines.emptySubtext == "Machines appear here once they pair.", "a host that cannot show a code says machines appear when they pair")
    }

    static func testPairingInProgressHidesTheSection() async {
        let section = present(HostWindowState(status: .pairing(deviceName: "Studio"))).machines
        expect(section.emptyHeading == nil && section.emptySubtext == nil, "the status card already says what is happening")
        expect(!section.showsEyebrow, "so the heading goes too")
        expect(section.isHidden, "and a section with nothing to show takes no room")
        let withRows = present(HostWindowState(status: .pairing(deviceName: "Studio"), machines: [armed])).machines
        expect(withRows.showsEyebrow && !withRows.isHidden, "rows keep the section")
    }

    static func testRowOrderAndLastSession() async {
        let none = present(HostWindowState(status: .waiting, machines: [disarmed, armed])).machines
        expect(none.rows.map(\.id) == ["b", "a"], "rows keep the order given")
        expect(none.lastSession == nil, "no last session, no card")
        var state = HostWindowState(status: .waiting, machines: [armed])
        state.lastSessionLine = "Kestrel Laptop saw Built-in Display on 21 Nov at 09:41."
        let with = present(state).machines
        expect(with.lastSession?.eyebrow == "Last host screen session", "the card's heading")
        expect(with.lastSession?.line == "Kestrel Laptop saw Built-in Display on 21 Nov at 09:41.", "the card's line")
    }

    static func testRowWithoutDisplaysLine() async {
        var reason = armed
        reason.sharedDisplaysLine = nil
        reason.notOfferedReason = "No display can be shared right now."
        var neither = armed
        neither.sharedDisplaysLine = nil
        let rows = present(HostWindowState(status: .waiting, machines: [reason, neither])).machines.rows
        expect(rows[0].subtitle == "No display can be shared right now.", "the reason stands in for the line")
        expect(rows[1].subtitle == nil, "with neither, the row is one line")
    }

    static func testOpenAtLogin() async {
        let on = present(HostWindowState(status: .waiting, openAtLogin: .on)).openAtLogin
        expect(on.title == "Open at login" && on.isOn && on.isEnabled && on.note == nil, "on is a plain checked switch")
        let off = present(HostWindowState(status: .waiting, openAtLogin: .off)).openAtLogin
        expect(!off.isOn && off.isEnabled && off.note == nil, "off is a plain unchecked switch")
        let unavailable = present(HostWindowState(status: .waiting, openAtLogin: .notAvailable)).openAtLogin
        expect(!unavailable.isOn && !unavailable.isEnabled, "a machine that cannot do it shows the switch dimmed")
        expect(unavailable.note == "Not available on this machine.", "and says so")
    }

    static func testLocalNetwork() async {
        let off = present(HostWindowState(status: .waiting)).localNetwork
        expect(off.title == "Allow connections from this network" && !off.isOn, "off by default")
        expect(
            off.explanation == "Lets a viewer on the same Wi-Fi or wired network connect by name, such as mini.local, "
                + "without Tailscale. Anyone on this network can then ask to pair. Leave it off on shared networks.",
            "the explanation is the macOS host's"
        )
        expect(present(HostWindowState(status: .waiting, allowsLocalNetwork: true)).localNetwork.isOn, "on follows the setting")
    }

    static func testRenameCopy() async {
        expect(HostWindowCopy.renameHeading(currentName: "Kestrel Laptop") == "Rename Kestrel Laptop", "the heading names the machine")
        expect(HostWindowCopy.renameHeading(currentName: "") == "Rename the unnamed machine", "an unnamed machine is described, not named")
        expect(
            HostWindowCopy.renameHint == "Only this machine sees this name. Leave it empty to use the name the other machine reports.",
            "the hint says where the name is kept"
        )
        expect(HostWindowCopy.renameCancel == "Cancel" && HostWindowCopy.renameConfirm == "Rename", "the two buttons")
    }

    static func testUnsupportedDesktopKeepsOnlyTheList() async {
        let presentation = present(HostWindowState(desktop: .unsupported, status: .waiting, machines: [armed]))
        expect(presentation.machines.rows.count == 1, "a paired machine can still be removed")
        expect(!presentation.showsSwitches, "no switch is offered where nothing can be hosted")
        expect(present(HostWindowState(status: .waiting)).showsSwitches, "a supported desktop shows them")
    }
}
#endif
