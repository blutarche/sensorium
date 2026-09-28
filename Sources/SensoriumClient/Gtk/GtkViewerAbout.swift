#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumCore

/// The About window the app menu's first item opens: the name, the icon and
/// the credit line the macOS About panel shows.
@MainActor
enum GtkViewerAbout {
    static func present(over parent: GtkRef) {
        let dialog = gtk_about_dialog_new()
        let about = OpaquePointer(dialog)
        gtk_about_dialog_set_program_name(about, ViewerApplicationIdentity.applicationName)
        gtk_about_dialog_set_logo_icon_name(about, ViewerApplicationIdentity.applicationID)
        gtk_about_dialog_set_copyright(about, SensoriumCredit.copyrightLine)
        gtk_about_dialog_set_license_type(about, GTK_LICENSE_GPL_3_0)
        gtk_window_set_transient_for(sensorium_gtk_window(dialog), sensorium_gtk_window(parent))
        gtk_window_present(sensorium_gtk_window(dialog))
    }
}
#endif
