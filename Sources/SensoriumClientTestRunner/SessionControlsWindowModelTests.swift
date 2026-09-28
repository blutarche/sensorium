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

/// Scale, Displays and Screen menu states, and the window's capture, clipboard
/// and full-screen state.
func testSessionMenuBarStateTests() {
    var model = SessionControlsWindowModel()
    model.hostScreens = [screen("Studio Display", token: 1, identity: "studio")]
    model.selectedScreenToken = Data([1])
    model.isHostScreenSession = true
    model.hostScreenModes = [mode("m1", width: 1920, height: 1080, hiDPI: false)]
    model.currentHostScreenModeID = "m1"
    model.startTargetPreference = .virtualDisplay
    model.displayCount = 2
    model.clipboardSharingEnabled = false
    model.streamScalePreference = .fixed(1.0)
    model.streamScaleClampNotice = "Held to 0.75x \u{2014} you asked for 1.00x"

    let state = model.menuBarState(isPointerCaptured: true, isFullscreen: true)
    let preset = SavedHost.remoteCanvasPreset
    let expected = ViewerMenuBarState(
        streamScale: DisplayScaleMenuState(
            items: DisplayScaleMenuPlan.items(
                selectedPreference: .fixed(1.0),
                canvasLogicalWidth: Double(preset.logicalWidth),
                canvasLogicalHeight: Double(preset.logicalHeight)
            ),
            clampNotice: "Held to 0.75x \u{2014} you asked for 1.00x"
        ),
        displayCount: DisplayCountMenuState(items: DisplayCountMenuPlan.items(selectedCount: 2, isEnabled: false)),
        screen: ScreenMenuState(
            items: ScreenMenuPlan.items(displays: model.hostScreens, selectedToken: Data([1]), canvasAvailable: true),
            modes: ScreenMenuPlan.modeMenu(modes: model.hostScreenModes, currentModeID: "m1", isHostScreenSessionLive: true),
            startWith: ScreenMenuPlan.startWithMenu(
                preference: .virtualDisplay,
                offeredHostScreens: model.hostScreens,
                isHostScreenSessionLive: true,
                canvasAvailable: true
            )
        ),
        isPointerCaptured: true,
        isClipboardSharingEnabled: false,
        isFullscreen: true,
        canFullScreen: true
    )
    expect(state == expected, "the session menus read the macOS canvas window's state, got \(state)")
    print("PASS: the session window's menus read the state a macOS canvas window gives its menu bar")
}
