import SensoriumCore

/// Where a system-reserved shortcut typed into the viewer takes effect.
///
/// `remoteInFullscreen` is the default on purpose: a windowed viewer shares a
/// screen with this machine's own apps, and stealing Cmd-Tab from the machine
/// the user is physically sitting at is worse than not forwarding it.
/// Fullscreen is the unambiguous signal that the user means the remote
/// workstation.
public enum SystemShortcutMode: String, Sendable, CaseIterable, Equatable {
    case local
    case remoteWhenFocused
    case remoteInFullscreen

    public static let `default` = SystemShortcutMode.remoteInFullscreen

    /// The `--system-shortcuts` launch flag's spelling, kebab-cased to match
    /// the other flags rather than the Swift case name.
    public var flagValue: String {
        switch self {
        case .local: "local"
        case .remoteWhenFocused: "remote-when-focused"
        case .remoteInFullscreen: "remote-in-fullscreen"
        }
    }

    public init?(flagValue: String) {
        guard let match = Self.allCases.first(where: { $0.flagValue == flagValue }) else {
            return nil
        }
        self = match
    }
}

/// One physical key plus the four modifiers the protocol forwards. Caps lock,
/// function, and numeric-pad state are deliberately absent: `CanvasModifierFlags`
/// does not carry them, so a chord can never be matched on a modifier the host
/// would never be told about.
public struct KeyChord: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: CanvasModifierFlags

    public init(keyCode: UInt16, modifiers: CanvasModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Where on the viewer a chord can still be caught. The distinction is not
/// cosmetic: it decides whether forwarding needs a TCC grant the viewer would
/// otherwise never require.
public enum SystemShortcutInterception: Equatable, Sendable {
    /// The viewer's own key-event path sees it, because macOS routes it
    /// through the ordinary application event dispatch. No extra permission.
    case applicationView
    /// The WindowServer claims it before any application is offered it. Only
    /// a `CGEventTap` can see it, and creating one requires Accessibility
    /// (TCC) approval for Sensorium.
    case eventTap
}

public struct SystemShortcut: Equatable, Sendable {
    public let name: String
    public let chord: KeyChord
    public let interception: SystemShortcutInterception

    public init(name: String, chord: KeyChord, interception: SystemShortcutInterception) {
        self.name = name
        self.chord = chord
        self.interception = interception
    }
}

/// The chords a remote *workstation* user expects to act on the far machine,
/// and the escape gesture that is excluded from them by construction.
public enum SystemShortcutCatalog {
    // Carbon virtual key codes, which is the vocabulary the protocol's
    // `keyCode` already speaks.
    private static let tab: UInt16 = 48
    private static let space: UInt16 = 49
    private static let grave: UInt16 = 50
    private static let escape: UInt16 = 53
    private static let letterQ: UInt16 = 12
    private static let letterW: UInt16 = 13
    private static let letterH: UInt16 = 4
    private static let letterM: UInt16 = 46
    private static let arrowLeft: UInt16 = 123
    private static let arrowRight: UInt16 = 124
    private static let arrowDown: UInt16 = 125
    private static let arrowUp: UInt16 = 126

    /// The one gesture that always returns the user to the machine they are
    /// sitting at. It is never a member of `all`, so no mode, focus state, or
    /// permission can make it forwardable — `escapeGestureIsNeverForwardable`
    /// proves that rather than trusting it. Control is what keeps it clear of
    /// macOS's own Cmd-Option-Escape (Force Quit), whose symbolic hotkey
    /// matches an exact modifier mask and so does not fire with Control added.
    public static let escapeGesture = KeyChord(
        keyCode: escape,
        modifiers: [.control, .option, .command]
    )

    /// Split by interception, because that is what decides which half of the
    /// set survives without an Accessibility grant on Sensorium.
    ///
    /// `eventTap` entries are macOS symbolic hotkeys: the WindowServer
    /// consumes them before application dispatch. `applicationView` entries
    /// are ordinary menu-style key equivalents, which the viewer's own key
    /// path already receives.
    public static let all: [SystemShortcut] = [
        SystemShortcut(name: "Cmd-Tab (switch app)", chord: KeyChord(keyCode: tab, modifiers: [.command]), interception: .eventTap),
        SystemShortcut(name: "Cmd-Shift-Tab (switch app backwards)", chord: KeyChord(keyCode: tab, modifiers: [.command, .shift]), interception: .eventTap),
        SystemShortcut(name: "Cmd-Space (Spotlight)", chord: KeyChord(keyCode: space, modifiers: [.command]), interception: .eventTap),
        SystemShortcut(name: "Cmd-` (next window in app)", chord: KeyChord(keyCode: grave, modifiers: [.command]), interception: .eventTap),
        SystemShortcut(name: "Cmd-Shift-` (previous window in app)", chord: KeyChord(keyCode: grave, modifiers: [.command, .shift]), interception: .eventTap),
        SystemShortcut(name: "Ctrl-Up (Mission Control)", chord: KeyChord(keyCode: arrowUp, modifiers: [.control]), interception: .eventTap),
        SystemShortcut(name: "Ctrl-Down (application windows)", chord: KeyChord(keyCode: arrowDown, modifiers: [.control]), interception: .eventTap),
        SystemShortcut(name: "Ctrl-Left (previous space)", chord: KeyChord(keyCode: arrowLeft, modifiers: [.control]), interception: .eventTap),
        SystemShortcut(name: "Ctrl-Right (next space)", chord: KeyChord(keyCode: arrowRight, modifiers: [.control]), interception: .eventTap),
        SystemShortcut(name: "Cmd-Q (quit app)", chord: KeyChord(keyCode: letterQ, modifiers: [.command]), interception: .applicationView),
        SystemShortcut(name: "Cmd-W (close window)", chord: KeyChord(keyCode: letterW, modifiers: [.command]), interception: .applicationView),
        SystemShortcut(name: "Cmd-H (hide app)", chord: KeyChord(keyCode: letterH, modifiers: [.command]), interception: .applicationView),
        SystemShortcut(name: "Cmd-M (minimize window)", chord: KeyChord(keyCode: letterM, modifiers: [.command]), interception: .applicationView)
    ]

    /// Exact modifier match, not a subset test: Cmd-Tab and Cmd-Shift-Tab are
    /// different shortcuts, and a chord carrying an extra modifier is neither.
    public static func shortcut(for chord: KeyChord) -> SystemShortcut? {
        all.first { $0.chord == chord }
    }

    /// True only when no catalog entry shares the escape gesture's chord, so
    /// the "un-forwardable by construction" claim is checkable rather than
    /// asserted in a comment.
    public static var escapeGestureIsNeverForwardable: Bool {
        shortcut(for: escapeGesture) == nil
    }
}

/// What the viewer window looked like when the key arrived. Pure data, so the
/// routing decision needs no window and no window server.
public struct ViewerWindowState: Equatable, Sendable {
    public let surfaceID: UInt32
    public let hasKeyFocus: Bool
    public let isFullscreen: Bool

    public init(surfaceID: UInt32, hasKeyFocus: Bool, isFullscreen: Bool) {
        self.surfaceID = surfaceID
        self.hasKeyFocus = hasKeyFocus
        self.isFullscreen = isFullscreen
    }
}

public enum SystemShortcutDecision: Equatable, Sendable {
    /// Send it to the host, tagged with the surface whose window had focus.
    case forwardToHost(surfaceID: UInt32)
    /// The local machine keeps it; nothing is sent.
    case deliverToLocalMachine
    /// The mode says forward, but this chord cannot be seen without
    /// Accessibility for Sensorium. Deliberately not `forwardToHost`: the
    /// caller must be able to say which shortcut is not reaching the host and
    /// why, instead of dropping it silently.
    case notForwardedAccessibilityRequired(SystemShortcut)
    /// The escape gesture. Never forwarded; hands the user back to the local
    /// machine.
    case releaseToLocalMachine

    public var forwardsToHost: Bool {
        if case .forwardToHost = self { return true }
        return false
    }
}

/// The whole routing policy: mode, focus, fullscreen, chord and
/// Sensorium's Accessibility status in, one decision out. No AppKit, no
/// event tap, no window — everything above it is glue.
public struct SystemShortcutRouter: Sendable {
    public let mode: SystemShortcutMode

    public init(mode: SystemShortcutMode = .default) {
        self.mode = mode
    }

    public func decide(
        chord: KeyChord,
        viewer: ViewerWindowState,
        accessibilityGranted: Bool
    ) -> SystemShortcutDecision {
        // First, and before anything that could forward: the escape gesture is
        // the user's guaranteed way out of a fullscreen viewer.
        if chord == SystemShortcutCatalog.escapeGesture {
            return .releaseToLocalMachine
        }
        guard let shortcut = SystemShortcutCatalog.shortcut(for: chord) else {
            // Ordinary typing. Unchanged in every mode: whatever the viewer's
            // key path receives goes to the canvas it is looking at.
            return viewer.hasKeyFocus ? .forwardToHost(surfaceID: viewer.surfaceID) : .deliverToLocalMachine
        }
        guard shouldForwardSystemShortcut(viewer: viewer) else {
            return .deliverToLocalMachine
        }
        guard shortcut.interception == .applicationView || accessibilityGranted else {
            return .notForwardedAccessibilityRequired(shortcut)
        }
        return .forwardToHost(surfaceID: viewer.surfaceID)
    }

    /// Whether the canvas must take this chord before the menu bar is offered
    /// it. AppKit matches a menu key equivalent ahead of the key window's
    /// `keyDown:`, so Cmd-Q -- a menu item and a catalog entry both -- quit
    /// the viewer rather than the app on the remote workstation, which is
    /// backwards once the user has asked for keys to go to the far machine.
    ///
    /// Only a chord the catalog reserves is taken this way, and only when
    /// `decide` says forward. Ordinary typing keeps its existing `keyDown`
    /// path, so the viewer's own chords that no catalog entry claims --
    /// Cmd-Ctrl-F, the way out of fullscreen -- still reach the menu.
    public func claimsKeyEquivalent(
        chord: KeyChord,
        viewer: ViewerWindowState,
        accessibilityGranted: Bool
    ) -> Bool {
        guard SystemShortcutCatalog.shortcut(for: chord) != nil else { return false }
        return decide(
            chord: chord,
            viewer: viewer,
            accessibilityGranted: accessibilityGranted
        ).forwardsToHost
    }

    private func shouldForwardSystemShortcut(viewer: ViewerWindowState) -> Bool {
        switch mode {
        case .local:
            false
        case .remoteWhenFocused:
            viewer.hasKeyFocus
        case .remoteInFullscreen:
            viewer.hasKeyFocus && viewer.isFullscreen
        }
    }
}
