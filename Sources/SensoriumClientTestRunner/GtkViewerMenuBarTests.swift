#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient

/// The GTK menu bar draws `LinuxViewerMenu.bar` item for item: the same
/// titles, order, separators, submenus, chords, checkmarks and enabled
/// states, read back out of the menu model and actions GTK is given. GTK
/// needs a display, so this runs only when `SENSORIUM_GTK_WINDOW_TESTS=1`
/// says the Wayland display it would open is a scratch one.
@MainActor
func testGtkViewerMenuBarMatchesModelTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: the GTK menu bar needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    GtkToolkit.start()
    let window = gtk_window_new()!
    defer { gtk_window_destroy(sensorium_gtk_window(window)) }
    let bar = GtkViewerMenuBar(window: UnsafeMutableRawPointer(window))
    for state in [ViewerMenuBarState.initial, menuBarFixtureState()] {
        let model = LinuxViewerMenu.bar(state)
        bar.update(model)
        let expected = ViewerMenuPlan.rows(of: model)
        let drawn = bar.rows()
        for (index, pair) in zip(expected, drawn).enumerated() where pair.0 != pair.1 {
            expect(false, "row \(index) differs: model \(pair.0), GTK \(pair.1)")
        }
        expect(expected.count == drawn.count, "the model has \(expected.count) rows, GTK drew \(drawn.count)")
    }
    print("PASS: the GTK menu bar draws the shared menu model item for item")
}

/// A key press chooses the enabled item that shows its chord, Ctrl standing
/// in for Command. Edit's chords stay with the focused field, which already
/// handles them, and a disabled item's chord chooses nothing.
@MainActor
func testGtkViewerMenuBarKeyChordsTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: the GTK menu bar needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    GtkToolkit.start()
    let window = gtk_window_new()!
    defer { gtk_window_destroy(sensorium_gtk_window(window)) }
    let bar = GtkViewerMenuBar(window: UnsafeMutableRawPointer(window))
    bar.update(LinuxViewerMenu.bar(ViewerMenuBarState(canFullScreen: false, zoomEnabled: false)))
    let control = GDK_CONTROL_MASK
    let shift = GDK_SHIFT_MASK
    let cases: [(guint, GdkModifierType, ViewerMenuCommand?, String)] = [
        (guint(GDK_KEY_q), control, .quit, "Ctrl-Q quits"),
        (guint(GDK_KEY_Q), control, .quit, "Ctrl-Q quits with Caps Lock on"),
        (guint(GDK_KEY_1), control, .showYourMachines, "Ctrl-1 shows Your Machines"),
        (guint(GDK_KEY_q), GdkModifierType(0), nil, "Q alone is typing"),
        (guint(GDK_KEY_q), GdkModifierType(control.rawValue | shift.rawValue), nil, "Ctrl-Shift-Q is no item's chord"),
        (guint(GDK_KEY_c), control, nil, "Ctrl-C stays with the focused field"),
        (guint(GDK_KEY_f), GdkModifierType(control.rawValue | GDK_SUPER_MASK.rawValue), nil, "full screen's chord does nothing while it is disabled")
    ]
    for (keyval, state, command, description) in cases {
        let chosen = bar.command(keyval: keyval, state: state)
        expect(chosen == command, "\(description), got \(String(describing: chosen))")
    }
    print("PASS: a menu chord chooses its enabled item, and leaves Edit's chords to the focused field")
}

/// The label the painted session bar draws for a chord is the one GTK draws
/// beside the same accelerator in Your Machines.
@MainActor
func testGtkChordLabelsMatchGtkTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: GTK's accelerator labels need a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check them")
        return
    }
    GtkToolkit.start()
    for row in ViewerMenuPlan.rows(of: LinuxViewerMenu.bar(.initial)) where !row.keyEquivalent.isEmpty {
        guard let accel = LinuxViewerMenu.accelerator(keyEquivalent: row.keyEquivalent, modifiers: row.modifiers) else { continue }
        var key: guint = 0
        var mods = GdkModifierType(0)
        _ = gtk_accelerator_parse(accel, &key, &mods)
        let gtkLabel = gtk_accelerator_get_label(key, mods).map { pointer -> String in
            defer { g_free(pointer) }
            return String(cString: pointer)
        }
        let ours = LinuxViewerMenu.chordLabel(keyEquivalent: row.keyEquivalent, modifiers: row.modifiers, style: .yourMachines)
        expect(ours == gtkLabel, "\(row.title): GTK spells \(accel) \(String(describing: gtkLabel)), ours \(String(describing: ours))")
    }
    print("PASS: every menu chord is spelled the way GTK spells its accelerator")
}
#else
func testGtkChordLabelsMatchGtkTests() {}
func testGtkViewerMenuBarMatchesModelTests() {}
func testGtkViewerMenuBarKeyChordsTests() {}
#endif
