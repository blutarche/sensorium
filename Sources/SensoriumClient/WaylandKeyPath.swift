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
        guard let keyboard, let event = keyboard.key(evdev: evdev, isDown: isDown) else {
            return .dropped
        }
        let destination = destination(for: event)
        guard case let .key(keyCode, _, modifiers) = event,
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

    /// The same decision for an event the window already has in hand: a key
    /// repeat the viewer itself generated, or a modifier change.
    public static func destination(for event: CanvasSurfaceEvent) -> WaylandKeyDestination {
        guard case let .key(keyCode, isDown, modifiers) = event else {
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
