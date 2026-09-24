import Foundation
import SensoriumClient
import SensoriumCore

private func screen(_ label: String, token: UInt8, identity: String) -> HostScreenListEntry {
    HostScreenListEntry(
        opaqueToken: Data([token]),
        label: label,
        logicalWidth: 1920,
        logicalHeight: 1080,
        backingScale: 2,
        isBuiltin: false,
        displayIdentity: identity
    )
}

private func mode(_ id: String, width: Int, height: Int, hiDPI: Bool) -> HostScreenModeEntry {
    HostScreenModeEntry(
        modeID: id,
        width: width,
        height: height,
        pixelWidth: hiDPI ? width * 2 : width,
        pixelHeight: hiDPI ? height * 2 : height,
        refreshRate: 60,
        isHiDPI: hiDPI
    )
}

/// The session controls window's own content, as rows: the same plans the
/// macOS menu bar draws, turned into one list a window can show, and one
/// activation per row naming exactly which outbound call a pick makes.
/// Holds no widget, so both halves are checked without a toolkit.
func testSessionControlsWindowModelTests() {
    var model = SessionControlsWindowModel()
    model.hostScreens = [screen("Studio Display", token: 1, identity: "studio")]
    model.selectedScreenToken = Data([1])
    model.isHostScreenSession = true
    model.hostScreenModes = [mode("m1", width: 1920, height: 1080, hiDPI: false), mode("m2", width: 1280, height: 800, hiDPI: true)]
    model.currentHostScreenModeID = "m1"
    model.startTargetPreference = .virtualDisplay
    model.displayCount = 1
    model.clipboardSharingEnabled = true
    model.streamScalePreference = .automatic
    model.canvasLogicalWidth = 1920
    model.canvasLogicalHeight = 1080
    model.streamScaleClampNotice = "Held to 0.75x \u{2014} you asked for 1.00x"

    let sections = model.sections
    expect(sections.count == 6, "one section per plan the macOS menu bar draws")
    expect(
        sections.map(\.title) == ["Screen", "Resolution", "Start With", "Displays", "Scale", "Clipboard"],
        "the sections are titled by the plans they come from, in the order a person reads them"
    )

    let screenSection = sections[0]
    expect(
        screenSection.rows.map(\.title) == ["Virtual Display", "Studio Display"],
        "the screen rows are ScreenMenuPlan's own rows"
    )
    expect(screenSection.rows[1].isSelected, "the screen this session is streaming is the selected row")
    expect(
        screenSection.rows[0].activation == .selectRealScreen(nil),
        "picking Virtual Display asks for no real screen at all"
    )
    expect(
        screenSection.rows[1].activation == .selectRealScreen(Data([1])),
        "picking a screen asks for it by the token the host offered"
    )

    let modes = sections[1]
    expect(
        modes.rows.map(\.title) == ["1920 \u{00D7} 1080", "1280 \u{00D7} 800 (HiDPI)"],
        "the resolution rows are ScreenMenuPlan's own mode titles"
    )
    expect(modes.rows[0].isSelected, "the mode the screen is on right now is the selected row")
    expect(modes.rows[1].activation == .selectHostScreenMode("m2"), "picking a mode names it by the host's own id")
    expect(modes.rows.allSatisfy(\.isEnabled), "a live host-screen session with modes offered can change them")

    let startWith = sections[2]
    expect(
        startWith.rows.map(\.title) == ["Host Screen When Offered", "Virtual Display", "Studio Display"],
        "the start-with rows are ScreenMenuPlan's own rows"
    )
    expect(
        startWith.rows.allSatisfy { !$0.isEnabled },
        "start-with cannot be acted on during a host-screen session, so every row is disabled"
    )
    expect(
        startWith.rows[1].activation == .selectStartTarget(.virtualDisplay),
        "picking a start target names the target itself"
    )

    let displays = sections[3]
    expect(displays.rows.map(\.title) == ["1 Display", "2 Displays"], "the display-count rows are the plan's own rows")
    expect(
        displays.rows.allSatisfy { !$0.isEnabled },
        "a host-screen session refuses a second display, so neither count can be picked"
    )
    expect(displays.rows[1].activation == .selectDisplayCount(2), "picking a count names the count")

    let scale = sections[4]
    expect(scale.rows.first?.title == "Automatic", "the scale rows start at Automatic, the plan's own first row")
    expect(scale.rows.first?.isSelected == true, "the preference this window holds is the selected row")
    expect(scale.rows.first?.activation == .setStreamScale(nil), "Automatic asks for no cap at all")
    expect(
        scale.note == "Held to 0.75x \u{2014} you asked for 1.00x",
        "the clamp notice is the section's note, not a row a person can pick"
    )

    let clipboard = sections[5]
    expect(clipboard.rows.count == 1, "clipboard sharing is one row, because there is nothing else to name")
    expect(clipboard.rows[0].isSelected, "the row is checked while sharing is on")
    expect(
        clipboard.rows[0].activation == .setClipboardSharing(false),
        "activating the row asks for the opposite of what it holds now"
    )

    model.isHostScreenSession = false
    model.hostScreenModes = []
    let quiet = model.sections
    expect(
        quiet[1].rows.isEmpty && !quiet[1].isEnabled,
        "a session with no host screen offers no resolution to change, and says so by being disabled"
    )
    expect(
        quiet[3].rows.allSatisfy(\.isEnabled),
        "a session canvas can still be asked for a second display"
    )

    print("PASS: the session controls window turns the viewer's own plans into rows, each naming the call its pick makes")
}

