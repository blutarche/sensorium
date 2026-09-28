#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient
import SensoriumCore

/// Your Machines carries the menu bar across its top, above every step, with
/// the menus a macOS viewer shows while that window is in front: no session
/// state, no full screen, and no zoom for a window that cannot be resized,
/// though it can be minimized.
@MainActor
func testGtkYourMachinesMenuBarTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' menu bar needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: []))
    let content = gtk_window_get_child(sensorium_gtk_window(window.toplevel))
    let first = gtk_widget_get_first_child(content)
    expect(
        first.map { UnsafeMutableRawPointer($0) } == window.menuBar.widget,
        "the menu bar is the first thing in the window, above the steps"
    )
    let expected = ViewerMenuPlan.rows(of: LinuxViewerMenu.bar(ViewerMenuBarState(canFullScreen: false, zoomEnabled: false)))
    let drawn = window.menuBar.rows()
    for (index, pair) in zip(expected, drawn).enumerated() where pair.0 != pair.1 {
        expect(false, "row \(index) differs: model \(pair.0), Your Machines \(pair.1)")
    }
    expect(expected.count == drawn.count, "the model has \(expected.count) rows, Your Machines drew \(drawn.count)")
    print("PASS: Your Machines carries the shared menu bar above every step")
}

/// Every item Your Machines enables does what the macOS one does.
@MainActor
func testGtkYourMachinesMenuCommandsTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' menu commands need a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check them")
        return
    }
    let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: []))
    defer { window.hide() }
    window.show()
    var quitRequested = false
    window.onCloseRequested = { quitRequested = true }
    let stack = gtk_widget_get_next_sibling(gtk_widget_get_first_child(gtk_window_get_child(sensorium_gtk_window(window.toplevel))))
    let visibleStep = { String(cString: gtk_stack_get_visible_child_name(sensorium_gtk_stack(stack))) }

    window.showCodeStep(for: nil)
    pump(seconds: 0.2)
    expect(window.menuBar.activate(title: "Select All"), "Select All is enabled while the code field has focus")
    let focus = gtk_window_get_focus(sensorium_gtk_window(window.toplevel))
    gtk_editable_set_text(sensorium_gtk_editable(focus), "100.64.1.2")
    _ = window.menuBar.activate(title: "Select All")
    var start: Int32 = 0
    var end: Int32 = 0
    _ = gtk_editable_get_selection_bounds(sensorium_gtk_editable(focus), &start, &end)
    expect(start == 0 && end == 10, "Select All selects the focused field's text, got \(start)..<\(end)")

    expect(window.menuBar.activate(title: "Your Machines\u{2026}"), "Your Machines is enabled")
    expect(visibleStep() == "list", "Your Machines goes back to the list, got \(visibleStep())")

    let before = g_list_model_get_n_items(gtk_window_get_toplevels())
    expect(window.menuBar.activate(title: "About Sensorium"), "About is enabled")
    pump(seconds: 0.2)
    let about = aboutDialog()
    expect(g_list_model_get_n_items(gtk_window_get_toplevels()) == before + 1 && about != nil, "About opens its own window")
    if let about {
        let copyright = gtk_about_dialog_get_copyright(OpaquePointer(about)).map { String(cString: $0) }
        expect(copyright == SensoriumCredit.copyrightLine, "About credits \(SensoriumCredit.copyrightLine), got \(String(describing: copyright))")
        gtk_window_destroy(sensorium_gtk_window(about))
    }

    expect(!window.menuBar.activate(title: "Zoom"), "Zoom is disabled for a window that cannot be resized")
    expect(window.menuBar.activate(title: "Quit Sensorium") && quitRequested, "Quit takes the quit path")
    print("PASS: Your Machines' menu items quit, go back to the list, show About and edit the focused field")
}

/// With the desktop's text scaled to 125%, the menu bar still fits Your
/// Machines' fixed 460-point width, through Help, without widening it.
@MainActor
func testGtkYourMachinesMenuBarFitsLargeTextTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' menu bar width needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    /// How far the last title's right edge reaches into the bar, the bar's
    /// own width, and the window's.
    func measured(textScale: Double) -> (titles: Double, bar: Int32, window: Int32) {
        setXftDPI(Int32(96 * textScale * 1024))
        let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: []))
        defer { window.hide() }
        window.show()
        pump(seconds: 0.3)
        let bar = sensorium_gtk_widget(window.menuBar.widget)
        var reach = 0.0
        var item = gtk_widget_get_first_child(bar)
        while let current = item {
            var from = graphene_point_t(x: Float(gtk_widget_get_width(current)), y: 0)
            var to = graphene_point_t()
            if gtk_widget_compute_point(current, bar, &from, &to) != 0 {
                reach = max(reach, Double(to.x))
            }
            item = gtk_widget_get_next_sibling(current)
        }
        return (reach, gtk_widget_get_width(bar), gtk_widget_get_width(sensorium_gtk_widget(window.toplevel)))
    }
    let normal = measured(textScale: 1)
    let large = measured(textScale: 1.25)
    setXftDPI(96 * 1024)
    expect(normal.titles > 0, "the bar lays out its titles, got \(normal)")
    for (label, size) in [("100%", normal), ("125%", large)] {
        expect(
            size.titles <= Double(size.bar) - Double(ViewerChromeMetrics.MenuBar.barPaddingX),
            "at \(label) text every title fits inside the bar, \(size.titles) of \(size.bar)"
        )
    }
    expect(normal.window == 460, "at 100% text the window is 460 points wide, got \(normal.window) (bar \(normal.bar), titles end at \(normal.titles))")
    expect(large.window == 460, "at 125% text the window stays 460 points wide, got \(large.window) (\(normal.window) at 100%, bar \(normal.bar) then \(large.bar), titles end at \(normal.titles) then \(large.titles))")
    print("PASS: the menu bar fits Your Machines' 460 points at 125% text (titles end at \(normal.titles) at 100%, \(large.titles) at 125%, bar \(large.bar))")
}

@MainActor
private func setXftDPI(_ dpi: Int32) {
    let settings = gtk_settings_get_default()
    var value = GValue()
    g_value_init(&value, g_type_from_name("gint"))
    g_value_set_int(&value, dpi)
    g_object_set_property(sensorium_g_object(UnsafeMutableRawPointer(settings)), "gtk-xft-dpi", &value)
    g_value_unset(&value)
}

private func pump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(5_000)
    }
}

@MainActor
private func aboutDialog() -> UnsafeMutableRawPointer? {
    let toplevels = gtk_window_get_toplevels()
    for index in 0..<g_list_model_get_n_items(toplevels) {
        guard let item = g_list_model_get_item(toplevels, index) else { continue }
        defer { g_object_unref(item) }
        if sensorium_is_about_dialog(item) != 0 { return item }
    }
    return nil
}
#else
func testGtkYourMachinesMenuBarTests() {}
func testGtkYourMachinesMenuCommandsTests() {}
func testGtkYourMachinesMenuBarFitsLargeTextTests() {}
#endif
