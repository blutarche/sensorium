#if os(Linux)

/// The inverse of the Linux viewer's evdev-to-macOS table, for keys that
/// travel the wire as macOS virtual keycodes and must reach the portal as
/// evdev codes. The viewer translates physical positions to macOS virtual
/// keycodes before sending, so this returns the key at that same position.
///
/// The viewer's table sends two evdev keys to one macOS key in four places.
/// Each is decided here, and a test fails when the viewer's table gains a
/// fifth:
///
/// - 105, 107 and 113 (F13, F14, F15) post Print Screen, Scroll Lock and
///   Pause, the PC keys the viewer's table puts there.
/// - 104 (Kana) posts Henkan, the Japanese key beside the space bar, which is
///   the position a Mac JIS keyboard's Kana key occupies.
public enum MacOSKeyToEvdev {
    /// The evdev `KEY_*` code for a macOS virtual keycode, or nil when the
    /// viewer's table never produces that keycode.
    public static func evdevCode(forMacOSKeyCode keyCode: UInt16) -> UInt32? {
        table[keyCode]
    }

    private static let table: [UInt16: UInt32] = [
        0: 30,  // KEY_A
        1: 31,  // KEY_S
        2: 32,  // KEY_D
        3: 33,  // KEY_F
        4: 35,  // KEY_H
        5: 34,  // KEY_G
        6: 44,  // KEY_Z
        7: 45,  // KEY_X
        8: 46,  // KEY_C
        9: 47,  // KEY_V
        10: 86,  // KEY_102ND
        11: 48,  // KEY_B
        12: 16,  // KEY_Q
        13: 17,  // KEY_W
        14: 18,  // KEY_E
        15: 19,  // KEY_R
        16: 21,  // KEY_Y
        17: 20,  // KEY_T
        18: 2,  // KEY_1
        19: 3,  // KEY_2
        20: 4,  // KEY_3
        21: 5,  // KEY_4
        22: 7,  // KEY_6
        23: 6,  // KEY_5
        24: 13,  // KEY_EQUAL
        25: 10,  // KEY_9
        26: 8,  // KEY_7
        27: 12,  // KEY_MINUS
        28: 9,  // KEY_8
        29: 11,  // KEY_0
        30: 27,  // KEY_RIGHTBRACE
        31: 24,  // KEY_O
        32: 22,  // KEY_U
        33: 26,  // KEY_LEFTBRACE
        34: 23,  // KEY_I
        35: 25,  // KEY_P
        36: 28,  // KEY_ENTER
        37: 38,  // KEY_L
        38: 36,  // KEY_J
        39: 40,  // KEY_APOSTROPHE
        40: 37,  // KEY_K
        41: 39,  // KEY_SEMICOLON
        42: 43,  // KEY_BACKSLASH
        43: 51,  // KEY_COMMA
        44: 53,  // KEY_SLASH
        45: 49,  // KEY_N
        46: 50,  // KEY_M
        47: 52,  // KEY_DOT
        48: 15,  // KEY_TAB
        49: 57,  // KEY_SPACE
        50: 41,  // KEY_GRAVE
        51: 14,  // KEY_BACKSPACE
        53: 1,  // KEY_ESC
        54: 126,  // KEY_RIGHTMETA
        55: 125,  // KEY_LEFTMETA
        56: 42,  // KEY_LEFTSHIFT
        57: 58,  // KEY_CAPSLOCK
        58: 56,  // KEY_LEFTALT
        59: 29,  // KEY_LEFTCTRL
        60: 54,  // KEY_RIGHTSHIFT
        61: 100,  // KEY_RIGHTALT
        62: 97,  // KEY_RIGHTCTRL
        64: 187,  // KEY_F17
        65: 83,  // KEY_KPDOT
        67: 55,  // KEY_KPASTERISK
        69: 78,  // KEY_KPPLUS
        71: 69,  // KEY_NUMLOCK
        75: 98,  // KEY_KPSLASH
        76: 96,  // KEY_KPENTER
        78: 74,  // KEY_KPMINUS
        79: 188,  // KEY_F18
        80: 189,  // KEY_F19
        81: 117,  // KEY_KPEQUAL
        82: 82,  // KEY_KP0
        83: 79,  // KEY_KP1
        84: 80,  // KEY_KP2
        85: 81,  // KEY_KP3
        86: 75,  // KEY_KP4
        87: 76,  // KEY_KP5
        88: 77,  // KEY_KP6
        89: 71,  // KEY_KP7
        90: 190,  // KEY_F20
        91: 72,  // KEY_KP8
        92: 73,  // KEY_KP9
        93: 124,  // KEY_YEN
        94: 89,  // KEY_RO
        95: 95,  // KEY_KPJPCOMMA
        96: 63,  // KEY_F5
        97: 64,  // KEY_F6
        98: 65,  // KEY_F7
        99: 61,  // KEY_F3
        100: 66,  // KEY_F8
        101: 67,  // KEY_F9
        102: 94,  // KEY_MUHENKAN
        103: 87,  // KEY_F11
        104: 92,  // KEY_HENKAN
        105: 99,  // KEY_SYSRQ
        106: 186,  // KEY_F16
        107: 70,  // KEY_SCROLLLOCK
        109: 68,  // KEY_F10
        110: 127,  // KEY_COMPOSE
        111: 88,  // KEY_F12
        113: 119,  // KEY_PAUSE
        114: 110,  // KEY_INSERT
        115: 102,  // KEY_HOME
        116: 104,  // KEY_PAGEUP
        117: 111,  // KEY_DELETE
        118: 62,  // KEY_F4
        119: 107,  // KEY_END
        120: 60,  // KEY_F2
        121: 109,  // KEY_PAGEDOWN
        122: 59,  // KEY_F1
        123: 105,  // KEY_LEFT
        124: 106,  // KEY_RIGHT
        125: 108,  // KEY_DOWN
        126: 103  // KEY_UP
    ]
}

#endif
