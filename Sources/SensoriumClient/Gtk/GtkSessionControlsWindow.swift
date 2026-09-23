#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumCore

/// The session's own choices, in a window: which screen, which resolution,
/// what to start with next time, how many displays, what scale, and whether
/// the clipboard is shared.
///
/// macOS hangs these off a menu bar. A Wayland desktop gives a client no menu
/// bar to hang anything off, so the same choices are one window the session
/// chord opens. Every row, every checkmark and every disabled state is
/// `SessionControlsWindowModel`'s decision; this holds widgets and reports
/// which row was pressed.
@MainActor
public final class GtkSessionControlsWindow {
    private let window: GtkRef
    private let body: GtkRef
    private let activate: (SessionControlsActivation) -> Void
    /// Boxed closures the rows currently on screen reach back through.
    /// Dropped whenever the rows are rebuilt, along with the widgets that
    /// held them.
    private var rowCallbacks: [AnyObject] = []
    private var windowCallbacks: [AnyObject] = []
    private var isPresented = false

    public init(activate: @escaping (SessionControlsActivation) -> Void) {
        self.activate = activate
        GtkToolkit.start()
        window = gtkRef(gtk_window_new())
        gtk_window_set_title(sensorium_gtk_window(window), "Session")
        gtk_window_set_default_size(sensorium_gtk_window(window), 380, 560)
        gtk_widget_add_css_class(sensorium_gtk_widget(window), "sensorium")

        let scroller = gtkRef(gtk_scrolled_window_new())
        body = GtkWidgets.box(vertical: true, spacing: 16)
        for edge in [gtk_widget_set_margin_start, gtk_widget_set_margin_end,
                     gtk_widget_set_margin_top, gtk_widget_set_margin_bottom] {
            edge(sensorium_gtk_widget(body), 20)
        }
        gtk_scrolled_window_set_child(sensorium_gtk_scrolled_window(scroller), sensorium_gtk_widget(body))
        gtk_window_set_child(sensorium_gtk_window(window), sensorium_gtk_widget(scroller))

        // Closing this window ends nothing: it is a set of choices about a
        // session that stays live behind it.
        let closeCallback = GtkCallback { [weak self] in self?.close() }
        windowCallbacks.append(closeCallback)
        let closeRequest: @convention(c) (GtkRef?, GtkRef?) -> gboolean = { _, data in
            gtkRunCallback(data)
            return 1
        }
        gtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(closeCallback).toOpaque())
    }

    public func present(model: SessionControlsWindowModel) {
        update(model: model)
        isPresented = true
        gtk_window_present(sensorium_gtk_window(window))
    }

    /// Redraws the rows from a model that has changed. Does nothing while the
    /// window has never been shown: a session that pushes a new display count
    /// before anyone asked for this window should not make one appear.
    public func update(model: SessionControlsWindowModel) {
        guard isPresented || rowCallbacks.isEmpty else { return }
        rowCallbacks = []
        GtkWidgets.removeAllChildren(of: body)
        for section in model.sections {
            let group = GtkWidgets.box(vertical: true, spacing: 8)
            GtkWidgets.append(
                GtkWidgets.label(section.title.uppercased(), cssClass: GtkViewerStyle.Class.eyebrow),
                to: group
            )
            if section.rows.isEmpty {
                GtkWidgets.append(
                    GtkWidgets.label(Self.nothingToOffer, cssClass: GtkViewerStyle.Class.muted),
                    to: group
                )
            }
            for row in section.rows {
                GtkWidgets.append(button(for: row), to: group)
            }
            if let note = section.note {
                GtkWidgets.append(GtkWidgets.label(note, cssClass: GtkViewerStyle.Class.muted), to: group)
            }
            GtkWidgets.append(group, to: body)
        }
    }

    public func close() {
        isPresented = false
        gtk_widget_set_visible(sensorium_gtk_widget(window), 0)
    }

    private func button(for row: SessionControlsRow) -> GtkRef {
        // The checkmark is part of the title rather than a separate widget:
        // a row that is the current choice reads as one line either way, and
        // one line is what a person scanning a list reads.
        let title = (row.isSelected ? "\u{2713} " : "   ") + row.title
        let button = GtkWidgets.button(title, cssClass: row.isSelected ? GtkViewerStyle.Class.primary : nil)
        gtk_widget_set_halign(sensorium_gtk_widget(button), GTK_ALIGN_FILL)
        GtkWidgets.setEnabled(row.isEnabled, on: button)
        let activation = row.activation
        let callback = GtkCallback { [weak self] in self?.activate(activation) }
        rowCallbacks.append(callback)
        gtkConnect(button, "clicked", gtkClickedHandler, Unmanaged.passUnretained(callback).toOpaque())
        return button
    }

    /// Said rather than left blank: an empty group reads as a window that
    /// failed to load, and this one is a fact about the session.
    private static let nothingToOffer = "Nothing to choose here in this session."
}
#endif
