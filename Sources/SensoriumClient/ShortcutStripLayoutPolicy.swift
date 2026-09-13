import Foundation

/// How much of a session window's top edge the shortcut strip's own band
/// claims, and what that leaves the video. Holds no view, so both are
/// verified without a window.
///
/// The strip only ever claims a band while it is pinned open: an unpinned
/// strip revealed by a hover or the summoning chord still overlays the
/// picture, the way it always has, and closes itself on its own.
public struct ShortcutStripLayoutPolicy: Equatable, Sendable {
    /// `stripHeight` is `ShortcutStripView.height`; `isStripOpen` is true for
    /// `.shown` and `.confirming`, false for `.hidden` and `.hiding`.
    public static func videoTopInset(
        isPinned: Bool,
        isStripOpen: Bool,
        stripHeight: CGFloat
    ) -> CGFloat {
        guard isPinned, isStripOpen else { return 0 }
        return stripHeight
    }

    /// The video's own height once that inset is taken off the top of the
    /// window content view it shares with the strip and the session HUD.
    public static func videoHeight(fullHeight: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, fullHeight - topInset)
    }
}
