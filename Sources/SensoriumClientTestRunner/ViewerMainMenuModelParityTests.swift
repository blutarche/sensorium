#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

@MainActor
private final class ParityTarget: ViewerMenuCommandTarget {
    let state = menuBarFixtureState()
    var viewerWindowState: ViewerWindowState {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: state.isFullscreen)
    }
    var isPointerCaptured: Bool { state.isPointerCaptured }
    var streamScaleMenuState: DisplayScaleMenuState { state.streamScale }
    var displayCountMenuState: DisplayCountMenuState { state.displayCount }
    var screenMenuState: ScreenMenuState { state.screen }
    var isClipboardSharingEnabled: Bool { state.isClipboardSharingEnabled }
    func toggleTelemetryOverlay() {}
    func togglePointerCapture() {}
    func toggleClipboardSharing() {}
    func selectStreamScale(_ preference: StreamScalePreference) {}
    func selectDisplayCount(_ count: Int) {}
}

/// The macOS menu bar, once every menu has refreshed against a focused
/// session window, lists exactly the shared model's rows: the test that fails
/// if macOS and the model, and so macOS and Linux, drift apart.
@MainActor
func testViewerMainMenuMatchesSharedModelTests() {
    let application = NSApplication.shared
    let originalMainMenu = application.mainMenu
    let originalWindowsMenu = application.windowsMenu
    let originalHelpMenu = application.helpMenu
    defer {
        application.mainMenu = originalMainMenu
        application.windowsMenu = originalWindowsMenu
        application.helpMenu = originalHelpMenu
    }
    let controller = ViewerMainMenuController(onQuit: {}, onShowYourMachines: {})
    controller.windowMenuTargetWindow = { nil }
    controller.install(into: application)
    let target = ParityTarget()
    controller.register(target)
    guard let bar = application.mainMenu else {
        expect(false, "install(into:) sets the main menu")
        return
    }

    var state = target.state
    state.minimizeEnabled = false
    state.zoomEnabled = false
    state.bringAllToFrontEnabled = application.windows.contains { $0.isVisible }
    let model = ViewerMenuPlan.bar(state)

    var actual: [ViewerMenuRow] = []
    func flatten(_ menu: NSMenu, depth: Int, count: Int?) {
        controller.menuNeedsUpdate(menu)
        for item in menu.items.prefix(count ?? menu.items.count) {
            actual.append(ViewerMenuRow(
                depth: depth,
                title: item.isSeparatorItem ? "" : item.title,
                keyEquivalent: item.keyEquivalent,
                // A separator carries AppKit's default Command mask, which no
                // one ever types.
                modifiers: item.isSeparatorItem ? [] : modifiers(item.keyEquivalentModifierMask),
                isEnabled: menu.autoenablesItems ? nil : (item.isSeparatorItem ? false : item.isEnabled),
                isChecked: item.state == .on,
                isSeparator: item.isSeparatorItem
            ))
            if let submenu = item.submenu {
                flatten(submenu, depth: depth + 1, count: nil)
            }
        }
    }
    for (holder, menu) in zip(bar.items, model) {
        guard let submenu = holder.submenu else { continue }
        actual.append(ViewerMenuRow(
            depth: 0, title: submenu.title, keyEquivalent: "", modifiers: [],
            isEnabled: true, isChecked: false, isSeparator: false
        ))
        // AppKit appends the live window list to the Window menu.
        flatten(submenu, depth: 1, count: menu.title == "Window" ? menu.items.count : nil)
    }
    let expected = ViewerMenuPlan.rows(of: model)
    expect(bar.items.count == model.count, "the macOS bar has \(model.count) menus, got \(bar.items.count)")
    for (index, pair) in zip(expected, actual).enumerated() where pair.0 != pair.1 {
        expect(false, "row \(index) differs: model \(pair.0), macOS \(pair.1)")
    }
    expect(expected.count == actual.count, "the model has \(expected.count) rows, macOS \(actual.count)")
    print("PASS: the macOS menu bar lists exactly the shared model's menus, items, chords, checks and enablement")
}

private func modifiers(_ mask: NSEvent.ModifierFlags) -> ViewerMenuModifiers {
    var result: ViewerMenuModifiers = []
    if mask.contains(.command) { result.insert(.command) }
    if mask.contains(.shift) { result.insert(.shift) }
    if mask.contains(.option) { result.insert(.option) }
    if mask.contains(.control) { result.insert(.control) }
    return result
}
#endif
