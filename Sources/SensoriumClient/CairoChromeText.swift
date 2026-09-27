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

/// The three weights this design system draws text in. A Pango weight
/// enum rather than a bold `Bool`, so the status panel and the diagnostics
/// HUD can ask for `medium` without a caller inventing a fourth boolean.
enum CairoFontWeight {
    case regular
    case medium
    case bold

    var pangoWeight: PangoWeight {
        switch self {
        case .regular: return PANGO_WEIGHT_NORMAL
        case .medium: return PANGO_WEIGHT_MEDIUM
        case .bold: return PANGO_WEIGHT_BOLD
        }
    }
}

@MainActor
enum CairoChromeText {
    /// How much room a string needs, wrapped at `maxWidth` when one is given,
    /// or truncated to one line with an ellipsis when `ellipsize` is true --
    /// the two never both apply, since a truncated line never wraps.
    static func measure(
        _ text: String,
        pointSize: Double,
        mono: Bool = false,
        weight: CairoFontWeight = .regular,
        maxWidth: Double? = nil,
        tracking: Double = 0,
        tabularFigures: Bool = false,
        ellipsize: Bool = false
    ) -> (width: Double, height: Double) {
        measure(
            text, pointSize: pointSize, mono: mono, weight: weight, maxWidth: maxWidth,
            tracking: tracking, tabularFigures: tabularFigures, ellipsize: ellipsize, on: measuringContext
        )
    }

    /// The same measurement, against a caller-supplied context rather than
    /// the always-unscaled `measuringContext` -- what a parity check needs to
    /// prove a string measures the same whether that context already carries
    /// a backing-scale `cairo_scale` or not.
    static func measure(
        _ text: String,
        pointSize: Double,
        mono: Bool = false,
        weight: CairoFontWeight = .regular,
        maxWidth: Double? = nil,
        tracking: Double = 0,
        tabularFigures: Bool = false,
        ellipsize: Bool = false,
        on context: OpaquePointer
    ) -> (width: Double, height: Double) {
        guard let layout = makeLayout(
            on: context,
            text: text,
            pointSize: pointSize,
            mono: mono,
            weight: weight,
            maxWidth: maxWidth,
            tracking: tracking,
            tabularFigures: tabularFigures,
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
        weight: CairoFontWeight = .regular,
        maxWidth: Double? = nil,
        tracking: Double = 0,
        tabularFigures: Bool = false,
        ellipsize: Bool = false
    ) -> Double {
        guard let layout = makeLayout(
            on: context,
            text: text,
            pointSize: pointSize,
            mono: mono,
            weight: weight,
            maxWidth: maxWidth,
            tracking: tracking,
            tabularFigures: tabularFigures,
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
        weight: CairoFontWeight = .regular
    ) -> Double {
        let size = measure(text, pointSize: pointSize, mono: mono, weight: weight)
        return draw(
            text,
            in: context,
            x: centreX - size.width / 2,
            y: y,
            pointSize: pointSize,
            color: color,
            mono: mono,
            weight: weight
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

    /// A plain X, drawn as two crossing strokes rather than a character --
    /// the transient notice's own dismiss glyph, which some fallback fonts
    /// substitute a box or a bare letter "X" for when asked to draw "✕".
    static func strokeCross(
        _ context: OpaquePointer,
        centreX: Double,
        centreY: Double,
        size: Double,
        color: ViewerColor,
        lineWidth: Double = 1.5
    ) {
        let half = size / 2
        cairo_new_path(context)
        cairo_move_to(context, centreX - half, centreY - half)
        cairo_line_to(context, centreX + half, centreY + half)
        cairo_move_to(context, centreX + half, centreY - half)
        cairo_line_to(context, centreX - half, centreY + half)
        setSource(context, color)
        cairo_set_line_width(context, lineWidth)
        cairo_stroke(context)
    }

    /// Built directly through Pango's own description API, rather than a
    /// parsed string: `pango_font_description_set_size` takes Pango units, the
    /// same fractional-point conversion `sensorium_pango_units_from_points`
    /// already gives the rest of this file, so a caller is never rounded to a
    /// whole point the way a string like `"Inter 12"` would round it.
    ///
    /// A "point" here means the same thing it does on macOS -- one logical
    /// pixel before the backing scale. Pango's own default reads a size in
    /// points through a 96 dpi font map, so the layout's own context is
    /// pinned to 72 dpi here, freshly on every call, rather than depending on
    /// a GTK window having set one first.
    ///
    /// Hint metrics and glyph-position rounding are both turned off for the
    /// same reason: left on, Pango snaps advances to the *device* pixel
    /// grid, so the same string measures a pixel or two wider once actually
    /// drawn on a context already carrying a backing-scale `cairo_scale` than
    /// it measured on the unscaled context `measure` always uses -- a label
    /// column sized from the one and truncated against the other. Turning
    /// both off makes a layout's own size depend only on its font and text,
    /// never on which context or backing scale it happened to be built on.
    private static func makeLayout(
        on context: OpaquePointer,
        text: String,
        pointSize: Double,
        mono: Bool,
        weight: CairoFontWeight,
        maxWidth: Double?,
        tracking: Double,
        tabularFigures: Bool = false,
        ellipsize: Bool = false
    ) -> OpaquePointer? {
        guard let layout = pango_cairo_create_layout(context) else { return nil }
        let layoutContext = pango_layout_get_context(layout)
        pango_cairo_context_set_resolution(layoutContext, 72)
        let fontOptions = cairo_font_options_create()
        cairo_font_options_set_hint_metrics(fontOptions, CAIRO_HINT_METRICS_OFF)
        pango_cairo_context_set_font_options(layoutContext, fontOptions)
        cairo_font_options_destroy(fontOptions)
        pango_context_set_round_glyph_positions(layoutContext, 0)
        let description = pango_font_description_new()
        pango_font_description_set_family(description, mono ? "JetBrains Mono" : "Inter")
        pango_font_description_set_weight(description, weight.pangoWeight)
        pango_font_description_set_size(description, sensorium_pango_units_from_points(pointSize))
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
        if tracking != 0 || tabularFigures {
            let attributes = pango_attr_list_new()
            if tracking != 0 {
                pango_attr_list_insert(
                    attributes,
                    pango_attr_letter_spacing_new(sensorium_pango_units_from_points(tracking))
                )
            }
            if tabularFigures {
                // The AppKit equivalent of `font-variant-numeric:
                // tabular-nums`, the same feature `SessionHUDRowView`'s own
                // tabular figures ask the font for on macOS.
                pango_attr_list_insert(attributes, pango_attr_font_features_new("tnum=1"))
            }
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
