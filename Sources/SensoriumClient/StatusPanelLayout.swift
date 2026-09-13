#if canImport(AppKit)
import AppKit

/// The session status panel's own width, computed from the button rows it
/// can show. `ViewerSessionStatusOverlay` sizes the panel to `sessionPanelWidth`
/// rather than letting `NSStackView` compress a button below its own
/// intrinsic size -- the defect docs/ux-spec.md's visual pass calls "no
/// clipped or wrapped-mid-word text".
///
/// Pure and AppKit-measurement-only: no window, no view hierarchy, so the
/// panel's own sizing is verifiable without one.
@MainActor
public enum StatusPanelLayout {
    /// The panel's width when its widest button row already fits it.
    public static let defaultWidth: CGFloat = 400
    private static let panelInset = ViewerDesign.Space.lg
    private static let buttonSpacing = ViewerDesign.Space.xs

    /// One width for the whole session: wide enough for the widest button row
    /// any `ViewerSessionStatus` can carry, so the panel does not change size
    /// as a session goes from lost to reconnecting to given up.
    public static let sessionPanelWidth: CGFloat = ViewerSessionStateMachine.buttonRows
        .map { width(forButtonTitles: $0) }
        .max() ?? defaultWidth

    /// Never narrower than `defaultWidth`, and wide enough that every title
    /// in `titles` measures at its own intrinsic `ViewerActionButton` width
    /// with equal insets on every button.
    public static func width(forButtonTitles titles: [String]) -> CGFloat {
        guard !titles.isEmpty else { return defaultWidth }
        let rowWidth = titles.map(buttonWidth).reduce(0, +)
            + CGFloat(titles.count - 1) * buttonSpacing
        return max(defaultWidth, rowWidth + panelInset * 2)
    }

    /// The same measurement `ViewerActionButton.intrinsicContentSize` makes
    /// from the title it actually has on screen, made before any button
    /// exists to ask.
    private static func buttonWidth(_ title: String) -> CGFloat {
        let measured = NSAttributedString(
            string: title,
            attributes: [.font: ViewerActionButton.titleFont]
        ).size().width
        return max(ViewerActionButton.minimumWidth, ceil(measured) + ViewerActionButton.horizontalInset * 2)
    }
}
#endif
