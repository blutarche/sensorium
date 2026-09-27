#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient

/// The activity dot pulses the way the macOS one does, and holds still when
/// the desktop turns animations off, as the macOS one does under Reduce
/// Motion. A pulse only runs in a window a compositor is drawing, so this
/// opens one, and runs only when `SENSORIUM_GTK_WINDOW_TESTS=1` says the
/// Wayland display it would open on is a scratch one.
@MainActor
func testGtkActivityPulseTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: the activity dot's pulse needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    GtkToolkit.start()

    let animated = dotShades(animationsEnabled: true)
    expect(animated.count > 1, "the activity dot pulses while animations are on -- it drew only \(animated)")
    let still = dotShades(animationsEnabled: false)
    expect(still.count == 1, "the activity dot holds still while animations are off -- it drew \(still)")

    print("PASS: the activity dot pulses, and holds still when the desktop turns animations off")
}

/// Every colour the middle of an activity dot is drawn in over about a
/// second, with GTK's own animation setting as given.
@MainActor
private func dotShades(animationsEnabled: Bool) -> Set<Int> {
    let settings = gtk_settings_get_default()
    var value = GValue()
    g_value_init(&value, g_type_from_name("gboolean"))
    g_value_set_boolean(&value, animationsEnabled ? 1 : 0)
    g_object_set_property(sensorium_g_object(UnsafeMutableRawPointer(settings)), "gtk-enable-animations", &value)
    g_value_unset(&value)

    let window = gtk_window_new()!
    let content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    let margin: Int32 = 8
    let size: Int32 = 24
    gtk_widget_set_margin_start(content, margin)
    gtk_widget_set_margin_top(content, margin)
    gtk_widget_set_margin_end(content, margin)
    gtk_widget_set_margin_bottom(content, margin)
    let dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    gtk_widget_set_size_request(dot, size, size)
    gtk_widget_add_css_class(dot, GtkViewerStyle.Class.dotActivity)
    gtk_box_append(sensorium_gtk_box(content), dot)
    gtk_window_set_child(sensorium_gtk_window(window), content)
    gtk_window_present(sensorium_gtk_window(window))
    defer { gtk_window_destroy(sensorium_gtk_window(window)) }

    let path = NSTemporaryDirectory() + "sensorium-activity-dot-\(UUID().uuidString).png"
    defer { try? FileManager.default.removeItem(atPath: path) }
    pump(seconds: 1)
    var shades = Set<Int>()
    for _ in 0..<20 {
        pump(seconds: 0.05)
        let scale = sensorium_window_content_write_png(window, path)
        guard scale > 0 else { continue }
        let middle = (margin + size / 2) * scale
        shades.insert(Int(sensorium_png_pixel(path, middle, middle)))
    }
    expect(!shades.isEmpty, "the activity dot's window was drawn")
    return shades
}

@MainActor
private func pump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(5_000)
    }
}
#else
/// Nothing to check outside GTK: the pulse checked here is a GTK stylesheet rule.
@MainActor
func testGtkActivityPulseTests() {}
#endif
