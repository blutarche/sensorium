#if canImport(CCairo)
import CCairo
import Foundation

/// Text and boxes, drawn with cairo and laid out with pango.
///
/// The viewer's chrome is the same on both platforms in every way that
/// matters -- same words, same palette, same 4px grid -- and differs only in
/// which library puts the pixels down. This is that library's side of it:
/// nothing here decides what to say or how wide a panel is, it only measures
/// and draws what it is handed.
@MainActor
enum CairoChromeText {
    /// The two faces the design system names. Pango falls back to whatever
    /// this desktop has when neither is installed, which is the right
    /// behaviour: a missing face should cost the shape of the letters, not
    /// the text.
    static func fontDescription(pointSize: Double, mono: Bool, bold: Bool) -> String {
        let family = mono ? "JetBrains Mono" : "Inter"
        let weight = bold ? " Bold" : ""
        return "\(family)\(weight) \(Int(pointSize.rounded()))"
    }

    /// How much room a string needs, wrapped at `maxWidth` when one is given,
    /// or truncated to one line with an ellipsis when `ellipsize` is true --
    /// the two never both apply, since a truncated line never wraps.
    static func measure(
        _ text: String,
        pointSize: Double,
        mono: Bool = false,
        bold: Bool = false,
        maxWidth: Double? = nil,
        tracking: Double = 0,
        ellipsize: Bool = false
    ) -> (width: Double, height: Double) {
        guard let layout = makeLayout(
            on: measuringContext,
            text: text,
            pointSize: pointSize,
            mono: mono,
            bold: bold,
            maxWidth: maxWidth,
            tracking: tracking,
            ellipsize: ellipsize
        ) else {
            return (0, 0)
        }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return (Double(width), Double(height))
    }

    /// Draws `text` with its top-left corner at `x`, `y` and answers how tall
    /// it turned out, so a caller stacking lines does not have to measure the
    /// same string twice.
    @discardableResult
    static func draw(
        _ text: String,
        in context: OpaquePointer,
        x: Double,
        y: Double,
        pointSize: Double,
        color: ViewerColor,
        mono: Bool = false,
        bold: Bool = false,
        maxWidth: Double? = nil,
        tracking: Double = 0,
        ellipsize: Bool = false
    ) -> Double {
        guard let layout = makeLayout(
            on: context,
            text: text,
            pointSize: pointSize,
            mono: mono,
            bold: bold,
            maxWidth: maxWidth,
            tracking: tracking,
            ellipsize: ellipsize
        ) else {
            return 0
        }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        setSource(context, color)
        cairo_move_to(context, x, y)
        pango_cairo_show_layout(context, layout)
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return Double(height)
    }

    /// Draws `text` right-aligned so its right edge lands on `rightX`. Passing
    /// `maxWidth` with `ellipsize` truncates a value too long for its column
    /// to one line with an ellipsis, the way `SessionHUDRowView` truncates a
    /// value AppKit lays out -- rather than letting it run into the label
    /// beside it.
    @discardableResult
    static func drawRightAligned(
        _ text: String,
        in context: OpaquePointer,
        rightX: Double,
        y: Double,
        pointSize: Double,
        color: ViewerColor,
        mono: Bool = false,
        bold: Bool = false,
        maxWidth: Double? = nil,
        ellipsize: Bool = false
    ) -> Double {
        let size = measure(text, pointSize: pointSize, mono: mono, bold: bold, maxWidth: maxWidth, ellipsize: ellipsize)
        return draw(
            text,
            in: context,
            x: rightX - size.width,
            y: y,
            pointSize: pointSize,
            color: color,
            mono: mono,
            bold: bold,
            maxWidth: maxWidth,
            ellipsize: ellipsize
        )
    }

    /// Draws `text` centred horizontally on `centreX`.
    @discardableResult
    static func drawCentred(
        _ text: String,
        in context: OpaquePointer,
        centreX: Double,
        y: Double,
        pointSize: Double,
        color: ViewerColor,
        mono: Bool = false,
        bold: Bool = false
    ) -> Double {
        let size = measure(text, pointSize: pointSize, mono: mono, bold: bold)
        return draw(
            text,
            in: context,
            x: centreX - size.width / 2,
            y: y,
            pointSize: pointSize,
            color: color,
            mono: mono,
            bold: bold
        )
    }

    static func setSource(_ context: OpaquePointer, _ color: ViewerColor) {
        cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha)
    }

    /// One rounded rectangle as a cairo path, ready to fill or stroke. The
    /// radii this system uses are small enough that four arcs is the whole
    /// shape.
    static func addRoundedRect(_ context: OpaquePointer, _ rect: ViewerChromeRect, radius: Double) {
        let limit = min(radius, min(rect.width, rect.height) / 2)
        let right = rect.x + rect.width
        let bottom = rect.y + rect.height
        cairo_new_sub_path(context)
        cairo_arc(context, right - limit, rect.y + limit, limit, -Double.pi / 2, 0)
        cairo_arc(context, right - limit, bottom - limit, limit, 0, Double.pi / 2)
        cairo_arc(context, rect.x + limit, bottom - limit, limit, Double.pi / 2, Double.pi)
        cairo_arc(context, rect.x + limit, rect.y + limit, limit, Double.pi, 3 * Double.pi / 2)
        cairo_close_path(context)
    }

    static func fill(
        _ context: OpaquePointer,
        _ rect: ViewerChromeRect,
        radius: Double,
        color: ViewerColor
    ) {
        addRoundedRect(context, rect, radius: radius)
        setSource(context, color)
        cairo_fill(context)
    }

    static func stroke(
        _ context: OpaquePointer,
        _ rect: ViewerChromeRect,
        radius: Double,
        color: ViewerColor,
        lineWidth: Double = 1
    ) {
        // Half a line width in, so a one-pixel border lands on the pixel
        // rather than straddling two and drawing at half strength.
        let inset = ViewerChromeRect(
            x: rect.x + lineWidth / 2,
            y: rect.y + lineWidth / 2,
            width: max(0, rect.width - lineWidth),
            height: max(0, rect.height - lineWidth)
        )
        addRoundedRect(context, inset, radius: radius)
        setSource(context, color)
        cairo_set_line_width(context, lineWidth)
        cairo_stroke(context)
    }

    /// A filled circle, which is what every tone indicator in this system is.
    static func fillDot(_ context: OpaquePointer, centreX: Double, centreY: Double, radius: Double, color: ViewerColor) {
        cairo_new_sub_path(context)
        cairo_arc(context, centreX, centreY, radius, 0, 2 * Double.pi)
        setSource(context, color)
        cairo_fill(context)
    }

    private static func makeLayout(
        on context: OpaquePointer,
        text: String,
        pointSize: Double,
        mono: Bool,
        bold: Bool,
        maxWidth: Double?,
        tracking: Double,
        ellipsize: Bool = false
    ) -> OpaquePointer? {
        guard let layout = pango_cairo_create_layout(context) else { return nil }
        let description = pango_font_description_from_string(
            fontDescription(pointSize: pointSize, mono: mono, bold: bold)
        )
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, text, -1)
        if let maxWidth, maxWidth > 0 {
            pango_layout_set_width(layout, sensorium_pango_units_from_points(maxWidth))
            if ellipsize {
                // A layout's own line limit defaults to one, so setting the
                // width and this alone truncates that one line -- the same
                // single-line-with-ellipsis a truncating-tail `NSTextField`
                // gives a value too wide for its column.
                pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            } else {
                pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
            }
        }
        if tracking != 0 {
            let attributes = pango_attr_list_new()
            pango_attr_list_insert(
                attributes,
                pango_attr_letter_spacing_new(sensorium_pango_units_from_points(tracking))
            )
            pango_layout_set_attributes(layout, attributes)
            pango_attr_list_unref(attributes)
        }
        return layout
    }

    /// One cairo context that draws nowhere, kept for measuring text before
    /// there is a buffer to draw it into. Pango needs a context to resolve a
    /// font against, and the smallest honest one is a single pixel.
    private static let measuringContext: OpaquePointer = {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
        guard let surface, let context = cairo_create(surface) else {
            preconditionFailure("cairo built no drawing context")
        }
        cairo_surface_destroy(surface)
        return context
    }()
}
#endif
