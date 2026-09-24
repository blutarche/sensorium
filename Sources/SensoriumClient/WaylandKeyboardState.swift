#if canImport(CXkbcommon)
import CXkbcommon
import Foundation
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

/// The keyboard as a Wayland compositor describes it: a keymap the
/// compositor hands over, the modifier state that goes with it, and the
/// physical key codes it reports.
///
/// Wayland delivers evdev key codes and leaves interpretation to the client,
/// so this is where a key press becomes something the wire can carry. Two
/// separate translations happen here and must not be confused: the physical
/// key becomes a Carbon virtual key code through `EvdevKeycodeTable`, by
/// position and never by legend, while xkb is used only to know which
/// modifiers are held. The layout the person at the viewer chose is
/// deliberately not applied -- the host applies its own.
///
/// Both key events and `wl_keyboard.modifiers` events keep this keyboard's
/// xkb state current: `xkb_state_update_key` advances it from a key press or
/// release, and `reconcileModifiers(...)` applies every `modifiers` event
/// the compositor sends, including group and lock changes a key event alone
/// would not carry.
@MainActor
public final class WaylandKeyboardState: WaylandKeyTranslating {
    /// The xkb objects this keyboard is made of, held together so they are
    /// released together and in the order xkb requires. Reached only from
    /// the event loop's own thread, which is where every keyboard event
    /// arrives and where this object is built and dropped.
    private final class Handles: @unchecked Sendable {
        let context: OpaquePointer
        let keymap: OpaquePointer
        var state: OpaquePointer

        init(context: OpaquePointer, keymap: OpaquePointer, state: OpaquePointer) {
            self.context = context
            self.keymap = keymap
            self.state = state
        }

        deinit {
            xkb_state_unref(state)
            xkb_keymap_unref(keymap)
            xkb_context_unref(context)
        }
    }

    private let handles: Handles
    /// Which modifier keys are believed held, so one physical transition is
    /// reported once. `CanvasSurfaceEventRouter` derives down from up by
    /// toggling, and a duplicate would invert it for every later press.
    private var heldModifierCodes: Set<UInt32> = []
    /// Said once per key code for the life of the process: a keyboard with a
    /// key this table has no position for would otherwise report it on every
    /// press and every release.
    private static var reportedUnmappedCodes: Set<UInt32> = []

    /// The keys whose state belongs to the machine the person is sitting at
    /// and never travels: the two locks, and the Fn key, which has no evdev
    /// code an ordinary keyboard even reports. Forwarding a lock would fight
    /// the host's own lock state, since each machine keeps one of its own.
    private static let neverForwarded: Set<UInt32> = [
        58,  // KEY_CAPSLOCK
        69,  // KEY_NUMLOCK
        464  // KEY_FN
    ]

    /// This machine's own default keymap, for a keyboard whose compositor has
    /// not sent one yet or sent one that would not compile.
    public convenience init?() {
        guard let context = xkb_context_new(XKB_CONTEXT_NO_FLAGS),
              let keymap = xkb_keymap_new_from_names(context, nil, XKB_KEYMAP_COMPILE_NO_FLAGS) else {
            return nil
        }
        self.init(context: context, keymap: keymap)
    }

    /// The compositor's own keymap, from the descriptor `wl_keyboard.keymap`
    /// carried. The descriptor is this client's to close, and is closed here
    /// whether or not the keymap compiled.
    public convenience init?(keymapFileDescriptor descriptor: Int32, size: Int) {
        defer { close(descriptor) }
        guard size > 0 else { return nil }
        // The compositor's own claim about `size` is not trusted: mapping
        // more than the file actually holds would read past its end, into
        // whatever else happens to be mapped after it.
        var status = stat()
        guard fstat(descriptor, &status) == 0, Int(status.st_size) >= size else {
            print("Sensorium: this compositor's keymap claimed a size larger than the file it sent, so it was not read")
            return nil
        }
        guard let context = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
        // Privately: the compositor may hand the same file to every client,
        // and a shared mapping would let one client's write reach the rest.
        let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else {
            xkb_context_unref(context)
            return nil
        }
        defer { munmap(mapped, size) }
        // The real length is passed rather than relying on a NUL terminator
        // the compositor never promised the mapping ends with.
        guard let keymap = xkb_keymap_new_from_buffer(
            context,
            mapped.assumingMemoryBound(to: CChar.self),
            size,
            XKB_KEYMAP_FORMAT_TEXT_V1,
            XKB_KEYMAP_COMPILE_NO_FLAGS
        ) else {
            xkb_context_unref(context)
            return nil
        }
        self.init(context: context, keymap: keymap)
    }

    private init?(context: OpaquePointer, keymap: OpaquePointer) {
        guard let state = xkb_state_new(keymap) else {
            xkb_keymap_unref(keymap)
            xkb_context_unref(context)
            return nil
        }
        handles = Handles(context: context, keymap: keymap, state: state)
    }

    /// The four modifiers the wire carries, as this keyboard's state has
    /// them now. Caps Lock, Num Lock and Fn are not among them: the protocol
    /// has no flag for any of the three, and the far machine keeps its own.
    public var modifiers: CanvasModifierFlags {
        var flags: CanvasModifierFlags = []
        if isActive(XKB_MOD_NAME_SHIFT) { flags.insert(.shift) }
        if isActive(XKB_MOD_NAME_CTRL) { flags.insert(.control) }
        if isActive(XKB_MOD_NAME_ALT) { flags.insert(.option) }
        if isActive(XKB_MOD_NAME_LOGO) { flags.insert(.command) }
        return flags
    }

    /// Every `wl_keyboard.modifiers` event, applied through
    /// `xkb_state_update_mask`, which sets this keyboard's absolute state
    /// rather than adjusting it, so applying it after every key does not
    /// double-count anything `xkb_state_update_key` already recorded.
    /// Modifiers already held when the keyboard enters this surface are
    /// still not forwarded as a key event of their own: the macOS viewer
    /// receives no `flagsChanged` for those either, since only a transition
    /// carries one.
    public func reconcileModifiers(depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32) {
        xkb_state_update_mask(handles.state, depressed, latched, locked, 0, 0, group)
    }

    /// One `wl_keyboard.key`, as the event the canvas should be told about,
    /// or nil for a key that is never forwarded.
    public func key(evdev code: UInt32, isDown: Bool) -> CanvasSurfaceEvent? {
        // xkb counts the same physical keys eight higher than evdev does.
        xkb_state_update_key(handles.state, code + 8, isDown ? XKB_KEY_DOWN : XKB_KEY_UP)
        guard !Self.neverForwarded.contains(code) else { return nil }
        guard let keyCode = EvdevKeycodeTable.macOSKeyCode(forEvdev: code) else {
            reportUnmapped(code)
            return nil
        }
        guard EvdevKeycodeTable.isModifierKey(evdev: code) else {
            return .key(keyCode: keyCode, isDown: isDown, modifiers: modifiers)
        }
        guard isDown != heldModifierCodes.contains(code) else { return nil }
        if isDown {
            heldModifierCodes.insert(code)
        } else {
            heldModifierCodes.remove(code)
        }
        return .modifiersChanged(keyCode: keyCode, modifiers: modifiers)
    }

    /// The keyboard left this surface. Nothing is held any more as far as
    /// this window is concerned: a key still down when the keyboard left is
    /// released somewhere else, and no release for it will ever arrive here.
    /// The canvas is told separately, through `focusLost`, which releases
    /// what the host still believes is down.
    public func focusLeft() {
        heldModifierCodes.removeAll()
        guard let fresh = xkb_state_new(handles.keymap) else { return }
        xkb_state_unref(handles.state)
        handles.state = fresh
    }

    private func isActive(_ name: String) -> Bool {
        name.withCString { modifier in
            xkb_state_mod_name_is_active(
                handles.state,
                modifier,
                xkb_state_component(
                    rawValue: XKB_STATE_MODS_DEPRESSED.rawValue
                        | XKB_STATE_MODS_LATCHED.rawValue
                        | XKB_STATE_MODS_LOCKED.rawValue
                )
            ) > 0
        }
    }

    private func reportUnmapped(_ code: UInt32) {
        guard Self.reportedUnmappedCodes.insert(code).inserted else { return }
        print("Sensorium: this keyboard's key \(code) has no position on a Mac keyboard, so it is not forwarded")
    }
}
#endif
