import Foundation
import SensoriumClient
import SensoriumCore

/// A session state every dynamic menu has something to show for: two screens
/// with one streaming, its modes live, a clamp notice, two displays chosen,
/// a captured pointer, clipboard sharing off and a full-screen window.
func menuBarFixtureState() -> ViewerMenuBarState {
    let studio = Data([1])
    let side = Data([2])
    return ViewerMenuBarState(
        streamScale: DisplayScaleMenuState(
            items: [
                DisplayScaleMenuItem(scale: nil, title: "Automatic", isSelected: false),
                DisplayScaleMenuItem(scale: 1.0, title: "1.00x (1920 \u{00D7} 1200)", isSelected: true)
            ],
            clampNotice: "Limited to 1.00x by the host"
        ),
        displayCount: DisplayCountMenuState(items: [
            DisplayCountMenuItem(count: 1, title: "1 Display", isSelected: false),
            DisplayCountMenuItem(count: 2, title: "2 Displays", isSelected: true, isEnabled: false)
        ]),
        screen: ScreenMenuState(
            items: [
                ScreenMenuItem(token: nil, title: "Virtual Display", isSelected: false),
                ScreenMenuItem(token: studio, title: "Studio Display", isSelected: true),
                ScreenMenuItem(token: side, title: "Side Display", isSelected: false)
            ],
            modes: HostScreenModeMenuState(title: "Resolution", isEnabled: true, items: [
                HostScreenModeMenuItem(modeID: "a", title: "1920 \u{00D7} 1080", isSelected: true),
                HostScreenModeMenuItem(modeID: "b", title: "2560 \u{00D7} 1440", isSelected: false)
            ]),
            startWith: StartWithMenuState(title: "Start With", items: [
                StartWithMenuItem(target: .hostScreenWhenOffered, title: "Last Used", isSelected: true, isEnabled: true),
                StartWithMenuItem(target: .virtualDisplay, title: "Virtual Display", isSelected: false, isEnabled: false)
            ])
        ),
        isPointerCaptured: true,
        isClipboardSharingEnabled: false,
        isFullscreen: true,
        canFullScreen: true,
        minimizeEnabled: false,
        zoomEnabled: true,
        bringAllToFrontEnabled: true
    )
}

/// The two update items appear only where an updater runs, and their
/// checkmark reads the preference.
func testViewerMenuUpdateItemsTests() {
    func appMenu(_ checksAutomatically: Bool?) -> [ViewerMenuItem] {
        var state = ViewerMenuBarState.initial
        state.checksForUpdatesAutomatically = checksAutomatically
        return ViewerMenuPlan.bar(state).first { $0.title == "Sensorium" }?.items ?? []
    }
    let withoutUpdater = appMenu(nil)
    expect(
        !withoutUpdater.contains { $0.command == .checkForUpdates || $0.command == .toggleAutomaticUpdates },
        "with no updater there are no update items"
    )
    expect(withoutUpdater.map(\.title).prefix(3) == ["About Sensorium", "", "Your Machines\u{2026}"], "and the app menu reads as before")

    let on = appMenu(true)
    expect(
        on.map(\.title).prefix(5) == [
            "About Sensorium", "Check for Updates\u{2026}", "Check for Updates Automatically", "", "Your Machines\u{2026}"
        ],
        "the update items follow About, got \(on.map(\.title))"
    )
    expect(on[1].command == .checkForUpdates && on[1].keyEquivalent.isEmpty && on[1].isEnabled, "Check for Updates\u{2026} has no chord")
    expect(on[2].command == .toggleAutomaticUpdates && on[2].isSelected, "automatic updates on is checked")
    expect(appMenu(false)[2].isSelected == false, "and off is unchecked")
    print("PASS: the Sensorium menu offers Check for Updates\u{2026} and Check for Updates Automatically only where an updater runs")
}

/// The one menu bar both platforms build: its menus in macOS order, and every
/// state-dependent item reading the state it was given.
func testViewerMenuBarModelTests() {
    let bar = ViewerMenuPlan.bar(menuBarFixtureState())
    let titles = bar.map(\.title)
    expect(
        titles == ["Sensorium", "Edit", "View", "Displays", "Resolution", "Screen", "Window", "Help"],
        "the bar's menus are in macOS order, got \(titles)"
    )
    let rows = ViewerMenuPlan.rows(of: bar)
    func row(_ title: String) -> ViewerMenuRow? { rows.first { $0.title == title } }
    expect(row("Release Captured Pointer")?.isChecked == true, "a captured pointer reads as such, checked")
    expect(row("Share Clipboard")?.isChecked == false, "clipboard sharing off is unchecked")
    expect(row("Exit Full Screen")?.isEnabled == true, "a full-screen window offers Exit Full Screen")
    expect(row("Minimize")?.isEnabled == false && row("Zoom")?.isEnabled == true, "the Window menu reads its state")
    expect(row("2 Displays").map { $0.isChecked && $0.isEnabled == false } == true, "a display count keeps its check and enablement")
    expect(row("Limited to 1.00x by the host")?.isEnabled == false, "the clamp notice is never clickable")
    let resolution = rows.firstIndex { $0.title == "Resolution" && $0.depth == 1 }
    expect(
        resolution.map { rows[$0 + 1].depth == 2 && rows[$0 + 1].title == "1920 \u{00D7} 1080" && rows[$0 + 1].isChecked } == true,
        "the Screen menu's Resolution submenu carries the host's modes, the current one checked"
    )
    expect(
        row("Undo")?.isEnabled == nil,
        "Edit's enablement is left to whichever field has focus, on both platforms"
    )
    expect(
        rows.filter { $0.title.hasPrefix("Escape back to this machine") }.map(\.isEnabled) == [false],
        "Help states the escape gesture, never clickable"
    )
    expect(
        ViewerMenuPlan.menus.map(\.title) == ["Sensorium", "Edit", "View", "Window", "Help"],
        "the fixed menus are still the five the bar starts from"
    )
    print("PASS: the shared menu bar lists every menu in macOS order and every item reads its state")
}
