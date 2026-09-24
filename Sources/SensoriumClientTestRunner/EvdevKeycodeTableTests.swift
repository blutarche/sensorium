import Foundation
import SensoriumClient
import SensoriumCore

/// One evdev `KEY_*` code and the Carbon virtual keycode it must translate
/// to, named the way the Linux header names it so a mismatch is readable.
private struct EvdevCase {
    let evdev: UInt32
    let carbon: UInt16?
    let label: String
}

/// The full physical-position table, covering every category
/// `EvdevKeycodeTable` documents: letters, digits, the punctuation row,
/// editing and whitespace keys, function keys, modifiers, the keypad, the
/// ISO extra key and the Menu key.
private let evdevCases: [EvdevCase] = [
    // Letters.
    EvdevCase(evdev: 30, carbon: 0, label: "KEY_A"),
    EvdevCase(evdev: 48, carbon: 11, label: "KEY_B"),
    EvdevCase(evdev: 46, carbon: 8, label: "KEY_C"),
    EvdevCase(evdev: 32, carbon: 2, label: "KEY_D"),
    EvdevCase(evdev: 18, carbon: 14, label: "KEY_E"),
    EvdevCase(evdev: 33, carbon: 3, label: "KEY_F"),
    EvdevCase(evdev: 34, carbon: 5, label: "KEY_G"),
    EvdevCase(evdev: 35, carbon: 4, label: "KEY_H"),
    EvdevCase(evdev: 23, carbon: 34, label: "KEY_I"),
    EvdevCase(evdev: 36, carbon: 38, label: "KEY_J"),
    EvdevCase(evdev: 37, carbon: 40, label: "KEY_K"),
    EvdevCase(evdev: 38, carbon: 37, label: "KEY_L"),
    EvdevCase(evdev: 50, carbon: 46, label: "KEY_M"),
    EvdevCase(evdev: 49, carbon: 45, label: "KEY_N"),
    EvdevCase(evdev: 24, carbon: 31, label: "KEY_O"),
    EvdevCase(evdev: 25, carbon: 35, label: "KEY_P"),
    EvdevCase(evdev: 16, carbon: 12, label: "KEY_Q"),
    EvdevCase(evdev: 19, carbon: 15, label: "KEY_R"),
    EvdevCase(evdev: 31, carbon: 1, label: "KEY_S"),
    EvdevCase(evdev: 20, carbon: 17, label: "KEY_T"),
    EvdevCase(evdev: 22, carbon: 32, label: "KEY_U"),
    EvdevCase(evdev: 47, carbon: 9, label: "KEY_V"),
    EvdevCase(evdev: 17, carbon: 13, label: "KEY_W"),
    EvdevCase(evdev: 45, carbon: 7, label: "KEY_X"),
    EvdevCase(evdev: 21, carbon: 16, label: "KEY_Y"),
    EvdevCase(evdev: 44, carbon: 6, label: "KEY_Z"),

    // Digit row.
    EvdevCase(evdev: 2, carbon: 18, label: "KEY_1"),
    EvdevCase(evdev: 3, carbon: 19, label: "KEY_2"),
    EvdevCase(evdev: 4, carbon: 20, label: "KEY_3"),
    EvdevCase(evdev: 5, carbon: 21, label: "KEY_4"),
    EvdevCase(evdev: 6, carbon: 23, label: "KEY_5"),
    EvdevCase(evdev: 7, carbon: 22, label: "KEY_6"),
    EvdevCase(evdev: 8, carbon: 26, label: "KEY_7"),
    EvdevCase(evdev: 9, carbon: 28, label: "KEY_8"),
    EvdevCase(evdev: 10, carbon: 25, label: "KEY_9"),
    EvdevCase(evdev: 11, carbon: 29, label: "KEY_0"),

    // Punctuation row, plus the ISO extra key.
    EvdevCase(evdev: 12, carbon: 27, label: "KEY_MINUS"),
    EvdevCase(evdev: 13, carbon: 24, label: "KEY_EQUAL"),
    EvdevCase(evdev: 26, carbon: 33, label: "KEY_LEFTBRACE"),
    EvdevCase(evdev: 27, carbon: 30, label: "KEY_RIGHTBRACE"),
    EvdevCase(evdev: 39, carbon: 41, label: "KEY_SEMICOLON"),
    EvdevCase(evdev: 40, carbon: 39, label: "KEY_APOSTROPHE"),
    EvdevCase(evdev: 41, carbon: 50, label: "KEY_GRAVE"),
    EvdevCase(evdev: 43, carbon: 42, label: "KEY_BACKSLASH"),
    EvdevCase(evdev: 51, carbon: 43, label: "KEY_COMMA"),
    EvdevCase(evdev: 52, carbon: 47, label: "KEY_DOT"),
    EvdevCase(evdev: 53, carbon: 44, label: "KEY_SLASH"),
    EvdevCase(evdev: 86, carbon: 10, label: "KEY_102ND"),

    // Editing and whitespace.
    EvdevCase(evdev: 28, carbon: 36, label: "KEY_ENTER"),
    EvdevCase(evdev: 15, carbon: 48, label: "KEY_TAB"),
    EvdevCase(evdev: 57, carbon: 49, label: "KEY_SPACE"),
    EvdevCase(evdev: 14, carbon: 51, label: "KEY_BACKSPACE"),
    EvdevCase(evdev: 1, carbon: 53, label: "KEY_ESC"),
    EvdevCase(evdev: 111, carbon: 117, label: "KEY_DELETE"),
    EvdevCase(evdev: 102, carbon: 115, label: "KEY_HOME"),
    EvdevCase(evdev: 107, carbon: 119, label: "KEY_END"),
    EvdevCase(evdev: 104, carbon: 116, label: "KEY_PAGEUP"),
    EvdevCase(evdev: 109, carbon: 121, label: "KEY_PAGEDOWN"),
    EvdevCase(evdev: 103, carbon: 126, label: "KEY_UP"),
    EvdevCase(evdev: 108, carbon: 125, label: "KEY_DOWN"),
    EvdevCase(evdev: 105, carbon: 123, label: "KEY_LEFT"),
    EvdevCase(evdev: 106, carbon: 124, label: "KEY_RIGHT"),
    // No Mac keyboard has an Insert key, and Carbon has no constant for
    // one: nil is the honest answer, not a guess at a target.
    EvdevCase(evdev: 110, carbon: nil, label: "KEY_INSERT"),

    // Function keys, including Print Screen/Scroll Lock/Pause mapped onto
    // F13-F15, exactly where Apple's own keyboard-layout handling for a PC
    // keyboard already puts them.
    EvdevCase(evdev: 59, carbon: 122, label: "KEY_F1"),
    EvdevCase(evdev: 60, carbon: 120, label: "KEY_F2"),
    EvdevCase(evdev: 61, carbon: 99, label: "KEY_F3"),
    EvdevCase(evdev: 62, carbon: 118, label: "KEY_F4"),
    EvdevCase(evdev: 63, carbon: 96, label: "KEY_F5"),
    EvdevCase(evdev: 64, carbon: 97, label: "KEY_F6"),
    EvdevCase(evdev: 65, carbon: 98, label: "KEY_F7"),
    EvdevCase(evdev: 66, carbon: 100, label: "KEY_F8"),
    EvdevCase(evdev: 67, carbon: 101, label: "KEY_F9"),
    EvdevCase(evdev: 68, carbon: 109, label: "KEY_F10"),
    EvdevCase(evdev: 87, carbon: 103, label: "KEY_F11"),
    EvdevCase(evdev: 88, carbon: 111, label: "KEY_F12"),
    EvdevCase(evdev: 99, carbon: 105, label: "KEY_SYSRQ (Print Screen)"),
    EvdevCase(evdev: 70, carbon: 107, label: "KEY_SCROLLLOCK"),
    EvdevCase(evdev: 119, carbon: 113, label: "KEY_PAUSE"),
    EvdevCase(evdev: 183, carbon: 105, label: "KEY_F13"),
    EvdevCase(evdev: 184, carbon: 107, label: "KEY_F14"),
    EvdevCase(evdev: 185, carbon: 113, label: "KEY_F15"),
    EvdevCase(evdev: 186, carbon: 106, label: "KEY_F16"),
    EvdevCase(evdev: 187, carbon: 64, label: "KEY_F17"),
    EvdevCase(evdev: 188, carbon: 79, label: "KEY_F18"),
    EvdevCase(evdev: 189, carbon: 80, label: "KEY_F19"),
    EvdevCase(evdev: 190, carbon: 90, label: "KEY_F20"),

    // Modifiers, including AltGr as an ordinary Right Alt press: a physical
    // AltGr key already reports KEY_RIGHTALT, so there is nothing separate
    // to translate.
    EvdevCase(evdev: 42, carbon: 56, label: "KEY_LEFTSHIFT"),
    EvdevCase(evdev: 54, carbon: 60, label: "KEY_RIGHTSHIFT"),
    EvdevCase(evdev: 29, carbon: 59, label: "KEY_LEFTCTRL"),
    EvdevCase(evdev: 97, carbon: 62, label: "KEY_RIGHTCTRL"),
    EvdevCase(evdev: 56, carbon: 58, label: "KEY_LEFTALT"),
    EvdevCase(evdev: 100, carbon: 61, label: "KEY_RIGHTALT (AltGr)"),
    EvdevCase(evdev: 125, carbon: 55, label: "KEY_LEFTMETA"),
    EvdevCase(evdev: 126, carbon: 54, label: "KEY_RIGHTMETA"),
    EvdevCase(evdev: 58, carbon: 57, label: "KEY_CAPSLOCK"),

    // Keypad.
    EvdevCase(evdev: 82, carbon: 82, label: "KEY_KP0"),
    EvdevCase(evdev: 79, carbon: 83, label: "KEY_KP1"),
    EvdevCase(evdev: 80, carbon: 84, label: "KEY_KP2"),
    EvdevCase(evdev: 81, carbon: 85, label: "KEY_KP3"),
    EvdevCase(evdev: 75, carbon: 86, label: "KEY_KP4"),
    EvdevCase(evdev: 76, carbon: 87, label: "KEY_KP5"),
    EvdevCase(evdev: 77, carbon: 88, label: "KEY_KP6"),
    EvdevCase(evdev: 71, carbon: 89, label: "KEY_KP7"),
    EvdevCase(evdev: 72, carbon: 91, label: "KEY_KP8"),
    EvdevCase(evdev: 73, carbon: 92, label: "KEY_KP9"),
    EvdevCase(evdev: 83, carbon: 65, label: "KEY_KPDOT"),
    EvdevCase(evdev: 55, carbon: 67, label: "KEY_KPASTERISK"),
    EvdevCase(evdev: 78, carbon: 69, label: "KEY_KPPLUS"),
    EvdevCase(evdev: 74, carbon: 78, label: "KEY_KPMINUS"),
    EvdevCase(evdev: 98, carbon: 75, label: "KEY_KPSLASH"),
    EvdevCase(evdev: 96, carbon: 76, label: "KEY_KPENTER"),
    EvdevCase(evdev: 117, carbon: 81, label: "KEY_KPEQUAL"),
    EvdevCase(evdev: 69, carbon: 71, label: "KEY_NUMLOCK"),

    // The physical Menu key: a PC keyboard reports it as KEY_COMPOSE.
    EvdevCase(evdev: 127, carbon: 110, label: "KEY_COMPOSE (Menu)")
]

/// Every evdev code `EvdevCase` names must translate to the Carbon code it
/// names, and a code the table has no entry for returns nil rather than
/// trapping.
func testEvdevKeycodeTableTests() {
    for testCase in evdevCases {
        expect(
            EvdevKeycodeTable.macOSKeyCode(forEvdev: testCase.evdev) == testCase.carbon,
            "\(testCase.label) (evdev \(testCase.evdev)) did not translate to Carbon \(String(describing: testCase.carbon))"
        )
    }

    expect(
        EvdevKeycodeTable.macOSKeyCode(forEvdev: 999) == nil,
        "an evdev code above the table returned something instead of nil"
    )
    expect(
        EvdevKeycodeTable.macOSKeyCode(forEvdev: UInt32.max) == nil,
        "the largest possible evdev code did not trap and returned nil"
    )

    // `isModifierKey` is true for exactly the four modifier pairs (eight
    // codes) and false for every other evdev code, Caps Lock included: Caps
    // Lock is not one of the four modifiers `CanvasModifierFlags` carries.
    let modifierEvdevCodes: Set<UInt32> = [42, 54, 29, 97, 56, 100, 125, 126]
    for code in modifierEvdevCodes {
        expect(EvdevKeycodeTable.isModifierKey(evdev: code), "evdev \(code) is one of the eight modifier codes")
    }
    let nonModifierEvdevCodes: [UInt32] = [30, 2, 58, 28, 999]
    for code in nonModifierEvdevCodes {
        expect(!EvdevKeycodeTable.isModifierKey(evdev: code), "evdev \(code) is not a modifier code")
    }

    // Cross-check against the two live Carbon keycode lists this table
    // exists to serve: every code `SystemShortcutCatalog.all`'s chords use,
    // and every code a shortcut-strip chord actually sends, must be
    // reachable from the corresponding evdev code above. The Launchpad key
    // (Carbon 131, a macOS-only value with no Carbon constant of its own)
    // has no evdev counterpart on any physical keyboard and is intentionally
    // excluded: there is no PC key that sends it.
    let catalogCarbonCodes = Set(SystemShortcutCatalog.all.map { $0.chord.keyCode })
    let reachableCarbonCodes = Set(evdevCases.compactMap { $0.carbon })
    expect(
        catalogCarbonCodes.isSubset(of: reachableCarbonCodes),
        "every SystemShortcutCatalog chord's keyCode must be reachable from some evdev code"
    )

    let stripCarbonCodes = Set(
        ShortcutStripAction.allCases.flatMap { action in
            action.events().compactMap { event -> UInt16? in
                guard case let .key(keyCode, _, _) = event else { return nil }
                return keyCode
            }
        }
    )
    let launchpadCarbonCode: UInt16 = 131
    expect(
        stripCarbonCodes.subtracting([launchpadCarbonCode]).isSubset(of: reachableCarbonCodes),
        "every shortcut-strip chord's keyCode, other than the Mac-only Launchpad key, must be reachable from some evdev code"
    )

    print("PASS: every evdev key the table names translates to its Carbon virtual keycode, isModifierKey holds for exactly the eight modifier codes, and every live shortcut chord's keyCode is reachable from it")
}
