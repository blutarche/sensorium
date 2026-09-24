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
    case quit
    /// Brings the launch window -- the list of machines this one has paired with
    /// -- to the front, whether or not a session is running. It is the only
    /// way to reach a different machine from inside a live session.
    case showYourMachines
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

    public init(
        title: String,
        command: ViewerMenuCommand,
        keyEquivalent: String = "",
        modifiers: ViewerMenuModifiers = [],
        isEnabled: Bool = true,
        isSelected: Bool = false
    ) {
        self.title = title
        self.command = command
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }

    public static let separator = ViewerMenuItem(title: "", command: .separator, isEnabled: false)
}

public struct ViewerMenu: Equatable, Sendable {
    public let title: String
    public let items: [ViewerMenuItem]
}

public enum ViewerMenuPlan {
    /// Cmd-W and Cmd-M are deliberately absent. Both are
    /// `SystemShortcutCatalog` entries the viewer forwards to the host, and a
    /// menu key equivalent is matched before the key window's own key path, so
    /// an item claiming either would quietly stop it ever reaching the remote
    /// workstation. The close button, not a chord, is how a window is closed.
    public static let menus: [ViewerMenu] = [
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
            .separator,
            ViewerMenuItem(title: "Quit \(appName)", command: .quit, keyEquivalent: "q", modifiers: [.command])
        ]),
        ViewerMenu(title: "View", items: [
            ViewerMenuItem(
                title: "Enter Full Screen",
                command: .toggleFullScreen,
                keyEquivalent: "f",
                modifiers: [.command, .control]
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
            // The static default, for the moment before anything has told this
            // item which state it is in; `ViewerMainMenuController` rewrites
            // the title on every `menuNeedsUpdate` so it always names the
            // state the window is in.
            ViewerMenuItem(
                title: pointerCaptureTitle(isCaptured: false),
                command: .togglePointerCapture,
                keyEquivalent: "g",
                modifiers: [.command, .shift]
            ),
            // The state before any window has said otherwise.
            ViewerMenuItem(
                title: "Share Clipboard",
                command: .toggleClipboardSharing,
                keyEquivalent: "c",
                modifiers: [.command, .shift],
                isSelected: ClipboardSyncEngine.sharingEnabledByDefault
            )
        ]),
        ViewerMenu(title: "Help", items: [
            ViewerMenuItem(
                title: "Escape back to this machine: \(ViewerKeyNames.escapeGesture)",
                command: .escapeGestureHint,
                isEnabled: false
            )
        ])
    ]

    public static let appName = "Sensorium"

    /// What the captured-pointer item says for itself, so the title names
    /// the mode rather than only offering a toggle.
    public static func pointerCaptureTitle(isCaptured: Bool) -> String {
        isCaptured ? "Release Captured Pointer" : "Capture Pointer"
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
