#if canImport(CGtk4)
import CGtk4

/// Opens a web page in the person's default browser. Inside a sandbox GTK
/// hands the request to the desktop's OpenURI portal.
@MainActor
enum GtkURIOpener {
    static func open(_ uri: String) {
        guard let launcher = gtk_uri_launcher_new(uri) else { return }
        gtk_uri_launcher_launch(launcher, nil, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(launcher))
    }
}
#endif
