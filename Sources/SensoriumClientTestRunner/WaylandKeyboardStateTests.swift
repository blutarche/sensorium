#if canImport(CGLib)
import Foundation
import SensoriumClient
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

/// What a Wayland keyboard's evdev codes become on the wire, against this
/// machine's own default keymap. The physical position is what travels: the
/// PC keyboard's Super and Alt keys arrive at the host as Command and Option
/// because that is where those keys sit, not because of anything printed on
/// them.
@MainActor
func testWaylandKeyboardStateTests() {
    guard let keyboard = WaylandKeyboardState() else {
        expect(false, "a keyboard state could be built from this machine's default keymap")
        return
    }

    expect(
        keyboard.key(evdev: 42, isDown: true) == .modifiersChanged(keyCode: 56, modifiers: [.shift]),
        "Left Shift going down reports the Shift modifier as held"
    )
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [.shift]),
        "A going down while Shift is held is the A key with Shift"
    )
    expect(
        keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: [.shift]),
        "A coming up while Shift is held is the A key with Shift"
    )
    expect(
        keyboard.key(evdev: 42, isDown: false) == .modifiersChanged(keyCode: 56, modifiers: []),
        "Left Shift coming up reports nothing held"
    )

    expect(
        keyboard.key(evdev: 125, isDown: true) == .modifiersChanged(keyCode: 55, modifiers: [.command]),
        "the Super key is Command, by the position it sits in"
    )
    expect(
        keyboard.key(evdev: 56, isDown: true) == .modifiersChanged(keyCode: 58, modifiers: [.command, .option]),
        "the Alt key is Option, and joins the modifiers already held"
    )
    expect(
        keyboard.key(evdev: 56, isDown: false) == .modifiersChanged(keyCode: 58, modifiers: [.command]),
        "Alt coming up leaves Command held"
    )
    expect(
        keyboard.key(evdev: 125, isDown: false) == .modifiersChanged(keyCode: 55, modifiers: []),
        "Super coming up leaves nothing held"
    )

    expect(keyboard.key(evdev: 58, isDown: true) == nil, "Caps Lock going down is never forwarded")
    expect(keyboard.key(evdev: 58, isDown: false) == nil, "Caps Lock coming up is never forwarded")
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: []),
        "a key typed with Caps Lock on carries no modifier the wire knows about"
    )
    expect(keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: []), "and comes up the same way")
    expect(keyboard.key(evdev: 58, isDown: true) == nil, "Caps Lock going down again is still never forwarded")
    expect(keyboard.key(evdev: 58, isDown: false) == nil, "Caps Lock coming up again is still never forwarded")
    expect(keyboard.key(evdev: 69, isDown: true) == nil, "Num Lock is never forwarded either")
    expect(keyboard.key(evdev: 69, isDown: false) == nil, "Num Lock coming up is never forwarded either")

    expect(keyboard.key(evdev: 0x2FF, isDown: true) == nil, "a key with no position on a Mac keyboard is dropped")
    expect(keyboard.key(evdev: 0x2FF, isDown: false) == nil, "and its release is dropped too")

    // The way out of a fullscreen viewer, typed on a PC keyboard: Ctrl, Alt,
    // Super and Escape. It has to arrive as exactly the chord the shortcut
    // catalog reserves, or nothing would release the person's own machine.
    expect(keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control]), "Ctrl is Control")
    expect(keyboard.key(evdev: 56, isDown: true) != nil, "Alt joins the chord")
    expect(keyboard.key(evdev: 125, isDown: true) != nil, "Super joins the chord")
    guard case let .key(escapeCode, _, escapeModifiers)? = keyboard.key(evdev: 1, isDown: true) else {
        expect(false, "Escape typed with Ctrl, Alt and Super is a key event")
        return
    }
    expect(
        KeyChord(keyCode: escapeCode, modifiers: escapeModifiers) == SystemShortcutCatalog.escapeGesture,
        "Ctrl-Alt-Super-Escape on a PC keyboard is the escape gesture the catalog reserves"
    )

    keyboard.focusLeft()
    expect(
        keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control]),
        "a keyboard that left and came back reports the next modifier press as a press"
    )

    print("PASS: a Wayland keyboard's evdev codes become the wire's keys and modifiers by physical position")
}

/// Regression test: every `wl_keyboard.modifiers` event is applied, not only
/// the first one after `enter`, so a group or lock change later in a session
/// is not silently dropped. A modifier already held when it arrives is still
/// not forwarded as a key event of its own -- only the physical release and
/// the next physical press are.
@MainActor
func testWaylandKeyboardStateModifiersEventTests() {
    guard let keyboard = WaylandKeyboardState() else {
        expect(false, "a keyboard state could be built from this machine's default keymap")
        return
    }

    // Bit 2 is Control in the default xkb keymap's modifier order (Shift,
    // Lock, Control, ...). Checked explicitly so a wrong bit index fails
    // loudly here rather than making the rest of this case vacuous.
    keyboard.reconcileModifiers(depressed: 1 << 2, latched: 0, locked: 0, group: 0)
    expect(keyboard.modifiers == [.control], "reconcileModifiers applied a depressed Control bit to this keyboard's state")

    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [.control]),
        "a key pressed while Control arrived only through a modifiers event still carries it"
    )

    expect(
        keyboard.key(evdev: 29, isDown: false) == nil,
        "Control's physical release is dropped: this keyboard never saw a key event bring it down, only a modifiers event"
    )

    expect(
        keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control]),
        "Control's next physical press is forwarded normally, now that a real key event started holding it"
    )

    print("PASS: every wl_keyboard.modifiers event updates this keyboard's xkb state, and a modifier held only through one is still not forwarded until a real key event holds it")
}

/// Regression test: a compositor's claimed keymap size must never be trusted
/// past what the file it sent actually holds. A descriptor whose real
/// content is shorter than the claimed size is refused rather than mapped,
/// and refusing it must not trap.
@MainActor
func testWaylandKeyboardStateTruncatedKeymapSizeTests() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-truncated-keymap-\(UUID().uuidString)")
    let realContent = "short"
    _ = FileManager.default.createFile(atPath: path.path, contents: Data(realContent.utf8))
    defer { try? FileManager.default.removeItem(at: path) }

    let descriptor = open(path.path, O_RDONLY)
    expect(descriptor >= 0, "the temp file for the truncated-keymap regression could be opened")
    guard descriptor >= 0 else { return }

    let claimedSize = realContent.utf8.count + 4096
    let keyboard = WaylandKeyboardState(keymapFileDescriptor: descriptor, size: claimedSize)
    expect(keyboard == nil, "a keymap size claim larger than the file's real length is refused rather than mapped")

    print("PASS: a compositor's keymap size claim larger than the file it sent is refused without trapping")
}
#else
/// Nothing to check where there is no Wayland keyboard: the macOS viewer's
/// keys arrive through AppKit.
@MainActor
func testWaylandKeyboardStateTests() {}
@MainActor
func testWaylandKeyboardStateModifiersEventTests() {}
@MainActor
func testWaylandKeyboardStateTruncatedKeymapSizeTests() {}
#endif
