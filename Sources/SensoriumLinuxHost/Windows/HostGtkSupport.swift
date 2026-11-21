#if os(Linux)
import CCairo
import CGLib
import CGtk4
import Foundation

/// One GTK object, held as a plain pointer. Which GTK types a release
/// declares publicly and which it keeps opaque is the shim's business.
typealias HostGtkRef = UnsafeMutableRawPointer

func hostGtkRef(_ object: UnsafeMutableRawPointer?) -> HostGtkRef {
    guard let object else { preconditionFailure("GTK built no object") }
    return object
}

func hostGtkRef(_ object: OpaquePointer?) -> HostGtkRef {
    guard let object else { preconditionFailure("GTK built no object") }
    return UnsafeMutableRawPointer(object)
}

/// A Swift closure a GTK signal can reach: boxed, with the box's address
/// carried through GTK's user-data pointer. The window that makes a box keeps
/// it alive for as long as the widget it belongs to is on screen. Every one of
/// these runs on the thread GTK's event loop runs on, which is the main
/// actor's, so the promise that it is `Sendable` is made here by hand.
final class HostGtkCallback: @unchecked Sendable {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

func hostGtkRun(_ data: HostGtkRef?) {
    guard let data else { return }
    // Bound first: a handler that rebuilds the page it was clicked on drops
    // the box holding it, and the local keeps it alive until it returns.
    let callback = Unmanaged<HostGtkCallback>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { callback.run() }
}

let hostGtkClicked: @convention(c) (HostGtkRef?, HostGtkRef?) -> Void = { _, data in
    hostGtkRun(data)
}

/// A key controller's closure: whether it took the key.
final class HostGtkKeyHandler: @unchecked Sendable {
    let run: @MainActor (guint) -> Bool

    init(_ run: @escaping @MainActor (guint) -> Bool) {
        self.run = run
    }
}

let hostGtkKeyPressed: @convention(c) (HostGtkRef?, guint, guint, GdkModifierType, HostGtkRef?) -> gboolean = {
    _, keyval, _, _, data in
    guard let data else { return 0 }
    let handler = Unmanaged<HostGtkKeyHandler>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated { handler.run(keyval) } ? 1 : 0
}

@discardableResult
func hostGtkConnect<Handler>(
    _ instance: HostGtkRef, _ signal: String, _ handler: Handler, _ data: HostGtkRef?
) -> gulong {
    let erased = unsafeBitCast(handler, to: (@convention(c) () -> Void).self)
    return sensorium_signal_connect(instance, signal, erased, data)
}

/// The handful of widgets the host windows build, in the shapes they build
/// them. Nothing here decides anything: every word and every state is handed
/// in by a window, which got it from `HostWindowPresentation`.
enum HostWidgets {
    static func widget(_ object: HostGtkRef) -> UnsafeMutablePointer<GtkWidget> {
        sensorium_gtk_widget(object)
    }

    static func box(vertical: Bool, spacing: Int32 = 0) -> HostGtkRef {
        let box = hostGtkRef(gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing))
        gtk_widget_set_halign(widget(box), GTK_ALIGN_FILL)
        return box
    }

    static func append(_ child: HostGtkRef, to parent: HostGtkRef) {
        gtk_box_append(sensorium_gtk_box(parent), widget(child))
    }

    static func addClass(_ name: String, to object: HostGtkRef) {
        gtk_widget_add_css_class(widget(object), name)
    }

    static func setMargins(_ object: HostGtkRef, top: Int = 0, bottom: Int = 0, start: Int = 0, end: Int = 0) {
        gtk_widget_set_margin_top(widget(object), Int32(top))
        gtk_widget_set_margin_bottom(widget(object), Int32(bottom))
        gtk_widget_set_margin_start(widget(object), Int32(start))
        gtk_widget_set_margin_end(widget(object), Int32(end))
    }

    static func setBottomGap(_ gap: Int, on object: HostGtkRef) {
        gtk_widget_set_margin_bottom(widget(object), Int32(gap))
    }

    /// A label, wrapped at the width its column gives it the way a macOS
    /// label wraps at its `preferredMaxLayoutWidth`, instead of asking for a
    /// width that would widen the window.
    static func label(_ text: String, classes: [String], wraps: Bool = true, centered: Bool = false) -> HostGtkRef {
        let label = hostGtkRef(gtk_label_new(text))
        gtk_label_set_xalign(sensorium_gtk_label(label), centered ? 0.5 : 0)
        if centered { gtk_label_set_justify(sensorium_gtk_label(label), GTK_JUSTIFY_CENTER) }
        if wraps {
            gtk_label_set_wrap(sensorium_gtk_label(label), 1)
            gtk_label_set_wrap_mode(sensorium_gtk_label(label), PANGO_WRAP_WORD_CHAR)
            gtk_label_set_max_width_chars(sensorium_gtk_label(label), 1)
            gtk_widget_set_halign(widget(label), GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(widget(label), 1)
        } else {
            gtk_widget_set_halign(widget(label), GTK_ALIGN_START)
        }
        for name in classes { addClass(name, to: label) }
        return label
    }

    /// One line that ends in an ellipsis rather than wrapping.
    static func singleLineLabel(_ text: String, classes: [String]) -> HostGtkRef {
        let label = self.label(text, classes: classes, wraps: false)
        gtk_label_set_ellipsize(sensorium_gtk_label(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(sensorium_gtk_label(label), 1)
        gtk_widget_set_hexpand(widget(label), 1)
        gtk_widget_set_halign(widget(label), GTK_ALIGN_FILL)
        return label
    }

    /// A button that takes no keyboard focus, as on macOS with Full Keyboard
    /// Access off, which is how it ships.
    static func button(child: HostGtkRef?, classes: [String], onClick: HostGtkCallback?) -> HostGtkRef {
        let button = hostGtkRef(gtk_button_new())
        gtk_widget_set_can_focus(widget(button), 0)
        if let child {
            gtk_button_set_child(sensorium_gtk_button(button), widget(child))
        }
        for name in classes { addClass(name, to: button) }
        if let onClick {
            hostGtkConnect(button, "clicked", hostGtkClicked, Unmanaged.passUnretained(onClick).toOpaque())
        }
        return button
    }

    static func titledButton(
        _ title: String, labelClasses: [String] = [], classes: [String], onClick: HostGtkCallback?
    ) -> HostGtkRef {
        let label = hostGtkRef(gtk_label_new(title))
        for name in labelClasses { addClass(name, to: label) }
        let button = button(child: label, classes: classes, onClick: onClick)
        gtk_widget_set_hexpand(widget(button), 1)
        return button
    }

    static func setAccessibleLabel(_ label: String, on object: HostGtkRef) {
        gtk_widget_set_tooltip_text(widget(object), label)
        sensorium_accessible_set_label(object, label)
    }

    static func setEnabled(_ enabled: Bool, on object: HostGtkRef) {
        gtk_widget_set_sensitive(widget(object), enabled ? 1 : 0)
    }

    /// A filled rectangle of `colour` one point thick: a row's hairline.
    static func hairline(vertical: Bool = false) -> HostGtkRef {
        let line = hostGtkRef(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        addClass(HostWindowStyle.Class.separator, to: line)
        if vertical {
            gtk_widget_set_vexpand(widget(line), 1)
        } else {
            gtk_widget_set_hexpand(widget(line), 1)
        }
        return line
    }

    /// A custom-drawn area of `width` by `height` points, drawn by `draw` in
    /// the area's own logical units.
    static func drawingArea(width: Int, height: Int, draw: HostGtkDrawing) -> HostGtkRef {
        let area = hostGtkRef(gtk_drawing_area_new())
        gtk_widget_set_size_request(widget(area), Int32(width), Int32(height))
        gtk_widget_set_halign(widget(area), GTK_ALIGN_START)
        gtk_widget_set_valign(widget(area), GTK_ALIGN_CENTER)
        gtk_drawing_area_set_draw_func(
            sensorium_gtk_drawing_area(area),
            { _, context, width, height, data in
                guard let context, let data else { return }
                let drawing = Unmanaged<HostGtkDrawing>.fromOpaque(data).takeUnretainedValue()
                drawing.draw(context, Double(width), Double(height))
            },
            Unmanaged.passUnretained(draw).toOpaque(),
            nil
        )
        return area
    }
}

/// A drawing closure a GTK drawing area can reach.
final class HostGtkDrawing: @unchecked Sendable {
    let draw: (OpaquePointer, Double, Double) -> Void

    init(_ draw: @escaping (OpaquePointer, Double, Double) -> Void) {
        self.draw = draw
    }
}

/// Installs a window's stylesheet and the toolkit's own light or dark
/// preference, once per appearance a process asks for. A second install of the
/// same appearance would stack a second copy of every rule.
@MainActor
enum HostWindowTheme {
    private static var provider: HostGtkRef?
    private static var installed: IndicatorAppearance?

    static func install(_ appearance: IndicatorAppearance) {
        guard installed != appearance, let display = gdk_display_get_default() else { return }
        if let provider {
            gtk_style_context_remove_provider_for_display(display, sensorium_gtk_style_provider(provider))
        }
        sensorium_set_prefer_dark_theme(appearance == .dark ? 1 : 0)
        let created = hostGtkRef(gtk_css_provider_new())
        gtk_css_provider_load_from_string(sensorium_gtk_css_provider(created), HostWindowStyle.stylesheet(for: appearance))
        gtk_style_context_add_provider_for_display(
            display, sensorium_gtk_style_provider(created), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
        provider = created
        installed = appearance
    }
}

/// Cairo drawing helpers for the controls the host windows draw themselves.
enum HostCairo {
    static func roundedRect(_ context: OpaquePointer, x: Double, y: Double, width: Double, height: Double, radius: Double) {
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - radius, y + radius, radius, -.pi / 2, 0)
        cairo_arc(context, x + width - radius, y + height - radius, radius, 0, .pi / 2)
        cairo_arc(context, x + radius, y + height - radius, radius, .pi / 2, .pi)
        cairo_arc(context, x + radius, y + radius, radius, .pi, 1.5 * .pi)
        cairo_close_path(context)
    }

    static func setSource(_ context: OpaquePointer, _ color: HostWindowColor, _ appearance: IndicatorAppearance, alpha: Double = 1) {
        let value = color.rgb(appearance)
        cairo_set_source_rgba(context, value.red, value.green, value.blue, alpha)
    }
}
#endif
