#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumCore

/// The About window the app menu's first item opens: the name, the icon and
/// the credit line the macOS About panel shows.
///
/// Nothing in it is a control. The macOS panel has none, and a GTK label that
/// can be selected also takes keyboard focus, which opens the window with its
/// version highlighted and sends the first Tab onto text.
@MainActor
enum GtkViewerAbout {
    static func present(over parent: GtkRef) {
        guard let dialog = gtk_about_dialog_new() else { return }
        let about = OpaquePointer(dialog)
        gtk_about_dialog_set_program_name(about, ViewerApplicationIdentity.applicationName)
        gtk_about_dialog_set_version(about, ViewerRelease.version)
        gtk_about_dialog_set_logo_icon_name(about, ViewerApplicationIdentity.applicationID)
        // The license is named in the credit line, as on macOS. A license
        // type would add a paragraph that has a link in it.
        gtk_about_dialog_set_copyright(about, SensoriumCredit.copyrightLine)
        gtk_widget_add_css_class(sensorium_gtk_widget(dialog), "sensorium")
        makeTextInert(under: dialog)
        gtk_window_set_transient_for(sensorium_gtk_window(dialog), sensorium_gtk_window(parent))
        gtk_window_present(sensorium_gtk_window(dialog))
    }

    private static func makeTextInert(under widget: UnsafeMutablePointer<GtkWidget>) {
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if String(cString: gtk_widget_get_css_name(current)) == "label" {
                gtk_label_set_selectable(sensorium_gtk_label(current), 0)
                gtk_widget_set_focusable(current, 0)
            }
            makeTextInert(under: current)
            child = gtk_widget_get_next_sibling(current)
        }
    }
}
#endif
