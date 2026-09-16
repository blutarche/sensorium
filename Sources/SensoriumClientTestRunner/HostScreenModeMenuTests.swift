import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer's half of the host screen's display mode: the Resolution
/// submenu under Screen, what it offers and when it can be used at all, the
/// request a pick sends, and what a refusal says. None of it needs a menu
/// bar or a window.
private let nativeMode = HostScreenModeEntry(
    modeID: "3008x1692@3008x1692@60",
    width: 3008,
    height: 1692,
    pixelWidth: 3008,
    pixelHeight: 1692,
    refreshRate: 60,
    isHiDPI: false
)

private let readableMode = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

@MainActor
func testHostScreenModeMenuTests() async {
    do {
        // The rows are the host's own modes, named for a person
        let menu = ScreenMenuPlan.modeMenu(
            modes: [readableMode, nativeMode],
            currentModeID: nativeMode.modeID,
            isHostScreenSessionLive: true
        )
        expect(menu.title == "Resolution", "the submenu is called what the person is choosing")
        expect(menu.isEnabled, "and can be used while a host screen is live")
        expect(
            menu.items.map(\.title) == ["1920 \u{00D7} 1080 (HiDPI)", "3008 \u{00D7} 1692"],
            "each row is the size a person would recognise, with HiDPI named only where it applies -- got: \(menu.items.map(\.title))"
        )
        expect(
            menu.items.map(\.isSelected) == [false, true],
            "and the mode the screen is on right now is the one checked"
        )
        expect(
            menu.items.map(\.modeID) == [readableMode.modeID, nativeMode.modeID],
            "every row carries the host's own identifier for the mode, which is the only thing a pick ever sends back"
        )
        print("PASS: the Screen menu's Resolution submenu offers the host screen's own modes, checking the one it is on")
    }

    do {
        // Outside a host-screen session there is nothing to change
        let noSession = ScreenMenuPlan.modeMenu(
            modes: [readableMode, nativeMode],
            currentModeID: nativeMode.modeID,
            isHostScreenSessionLive: false
        )
        expect(
            !noSession.isEnabled,
            "a virtual-display session has no host screen whose resolution could change, so the submenu cannot be used"
        )
        let noModes = ScreenMenuPlan.modeMenu(modes: [], currentModeID: nil, isHostScreenSessionLive: true)
        expect(
            !noModes.isEnabled && noModes.items.isEmpty,
            "and a host that offered no modes leaves nothing to pick, rather than an empty menu that looks pickable"
        )
        print("PASS: the Resolution submenu can only be used while a host screen is live and its modes are known")
    }

    do {
        // The Screen menu still says what it always said
        let state = ScreenMenuState(
            items: ScreenMenuPlan.items(displays: [], selectedToken: nil),
            modes: ScreenMenuPlan.modeMenu(modes: [], currentModeID: nil, isHostScreenSessionLive: false)
        )
        expect(
            state.items == [ScreenMenuItem(token: nil, title: "Virtual Display", isSelected: true)],
            "adding a Resolution submenu changes none of the rows that were already there"
        )
        print("PASS: the Screen menu's own rows are unchanged by the Resolution submenu beside them")
    }

    do {
        // A refused change says so in words, and says what is true
        let failed = HostScreenRefusalCopy.modeRefusalLine(
            reason: HostScreenModeRefusalReason.failed, hostLabel: "studio-mini"
        )
        expect(
            failed == "studio-mini could not change its screen\u{2019}s resolution. It is back to what it was.",
            "the refusal names the machine and says what the screen is on now -- got: \(failed)"
        )
        let unknown = HostScreenRefusalCopy.modeRefusalLine(
            reason: HostScreenModeRefusalReason.unknown, hostLabel: "studio-mini"
        )
        expect(
            unknown.localizedCaseInsensitiveContains("no longer offers"),
            "a resolution the host has stopped offering is explained as that, not as a failure of this machine"
        )
        let notLive = HostScreenRefusalCopy.modeRefusalLine(
            reason: HostScreenModeRefusalReason.notLive, hostLabel: "studio-mini"
        )
        expect(
            notLive.localizedCaseInsensitiveContains("screen"),
            "and a session that is no longer showing a host screen says so"
        )
        for line in [failed, unknown, notLive] {
            expect(
                !line.contains("host-screen-mode"),
                "no refusal shows the wire token to a person -- got: \(line)"
            )
        }
        let invented = HostScreenRefusalCopy.modeRefusalLine(reason: "a-reason-this-build-never-saw", hostLabel: "studio-mini")
        expect(
            invented.contains("a\u{2011}reason\u{2011}this\u{2011}build\u{2011}never\u{2011}saw"),
            "an unrecognised reason is quoted rather than translated into a cause nobody reported -- got: \(invented)"
        )
        print("PASS: every host-screen resolution refusal reads as a sentence, and an unknown one is quoted rather than invented")
    }

    do {
        // A mode message is recognised as what it is
        expect(
            ClientSessionRunner.hostScreenModeOutcome(for: .hostScreenModeList(
                modes: [readableMode], currentModeID: readableMode.modeID
            )) == .list(modes: [readableMode], currentModeID: readableMode.modeID),
            "a mode list arriving mid-session is read as one"
        )
        let geometry = SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2.0)
        expect(
            ClientSessionRunner.hostScreenModeOutcome(for: .hostScreenModeApplied(
                geometry: geometry, currentModeID: readableMode.modeID
            )) == .applied(geometry: geometry, currentModeID: readableMode.modeID),
            "so is the answer that a change took, carrying the geometry this viewer must now size to"
        )
        expect(
            ClientSessionRunner.hostScreenModeOutcome(for: .hostScreenModeRefused(
                reason: HostScreenModeRefusalReason.failed
            )) == .refused(reason: HostScreenModeRefusalReason.failed),
            "and the answer that it did not"
        )
        expect(
            ClientSessionRunner.hostScreenModeOutcome(for: .goodbye(reason: "whatever")) == nil,
            "and nothing else on the wire is mistaken for one"
        )
        print("PASS: the viewer reads the host's mode messages as themselves and mistakes nothing else for one")
    }
}
