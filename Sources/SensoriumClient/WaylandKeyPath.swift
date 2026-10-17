import Foundation
import SensoriumCore

/// What the Linux session window needs from the keyboard's own translation of
/// one key the compositor reported.
///
/// A protocol rather than the concrete keyboard, because the concrete one
/// needs xkbcommon and a live compositor.
@MainActor
public protocol WaylandKeyTranslating {
    /// The press as a wire event, or `nil` for a key with no position the far
    /// machine would understand.
    func key(evdev code: UInt32, isDown: Bool) -> CanvasSurfaceEvent?
    /// The character the key types in the person's own layout, lowercased:
    /// what a menu chord is matched against, as macOS matches one.
    func character(evdev code: UInt32) -> String?
}

/// What the session window's menu needs to decide whether a key is its own.
public struct WaylandSessionMenuKeys: Sendable {
    public let menus: [ViewerMenu]
    public let router: SystemShortcutRouter
    public let viewer: ViewerWindowState

    public init(menus: [ViewerMenu], router: SystemShortcutRouter, viewer: ViewerWindowState) {
        self.menus = menus
        self.router = router
        self.viewer = viewer
    }
}

/// Where one key the compositor reported goes.
public enum WaylandKeyDestination: Equatable, Sendable {
    /// The viewer's own chord for the shortcut strip.
    case shortcutStrip(isDown: Bool)
    /// A chord the far machine reserves, offered first to the compositor's
    /// shortcut inhibitor and then, if it is the escape gesture, to the way
    /// back to the local machine. Carries the event it came from, because a
    /// reserved chord neither of those takes still goes to the canvas.
    case reservedChord(KeyChord, CanvasSurfaceEvent, isDown: Bool)
    /// A chord a menu item shows, which a macOS canvas would leave to the
    /// menu too.
    case menuCommand(ViewerMenuCommand, isDown: Bool)
    case canvas(CanvasSurfaceEvent)
    /// Nothing to send.
    case dropped
}

/// The keys whose press was sent to the far machine and whose release it has
/// not yet been sent.
///
/// A release is the far machine's whenever its press was, however the menus
/// or the viewer's own chords would read it by then: a key pressed alone and
/// let go after the viewer's chord modifiers went down is no chord at all to
/// the machine that saw it pressed, and swallowing the release would leave
/// it held there.
public struct WaylandForwardedKeys: Equatable, Sendable {
    private var held: Set<UInt32> = []

    public init() {}

    /// The press of this key was sent to the far machine.
    public mutating func noteForwarded(evdev code: UInt32) {
        held.insert(code)
    }

    /// Answers whether this key's release is owed to the far machine, and
    /// settles the debt: it is owed once.
    public mutating func takeRelease(evdev code: UInt32) -> Bool {
        held.remove(code) != nil
    }

    /// The far machine let go of everything, as it does when the keyboard
    /// leaves the window.
    public mutating func removeAll() {
        held.removeAll()
    }
}

/// The one place the Linux viewer decides where a key goes.
///
/// Split out of `WaylandSessionWindow` because that window cannot be built
/// without a compositor, and this order is what decides which keys stay on
/// the machine the person is sitting at.
public enum WaylandKeyPath {
    /// The order: the strip's chord, which belongs to the machine the person
    /// is sitting at, then a menu item's chord, then the chords the far
    /// machine reserves, then the canvas.
    @MainActor
    public static func destination(
        evdev: UInt32,
        isDown: Bool,
        keyboard: WaylandKeyTranslating?,
        menu: WaylandSessionMenuKeys? = nil
    ) -> WaylandKeyDestination {
        var none = WaylandForwardedKeys()
        return destination(evdev: evdev, isDown: isDown, keyboard: keyboard, menu: menu, forwarded: &none)
    }

    /// The same order, after the one rule that comes before it: the release
    /// of a key the far machine saw pressed goes to the far machine.
    @MainActor
    public static func destination(
        evdev: UInt32,
        isDown: Bool,
        keyboard: WaylandKeyTranslating?,
        menu: WaylandSessionMenuKeys?,
        forwarded: inout WaylandForwardedKeys
    ) -> WaylandKeyDestination {
        if !isDown, let release = forwardedRelease(evdev: evdev, keyboard: keyboard, forwarded: &forwarded) {
            return release
        }
        guard let keyboard, let event = keyboard.key(evdev: evdev, isDown: isDown) else {
            return .dropped
        }
        let destination = destination(for: event)
        guard case let .key(keyCode, _, modifiers, _) = event,
              destination != .shortcutStrip(isDown: isDown),
              let menu, let key = keyboard.character(evdev: evdev),
              let command = LinuxViewerMenu.sessionCommand(
                  chord: KeyChord(keyCode: keyCode, modifiers: modifiers),
                  key: key,
                  in: menu.menus,
                  router: menu.router,
                  viewer: menu.viewer
              )
        else { return destination }
        return .menuCommand(command, isDown: isDown)
    }

    /// Where the release of this key goes if the far machine saw it pressed,
    /// and nil if it did not. Asked on its own by a window whose open menu
    /// takes every other key.
    @MainActor
    public static func forwardedRelease(
        evdev: UInt32,
        keyboard: WaylandKeyTranslating?,
        forwarded: inout WaylandForwardedKeys
    ) -> WaylandKeyDestination? {
        guard forwarded.takeRelease(evdev: evdev) else { return nil }
        // The keyboard is told even when the far machine is not, so its
        // record of what is held stays true.
        guard let event = keyboard?.key(evdev: evdev, isDown: false) else { return .dropped }
        return .canvas(event)
    }

    /// The same decision for an event the window already has in hand: a key
    /// repeat the viewer itself generated, or a modifier change.
    public static func destination(for event: CanvasSurfaceEvent) -> WaylandKeyDestination {
        guard case let .key(keyCode, isDown, modifiers, _) = event else {
            return .canvas(event)
        }
        let chord = KeyChord(keyCode: keyCode, modifiers: modifiers)
        // The strip's chord belongs to the machine the person is sitting at
        // rather than the one being worked on, and is never forwarded.
        if chord == SystemShortcutCatalog.shortcutStripToggle {
            return .shortcutStrip(isDown: isDown)
        }
        if chord == SystemShortcutCatalog.escapeGesture
            || SystemShortcutCatalog.shortcut(for: chord) != nil {
            return .reservedChord(chord, event, isDown: isDown)
        }
        return .canvas(event)
    }
}
