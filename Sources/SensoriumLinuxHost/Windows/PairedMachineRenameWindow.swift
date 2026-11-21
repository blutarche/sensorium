#if os(Linux)
import CGLib
import CGtk4
import Foundation

/// The small window a paired machine's Rename opens: a heading naming the
/// machine, one field holding the name shown now, and Cancel and Rename.
/// Return renames and Escape cancels. What it hands back is the field as
/// typed; the caller decides what is stored.
@MainActor
public final class PairedMachineRenameWindow {
    private let window: HostGtkRef
    private let entry: HostGtkRef
    private var retained: [AnyObject] = []

    /// `currentName` is empty for a machine with no name of its own.
    public init(
        currentName: String,
        appearance: IndicatorAppearance,
        onRename: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        HostWindowTheme.install(appearance)
        typealias Space = HostWindowMetrics.Space
        typealias Class = HostWindowStyle.Class
        window = hostGtkRef(gtk_window_new())
        gtk_window_set_title(sensorium_gtk_window(window), HostWindowCopy.windowTitle)
        gtk_window_set_default_size(sensorium_gtk_window(window), Int32(HostWindowMetrics.renameWidth), -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        HostWidgets.addClass(Class.window, to: window)

        let title = HostWidgets.label(HostWindowCopy.renameHeading(currentName: currentName), classes: [Class.sheetTitle])
        entry = hostGtkRef(gtk_entry_new())
        gtk_editable_set_text(sensorium_gtk_editable(entry), currentName)
        gtk_entry_set_placeholder_text(sensorium_gtk_entry(entry), currentName)
        gtk_widget_set_hexpand(HostWidgets.widget(entry), 1)
        let hint = HostWidgets.label(HostWindowCopy.renameHint, classes: [Class.detail])

        let window = self.window
        let entry = self.entry
        let finish: @MainActor (Bool) -> Void = { rename in
            let typed = gtk_editable_get_text(sensorium_gtk_editable(entry)).map { String(cString: $0) } ?? ""
            gtk_window_destroy(sensorium_gtk_window(window))
            if rename { onRename(typed) } else { onCancel() }
        }
        let rename = HostGtkCallback { finish(true) }
        let cancel = HostGtkCallback { finish(false) }
        retained.append(contentsOf: [rename, cancel])
        let cancelButton = HostWidgets.titledButton(
            HostWindowCopy.renameCancel, classes: [Class.sheetButton, Class.sheetCancel], onClick: cancel
        )
        let renameButton = HostWidgets.titledButton(
            HostWindowCopy.renameConfirm, classes: [Class.sheetButton], onClick: rename
        )
        let buttons = HostWidgets.box(vertical: false, spacing: Int32(Space.xs))
        gtk_widget_set_halign(HostWidgets.widget(buttons), GTK_ALIGN_END)
        for button in [cancelButton, renameButton] {
            gtk_widget_set_hexpand(HostWidgets.widget(button), 0)
            HostWidgets.append(button, to: buttons)
        }

        HostWidgets.setMargins(hint, bottom: Space.md - Space.xs)
        let column = HostWidgets.box(vertical: true, spacing: Int32(Space.xs))
        gtk_widget_set_size_request(HostWidgets.widget(column), Int32(HostWindowMetrics.renameWidth - Space.lg * 2), -1)
        HostWidgets.setMargins(column, top: Space.lg, bottom: Space.lg, start: Space.lg, end: Space.lg)
        for view in [title, entry, hint, buttons] { HostWidgets.append(view, to: column) }
        gtk_window_set_child(sensorium_gtk_window(window), HostWidgets.widget(column))
        gtk_window_set_default_widget(sensorium_gtk_window(window), HostWidgets.widget(renameButton))

        // Return in the field renames; Escape anywhere cancels.
        hostGtkConnect(entry, "activate", hostGtkClicked, Unmanaged.passUnretained(rename).toOpaque())
        let keys = HostGtkKeyHandler { keyval in
            guard keyval == guint(GDK_KEY_Escape) else { return false }
            finish(false)
            return true
        }
        retained.append(keys)
        let controller = hostGtkRef(gtk_event_controller_key_new())
        hostGtkConnect(controller, "key-pressed", hostGtkKeyPressed, Unmanaged.passUnretained(keys).toOpaque())
        gtk_widget_add_controller(HostWidgets.widget(window), sensorium_gtk_event_controller(controller))
        let closeRequest: @convention(c) (HostGtkRef?, HostGtkRef?) -> gboolean = { _, data in
            hostGtkRun(data)
            return 1
        }
        hostGtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(cancel).toOpaque())
    }

    /// The toplevel, for a probe that draws it.
    public var toplevel: UnsafeMutableRawPointer { window }

    /// Takes the window away without renaming.
    public func dismiss() {
        gtk_window_destroy(sensorium_gtk_window(window))
    }

    /// Puts the window up over `parent` with the cursor in the field.
    public func show(over parent: UnsafeMutableRawPointer? = nil) {
        if let parent {
            gtk_window_set_transient_for(sensorium_gtk_window(window), sensorium_gtk_window(parent))
            gtk_window_set_modal(sensorium_gtk_window(window), 1)
        }
        gtk_window_present(sensorium_gtk_window(window))
        gtk_widget_grab_focus(HostWidgets.widget(entry))
        gtk_editable_select_region(sensorium_gtk_editable(entry), 0, -1)
    }
}
#endif
