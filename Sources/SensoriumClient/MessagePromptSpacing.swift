/// The vertical gaps between a message prompt's own pieces -- eyebrow,
/// headline, detail, then its buttons -- matching `ViewerMessageWindow`'s own
/// chain on macOS: `root.spacing` (the default gap, after the eyebrow) and
/// its two `setCustomSpacing` overrides (after the headline, after the
/// detail). Portable so both platforms read the same three numbers.
public enum MessagePromptSpacing {
    public static let afterEyebrow = Double(ViewerChromeMetrics.Space.sm)
    public static let afterHeadline = Double(ViewerChromeMetrics.Space.xs)
    public static let afterDetail = Double(ViewerChromeMetrics.Space.lg)
}
