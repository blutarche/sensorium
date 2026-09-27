#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

@MainActor
private final class StandardMenusFakeTarget: ViewerMenuCommandTarget {
    var viewerWindowState: ViewerWindowState
    let isPointerCaptured = false
    let streamScaleMenuState = DisplayScaleMenuState(items: [], clampNotice: nil)
    let displayCountMenuState = DisplayCountMenuState(items: [])
    let isClipboardSharingEnabled = true

    init(hasKeyFocus: Bool, isFullscreen: Bool) {
        viewerWindowState = ViewerWindowState(surfaceID: 0, hasKeyFocus: hasKeyFocus, isFullscreen: isFullscreen)
    }

    func toggleTelemetryOverlay() {}
    func togglePointerCapture() {}
    func toggleClipboardSharing() {}
    func selectStreamScale(_ preference: StreamScalePreference) {}
    func selectDisplayCount(_ count: Int) {}
}

/// The menus a standard Mac app is expected to have, built for real: Window
/// handed to `NSApp.windowsMenu` so macOS appends the live window list, Help
/// handed to `NSApp.helpMenu`, Edit left to the responder chain's own
/// automatic enabling, and the full screen item's title and enabled state
/// tracking the key window it was last asked about.
@MainActor
func testViewerMainMenuStandardMenusTests() {
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
    controller.install(into: application)

    guard let bar = application.mainMenu else {
        expect(false, "install(into:) sets the application's main menu")
        return
    }
    let titles = bar.items.map { $0.submenu?.title ?? $0.title }
    expect(titles.first == "Sensorium", "the application menu is still first, got \(titles)")
    expect(titles.contains("Edit"), "the menu bar has an Edit menu, got \(titles)")
    expect(titles.contains("Window"), "the menu bar has a Window menu, got \(titles)")
    expect(
        titles.firstIndex(of: "View").map { viewIndex in
            titles.firstIndex(of: "Displays").map { $0 > viewIndex } ?? false
        } == true,
            "Displays sits after View, got \(titles)"
    )
    expect(
        titles.firstIndex(of: "Screen").map { screenIndex in
            titles.firstIndex(of: "Window").map { $0 > screenIndex } ?? false
        } == true,
        "Window sits after Screen, and Help stays macOS's own last menu, got \(titles)"
    )
    expect(titles.last == "Help", "Help is still the last menu, got \(titles)")

    guard let editMenu = bar.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
        expect(false, "the Edit menu exists")
        return
    }
    expect(
        editMenu.autoenablesItems,
        "the Edit menu enables and disables its items automatically, by whatever implements them in the responder chain"
    )
    let editTitles = editMenu.items.map(\.title)
    expect(
        editTitles == ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All"],
        "the Edit menu offers the six standard commands in the standard order, got \(editTitles)"
    )
    for item in editMenu.items where item.action != nil {
        expect(item.target == nil, "\(item.title) is left to the responder chain, not given a fixed target")
    }

    guard let windowMenu = bar.items.first(where: { $0.submenu?.title == "Window" })?.submenu else {
        expect(false, "the Window menu exists")
        return
    }
    expect(application.windowsMenu === windowMenu, "the Window menu is handed to NSApp.windowsMenu")
    let windowTitles = windowMenu.items.map(\.title)
    expect(
        windowTitles == ["Minimize", "Zoom", "", "Bring All to Front"],
        "the Window menu is Minimize, Zoom, a separator, then Bring All to Front, got \(windowTitles)"
    )
    guard let minimizeItem = windowMenu.items.first(where: { $0.title == "Minimize" }) else {
        expect(false, "Minimize exists")
        return
    }
    expect(
        minimizeItem.keyEquivalent.isEmpty,
        "Minimize claims no Cmd-M -- that chord must still reach the host, got \"\(minimizeItem.keyEquivalent)\""
    )
    expect(
        minimizeItem.keyEquivalentModifierMask.isEmpty,
        "and no lingering modifier mask either, since Cmd-M is what `windowsMenu` reformats onto this item by default"
    )

    guard let helpMenu = bar.items.first(where: { $0.submenu?.title == "Help" })?.submenu else {
        expect(false, "the Help menu exists")
        return
    }
    expect(application.helpMenu === helpMenu, "the Help menu is handed to NSApp.helpMenu")

    print("PASS: the viewer's menu bar has a standard Edit, Window and Help menu, wired into NSApp")
}

/// The full screen item's title and enabled state, read live from whichever
/// window `menuNeedsUpdate` finds focused -- the same lazy-refresh AppKit
/// already uses for the pointer-capture and clipboard items in this menu.
@MainActor
func testViewerMainMenuFullScreenItemTests() {
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
    controller.install(into: application)
    guard
        let viewMenu = application.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu,
        let fullScreenItem = viewMenu.items.first(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
    else {
        expect(false, "the View menu has a full screen item")
        return
    }

    // No registered target focused: nothing this menu knows about can go
    // full screen, so the item is disabled.
    controller.menuNeedsUpdate(viewMenu)
    expect(fullScreenItem.title == "Enter Full Screen", "with no focused target, the title reads Enter Full Screen")
    expect(!fullScreenItem.isEnabled, "and the item is disabled -- nothing registered can go full screen")

    let windowed = StandardMenusFakeTarget(hasKeyFocus: true, isFullscreen: false)
    controller.register(windowed)
    controller.menuNeedsUpdate(viewMenu)
    expect(fullScreenItem.title == "Enter Full Screen", "a focused, windowed canvas still reads Enter Full Screen")
    expect(fullScreenItem.isEnabled, "and is enabled, since a canvas window can always go full screen")

    let fullscreen = StandardMenusFakeTarget(hasKeyFocus: true, isFullscreen: true)
    controller.register(fullscreen)
    controller.unregister(windowed)
    controller.menuNeedsUpdate(viewMenu)
    expect(fullScreenItem.title == "Exit Full Screen", "a focused canvas already in full screen reads Exit Full Screen")
    expect(fullScreenItem.isEnabled, "and stays enabled")

    print("PASS: the full screen item's title and enabled state track the key window it was last asked about")
}

/// The Window menu's Minimize, Zoom and Bring All to Front items, read live
/// from a real window's traits -- `ViewerMenuPlan.windowMenuState`'s own
/// rule is unit-tested in isolation; this is the wiring that reads a real
/// `NSWindow`'s style mask and `isMiniaturized` into it.
///
/// `windowMenuTargetWindow` stands in for the key window here: this process
/// has no active app and no run loop driving one, so no real window here can
/// ever actually become key or main. The windows below are never ordered
/// onto screen and never explicitly closed -- either one corrupts the heap
/// in this headless process, confirmed by bisection; ARC deallocates them
/// at scope exit instead. `hasVisibleWindow`'s own enabled case is covered
/// directly by `testViewerWindowMenuStateTests`.
@MainActor
func testViewerMainMenuWindowStateWiringTests() {
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
    controller.install(into: application)
    guard
        let windowMenu = application.windowsMenu,
        let minimizeItem = windowMenu.items.first(where: { $0.title == "Minimize" }),
        let zoomItem = windowMenu.items.first(where: { $0.title == "Zoom" }),
        let bringAllToFrontItem = windowMenu.items.first(where: { $0.title == "Bring All to Front" })
    else {
        expect(false, "the Window menu has Minimize, Zoom and Bring All to Front items")
        return
    }

    // No target at all: nothing this menu knows about can be minimized or
    // zoomed, and no window of the app is visible.
    controller.windowMenuTargetWindow = { nil }
    controller.menuNeedsUpdate(windowMenu)
    expect(!minimizeItem.isEnabled, "no target window disables Minimize, got enabled")
    expect(!zoomItem.isEnabled, "and disables Zoom, got enabled")
    expect(!bringAllToFrontItem.isEnabled, "and disables Bring All to Front -- no window of the app is visible")

    // The launch window's own style mask: no .miniaturizable, no .resizable.
    // Never ordered onto screen, and never closed -- see the doc comment
    // above; both trigger real window-server bookkeeping this headless
    // process doesn't have. Left for ARC to deallocate at scope exit.
    let plain = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    controller.windowMenuTargetWindow = { plain }
    controller.menuNeedsUpdate(windowMenu)
    expect(!minimizeItem.isEnabled, "a [.titled, .closable] window disables Minimize, got enabled")
    expect(!zoomItem.isEnabled, "and disables Zoom, got enabled")

    let ordinary = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: true
    )
    controller.windowMenuTargetWindow = { ordinary }
    controller.menuNeedsUpdate(windowMenu)
    expect(minimizeItem.isEnabled, "an ordinary, resizable, miniaturizable window enables Minimize, got disabled")
    expect(zoomItem.isEnabled, "and enables Zoom, got disabled")
    // Already-miniaturized windows disabling Minimize again is
    // `ViewerMenuPlan.windowMenuState`'s own rule, unit-tested directly in
    // `testViewerWindowMenuStateTests` -- driving a real `NSWindow` through
    // an actual miniaturize round trip needs a genuine window server
    // session this process does not have.

    print("PASS: the Window menu's Minimize, Zoom and Bring All to Front items track a window's real traits")
}
#endif
