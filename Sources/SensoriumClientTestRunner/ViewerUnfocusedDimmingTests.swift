#if canImport(AppKit)
import AppKit
import SensoriumClient

@MainActor
func testViewerUnfocusedDimming() {
    let key = "viewerUnfocusedDimmingPercent"
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.removeObject(forKey: key)
    let app = NSApplication.shared
    let menu = ViewerMainMenuController(onQuit: {}, onShowYourMachines: {})
    let oldMenu = app.mainMenu
    defer { app.mainMenu = oldMenu }
    menu.install(into: app)
    let item = app.mainMenu!.items.first { $0.submenu?.title == "View" }!.submenu!.items.first { $0.title == "Dim When Unfocused" }!
    let slider = item.view!.subviews.compactMap { $0 as? NSSlider }.first!
    expect(slider.doubleValue == 0, "unfocused dimming defaults to normal brightness")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let dimming = ViewerWindowDimming(window: window)
    withExtendedLifetime(dimming) {
        let overlay = window.contentView!.subviews.last!
        for percent in [0.0, 50.0, 100.0] {
            slider.doubleValue = percent
            _ = slider.target?.perform(slider.action!, with: slider)
            expect(overlay.alphaValue == percent / 100, "unfocused window dims by \(percent)%")
            expect(UserDefaults.standard.double(forKey: key) == percent, "dimming choice persists")
        }
        expect(overlay.hitTest(.zero) == nil, "dimming never consumes input")
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        if app.isActive && window.isKeyWindow {
            expect(overlay.alphaValue == 0, "focused window restores full brightness")
        } else {
            print("SKIP: focus restoration requires foreground activation in this runner")
        }
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        expect(overlay.alphaValue == 1, "losing focus reapplies selected dimming")
    }
    window.close()
    print("PASS: unfocused dimming slider, persistence, overlay and focus")
}
#endif
