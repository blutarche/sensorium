#if os(Linux)
import CCairo
import Foundation

/// Which of the two appearances the pill is drawn in.
public enum IndicatorAppearance: String, Sendable {
    case dark
    case light
}

/// The design system's colours the pill uses, with a dark and a light value
/// each. The values are the tokens of `docs/design-system.md`.
struct IndicatorColor {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(dark: UInt32, light: UInt32, in appearance: IndicatorAppearance) {
        self.init(hex: appearance == .dark ? dark : light)
    }
}

enum IndicatorPalette {
    static func background(_ appearance: IndicatorAppearance) -> IndicatorColor {
        IndicatorColor(dark: 0x07070A, light: 0xEDEDF0, in: appearance)
    }

    static func ink(_ appearance: IndicatorAppearance) -> IndicatorColor {
        IndicatorColor(dark: 0xF2EFEA, light: 0x0A0A0C, in: appearance)
    }

    /// The dot and the Stop button.
    static func alert(_ appearance: IndicatorAppearance) -> IndicatorColor {
        IndicatorColor(dark: 0xE26F5C, light: 0xB93A26, in: appearance)
    }

    static func accent(_ appearance: IndicatorAppearance) -> IndicatorColor {
        IndicatorColor(dark: 0x7C70F5, light: 0x5C51D0, in: appearance)
    }

    static func accentSecondary(_ appearance: IndicatorAppearance) -> IndicatorColor {
        IndicatorColor(dark: 0xF0A8D0, light: 0xC87AAA, in: appearance)
    }
}

/// One line of text, measured and drawn with Pango in the system's sans-serif
/// face. The settings match the Linux viewer's chrome text, so the pill reads
/// in the same font the rest of the product uses.
enum IndicatorText {
    static let semibold = 600

    /// How wide and tall `text` is on one line, and whether it had to end in
    /// an ellipsis to fit `maxWidth`.
    static func measure(
        _ text: String, pointSize: Double, maxWidth: Double? = nil
    ) -> (width: Double, height: Double, truncated: Bool) {
        withContext(width: 1, height: 1) { context in
            guard let layout = makeLayout(on: context, text: text, pointSize: pointSize, maxWidth: maxWidth) else {
                return (0, 0, false)
            }
            defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
            var width: Int32 = 0
            var height: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, &height)
            return (Double(width), Double(height), pango_layout_is_ellipsized(layout) != 0)
        }
    }

    /// Draws `text` with its top-left corner at `x`, `y`.
    static func draw(
        _ text: String, on context: OpaquePointer, x: Double, y: Double, pointSize: Double,
        maxWidth: Double?, color: IndicatorColor
    ) {
        guard let layout = makeLayout(on: context, text: text, pointSize: pointSize, maxWidth: maxWidth) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        cairo_set_source_rgb(context, color.red, color.green, color.blue)
        cairo_move_to(context, x, y)
        pango_cairo_show_layout(context, layout)
    }

    private static func makeLayout(
        on context: OpaquePointer, text: String, pointSize: Double, maxWidth: Double?
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
        pango_font_description_set_family(description, "sans-serif")
        pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(semibold)))
        pango_font_description_set_size(description, sensorium_pango_units_from_points(pointSize))
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, text, -1)
        if let maxWidth {
            pango_layout_set_width(layout, sensorium_pango_units_from_points(maxWidth))
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        }
        return layout
    }

    /// A cairo context onto a throwaway surface, for measuring.
    private static func withContext<T>(width: Int32, height: Int32, _ body: (OpaquePointer) -> T) -> T {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)!
        let context = cairo_create(surface)!
        defer {
            cairo_destroy(context)
            cairo_surface_destroy(surface)
        }
        return body(context)
    }
}

/// A drawn pill: premultiplied ARGB32 pixels in native byte order, the format
/// `wl_shm` calls `argb8888`.
public struct IndicatorBitmap: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let stride: Int
    public let pixels: [UInt8]
}

/// Draws the corner pill: a status dot, the device name and Stop on a rounded
/// plate with a gradient border.
///
/// The macOS pill rotates its border gradient and breathes its fill. This draws
/// the gradient fixed on one diagonal, which is the look the macOS pill falls
/// back to when the person has asked for reduced motion.
public enum IndicatorPillRenderer {
    /// The pill for `deviceName`: its layout, and the layout's logical size
    /// rounded up to whole points, which is the size the surface takes.
    public static func layout(for deviceName: String) -> (layout: IndicatorPillLayout, logicalWidth: Int, logicalHeight: Int) {
        let measured = IndicatorText.measure(deviceName, pointSize: IndicatorPillMetrics.nameFontSize)
        let layout = IndicatorPillLayout(measuredNameWidth: measured.width, nameLineHeight: max(measured.height, 1))
        return (layout, Int(layout.size.width.rounded(.up)), Int(layout.size.height.rounded(.up)))
    }

    /// Draws the pill at `scale` device pixels per logical point.
    public static func render(deviceName: String, appearance: IndicatorAppearance, scale: Double) -> IndicatorBitmap {
        typealias M = IndicatorPillMetrics
        let (layout, logicalWidth, logicalHeight) = layout(for: deviceName)
        let pixelWidth = max(1, Int((Double(logicalWidth) * scale).rounded()))
        let pixelHeight = max(1, Int((Double(logicalHeight) * scale).rounded()))
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(pixelWidth), Int32(pixelHeight))!
        let context = cairo_create(surface)!
        defer {
            cairo_destroy(context)
            cairo_surface_destroy(surface)
        }
        cairo_scale(context, Double(pixelWidth) / Double(logicalWidth), Double(pixelHeight) / Double(logicalHeight))

        let width = Double(logicalWidth)
        let height = Double(logicalHeight)
        let background = IndicatorPalette.background(appearance)
        let alert = IndicatorPalette.alert(appearance)

        roundedRectangle(context, x: 0, y: 0, width: width, height: height, radius: M.cornerRadius)
        cairo_set_source_rgb(context, background.red, background.green, background.blue)
        cairo_fill(context)

        let inset = M.borderWidth / 2
        roundedRectangle(
            context, x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset,
            radius: M.cornerRadius - inset
        )
        let gradient = cairo_pattern_create_linear(0, 0, width, height)!
        let start = IndicatorPalette.accent(appearance)
        let end = IndicatorPalette.accentSecondary(appearance)
        cairo_pattern_add_color_stop_rgb(gradient, 0, start.red, start.green, start.blue)
        cairo_pattern_add_color_stop_rgb(gradient, 1, end.red, end.green, end.blue)
        cairo_set_source(context, gradient)
        cairo_set_line_width(context, M.borderWidth)
        cairo_stroke(context)
        cairo_pattern_destroy(gradient)

        let dot = layout.dotRect
        cairo_arc(context, dot.x + dot.width / 2, dot.y + dot.height / 2, dot.width / 2, 0, 2 * Double.pi)
        cairo_set_source_rgb(context, alert.red, alert.green, alert.blue)
        cairo_fill(context)

        IndicatorText.draw(
            deviceName, on: context, x: layout.nameRect.x, y: layout.nameRect.y,
            pointSize: M.nameFontSize, maxWidth: layout.nameRect.width, color: IndicatorPalette.ink(appearance)
        )

        let stop = layout.stopRect
        roundedRectangle(context, x: stop.x, y: stop.y, width: stop.width, height: stop.height, radius: M.stopCornerRadius)
        cairo_set_source_rgb(context, alert.red, alert.green, alert.blue)
        cairo_fill(context)
        let label = IndicatorText.measure(stopLabel, pointSize: M.stopFontSize)
        IndicatorText.draw(
            stopLabel, on: context, x: stop.x + (stop.width - label.width) / 2,
            y: stop.y + (stop.height - label.height) / 2, pointSize: M.stopFontSize, maxWidth: nil,
            color: background
        )

        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let bytes = Array(UnsafeBufferPointer(start: cairo_image_surface_get_data(surface), count: stride * pixelHeight))
        return IndicatorBitmap(pixelWidth: pixelWidth, pixelHeight: pixelHeight, stride: stride, pixels: bytes)
    }

    /// The word on the Stop control, here and in the tray menu.
    public static let stopLabel = "Stop"

    /// Writes `bitmap` as a PNG, for looking at the pill without a compositor.
    public static func writePNG(_ bitmap: IndicatorBitmap, to path: String) -> Bool {
        var pixels = bitmap.pixels
        return pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let surface = cairo_image_surface_create_for_data(
                buffer.baseAddress, CAIRO_FORMAT_ARGB32, Int32(bitmap.pixelWidth), Int32(bitmap.pixelHeight),
                Int32(bitmap.stride)
            ) else { return false }
            defer { cairo_surface_destroy(surface) }
            return cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS
        }
    }

    private static func roundedRectangle(
        _ context: OpaquePointer, x: Double, y: Double, width: Double, height: Double, radius: Double
    ) {
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - radius, y + radius, radius, -Double.pi / 2, 0)
        cairo_arc(context, x + width - radius, y + height - radius, radius, 0, Double.pi / 2)
        cairo_arc(context, x + radius, y + height - radius, radius, Double.pi / 2, Double.pi)
        cairo_arc(context, x + radius, y + radius, radius, Double.pi, 3 * Double.pi / 2)
        cairo_close_path(context)
    }
}
#endif
