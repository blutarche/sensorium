/// How the viewer spells a key chord to the person reading it. macOS names
/// its modifiers one way and a PC keyboard another, and the same sentence is
/// shown on both, so the spelling is decided once here rather than written
/// out wherever a sentence needs it.
public enum ViewerKeyNames {
    /// `SystemShortcutCatalog.escapeGesture`, in words.
    public static let escapeGesture: String = {
        #if os(macOS)
        "Control-Option-Command-Escape"
        #else
        "Ctrl-Alt-Super-Escape"
        #endif
    }()

    /// `SystemShortcutCatalog.shortcutStripToggle`, in words.
    public static let shortcutStrip: String = {
        #if os(macOS)
        "Control-Shift-Command-Space"
        #else
        "Ctrl-Shift-Super-Space"
        #endif
    }()

    /// `SystemShortcutCatalog.sessionControlsToggle`, in words.
    public static let sessionControls: String = {
        #if os(macOS)
        "Control-Shift-Command-K"
        #else
        "Ctrl-Shift-Super-K"
        #endif
    }()
}
