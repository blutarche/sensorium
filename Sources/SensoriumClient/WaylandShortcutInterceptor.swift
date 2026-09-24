import Foundation
import SensoriumCore

/// What shortcut forwarding asks of a Wayland compositor: stop taking your
/// own chords while this surface has the keyboard, and start again when the
/// viewer is done.
///
/// Behind a protocol for the same reason the pointer lock is: the decision of
/// when a chord counts as claimed is worth checking without a compositor.
@MainActor
public protocol WaylandShortcutInhibiting: AnyObject {
    /// Answers whether the request was made at all -- false where the
    /// compositor never advertised the interface.
    func requestShortcutInhibitor() -> Bool
    func destroyShortcutInhibitor()
}

/// The Wayland counterpart of the macOS event tap: where macOS needs an
/// Accessibility grant to see the chords the WindowServer takes first, a
/// Wayland client asks the compositor to stop taking them. Everything the
/// compositor then leaves alone arrives on the ordinary keyboard path, so
/// this type sees no events of its own -- the window hands it each reserved
/// chord and it answers whether the chord was claimed for the host.
@MainActor
public final class WaylandShortcutInterceptor: SystemShortcutInterceptor {
    /// Said when the compositor keeps its own shortcuts. Named here rather
    /// than at the call site so the one sentence the person reads is not
    /// assembled twice.
    public static let compositorKeepsShortcutsNotice =
        "the compositor is keeping its shortcuts; reserved chords stay local until the viewer window is focused again"

    private let inhibiting: any WaylandShortcutInhibiting
    private var handler: ((KeyChord, Bool) -> Bool)?
    private var onDegraded: ((String) -> Void)?
    private var hasInhibitor = false
    private var isInhibitActive = false

    public init(inhibiting: any WaylandShortcutInhibiting) {
        self.inhibiting = inhibiting
    }

    /// Whether the compositor has confirmed that reserved chords now reach
    /// this window.
    public var isActive: Bool { isInhibitActive }

    public func start(_ handler: @escaping (KeyChord, Bool) -> Bool, onDegraded: @escaping (String) -> Void) throws {
        self.handler = handler
        self.onDegraded = onDegraded
        // A fresh inhibitor is not active until the compositor says so, and a
        // second `start()` while one from a previous session is still held
        // must not let a chord claim on the strength of that old inhibitor's
        // `active` event.
        isInhibitActive = false
        destroyInhibitorIfHeld()
        hasInhibitor = inhibiting.requestShortcutInhibitor()
    }

    public func stop() {
        handler = nil
        onDegraded = nil
        isInhibitActive = false
        destroyInhibitorIfHeld()
    }

    /// `zwp_keyboard_shortcuts_inhibitor_v1.active`.
    public func inhibitorBecameActive() {
        isInhibitActive = true
    }

    /// `zwp_keyboard_shortcuts_inhibitor_v1.inactive`: the compositor is
    /// taking its own chords again, which it also does whenever this surface
    /// loses the keyboard.
    ///
    /// The inhibitor is destroyed here rather than kept for the compositor to
    /// re-activate, because a surface may hold only one at a time and the
    /// retry below has to be free to ask for a fresh one.
    public func inhibitorBecameInactive() {
        isInhibitActive = false
        destroyInhibitorIfHeld()
        onDegraded?(Self.compositorKeepsShortcutsNotice)
    }

    /// The keyboard entered this surface. An inhibitor the compositor never
    /// granted, or one it dropped, is asked for again here: the compositor
    /// answers focus, so the moment focus comes back is the moment worth
    /// asking again.
    public func keyboardDidEnter() {
        guard handler != nil, !hasInhibitor else { return }
        hasInhibitor = inhibiting.requestShortcutInhibitor()
    }

    /// Whether this chord was taken for the host, and so must not go on to
    /// ordinary routing. False whenever the compositor is still keeping its
    /// own shortcuts: a chord that reached this window anyway is not one the
    /// forwarder was promised, and the window's own key path is a better
    /// answer than claiming it here.
    public func claim(chord: KeyChord, isDown: Bool) -> Bool {
        guard isInhibitActive, let handler else { return false }
        return handler(chord, isDown)
    }

    private func destroyInhibitorIfHeld() {
        guard hasInhibitor else { return }
        hasInhibitor = false
        inhibiting.destroyShortcutInhibitor()
    }
}
