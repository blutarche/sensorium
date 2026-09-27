#if canImport(CGtk4)
import CGtk4
import SensoriumClient

/// GTK derives a Wayland window's `app_id` from the process name, and a
/// taskbar's icon from the toolkit's default, where nothing else is set. Both
/// setters are plain GLib/GTK state, so this checks them without opening a
/// display -- unlike `GtkToolkit.start()`, which does.
@MainActor
func testGtkApplicationIdentityTests() {
    GtkToolkit.applyProcessIdentity()
    GtkToolkit.applyDefaultIcon()

    expect(
        g_get_prgname().map(String.init(cString:)) == "com.sensorium.viewer",
        "applyProcessIdentity() sets the process name GTK derives a Wayland app_id from"
    )
    expect(
        gtk_window_get_default_icon_name().map(String.init(cString:)) == "com.sensorium.viewer",
        "applyDefaultIcon() sets the icon name a taskbar shows before any window has one"
    )

    print("PASS: GtkToolkit sets the process name and default icon a Linux desktop matches this viewer's launcher entry by")
}
#else
/// Nothing to check outside GTK: only that build matches this viewer to a
/// launcher entry on Linux.
@MainActor
func testGtkApplicationIdentityTests() {}
#endif
