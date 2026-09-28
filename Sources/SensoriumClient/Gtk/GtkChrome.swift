#if canImport(CGtk4)
import CCairo
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

/// A key controller's closure: whether it took the key, so GTK knows not to
/// pass it on. Sendable for the same reason `GtkCallback` is.
final class GtkKeyPressHandler: @unchecked Sendable {
    let run: @MainActor (guint, GdkModifierType) -> Bool

    init(_ run: @escaping @MainActor (guint, GdkModifierType) -> Bool) {
        self.run = run
    }
}

let gtkKeyPressedHandler: @convention(c) (GtkRef?, guint, guint, GdkModifierType, GtkRef?) -> gboolean = {
    _, keyval, _, state, data in
    guard let data else { return 0 }
    let handler = Unmanaged<GtkKeyPressHandler>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated { handler.run(keyval, state) } ? 1 : 0
}

let gtkActionActivateHandler: @convention(c) (GtkRef?, OpaquePointer?, GtkRef?) -> Void = { _, parameter, data in
    guard let parameter else { return }
    gtkRunIndexedCallback(data, g_variant_get_int32(parameter))
}

/// The half of `GtkViewerStyle` that actually talks to GTK. The stylesheet
/// string itself, and the class names it defines, are declared in
/// `GtkViewerStylesheet.swift`, ungated, so a typo in the CSS this builds is
/// a compile-and-test-time error rather than one only a Linux box can catch.
extension GtkViewerStyle {
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

    /// One gap in a message prompt's own vertical chain -- see
    /// `MessagePromptSpacing`.
    enum MessagePromptGapAfter {
        case eyebrow
        case headline
        case detail
    }

    /// Sets `widget`'s own top margin to the gap that belongs above it in a
    /// message prompt -- a per-child margin rather than the box's own
    /// uniform `spacing`, since GTK's box has no per-gap override the way
    /// `NSStackView.setCustomSpacing` does.
    static func applyMessagePromptSpacing(after gap: MessagePromptGapAfter, to widget: GtkRef) {
        let margin: Double
        switch gap {
        case .eyebrow: margin = MessagePromptSpacing.afterEyebrow
        case .headline: margin = MessagePromptSpacing.afterHeadline
        case .detail: margin = MessagePromptSpacing.afterDetail
        }
        gtk_widget_set_margin_top(sensorium_gtk_widget(widget), Int32(margin))
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
        if wraps {
            // Wraps at the width its column is given, as a macOS label wraps
            // at its `preferredMaxLayoutWidth`, instead of asking for a
            // width of its own that would widen the window.
            gtk_label_set_wrap_mode(sensorium_gtk_label(label), PANGO_WRAP_WORD_CHAR)
            gtk_label_set_max_width_chars(sensorium_gtk_label(label), 1)
            gtk_widget_set_halign(sensorium_gtk_widget(label), GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(sensorium_gtk_widget(label), 1)
        } else {
            gtk_widget_set_halign(sensorium_gtk_widget(label), GTK_ALIGN_START)
        }
        gtk_widget_add_css_class(sensorium_gtk_widget(label), cssClass)
        return label
    }

    /// `label`, set in `size`-point sans or `mono`, on the lines AppKit sets
    /// that text on: a box `TextLine.height` tall for each line, the first
    /// line's baseline `TextLine.baseline` below its top to the fraction of a
    /// point, whatever the Linux face's own ascent and descent. A CSS
    /// line-height alone spaces the lines but centres the face's own ascent
    /// and descent on each, and an ellipsis Pango adds keeps the face's own
    /// line. The box is shown only while the label is.
    static func onTextLine(_ label: GtkRef, size: Int, mono: Bool = false) -> GtkRef {
        let line = gtkRef(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        g_object_set_data(sensorium_g_object(line), textLineSizeKey, UnsafeMutableRawPointer(bitPattern: size))
        g_object_set_data(sensorium_g_object(line), textLineMonoKey, UnsafeMutableRawPointer(bitPattern: mono ? 1 : 0))
        gtk_widget_set_layout_manager(
            sensorium_gtk_widget(line),
            gtk_custom_layout_new(textLineRequestMode, textLineMeasure, textLineAllocate)
        )
        gtk_box_append(sensorium_gtk_box(line), sensorium_gtk_widget(label))
        sensorium_bind_visible(label, line)
        return line
    }

    private static let textLineSizeKey = "sensorium-text-line-size"
    private static let textLineMonoKey = "sensorium-text-line-mono"

    private static func textLine(_ widget: UnsafeMutablePointer<GtkWidget>) -> (size: Double, mono: Bool) {
        (
            Double(Int(bitPattern: g_object_get_data(sensorium_g_object(widget), textLineSizeKey))),
            g_object_get_data(sensorium_g_object(widget), textLineMonoKey) != nil
        )
    }

    /// How many lines `label` sets its text on at `width` points.
    private static func lineCount(_ label: UnsafeMutablePointer<GtkWidget>, width: Int32) -> Int {
        guard gtk_label_get_wrap(sensorium_gtk_label(label)) != 0,
              let copy = pango_layout_copy(gtk_label_get_layout(sensorium_gtk_label(label))) else {
            return 1
        }
        defer { g_object_unref(UnsafeMutableRawPointer(copy)) }
        pango_layout_set_width(copy, width * PANGO_SCALE)
        return max(1, Int(pango_layout_get_line_count(copy)))
    }

    /// Wrapped text is as tall as the width it is given lets it be.
    private static let textLineRequestMode: @convention(c) (UnsafeMutablePointer<GtkWidget>?) -> GtkSizeRequestMode = { _ in
        GTK_SIZE_REQUEST_HEIGHT_FOR_WIDTH
    }

    private static let textLineMeasure: @convention(c) (
        UnsafeMutablePointer<GtkWidget>?, GtkOrientation, Int32,
        UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
        UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?
    ) -> Void = { widget, orientation, forSize, minimum, natural, _, _ in
        guard let widget, let label = gtk_widget_get_first_child(widget) else { return }
        // Asked for a height at no width, wrapped text answers as the label
        // does: its lines depend on a width only allocation gives it.
        if orientation == GTK_ORIENTATION_VERTICAL, forSize >= 0 || gtk_label_get_wrap(sensorium_gtk_label(label)) == 0 {
            let text = textLine(widget)
            let height = Int32(
                Double(lineCount(label, width: forSize)) * ViewerChromeMetrics.TextLine.height(size: text.size, mono: text.mono)
            )
            minimum?.pointee = height
            natural?.pointee = height
        } else {
            gtk_widget_measure(label, orientation, forSize, minimum, natural, nil, nil)
        }
    }

    private static let textLineAllocate: @convention(c) (
        UnsafeMutablePointer<GtkWidget>?, Int32, Int32, Int32
    ) -> Void = { widget, width, _, _ in
        guard let widget, let label = gtk_widget_get_first_child(widget) else { return }
        var natural: Int32 = 0
        gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, width, nil, &natural, nil, nil)
        let text = textLine(widget)
        let ascent = Double(pango_layout_get_baseline(gtk_label_get_layout(sensorium_gtk_label(label)))) / Double(PANGO_SCALE)
        var top = graphene_point_t(
            x: 0,
            y: Float(ViewerChromeMetrics.TextLine.baseline(size: text.size, mono: text.mono) - ascent)
        )
        gtk_widget_allocate(label, width, natural, -1, gsk_transform_translate(nil, &top))
    }

    /// A column of fixed width, the width every macOS window of this viewer
    /// lays its content out at, inset from the window's edges by
    /// `Space.xl`.
    static func column(width: Int32, spacing: Int32) -> GtkRef {
        let column = box(vertical: true, spacing: spacing)
        gtk_widget_set_size_request(sensorium_gtk_widget(column), width, -1)
        let inset = Int32(ViewerChromeMetrics.Space.xl)
        gtk_widget_set_margin_start(sensorium_gtk_widget(column), inset)
        gtk_widget_set_margin_end(sensorium_gtk_widget(column), inset)
        gtk_widget_set_margin_top(sensorium_gtk_widget(column), inset)
        gtk_widget_set_margin_bottom(sensorium_gtk_widget(column), inset)
        return column
    }

    /// A word that acts, drawn as text: the way back, the way to look again,
    /// the way to type an address instead -- `ViewerFormControls.linkButton`
    /// on macOS. `icon` stands in for the SF Symbol macOS draws ahead of the
    /// title.
    static func link(_ title: String, icon: GtkViewerStyle.LinkIcon?) -> GtkRef {
        let button = gtkRef(gtk_button_new())
        takesNoKeyboardFocus(button)
        gtk_widget_set_halign(sensorium_gtk_widget(button), GTK_ALIGN_START)
        gtk_widget_add_css_class(sensorium_gtk_widget(button), GtkViewerStyle.Class.link)
        let content = box(vertical: false, spacing: 0)
        if let icon {
            let area = gtkRef(gtk_drawing_area_new())
            gtk_widget_set_size_request(sensorium_gtk_widget(area), Int32(icon.titleOffset.rounded(.up)), -1)
            gtk_drawing_area_set_draw_func(
                sensorium_gtk_drawing_area(area),
                { area, context, _, _, data in
                    guard let area, let context,
                        let icon = GtkViewerStyle.LinkIcon(rawValue: Int(bitPattern: data)) else { return }
                    var color = GdkRGBA()
                    gtk_widget_get_color(sensorium_gtk_widget(area), &color)
                    GtkWidgets.drawLinkIcon(icon, in: context, color: color)
                },
                UnsafeMutableRawPointer(bitPattern: icon.rawValue),
                nil
            )
            append(area, to: content)
        }
        append(gtkRef(gtk_label_new(title)), to: content)
        gtk_button_set_child(sensorium_gtk_button(button), sensorium_gtk_widget(content))
        return button
    }

    /// The "\u{2026}" a saved machine's row ends in: `GtkViewerStyle.MoreDots`,
    /// in the colour GTK resolves for the button that holds it, placed on the
    /// device pixels this draw lands on.
    static func moreDots() -> GtkRef {
        let area = gtkRef(gtk_drawing_area_new())
        let size = Int32(GtkViewerStyle.MoreDots.buttonSize)
        gtk_widget_set_size_request(sensorium_gtk_widget(area), size, size)
        gtk_drawing_area_set_draw_func(
            sensorium_gtk_drawing_area(area),
            { area, context, _, _, _ in
                guard let area, let context else { return }
                var color = GdkRGBA()
                gtk_widget_get_color(sensorium_gtk_widget(area), &color)
                // GTK hands a drawing area a context in logical units and
                // scales it afterwards, so the surface's own scale and this
                // widget's place on it are what the dots are snapped against.
                let widget = sensorium_gtk_widget(area)
                var scale = 1.0
                var origin = (x: 0.0, y: 0.0)
                if let native = gtk_widget_get_native(widget), let surface = gtk_native_get_surface(native) {
                    scale = gdk_surface_get_scale(surface)
                    var from = graphene_point_t(x: 0, y: 0)
                    var to = graphene_point_t(x: 0, y: 0)
                    var offset = (x: 0.0, y: 0.0)
                    gtk_native_get_surface_transform(native, &offset.x, &offset.y)
                    if gtk_widget_compute_point(widget, sensorium_gtk_widget(UnsafeMutableRawPointer(native)), &from, &to) != 0 {
                        origin = ((Double(to.x) + offset.x) * scale, (Double(to.y) + offset.y) * scale)
                    }
                }
                let dots = GtkViewerStyle.MoreDots.placement(scale: scale, origin: origin)
                cairo_set_source_rgba(context, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
                for centre in dots.centres {
                    cairo_new_sub_path(context)
                    cairo_arc(context, (centre.x - origin.x) / scale, (centre.y - origin.y) / scale, dots.diameter / 2 / scale, 0, 2 * .pi)
                }
                cairo_fill(context)
            },
            nil,
            nil
        )
        return area
    }

    /// Draws in the colour GTK resolves for the link itself, so the icon
    /// dims with its title.
    fileprivate static func drawLinkIcon(_ icon: GtkViewerStyle.LinkIcon, in context: OpaquePointer, color: GdkRGBA) {
        cairo_set_source_rgba(context, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)
        for shape in icon.shapes {
            switch shape {
            case let .polyline(points, width):
                guard let first = points.first else { continue }
                cairo_new_path(context)
                cairo_move_to(context, first.x, first.y)
                for point in points.dropFirst() { cairo_line_to(context, point.x, point.y) }
                cairo_set_line_width(context, width)
                cairo_stroke(context)
            case let .arc(x, y, radius, from, to, width):
                cairo_new_path(context)
                cairo_arc(context, x, y, radius, from, to)
                cairo_set_line_width(context, width)
                cairo_stroke(context)
            case let .roundedRect(x, y, width, height, radius, lineWidth):
                cairo_new_path(context)
                cairo_arc(context, x + width - radius, y + radius, radius, -.pi / 2, 0)
                cairo_arc(context, x + width - radius, y + height - radius, radius, 0, .pi / 2)
                cairo_arc(context, x + radius, y + height - radius, radius, .pi / 2, .pi)
                cairo_arc(context, x + radius, y + radius, radius, .pi, 1.5 * .pi)
                cairo_close_path(context)
                cairo_set_line_width(context, lineWidth)
                cairo_stroke(context)
            case let .fill(x, y, width, height):
                cairo_rectangle(context, x, y, width, height)
                cairo_fill(context)
            }
        }
    }

    /// A pulsing warn dot ahead of a muted sentence: the line that says a
    /// fetch is in flight, as `YourMachinesWindowController.loadingSentence`
    /// draws it.
    static func loadingSentence(_ text: String) -> GtkRef {
        let row = box(vertical: false, spacing: Int32(ViewerChromeMetrics.Space.xxs))
        append(dot(cssClass: GtkViewerStyle.Class.dotActivity), to: row)
        append(onTextLine(label(text, cssClass: GtkViewerStyle.Class.muted), size: 13), to: row)
        return row
    }

    /// A tone indicator drawn as a real 6x6 widget, the way `SavedMachineRowButton.dot`
    /// draws it on macOS -- a plain filled, rounded box, not a "\u{25CF}" glyph a
    /// fallback font could substitute or resize.
    static func dot(cssClass: String) -> GtkRef {
        let dot = box(vertical: false, spacing: 0)
        gtk_widget_set_size_request(sensorium_gtk_widget(dot), 6, 6)
        gtk_widget_set_halign(sensorium_gtk_widget(dot), GTK_ALIGN_START)
        gtk_widget_set_valign(sensorium_gtk_widget(dot), GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(sensorium_gtk_widget(dot), cssClass)
        return dot
    }

    static func button(_ title: String, cssClass: String?) -> GtkRef {
        let button = gtkRef(gtk_button_new_with_label(title))
        takesNoKeyboardFocus(button)
        gtk_widget_set_halign(sensorium_gtk_widget(button), GTK_ALIGN_START)
        if let cssClass {
            gtk_widget_add_css_class(sensorium_gtk_widget(button), cssClass)
        }
        return button
    }

    /// As on macOS, where with Full Keyboard Access off -- as it ships -- a
    /// button never takes keyboard focus: Tab moves between fields, and
    /// Return reaches the window's default button wherever focus is.
    static func takesNoKeyboardFocus(_ widget: GtkRef) {
        gtk_widget_set_can_focus(sensorium_gtk_widget(widget), 0)
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

    /// The spoken name of a control whose visible label says too little on
    /// its own, like a bare "\u{2026}".
    static func setAccessibleLabel(_ label: String, on widget: GtkRef) {
        gtk_widget_set_tooltip_text(sensorium_gtk_widget(widget), label)
        sensorium_accessible_set_label(widget, label)
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
