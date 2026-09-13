/// Why a `hostScreenModeRequest` was refused. Stable tokens rather than
/// prose, like `CanvasRefusalReason`'s, so the viewer can branch on one and
/// say something specific about it. None of them ends the session: the host
/// screen keeps streaming at whatever mode it was already on.
public enum HostScreenModeRefusalReason {
    /// This connection is not streaming a host screen, so there is no
    /// display a mode change could name.
    public static let notLive = "host-screen-mode-not-live"
    /// No mode with that identifier is on offer for this session's display
    /// -- an identifier from an older list, or from a display this session
    /// never had.
    public static let unknown = "host-screen-mode-unknown"
    /// The mode exists and was asked for, and the display would not take it
    /// (or would not keep streaming at it). The display is back on the mode
    /// it was already on.
    public static let failed = "host-screen-mode-failed"
}
