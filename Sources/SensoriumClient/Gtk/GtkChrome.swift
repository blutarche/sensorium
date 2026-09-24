#if canImport(CGtk4)
import CGtk4
import Foundation

/// One GTK object, held the way every other one here is held: as a plain
/// pointer. Which GTK types this release declares publicly and which it keeps
/// opaque is the shim's business, not this side's.
typealias GtkRef = UnsafeMutableRawPointer

/// The object a GTK constructor just handed back. Every one of them is
/// imported as an optional, and a constructor that returns nothing is a
/// toolkit that has already failed rather than a case a window can recover
/// from.
func gtkRef(_ object: UnsafeMutableRawPointer?) -> GtkRef {
    guard let object else { preconditionFailure("GTK built no object") }
    return object
}

/// The same, for the GTK types this release keeps opaque, which Swift imports
/// as `OpaquePointer` rather than as a pointer to a struct.
func gtkRef(_ object: OpaquePointer?) -> GtkRef {
    guard let object else { preconditionFailure("GTK built no object") }
    return UnsafeMutableRawPointer(object)
}

/// A Swift closure a GTK signal can reach. GTK hands a handler one `gpointer`
/// of its own, so the closure is boxed and the box's address is what GTK
/// carries; the window that made the box keeps it alive for as long as the
/// widget it belongs to is on screen.
/// Sendable because every one of these is made, run and dropped on the one
/// thread GTK's event loop runs on, which is the main actor's -- see
/// `GLibMainLoop`. The compiler cannot see that a GTK signal is delivered
/// there, so the promise is made here by hand.
final class GtkCallback: @unchecked Sendable {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// `g_signal_connect`, with the handler's real signature stated at the call
/// site. The shim casts it the way `G_CALLBACK` does.
@discardableResult
func gtkConnect<Handler>(
    _ instance: GtkRef,
    _ signal: String,
    _ handler: Handler,
    _ data: GtkRef?
) -> gulong {
    let erased = unsafeBitCast(handler, to: (@convention(c) () -> Void).self)
    return sensorium_signal_connect(instance, signal, erased, data)
}

/// Runs the boxed closure GTK carried through a signal's user-data pointer.
/// Every GTK callback in this viewer arrives on the event loop's own thread,
/// which is the main actor's thread -- see `GLibMainLoop`.
func gtkRunCallback(_ data: GtkRef?) {
    guard let data else { return }
    // Bound to a local first: a handler that rebuilds the page it was clicked
    // on drops the box holding it, and running the closure through the local
    // keeps it alive until it returns.
    let callback = Unmanaged<GtkCallback>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { callback.run() }
}

/// The plainest `clicked` handler there is: the boxed closure, and nothing
/// else. Shared by every button this viewer builds.
let gtkClickedHandler: @convention(c) (GtkRef?, GtkRef?) -> Void = { _, data in
    gtkRunCallback(data)
}

/// A menu action's closure. A row's menu names the row it belongs to by
/// number, which is the one thing GTK's own action machinery can carry for
/// us, so the handler is handed that number rather than the row.
/// Sendable for the same reason `GtkCallback` is.
final class GtkIndexedCallback: @unchecked Sendable {
    let run: @MainActor (Int32) -> Void

    init(_ run: @escaping @MainActor (Int32) -> Void) {
        self.run = run
    }
}

/// Runs the boxed closure GTK carried, handing it the number the caller
/// resolved -- a menu action's own parameter, or the key that was pressed.
func gtkRunIndexedCallback(_ data: GtkRef?, _ index: Int32) {
    guard let data else { return }
    let callback = Unmanaged<GtkIndexedCallback>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { callback.run(index) }
}

let gtkActionActivateHandler: @convention(c) (GtkRef?, OpaquePointer?, GtkRef?) -> Void = { _, parameter, data in
    guard let parameter else { return }
    gtkRunIndexedCallback(data, g_variant_get_int32(parameter))
}

/// The viewer's own palette, as one stylesheet. Generated from
/// `ViewerPalette`, which both platforms read, so the colours in a GTK window
/// and the colours in an AppKit one are the same values and not two lists that
/// drift.
enum GtkViewerStyle {
    /// Class names the window layer puts on widgets. Named here so a rule and
    /// the widget it styles cannot disagree about spelling.
    enum Class {
        static let heading = "sensorium-heading"
        static let sentence = "sensorium-sentence"
        static let muted = "sensorium-muted"
        static let bad = "sensorium-bad"
        static let rowName = "sensorium-row-name"
        static let rowDetail = "sensorium-row-detail"
        static let row = "sensorium-row"
        static let dotOnline = "sensorium-dot-online"
        static let dotOffline = "sensorium-dot-offline"
        static let dotActivity = "sensorium-dot-activity"
        static let primary = "sensorium-primary"
        static let link = "sensorium-link"
        static let code = "sensorium-code"
        static let eyebrow = "sensorium-eyebrow"
    }

    static var stylesheet: String {
        let palette = ViewerPalette.self
        return """
        window.sensorium, window.sensorium > * { background-color: \(palette.chromeBg.hexString); }
        window.sensorium label { color: \(palette.ink.hexString); }
        .\(Class.heading) { font-size: 20px; font-weight: 500; color: \(palette.ink.hexString); }
        .\(Class.eyebrow) { font-family: monospace; font-size: 11px; letter-spacing: 2px; color: \(palette.muted.hexString); }
        .\(Class.sentence) { font-size: 13px; color: \(palette.ink.hexString); }
        .\(Class.muted) { font-size: 13px; color: \(palette.muted.hexString); }
        .\(Class.bad) { font-size: 13px; color: \(palette.bad.hexString); }
        .\(Class.rowName) { font-size: 14px; color: \(palette.ink.hexString); }
        .\(Class.rowDetail) { font-size: 12px; color: \(palette.muted.hexString); }
        .\(Class.row) { background-color: \(palette.chromeBg2.hexString); border: 1px solid \(palette.chromeBorder2.hexString); border-radius: 4px; padding: 8px; }
        .\(Class.row):hover { border-color: \(palette.accent.hexString); }
        .\(Class.dotOnline) { color: \(palette.ok.hexString); }
        .\(Class.dotOffline) { color: \(palette.muted2.hexString); }
        .\(Class.dotActivity) { color: \(palette.warn.hexString); }
        .\(Class.primary) { background-image: none; background-color: \(palette.accent.hexString); color: \(palette.chromeBg.hexString); border: none; }
        .\(Class.link) { background: none; border: none; color: \(palette.accent.hexString); padding: 2px 0; }
        entry { background-image: none; background-color: \(palette.bg4.hexString); color: \(palette.ink.hexString); border: 1px solid \(palette.line.hexString); border-radius: 2px; }
        entry:focus-within { border-color: \(palette.accent.hexString); }
        .\(Class.code) { font-family: monospace; font-size: 20px; letter-spacing: 4px; }
        """
    }

    /// Installed once per process, on the display GTK opened. A second install
    /// would stack a second copy of every rule.
    private nonisolated(unsafe) static var isInstalled = false

    @MainActor
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        sensorium_prefer_dark_theme()
        guard let display = gdk_display_get_default() else { return }
        let provider = gtkRef(gtk_css_provider_new())
        gtk_css_provider_load_from_string(sensorium_gtk_css_provider(provider), stylesheet)
        gtk_style_context_add_provider_for_display(
            display,
            sensorium_gtk_style_provider(provider),
            guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }
}

/// The handful of widgets this viewer builds, in the shapes it builds them.
/// Nothing here decides anything -- every word and every enablement is handed
/// in by the caller, which got it from a portable model.
enum GtkWidgets {
    static func box(vertical: Bool, spacing: Int32) -> GtkRef {
        let box = gtkRef(gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing))
        gtk_widget_set_halign(sensorium_gtk_widget(box), GTK_ALIGN_FILL)
        return box
    }

    static func append(_ child: GtkRef, to parent: GtkRef) {
        gtk_box_append(sensorium_gtk_box(parent), sensorium_gtk_widget(child))
    }

    static func removeAllChildren(of parent: GtkRef) {
        while let child = gtk_widget_get_first_child(sensorium_gtk_widget(parent)) {
            gtk_box_remove(sensorium_gtk_box(parent), child)
        }
    }

    static func label(_ text: String, cssClass: String, wraps: Bool = true) -> GtkRef {
        let label = gtkRef(gtk_label_new(text))
        gtk_label_set_xalign(sensorium_gtk_label(label), 0)
        gtk_label_set_wrap(sensorium_gtk_label(label), wraps ? 1 : 0)
        gtk_label_set_max_width_chars(sensorium_gtk_label(label), 52)
        gtk_widget_set_halign(sensorium_gtk_widget(label), GTK_ALIGN_START)
        gtk_widget_add_css_class(sensorium_gtk_widget(label), cssClass)
        return label
    }

    static func button(_ title: String, cssClass: String?) -> GtkRef {
        let button = gtkRef(gtk_button_new_with_label(title))
        gtk_widget_set_halign(sensorium_gtk_widget(button), GTK_ALIGN_START)
        if let cssClass {
            gtk_widget_add_css_class(sensorium_gtk_widget(button), cssClass)
        }
        return button
    }

    static func entry(placeholder: String, cssClass: String?) -> GtkRef {
        let entry = gtkRef(gtk_entry_new())
        gtk_entry_set_placeholder_text(sensorium_gtk_entry(entry), placeholder)
        gtk_widget_set_hexpand(sensorium_gtk_widget(entry), 1)
        if let cssClass {
            gtk_widget_add_css_class(sensorium_gtk_widget(entry), cssClass)
        }
        return entry
    }

    static func text(of entry: GtkRef) -> String {
        guard let value = gtk_editable_get_text(sensorium_gtk_editable(entry)) else { return "" }
        return String(cString: value)
    }

    static func setText(_ value: String, on entry: GtkRef) {
        gtk_editable_set_text(sensorium_gtk_editable(entry), value)
    }

    static func setEnabled(_ enabled: Bool, on widget: GtkRef) {
        gtk_widget_set_sensitive(sensorium_gtk_widget(widget), enabled ? 1 : 0)
    }
}
#endif
