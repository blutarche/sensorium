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
        keyboard.key(evdev: 42, isDown: true) == .modifiersChanged(keyCode: 56, modifiers: [.shift], capsLock: false),
        "Left Shift going down reports the Shift modifier as held"
    )
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [.shift], capsLock: false),
        "A going down while Shift is held is the A key with Shift"
    )
    expect(
        keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: [.shift], capsLock: false),
        "A coming up while Shift is held is the A key with Shift"
    )
    expect(
        keyboard.key(evdev: 42, isDown: false) == .modifiersChanged(keyCode: 56, modifiers: [], capsLock: false),
        "Left Shift coming up reports nothing held"
    )

    expect(
        keyboard.key(evdev: 125, isDown: true) == .modifiersChanged(keyCode: 55, modifiers: [.command], capsLock: false),
        "the Super key is Command, by the position it sits in"
    )
    expect(
        keyboard.key(evdev: 56, isDown: true) == .modifiersChanged(keyCode: 58, modifiers: [.command, .option], capsLock: false),
        "the Alt key is Option, and joins the modifiers already held"
    )
    expect(
        keyboard.key(evdev: 56, isDown: false) == .modifiersChanged(keyCode: 58, modifiers: [.command], capsLock: false),
        "Alt coming up leaves Command held"
    )
    expect(
        keyboard.key(evdev: 125, isDown: false) == .modifiersChanged(keyCode: 55, modifiers: [], capsLock: false),
        "Super coming up leaves nothing held"
    )

    expect(keyboard.key(evdev: 58, isDown: true) == nil, "Caps Lock going down is never forwarded")
    expect(keyboard.key(evdev: 58, isDown: false) == nil, "Caps Lock coming up is never forwarded")
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [], capsLock: true),
        "a key typed with Caps Lock on says so, and carries no modifier bit for it"
    )
    expect(
        keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: [], capsLock: true),
        "and comes up the same way"
    )
    expect(keyboard.key(evdev: 58, isDown: true) == nil, "Caps Lock going down again is still never forwarded")
    expect(keyboard.key(evdev: 58, isDown: false) == nil, "Caps Lock coming up again is still never forwarded")
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [], capsLock: false),
        "a key typed once Caps Lock is off again says it is off"
    )
    expect(
        keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: [], capsLock: false),
        "and comes up the same way"
    )
    expect(keyboard.key(evdev: 69, isDown: true) == nil, "Num Lock is never forwarded either")
    expect(keyboard.key(evdev: 69, isDown: false) == nil, "Num Lock coming up is never forwarded either")

    expect(keyboard.key(evdev: 0x2FF, isDown: true) == nil, "a key with no position on a Mac keyboard is dropped")
    expect(keyboard.key(evdev: 0x2FF, isDown: false) == nil, "and its release is dropped too")

    // The way out of a fullscreen viewer, typed on a PC keyboard: Ctrl, Alt,
    // Super and Escape. It has to arrive as exactly the chord the shortcut
    // catalog reserves, or nothing would release the person's own machine.
    expect(keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control], capsLock: false), "Ctrl is Control")
    expect(keyboard.key(evdev: 56, isDown: true) != nil, "Alt joins the chord")
    expect(keyboard.key(evdev: 125, isDown: true) != nil, "Super joins the chord")
    guard case let .key(escapeCode, _, escapeModifiers, _)? = keyboard.key(evdev: 1, isDown: true) else {
        expect(false, "Escape typed with Ctrl, Alt and Super is a key event")
        return
    }
    expect(
        KeyChord(keyCode: escapeCode, modifiers: escapeModifiers) == SystemShortcutCatalog.escapeGesture,
        "Ctrl-Alt-Super-Escape on a PC keyboard is the escape gesture the catalog reserves"
    )

    keyboard.focusLeft()
    expect(
        keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control], capsLock: false),
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
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [.control], capsLock: false),
        "a key pressed while Control arrived only through a modifiers event still carries it"
    )

    expect(
        keyboard.key(evdev: 29, isDown: false) == nil,
        "Control's physical release is dropped: this keyboard never saw a key event bring it down, only a modifiers event"
    )

    expect(
        keyboard.key(evdev: 29, isDown: true) == .modifiersChanged(keyCode: 59, modifiers: [.control], capsLock: false),
        "Control's next physical press is forwarded normally, now that a real key event started holding it"
    )

    // Bit 1 is Lock. Caps Lock turned on at another window arrives only
    // this way, and the next key here says it is on.
    keyboard.reconcileModifiers(depressed: 0, latched: 0, locked: 1 << 1, group: 0)
    expect(
        keyboard.key(evdev: 30, isDown: false) == .key(keyCode: 0, isDown: false, modifiers: [], capsLock: true),
        "a key after a modifiers event that locked Caps Lock says Caps Lock is on"
    )
    keyboard.reconcileModifiers(depressed: 1 << 1, latched: 0, locked: 0, group: 0)
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [], capsLock: false),
        "Lock only held down, not locked, is not Caps Lock on"
    )

    print("PASS: every wl_keyboard.modifiers event updates this keyboard's xkb state, and a modifier held only through one is still not forwarded until a real key event holds it")
}

/// Right Alt is Option on every layout. On German, French, British and Nordic
/// layouts it is the level-3 shift (AltGr), which xkb does not report as Mod1,
/// so Option has to follow the physical Alt keys and not the layout's modifier
/// assignment: the far machine applies its own layout to the key position.
@MainActor
func testWaylandKeyboardStateAltGrOptionTests() {
    let variable = "XKB_DEFAULT_LAYOUT"
    let previous = getenv(variable).map { String(cString: $0) }
    setenv(variable, "de", 1)
    let keyboard = WaylandKeyboardState()
    if let previous {
        setenv(variable, previous, 1)
    } else {
        unsetenv(variable)
    }
    guard let keyboard else {
        expect(false, "a keyboard state could be built from the German keymap")
        return
    }

    expect(
        keyboard.key(evdev: 100, isDown: true) == .modifiersChanged(keyCode: 61, modifiers: [.option], capsLock: false),
        "Right Alt carries Option on a layout where it is the level-3 shift"
    )
    expect(
        keyboard.key(evdev: 30, isDown: true) == .key(keyCode: 0, isDown: true, modifiers: [.option], capsLock: false),
        "a key typed while Right Alt is held carries Option"
    )
    expect(
        keyboard.key(evdev: 100, isDown: false) == .modifiersChanged(keyCode: 61, modifiers: [], capsLock: false),
        "Right Alt coming up releases Option"
    )
    expect(
        keyboard.key(evdev: 56, isDown: true) == .modifiersChanged(keyCode: 58, modifiers: [.option], capsLock: false),
        "Left Alt is Option as before"
    )
    expect(
        keyboard.key(evdev: 100, isDown: true) == .modifiersChanged(keyCode: 61, modifiers: [.option], capsLock: false),
        "Right Alt with Left Alt held still reports Option"
    )
    expect(
        keyboard.key(evdev: 56, isDown: false) == .modifiersChanged(keyCode: 58, modifiers: [.option], capsLock: false),
        "letting go of Left Alt keeps Option while Right Alt is held"
    )
    expect(
        keyboard.key(evdev: 100, isDown: false) == .modifiersChanged(keyCode: 61, modifiers: [], capsLock: false),
        "and letting go of Right Alt releases it"
    )

    print("PASS: Right Alt is Option on a layout where it is the level-3 shift")
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

@MainActor
func testWaylandKeyboardStateAltGrOptionTests() {}
#endif
