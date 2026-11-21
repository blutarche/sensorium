#if os(Linux)
import CCairo
import CGtk4
import Foundation

/// The controls the host windows draw themselves, in the design system's own
/// tokens rather than a desktop theme's, so a switch reads the same on every
/// desktop and in both appearances. Each is a plain button holding a drawing,
/// so none of it depends on a theme node.
@MainActor
enum HostControls {
    /// The pill-shaped Share host screen switch, 38 by 22: an accent track
    /// when on, an input-fill track when off, and a knob that moves.
    static func toggle(
        isOn: Bool, isEnabled: Bool, appearance: IndicatorAppearance, label: String, onClick: HostGtkCallback
    ) -> (widget: HostGtkRef, retained: [AnyObject]) {
        typealias Size = (width: Int, height: Int)
        let size: Size = HostWindowMetrics.switchSize
        let inset = 2.0
        let drawing = HostGtkDrawing { context, _, _ in
            let height = Double(size.height)
            let width = Double(size.width)
            HostCairo.setSource(context, isOn ? HostWindowPalette.accent : HostWindowPalette.bg4, appearance, alpha: isEnabled ? 1 : 0.5)
            HostCairo.roundedRect(context, x: 0, y: 0, width: width, height: height, radius: height / 2)
            cairo_fill(context)
            let diameter = height - inset * 2
            let knobX = isOn ? width - inset - diameter : inset
            cairo_set_source_rgba(context, 1, 1, 1, isEnabled ? 1 : 0.5)
            cairo_arc(context, knobX + diameter / 2, inset + diameter / 2, diameter / 2, 0, 2 * .pi)
            cairo_fill(context)
        }
        let area = HostWidgets.drawingArea(width: size.width, height: size.height, draw: drawing)
        let button = HostWidgets.button(child: area, classes: [HostWindowStyle.Class.plain], onClick: onClick)
        gtk_widget_set_valign(HostWidgets.widget(button), GTK_ALIGN_CENTER)
        gtk_widget_set_halign(HostWidgets.widget(button), GTK_ALIGN_START)
        HostWidgets.setAccessibleLabel(label, on: button)
        HostWidgets.setEnabled(isEnabled, on: button)
        return (button, [drawing, onClick])
    }

    /// A 16 point box with a tick, ahead of its title. The box is the same
    /// input fill checked or not, with an ink tick, as the macOS check box
    /// draws it in the host's own palette.
    static func checkbox(
        title: String, isOn: Bool, isEnabled: Bool, appearance: IndicatorAppearance, onClick: HostGtkCallback
    ) -> (widget: HostGtkRef, retained: [AnyObject]) {
        let box = checkmark(isOn: isOn, isEnabled: isEnabled, appearance: appearance)
        let row = HostWidgets.box(vertical: false, spacing: Int32(HostWindowMetrics.Space.xs - 2))
        HostWidgets.append(box.widget, to: row)
        let label = HostWidgets.label(title, classes: [HostWindowStyle.Class.sentence], wraps: false)
        gtk_widget_set_hexpand(HostWidgets.widget(label), 1)
        HostWidgets.append(label, to: row)
        let button = HostWidgets.button(child: row, classes: [HostWindowStyle.Class.plain], onClick: onClick)
        gtk_widget_set_halign(HostWidgets.widget(button), GTK_ALIGN_FILL)
        HostWidgets.setEnabled(isEnabled, on: button)
        return (button, [box.drawing, onClick])
    }

    /// The tick box alone, for the checkbox and for a menu row that carries a
    /// check beside its title.
    static func checkmark(
        isOn: Bool, isEnabled: Bool, appearance: IndicatorAppearance, drawsBox: Bool = true
    ) -> (widget: HostGtkRef, drawing: HostGtkDrawing) {
        let side = Double(HostWindowMetrics.checkboxSize)
        let alpha = isEnabled ? 1.0 : 0.5
        let drawing = HostGtkDrawing { context, _, _ in
            if drawsBox {
                HostCairo.setSource(context, HostWindowPalette.bg4, appearance, alpha: alpha)
                HostCairo.roundedRect(context, x: 0, y: 0, width: side, height: side, radius: 3)
                cairo_fill(context)
            }
            guard isOn else { return }
            HostCairo.setSource(context, HostWindowPalette.ink, appearance, alpha: alpha)
            cairo_set_line_width(context, 1.8)
            cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
            cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)
            cairo_move_to(context, side * 0.26, side * 0.52)
            cairo_line_to(context, side * 0.43, side * 0.69)
            cairo_line_to(context, side * 0.75, side * 0.31)
            cairo_stroke(context)
        }
        let widget = HostWidgets.drawingArea(
            width: HostWindowMetrics.checkboxSize, height: HostWindowMetrics.checkboxSize, draw: drawing
        )
        return (widget, drawing)
    }

    /// Three dots in muted ink: a row's "more" button, drawn rather than taken
    /// from an icon theme.
    static func moreDots(appearance: IndicatorAppearance) -> (widget: HostGtkRef, drawing: HostGtkDrawing) {
        let side = Double(HostWindowMetrics.moreButtonSize)
        let diameter = 3.0
        let gap = 3.0
        let drawing = HostGtkDrawing { context, _, _ in
            let span = diameter * 3 + gap * 2
            HostCairo.setSource(context, HostWindowPalette.muted, appearance)
            for index in 0..<3 {
                let x = (side - span) / 2 + Double(index) * (diameter + gap) + diameter / 2
                cairo_new_sub_path(context)
                cairo_arc(context, x, side / 2, diameter / 2, 0, 2 * .pi)
            }
            cairo_fill(context)
        }
        let widget = HostWidgets.drawingArea(
            width: HostWindowMetrics.moreButtonSize, height: HostWindowMetrics.moreButtonSize, draw: drawing
        )
        return (widget, drawing)
    }
}
#endif
