import Foundation
import SensoriumCore

/// One row of the Screen menu: the display it selects (`nil` for Virtual
/// display, the default), its title, and whether it is the session's
/// current choice.
public struct ScreenMenuItem: Equatable, Sendable {
    public let token: Data?
    public let title: String
    public let isSelected: Bool

    public init(token: Data?, title: String, isSelected: Bool) {
        self.token = token
        self.title = title
        self.isSelected = isSelected
    }
}

/// One row of the Screen menu's Resolution submenu: the host screen's own
/// display mode it selects, named as a person reads it, and whether the
/// screen is on it right now.
public struct HostScreenModeMenuItem: Equatable, Sendable {
    public let modeID: String
    public let title: String
    public let isSelected: Bool

    public init(modeID: String, title: String, isSelected: Bool) {
        self.modeID = modeID
        self.title = title
        self.isSelected = isSelected
    }
}

/// The Resolution submenu under Screen, as data. `isEnabled` is false
/// whenever there is nothing a pick could do: a session streaming a virtual
/// display has no host screen whose mode could change, and a host that
/// offered no modes has nothing to offer. Disabled rather than hidden, the
/// same reasoning `DisplayCountMenuPlan` already follows for its own rows.
public struct HostScreenModeMenuState: Equatable, Sendable {
    public let title: String
    public let isEnabled: Bool
    public let items: [HostScreenModeMenuItem]

    public init(title: String, isEnabled: Bool, items: [HostScreenModeMenuItem]) {
        self.title = title
        self.isEnabled = isEnabled
        self.items = items
    }
}

/// One row of the Screen menu's "Start with" submenu: the preference it
/// sets for this machine's *next* launch, named as a person reads it, and
/// whether it is the preference already saved.
public struct StartWithMenuItem: Equatable, Sendable {
    public let target: StartTarget
    public let title: String
    public let isSelected: Bool
    /// `false` during a host-screen session -- the same reason
    /// `DisplayCountMenuItem.isEnabled` is: this menu cannot do anything
    /// about the session that is live right now, only the next one, and a
    /// row that only ever ends in a wait for the next launch is disabled
    /// rather than left offering a pick nothing here can act on yet.
    public let isEnabled: Bool

    public init(target: StartTarget, title: String, isSelected: Bool, isEnabled: Bool) {
        self.target = target
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

/// The Screen menu's "Start with" submenu, as data: which target this
/// machine starts on next time it is entered from *Your machines*.
public struct StartWithMenuState: Equatable, Sendable {
    public let title: String
    public let items: [StartWithMenuItem]

    public init(title: String, items: [StartWithMenuItem]) {
        self.title = title
        self.items = items
    }
}

/// The Screen menu's whole content, as data. AppKit-free, so what the menu
/// offers is verified without a menu bar -- `ViewerMainMenuController` only
/// asks this for the current rows and draws them, the same split
/// `DisplayCountMenuPlan` already keeps for the Displays menu next to it.
public struct ScreenMenuState: Equatable, Sendable {
    public let items: [ScreenMenuItem]
    /// The Resolution submenu that hangs off this menu -- the host screen's
    /// own display mode, which only a live host-screen session has. Defaulted
    /// to an empty, unusable one so a caller with no host screen in sight
    /// states nothing about modes.
    public let modes: HostScreenModeMenuState
    /// The "Start with" submenu that hangs off this menu -- which target
    /// this machine starts on next time. Defaulted to "Last used", nothing
    /// else offered, so a caller with no saved preference or host-screen
    /// offer in sight states nothing beyond the current default.
    public let startWith: StartWithMenuState

    public init(
        items: [ScreenMenuItem],
        modes: HostScreenModeMenuState = ScreenMenuPlan.modeMenu(
            modes: [], currentModeID: nil, isHostScreenSessionLive: false
        ),
        startWith: StartWithMenuState = ScreenMenuPlan.startWithMenu(
            preference: .hostScreenWhenOffered, offeredHostScreens: [], isHostScreenSessionLive: false
        )
    ) {
        self.items = items
        self.modes = modes
        self.startWith = startWith
    }
}

public enum ScreenMenuPlan {
    /// docs/ux-spec.md: "Virtual display (default) or Host screen, one of
    /// the host's screens, offered only when the host has allowed this machine
    /// to see a host screen." `displays` is empty for every machine that has
    /// never received a `hostScreenList` offer, in which case Virtual
    /// display is the only row -- there is nothing else to offer, not a
    /// permission this menu can guess at.
    public static func items(displays: [HostScreenListEntry], selectedToken: Data?) -> [ScreenMenuItem] {
        var result = [
            ScreenMenuItem(token: nil, title: "Virtual Display", isSelected: selectedToken == nil)
        ]
        for display in displays {
            result.append(ScreenMenuItem(
                token: display.opaqueToken,
                title: display.label,
                isSelected: selectedToken == display.opaqueToken
            ))
        }
        return result
    }

    /// The Resolution submenu's own rows: every mode the host offered for
    /// the screen this session is streaming, in the host's own order, with
    /// the one it is on checked. A row is named for what a person is
    /// choosing -- the size the screen lays out at -- and says HiDPI only
    /// where that is what distinguishes it from another row of the same
    /// size.
    public static func modeMenu(
        modes: [HostScreenModeEntry],
        currentModeID: String?,
        isHostScreenSessionLive: Bool
    ) -> HostScreenModeMenuState {
        HostScreenModeMenuState(
            title: "Resolution",
            isEnabled: isHostScreenSessionLive && !modes.isEmpty,
            items: modes.map { mode in
                HostScreenModeMenuItem(
                    modeID: mode.modeID,
                    title: modeTitle(mode),
                    isSelected: mode.modeID == currentModeID
                )
            }
        )
    }

    /// "1920 \u{00D7} 1080 (HiDPI)" -- the multiplication sign, not a letter
    /// x, and the points the screen lays out in, which is what "looks like
    /// 1920 by 1080" means to the person choosing it.
    private static func modeTitle(_ mode: HostScreenModeEntry) -> String {
        let size = "\(mode.width) \u{00D7} \(mode.height)"
        return mode.isHiDPI ? "\(size) (HiDPI)" : size
    }

    /// The "Start with" submenu's own rows: "Host screen when offered" and
    /// "Virtual display" always, then one row per host screen this machine
    /// most recently offered -- the same list the Screen menu's own items
    /// already read, so a display can be picked as a starting point before
    /// it has ever been offered to this exact session. Each row's own
    /// `isEnabled` follows `DisplayCountMenuItem`'s rule, not a menu-wide
    /// disable: the row is still legible while it cannot be acted on.
    public static func startWithMenu(
        preference: StartTarget,
        offeredHostScreens: [HostScreenListEntry],
        isHostScreenSessionLive: Bool
    ) -> StartWithMenuState {
        var items = [
            StartWithMenuItem(
                target: .hostScreenWhenOffered,
                title: "Host Screen When Offered",
                isSelected: preference == .hostScreenWhenOffered,
                isEnabled: !isHostScreenSessionLive
            ),
            StartWithMenuItem(
                target: .virtualDisplay,
                title: "Virtual Display",
                isSelected: preference == .virtualDisplay,
                isEnabled: !isHostScreenSessionLive
            )
        ]
        for display in offeredHostScreens {
            items.append(StartWithMenuItem(
                target: .hostScreen(displayIdentity: display.displayIdentity, label: display.label),
                title: display.label,
                isSelected: isSameHostScreen(preference, displayIdentity: display.displayIdentity),
                isEnabled: !isHostScreenSessionLive
            ))
        }
        return StartWithMenuState(title: "Start With", items: items)
    }

    private static func isSameHostScreen(_ preference: StartTarget, displayIdentity: String) -> Bool {
        guard case let .hostScreen(preferredIdentity, _) = preference else { return false }
        return preferredIdentity == displayIdentity
    }
}
