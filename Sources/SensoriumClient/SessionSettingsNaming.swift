/// The one name every surface that opens or talks about the Linux session
/// settings window uses -- the GTK window's own title, and any copy that
/// names it, such as `HostScreenRefusalCopy`'s naming of where to pick a
/// host screen.
public enum SessionSettingsNaming {
    public static let title = "Session Settings"

    /// The gear button's own fallback word when no icon theme has a glyph
    /// for it -- short by necessity: `title` in full would widen the
    /// strip's trailing pill past what a slim bar can spare it.
    public static let shortTitle = "Settings"
}
