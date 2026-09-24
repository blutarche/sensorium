import Foundation

/// How wide the session status panel is, and where its buttons sit in it.
///
/// The rule is the one docs/ux-spec.md's visual pass asks for -- "no clipped
/// or wrapped-mid-word text" -- and it needs one measurement this type does
/// not make itself: how wide a title is in the face the button draws it in.
/// That measurement is handed in, so the same rule holds on a machine with a
/// font engine this target cannot import.
public enum ViewerStatusPanelMetrics {
    /// The panel's width when its widest button row already fits it.
    public static let defaultWidth: Double = 400
    public static let buttonMinimumWidth: Double = 96
    public static let buttonHeight: Double = 28
    public static let buttonHorizontalInset: Double = Double(ViewerChromeMetrics.Space.sm)
    public static let buttonSpacing: Double = Double(ViewerChromeMetrics.Space.xs)
    public static let panelInset: Double = Double(ViewerChromeMetrics.Space.lg)

    /// One title's button, at its own intrinsic width: the measured text plus
    /// equal insets, never below the minimum a two-word label needs to stay
    /// tappable.
    public static func buttonWidth(_ title: String, measure: (String) -> Double) -> Double {
        max(buttonMinimumWidth, (measure(title)).rounded(.up) + buttonHorizontalInset * 2)
    }

    /// Never narrower than `defaultWidth`, and wide enough that every title in
    /// `titles` measures at its own intrinsic width with equal insets on every
    /// button.
    public static func width(forButtonTitles titles: [String], measure: (String) -> Double) -> Double {
        guard !titles.isEmpty else { return defaultWidth }
        let rowWidth = titles.map { buttonWidth($0, measure: measure) }.reduce(0, +)
            + Double(titles.count - 1) * buttonSpacing
        return max(defaultWidth, rowWidth + panelInset * 2)
    }

    /// One width for the whole session: wide enough for the widest button row
    /// any `ViewerSessionStatus` can carry, so the panel does not change size
    /// as a session goes from lost to reconnecting to given up.
    public static func sessionPanelWidth(measure: (String) -> Double) -> Double {
        ViewerSessionStateMachine.buttonRows
            .map { width(forButtonTitles: $0, measure: measure) }
            .max() ?? defaultWidth
    }
}

/// One button of the status panel, and the rectangle it occupies in the
/// window's own logical units.
public struct ViewerStatusPanelButtonLayout: Equatable, Sendable {
    public let action: ViewerSessionAction
    public let rect: ViewerChromeRect

    public init(action: ViewerSessionAction, rect: ViewerChromeRect) {
        self.action = action
        self.rect = rect
    }
}

/// Which button a press on the status panel landed on.
///
/// The row is laid out from the right, because the action that restores the
/// session is the row's last member on both platforms -- the way macOS itself
/// places a default button in a horizontal row. Holds no view, so every
/// button's rect and every gap between them is checked without a window.
public enum ViewerStatusPanelHitTest {
    public static func buttonRow(
        buttons: [ViewerSessionButton],
        panel: ViewerChromeRect,
        measure: (String) -> Double
    ) -> [ViewerStatusPanelButtonLayout] {
        let bottom = panel.y + panel.height - ViewerStatusPanelMetrics.panelInset
        let top = bottom - ViewerStatusPanelMetrics.buttonHeight
        var right = panel.x + panel.width - ViewerStatusPanelMetrics.panelInset
        var layouts: [ViewerStatusPanelButtonLayout] = []
        for button in buttons.reversed() {
            let width = ViewerStatusPanelMetrics.buttonWidth(button.title, measure: measure)
            layouts.append(ViewerStatusPanelButtonLayout(
                action: button.action,
                rect: ViewerChromeRect(
                    x: right - width,
                    y: top,
                    width: width,
                    height: ViewerStatusPanelMetrics.buttonHeight
                )
            ))
            right -= width + ViewerStatusPanelMetrics.buttonSpacing
        }
        return layouts.reversed()
    }

    public static func action(
        atX x: Double,
        y: Double,
        in layouts: [ViewerStatusPanelButtonLayout]
    ) -> ViewerSessionAction? {
        layouts.first { $0.rect.contains(x: x, y: y) }?.action
    }
}
