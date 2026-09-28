import Foundation
import SensoriumCore

/// What the viewer's menu bar contains, as data: titles, chords, and which
/// existing capability each item reaches. AppKit-free on purpose, so the whole
/// menu is verified without a menu bar or a window.
///
/// Every command names something the app can already do. There is deliberately
/// no Settings item: a menu item that opens nothing is worse than no menu item.
public enum ViewerMenuCommand: Equatable, Sendable {
    case about
    case hide
    case hideOthers
    /// Standard `unhideAllApplications:` -- grouped with Hide and Hide
    /// Others rather than off on its own, the same grouping every macOS app
    /// menu uses.
    case showAll
    case quit
    /// Brings the launch window -- the list of machines this one has paired with
    /// -- to the front, whether or not a session is running. It is the only
    /// way to reach a different machine from inside a live session.
    case showYourMachines
    /// The six standard text-editing commands, routed to the responder chain
    /// by nil target -- see `ViewerMenu.autoenablesItems`.
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    /// Standard window-management commands, sent to whichever window is key.
    case minimize
    case zoom
    case bringAllToFront
    case toggleFullScreen
    case toggleTelemetryOverlay
    case togglePointerCapture
    /// docs/ux-spec.md's "Clipboard: on or off" -- a single checkbox item,
    /// not a multi-row menu like Displays or Screen, since there is nothing
    /// to name beyond the one state. See `ClipboardSharingToggle`.
    case toggleClipboardSharing
    /// Picks the cap on the streamed scale -- `nil` for Automatic, no cap at
    /// all -- for whichever window has focus. See `DisplayScaleMenuPlan`.
    case setStreamScale(Double?)
    /// The Displays menu's rows -- see `DisplayCountMenuPlan`.
    case selectDisplayCount(Int)
    /// The Screen menu's rows: `nil` for Virtual display, otherwise the
    /// host's own token for one of its screens -- see `ScreenMenuPlan`.
    case selectRealScreen(Data?)
    /// The Screen menu's Resolution submenu rows.
    case selectHostScreenMode(String)
    /// The Screen menu's "Start with" submenu rows.
    case selectStartTarget(StartTarget)
    /// An item that only opens `ViewerMenuItem.submenu`.
    case submenu
    /// The one line naming why the picture is currently clamped below what
    /// was asked for. Never clickable, like `escapeGestureHint`, and present
    /// only while there is something to explain -- see
    /// `DisplayScaleMenuPlan.clampNotice`.
    case streamScaleClampNotice
    /// States the escape gesture and nothing else. Never clickable and never
    /// given a key equivalent -- the gesture is `CanvasSurfaceView`'s
    /// guaranteed exit from a captured pointer, and a menu item claiming that
    /// chord would take it before the view could honour it.
    case escapeGestureHint
    case separator
}

/// The four modifiers a menu chord can carry, named rather than taken from
/// AppKit so the plan stays verifiable without it.
public struct ViewerMenuModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ViewerMenuModifiers(rawValue: 1 << 0)
    public static let shift = ViewerMenuModifiers(rawValue: 1 << 1)
    public static let option = ViewerMenuModifiers(rawValue: 1 << 2)
    public static let control = ViewerMenuModifiers(rawValue: 1 << 3)
}

public struct ViewerMenuItem: Equatable, Sendable {
    public let title: String
    public let command: ViewerMenuCommand
    /// The character the chord is typed on; empty when the item has no chord.
    public let keyEquivalent: String
    public let modifiers: ViewerMenuModifiers
    public let isEnabled: Bool
    /// Whether this item names the current choice -- the resolution picker's
    /// checkmark. Never true for a toggle or an informational item.
    public let isSelected: Bool
    public let submenu: ViewerMenu?

    public init(
        title: String,
        command: ViewerMenuCommand,
        keyEquivalent: String = "",
        modifiers: ViewerMenuModifiers = [],
        isEnabled: Bool = true,
        isSelected: Bool = false,
        submenu: ViewerMenu? = nil
    ) {
        self.title = title
        self.command = command
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.submenu = submenu
    }

    public static let separator = ViewerMenuItem(title: "", command: .separator, isEnabled: false)
}

public struct ViewerMenu: Equatable, Sendable {
    public let title: String
    /// `false` for every menu but Edit: those enable and disable their items
    /// explicitly (the escape-gesture line, the pointer-capture and full
    /// screen titles), and automatic enabling would fight that. Edit's items
    /// are nil-target standard editing selectors, so AppKit's own responder-
    /// chain check is what disables them while a session canvas -- which
    /// implements none of them -- is key, and enables them for the pairing
    /// form's text fields, which do.
    public let autoenablesItems: Bool
    public let items: [ViewerMenuItem]

    public init(title: String, autoenablesItems: Bool = false, items: [ViewerMenuItem]) {
        self.title = title
        self.autoenablesItems = autoenablesItems
        self.items = items
    }
}

/// Everything the menu bar's content depends on: the focused session
/// window's own state, or the defaults before any window has had focus.
public struct ViewerMenuBarState: Equatable, Sendable {
    public var streamScale: DisplayScaleMenuState
    public var displayCount: DisplayCountMenuState
    public var screen: ScreenMenuState
    public var isPointerCaptured: Bool
    public var isClipboardSharingEnabled: Bool
    public var isFullscreen: Bool
    public var canFullScreen: Bool
    public var minimizeEnabled: Bool
    public var zoomEnabled: Bool
    public var bringAllToFrontEnabled: Bool

    public init(
        streamScale: DisplayScaleMenuState = Self.initial.streamScale,
        displayCount: DisplayCountMenuState = Self.initial.displayCount,
        screen: ScreenMenuState = Self.initial.screen,
        isPointerCaptured: Bool = false,
        isClipboardSharingEnabled: Bool = ClipboardSyncEngine.sharingEnabledByDefault,
        isFullscreen: Bool = false,
        canFullScreen: Bool = true,
        minimizeEnabled: Bool = true,
        zoomEnabled: Bool = true,
        bringAllToFrontEnabled: Bool = true
    ) {
        self.streamScale = streamScale
        self.displayCount = displayCount
        self.screen = screen
        self.isPointerCaptured = isPointerCaptured
        self.isClipboardSharingEnabled = isClipboardSharingEnabled
        self.isFullscreen = isFullscreen
        self.canFullScreen = canFullScreen
        self.minimizeEnabled = minimizeEnabled
        self.zoomEnabled = zoomEnabled
        self.bringAllToFrontEnabled = bringAllToFrontEnabled
    }

    /// Before any window has had focus: the canvas geometry every session
    /// streams with no cap chosen, one display, and Virtual display the only
    /// screen until the host offers one.
    public static let initial = ViewerMenuBarState(
        streamScale: DisplayScaleMenuState(
            items: DisplayScaleMenuPlan.items(
                selectedPreference: .automatic,
                canvasLogicalWidth: Double(SavedHost.remoteCanvasPreset.logicalWidth),
                canvasLogicalHeight: Double(SavedHost.remoteCanvasPreset.logicalHeight)
            ),
            clampNotice: nil
        ),
        displayCount: DisplayCountMenuState(items: DisplayCountMenuPlan.items(selectedCount: 1)),
        screen: ScreenMenuState(items: ScreenMenuPlan.items(displays: [], selectedToken: nil))
    )
}

/// One line of a flattened menu bar, as either platform draws it: what a
/// test compares when it checks that two menu bars match. `depth` 0 is a
/// menu's own title in the bar. `isEnabled` is `nil` in a menu whose items
/// the focused text field enables (Edit).
public struct ViewerMenuRow: Equatable, Sendable, CustomStringConvertible {
    public let depth: Int
    public let title: String
    public let keyEquivalent: String
    public let modifiers: ViewerMenuModifiers
    public let isEnabled: Bool?
    public let isChecked: Bool
    public let isSeparator: Bool

    public init(
        depth: Int,
        title: String,
        keyEquivalent: String,
        modifiers: ViewerMenuModifiers,
        isEnabled: Bool?,
        isChecked: Bool,
        isSeparator: Bool
    ) {
        self.depth = depth
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
    }

    public var description: String {
        let enabled = isEnabled.map { $0 ? "on" : "off" } ?? "auto"
        return "\(depth) \"\(title)\" key=\(keyEquivalent)/\(modifiers.rawValue) \(enabled)"
            + "\(isChecked ? " checked" : "")\(isSeparator ? " separator" : "")"
    }
}

public enum ViewerMenuPlan {
    /// The fixed menus as they read before any window has had focus.
    public static let menus: [ViewerMenu] = fixedMenus(.initial)

    /// The whole bar, in order: the app menu, Edit, View, then the session's
    /// own Displays, Resolution and Screen, then Window and Help.
    public static func bar(_ state: ViewerMenuBarState) -> [ViewerMenu] {
        var result: [ViewerMenu] = []
        for menu in fixedMenus(state) {
            result.append(menu)
            if menu.title == "View" {
                result.append(displaysMenu(state.displayCount))
                result.append(resolutionMenu(state.streamScale))
                result.append(screenMenu(state.screen))
            }
        }
        return result
    }

    public static func displaysMenu(_ state: DisplayCountMenuState) -> ViewerMenu {
        ViewerMenu(title: "Displays", items: state.items.map {
            ViewerMenuItem(
                title: $0.title, command: .selectDisplayCount($0.count),
                isEnabled: $0.isEnabled, isSelected: $0.isSelected
            )
        })
    }

    public static func resolutionMenu(_ state: DisplayScaleMenuState) -> ViewerMenu {
        var items = state.items.map {
            ViewerMenuItem(title: $0.title, command: .setStreamScale($0.scale), isSelected: $0.isSelected)
        }
        if let clampNotice = state.clampNotice {
            items.append(.separator)
            items.append(ViewerMenuItem(title: clampNotice, command: .streamScaleClampNotice, isEnabled: false))
        }
        return ViewerMenu(title: "Resolution", items: items)
    }

    /// The screens, then the streamed screen's own Resolution, which is
    /// always present and only pickable in a live host-screen session, then
    /// "Start with", the saved choice for next time.
    public static func screenMenu(_ state: ScreenMenuState) -> ViewerMenu {
        var items = state.items.map {
            ViewerMenuItem(title: $0.title, command: .selectRealScreen($0.token), isSelected: $0.isSelected)
        }
        items.append(.separator)
        items.append(ViewerMenuItem(
            title: state.modes.title,
            command: .submenu,
            isEnabled: state.modes.isEnabled,
            submenu: ViewerMenu(title: state.modes.title, items: state.modes.items.map {
                ViewerMenuItem(
                    title: $0.title, command: .selectHostScreenMode($0.modeID),
                    isEnabled: state.modes.isEnabled, isSelected: $0.isSelected
                )
            })
        ))
        items.append(ViewerMenuItem(
            title: state.startWith.title,
            command: .submenu,
            submenu: ViewerMenu(title: state.startWith.title, items: state.startWith.items.map {
                ViewerMenuItem(
                    title: $0.title, command: .selectStartTarget($0.target),
                    isEnabled: $0.isEnabled, isSelected: $0.isSelected
                )
            })
        ))
        return ViewerMenu(title: "Screen", items: items)
    }

    /// Every line of `menus`, depth first, as `ViewerMenuRow`s.
    public static func rows(of menus: [ViewerMenu]) -> [ViewerMenuRow] {
        var result: [ViewerMenuRow] = []
        func add(_ menu: ViewerMenu, depth: Int) {
            for item in menu.items {
                let isSeparator = item.command == .separator
                result.append(ViewerMenuRow(
                    depth: depth,
                    title: item.title,
                    keyEquivalent: item.keyEquivalent,
                    modifiers: item.modifiers,
                    isEnabled: menu.autoenablesItems ? nil : item.isEnabled,
                    isChecked: item.isSelected,
                    isSeparator: isSeparator
                ))
                if let submenu = item.submenu {
                    add(submenu, depth: depth + 1)
                }
            }
        }
        for menu in menus {
            result.append(ViewerMenuRow(
                depth: 0, title: menu.title, keyEquivalent: "", modifiers: [],
                isEnabled: true, isChecked: false, isSeparator: false
            ))
            add(menu, depth: 1)
        }
        return result
    }

    /// Cmd-W and Cmd-M are deliberately absent. Both are
    /// `SystemShortcutCatalog` entries the viewer forwards to the host, and a
    /// menu key equivalent is matched before the key window's own key path, so
    /// an item claiming either would quietly stop it ever reaching the remote
    /// workstation. The close button, not a chord, is how a window is closed.
    private static func fixedMenus(_ state: ViewerMenuBarState) -> [ViewerMenu] {
        let fullScreen = fullScreenItem(isFullscreen: state.isFullscreen, canFullScreen: state.canFullScreen)
        return [
            ViewerMenu(title: appName, items: [
                ViewerMenuItem(title: "About \(appName)", command: .about),
                .separator,
                ViewerMenuItem(
                    title: "Your Machines\u{2026}",
                    command: .showYourMachines,
                    keyEquivalent: "1",
                    modifiers: [.command]
                ),
                .separator,
                ViewerMenuItem(title: "Hide \(appName)", command: .hide, keyEquivalent: "h", modifiers: [.command]),
                ViewerMenuItem(title: "Hide Others", command: .hideOthers, keyEquivalent: "h", modifiers: [.command, .option]),
                ViewerMenuItem(title: "Show All", command: .showAll),
                .separator,
                ViewerMenuItem(title: "Quit \(appName)", command: .quit, keyEquivalent: "q", modifiers: [.command])
            ]),
            // `SystemShortcutRouter.claimsKeyEquivalent` admits these same six
            // chords alongside `SystemShortcutCatalog`'s own entries, so the
            // canvas claims them before this menu can, exactly as it
            // does for Cmd-Q/W/H/M -- see that method's own doc comment.
            ViewerMenu(title: "Edit", autoenablesItems: true, items: [
                ViewerMenuItem(title: "Undo", command: .undo, keyEquivalent: "z", modifiers: [.command]),
                ViewerMenuItem(title: "Redo", command: .redo, keyEquivalent: "z", modifiers: [.command, .shift]),
                .separator,
                ViewerMenuItem(title: "Cut", command: .cut, keyEquivalent: "x", modifiers: [.command]),
                ViewerMenuItem(title: "Copy", command: .copy, keyEquivalent: "c", modifiers: [.command]),
                ViewerMenuItem(title: "Paste", command: .paste, keyEquivalent: "v", modifiers: [.command]),
                ViewerMenuItem(title: "Select All", command: .selectAll, keyEquivalent: "a", modifiers: [.command])
            ]),
            ViewerMenu(title: "View", items: [
                ViewerMenuItem(
                    title: fullScreen.title,
                    command: .toggleFullScreen,
                    keyEquivalent: "f",
                    modifiers: [.command, .control],
                    isEnabled: fullScreen.isEnabled
                ),
                .separator,
                // Named as toggles rather than as "Show…"/"Hide…": neither state
                // is readable from here, and a static title that is wrong half the
                // time is worse than one that is always true.
                ViewerMenuItem(
                    title: "Session Diagnostics",
                    command: .toggleTelemetryOverlay,
                    keyEquivalent: "l",
                    modifiers: [.command, .shift]
                ),
                ViewerMenuItem(
                    title: pointerCaptureTitle(isCaptured: state.isPointerCaptured),
                    command: .togglePointerCapture,
                    keyEquivalent: "g",
                    modifiers: [.command, .shift],
                    isSelected: state.isPointerCaptured
                ),
                ViewerMenuItem(
                    title: "Share Clipboard",
                    command: .toggleClipboardSharing,
                    keyEquivalent: "c",
                    modifiers: [.command, .shift],
                    isSelected: state.isClipboardSharingEnabled
                )
            ]),
            // Set as `NSApp.windowsMenu` by `ViewerMainMenuController.install(into:)`,
            // so macOS appends the live window list below these; installed with
            // no Cmd-M, the same reason the app menu carries no Cmd-W -- both are
            // `SystemShortcutCatalog` entries the viewer forwards to the host.
            ViewerMenu(title: "Window", items: [
                ViewerMenuItem(title: "Minimize", command: .minimize, isEnabled: state.minimizeEnabled),
                ViewerMenuItem(title: "Zoom", command: .zoom, isEnabled: state.zoomEnabled),
                .separator,
                ViewerMenuItem(title: "Bring All to Front", command: .bringAllToFront, isEnabled: state.bringAllToFrontEnabled)
            ]),
            ViewerMenu(title: "Help", items: [
                ViewerMenuItem(
                    title: "Escape back to this machine: \(ViewerKeyNames.escapeGesture)",
                    command: .escapeGestureHint,
                    isEnabled: false
                )
            ])
        ]
    }

    public static let appName = "Sensorium"

    /// What the captured-pointer item says for itself, so the title names
    /// the mode rather than only offering a toggle.
    public static func pointerCaptureTitle(isCaptured: Bool) -> String {
        isCaptured ? "Release Captured Pointer" : "Capture Pointer"
    }

    /// What the full screen item says and whether it can be clicked, so its
    /// title always names the key window's actual state rather than only
    /// offering a toggle -- the same reasoning `pointerCaptureTitle` follows.
    /// `canFullScreen` is false when no window this menu knows about is key
    /// -- the launch window included, which is not resizable and cannot
    /// enter full screen at all.
    public static func fullScreenItem(isFullscreen: Bool, canFullScreen: Bool) -> (title: String, isEnabled: Bool) {
        (isFullscreen ? "Exit Full Screen" : "Enter Full Screen", canFullScreen)
    }

    /// Whether the Window menu's Minimize, Zoom and Bring All to Front items
    /// can be clicked, computed from the traits of whichever window
    /// `ViewerMainMenuController.menuNeedsUpdate` currently reads them from
    /// -- the key window, or the main window if none is key -- and whether
    /// any window of the app is visible at all. A window like the launch
    /// window's own `[.titled, .closable]` carries neither `.miniaturizable`
    /// nor `.resizable`, so both `canMiniaturize` and `canZoom` are false
    /// for it.
    public static func windowMenuState(
        canMiniaturize: Bool,
        isMiniaturized: Bool,
        canZoom: Bool,
        hasVisibleWindow: Bool
    ) -> (minimizeEnabled: Bool, zoomEnabled: Bool, bringAllToFrontEnabled: Bool) {
        (canMiniaturize && !isMiniaturized, canZoom, hasVisibleWindow)
    }
}

/// What the Clipboard item's own toggle sends next. Pulled out here, rather
/// than computed inline in `ClientCanvasWindowController`, because that
/// class is never constructed by any verification runner -- building it
/// opens a window and creates a Metal device -- so this is the seam a test
/// can reach, the same reasoning `DisplayCountMenuPlan` and
/// `pointerCaptureTitle` above already follow for their own controls.
public enum ClipboardSharingToggle {
    /// Always the opposite of what this window currently caches -- the
    /// window's own choice is forwarded, sent by whoever owns the live
    /// session (`ClientSessionHost`), never decided a second time there.
    public static func nextValue(currentlyEnabled: Bool) -> Bool {
        !currentlyEnabled
    }
}
