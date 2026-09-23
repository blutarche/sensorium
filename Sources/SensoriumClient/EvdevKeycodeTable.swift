import Foundation

/// Translates the physical-position keycode space a Linux viewer receives
/// into the Carbon virtual keycode space the wire protocol already speaks
/// (see `docs/protocol.md`, "Input events"). The host feeds `key.keyCode`
/// straight into `CGEvent(keyboardEventSource:virtualKey:...)`, so a Linux
/// viewer must translate before it ever calls the client's input path.
///
/// The evdev codes are the `KEY_*` values from `input-event-codes.h`, which
/// is exactly what `wl_keyboard.key` delivers on the wire; an xkb keycode,
/// where one is needed instead, is always the evdev code plus 8.
///
/// Every mapping is by physical position (the US ANSI/ISO layout position of
/// the key), never by the legend printed on it: the host applies its own
/// keyboard layout to the virtual keycode it receives, so a viewer sending
/// the code for the key it labels differently would put a French AZERTY
/// user's `A` key onto the host's `Q`.
public enum EvdevKeycodeTable {
    /// The Carbon virtual keycode for the physical key at an evdev code, or
    /// nil when the host keyboard has no key in that position at all.
    public static func macOSKeyCode(forEvdev code: UInt32) -> UInt16? {
        switch code {
        // Letters.
        case 30: 0     // KEY_A -> kVK_ANSI_A
        case 48: 11    // KEY_B -> kVK_ANSI_B
        case 46: 8     // KEY_C -> kVK_ANSI_C
        case 32: 2     // KEY_D -> kVK_ANSI_D
        case 18: 14    // KEY_E -> kVK_ANSI_E
        case 33: 3     // KEY_F -> kVK_ANSI_F
        case 34: 5     // KEY_G -> kVK_ANSI_G
        case 35: 4     // KEY_H -> kVK_ANSI_H
        case 23: 34    // KEY_I -> kVK_ANSI_I
        case 36: 38    // KEY_J -> kVK_ANSI_J
        case 37: 40    // KEY_K -> kVK_ANSI_K
        case 38: 37    // KEY_L -> kVK_ANSI_L
        case 50: 46    // KEY_M -> kVK_ANSI_M
        case 49: 45    // KEY_N -> kVK_ANSI_N
        case 24: 31    // KEY_O -> kVK_ANSI_O
        case 25: 35    // KEY_P -> kVK_ANSI_P
        case 16: 12    // KEY_Q -> kVK_ANSI_Q
        case 19: 15    // KEY_R -> kVK_ANSI_R
        case 31: 1     // KEY_S -> kVK_ANSI_S
        case 20: 17    // KEY_T -> kVK_ANSI_T
        case 22: 32    // KEY_U -> kVK_ANSI_U
        case 47: 9     // KEY_V -> kVK_ANSI_V
        case 17: 13    // KEY_W -> kVK_ANSI_W
        case 45: 7     // KEY_X -> kVK_ANSI_X
        case 21: 16    // KEY_Y -> kVK_ANSI_Y
        case 44: 6     // KEY_Z -> kVK_ANSI_Z

        // Digit row.
        case 2: 18     // KEY_1 -> kVK_ANSI_1
        case 3: 19     // KEY_2 -> kVK_ANSI_2
        case 4: 20     // KEY_3 -> kVK_ANSI_3
        case 5: 21     // KEY_4 -> kVK_ANSI_4
        case 6: 23     // KEY_5 -> kVK_ANSI_5
        case 7: 22     // KEY_6 -> kVK_ANSI_6
        case 8: 26     // KEY_7 -> kVK_ANSI_7
        case 9: 28     // KEY_8 -> kVK_ANSI_8
        case 10: 25    // KEY_9 -> kVK_ANSI_9
        case 11: 29    // KEY_0 -> kVK_ANSI_0

        // Punctuation.
        case 12: 27    // KEY_MINUS -> kVK_ANSI_Minus
        case 13: 24    // KEY_EQUAL -> kVK_ANSI_Equal
        case 26: 33    // KEY_LEFTBRACE -> kVK_ANSI_LeftBracket
        case 27: 30    // KEY_RIGHTBRACE -> kVK_ANSI_RightBracket
        case 39: 41    // KEY_SEMICOLON -> kVK_ANSI_Semicolon
        case 40: 39    // KEY_APOSTROPHE -> kVK_ANSI_Quote
        case 41: 50    // KEY_GRAVE -> kVK_ANSI_Grave
        case 43: 42    // KEY_BACKSLASH -> kVK_ANSI_Backslash
        case 51: 43    // KEY_COMMA -> kVK_ANSI_Comma
        case 52: 47    // KEY_DOT -> kVK_ANSI_Period
        case 53: 44    // KEY_SLASH -> kVK_ANSI_Slash
        // KEY_102ND: the extra key next to Left Shift on ISO keyboards.
        case 86: 10    // KEY_102ND -> kVK_ISO_Section

        // Editing and whitespace.
        case 28: 36    // KEY_ENTER -> kVK_Return
        case 15: 48    // KEY_TAB -> kVK_Tab
        case 57: 49    // KEY_SPACE -> kVK_Space
        case 14: 51    // KEY_BACKSPACE -> kVK_Delete
        case 1: 53     // KEY_ESC -> kVK_Escape
        case 111: 117  // KEY_DELETE -> kVK_ForwardDelete
        case 102: 115  // KEY_HOME -> kVK_Home
        case 107: 119  // KEY_END -> kVK_End
        case 104: 116  // KEY_PAGEUP -> kVK_PageUp
        case 109: 121  // KEY_PAGEDOWN -> kVK_PageDown
        case 103: 126  // KEY_UP -> kVK_UpArrow
        case 108: 125  // KEY_DOWN -> kVK_DownArrow
        case 105: 123  // KEY_LEFT -> kVK_LeftArrow
        case 106: 124  // KEY_RIGHT -> kVK_RightArrow
        // KEY_INSERT: no Mac keyboard has an Insert key, and no Carbon
        // constant names one; there is no sane physical target.
        case 110: nil  // KEY_INSERT -> (none)

        // Function keys.
        case 59: 122   // KEY_F1 -> kVK_F1
        case 60: 120   // KEY_F2 -> kVK_F2
        case 61: 99    // KEY_F3 -> kVK_F3
        case 62: 118   // KEY_F4 -> kVK_F4
        case 63: 96    // KEY_F5 -> kVK_F5
        case 64: 97    // KEY_F6 -> kVK_F6
        case 65: 98    // KEY_F7 -> kVK_F7
        case 66: 100   // KEY_F8 -> kVK_F8
        case 67: 101   // KEY_F9 -> kVK_F9
        case 68: 109   // KEY_F10 -> kVK_F10
        case 87: 103   // KEY_F11 -> kVK_F11
        case 88: 111   // KEY_F12 -> kVK_F12
        // Print Screen, Scroll Lock and Pause have no Carbon equivalent
        // either; F13-F15 is where Apple's own keyboard-layout handling for
        // PC keyboards already puts them, so a Linux viewer's Print/Scroll
        // Lock/Pause keys land where a USB PC keyboard's already would on
        // this same host.
        case 99: 105   // KEY_SYSRQ (Print Screen) -> kVK_F13
        case 70: 107   // KEY_SCROLLLOCK -> kVK_F14
        case 119: 113  // KEY_PAUSE -> kVK_F15
        case 183: 105  // KEY_F13 -> kVK_F13
        case 184: 107  // KEY_F14 -> kVK_F14
        case 185: 113  // KEY_F15 -> kVK_F15
        case 186: 106  // KEY_F16 -> kVK_F16
        case 187: 64   // KEY_F17 -> kVK_F17
        case 188: 79   // KEY_F18 -> kVK_F18
        case 189: 80   // KEY_F19 -> kVK_F19
        case 190: 90   // KEY_F20 -> kVK_F20

        // Modifiers. Right Alt doubles as AltGr: a physical PC keyboard's
        // AltGr key already reports evdev's KEY_RIGHTALT, the same code an
        // ordinary Right Alt press reports, so no separate case is needed.
        case 42: 56    // KEY_LEFTSHIFT -> kVK_Shift
        case 54: 60    // KEY_RIGHTSHIFT -> kVK_RightShift
        case 29: 59    // KEY_LEFTCTRL -> kVK_Control
        case 97: 62    // KEY_RIGHTCTRL -> kVK_RightControl
        case 56: 58    // KEY_LEFTALT -> kVK_Option
        case 100: 61   // KEY_RIGHTALT (and AltGr) -> kVK_RightOption
        // Super maps to Command and Alt to Option: the only sane physical
        // mapping, and what every macOS keyboard-layout setting for PC
        // keyboards already does.
        case 125: 55   // KEY_LEFTMETA -> kVK_Command
        case 126: 54   // KEY_RIGHTMETA -> kVK_RightCommand
        case 58: 57    // KEY_CAPSLOCK -> kVK_CapsLock

        // Keypad.
        case 82: 82    // KEY_KP0 -> kVK_ANSI_Keypad0
        case 79: 83    // KEY_KP1 -> kVK_ANSI_Keypad1
        case 80: 84    // KEY_KP2 -> kVK_ANSI_Keypad2
        case 81: 85    // KEY_KP3 -> kVK_ANSI_Keypad3
        case 75: 86    // KEY_KP4 -> kVK_ANSI_Keypad4
        case 76: 87    // KEY_KP5 -> kVK_ANSI_Keypad5
        case 77: 88    // KEY_KP6 -> kVK_ANSI_Keypad6
        case 71: 89    // KEY_KP7 -> kVK_ANSI_Keypad7
        case 72: 91    // KEY_KP8 -> kVK_ANSI_Keypad8
        case 73: 92    // KEY_KP9 -> kVK_ANSI_Keypad9
        case 83: 65    // KEY_KPDOT -> kVK_ANSI_KeypadDecimal
        case 55: 67    // KEY_KPASTERISK -> kVK_ANSI_KeypadMultiply
        case 78: 69    // KEY_KPPLUS -> kVK_ANSI_KeypadPlus
        case 74: 78    // KEY_KPMINUS -> kVK_ANSI_KeypadMinus
        case 98: 75    // KEY_KPSLASH -> kVK_ANSI_KeypadDivide
        case 96: 76    // KEY_KPENTER -> kVK_ANSI_KeypadEnter
        case 117: 81   // KEY_KPEQUAL -> kVK_ANSI_KeypadEquals
        // NumLock has no Carbon constant of its own; kVK_ANSI_KeypadClear is
        // the physical key Mac keyboards without a numeric keypad print
        // "clear" on and full-size Mac keyboards print "clear" on too, in
        // NumLock's own corner of the keypad.
        case 69: 71    // KEY_NUMLOCK -> kVK_ANSI_KeypadClear

        // KEY_COMPOSE is the evdev code a physical PC keyboard's Menu key
        // actually sends; kVK_ContextualMenu is the nearest Mac equivalent,
        // a dedicated key that opens the same context menu a right-click
        // would.
        case 127: 110  // KEY_COMPOSE (Menu) -> kVK_ContextualMenu

        default: nil
        }
    }

    /// The evdev codes whose Carbon counterpart is a modifier key the wire
    /// reports through `modifiersChanged` rather than `key`: left/right
    /// Shift, Control, Alt and Super (Meta).
    public static func isModifierKey(evdev code: UInt32) -> Bool {
        modifierCodes.contains(code)
    }

    private static let modifierCodes: Set<UInt32> = [
        42, 54,   // KEY_LEFTSHIFT, KEY_RIGHTSHIFT
        29, 97,   // KEY_LEFTCTRL, KEY_RIGHTCTRL
        56, 100,  // KEY_LEFTALT, KEY_RIGHTALT
        125, 126  // KEY_LEFTMETA, KEY_RIGHTMETA
    ]
}
