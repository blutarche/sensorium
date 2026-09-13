import Foundation

/// One row of the Displays menu: the count it selects, whether it is the
/// session's current choice, and whether it can be picked at all.
public struct DisplayCountMenuItem: Equatable, Sendable {
    public let count: Int
    public let title: String
    public let isSelected: Bool
    /// `false` during a host-screen session -- the host's own mixed-session
    /// gate refuses a second display there, so the row is disabled rather
    /// than left offering a pick that can only end in a refusal.
    public let isEnabled: Bool

    public init(count: Int, title: String, isSelected: Bool, isEnabled: Bool = true) {
        self.count = count
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

/// The Displays menu's whole content, as data. AppKit-free, so what the menu
/// says and which row is checked is verified without a menu bar --
/// `ViewerMainMenuController` only asks this for the current rows and draws them,
/// the same split `DisplayScaleMenuPlan` already keeps for the Resolution
/// menu next to it.
public struct DisplayCountMenuState: Equatable, Sendable {
    public let items: [DisplayCountMenuItem]

    public init(items: [DisplayCountMenuItem]) {
        self.items = items
    }
}

public enum DisplayCountMenuPlan {
    /// docs/ux-spec.md: "Displays: 1 or 2." Nothing else is ever offered --
    /// the host's own cap on how many session displays a connection may open
    /// is the reason a request for 2 can be refused, not a reason to hide the
    /// row: the refusal, when it happens, says why in the window itself.
    ///
    /// `isEnabled` disables both rows together during a host-screen session,
    /// where a second display is refused before it is ever asked for; it
    /// never hides a row, the same reasoning `selectedCount` above already
    /// follows for offering both counts unconditionally.
    public static func items(selectedCount: Int, isEnabled: Bool = true) -> [DisplayCountMenuItem] {
        [
            DisplayCountMenuItem(count: 1, title: "1 Display", isSelected: selectedCount == 1, isEnabled: isEnabled),
            DisplayCountMenuItem(count: 2, title: "2 Displays", isSelected: selectedCount == 2, isEnabled: isEnabled)
        ]
    }
}
