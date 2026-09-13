import SensoriumCore

/// A key combination the window server or Dock consumes for itself, ahead of
/// any event tap an ordinary app -- or `.cgSessionEventTap`, where every other
/// injected key lands -- ever sees. `CoreGraphicsInputInjector` posts a key
/// matching this rule at `.cghidEventTap` instead, the one tap early enough
/// for that consumer to still see it. Everything else is delivered normally
/// by being left where it already was.
///
/// Carbon's virtual key codes, the vocabulary the protocol's `keyCode`
/// already speaks. The F-key codes below are its `kVK_F1`...`kVK_F20`
/// constants; fn is not one of `CanvasModifierFlags`'s four bits and never
/// arrives over the wire, so "no or only fn" reduces here to no modifier at
/// all.
public enum SystemHotkeyChord {
    /// Shared with `CoreGraphicsInputTranslation.nativeAuxiliaryFlags`, which
    /// needs the same two code sets for an unrelated reason: not to route a
    /// tap, but because a real arrow or F-row key carries flag bits our
    /// synthetic event never sets on its own.
    static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90
    ]
    private static let spaceKeyCode: UInt16 = 49
    private static let tabKeyCode: UInt16 = 48
    private static let letterQKeyCode: UInt16 = 12
    private static let launchpadKeyCode: UInt16 = 131

    public static func isSystemHotkey(keyCode: UInt16, modifiers: CanvasModifierFlags) -> Bool {
        if modifiers == [.control], arrowKeyCodes.contains(keyCode) {
            return true
        }
        if modifiers.isEmpty, functionKeyCodes.contains(keyCode) {
            return true
        }
        if modifiers == [.command], keyCode == spaceKeyCode || keyCode == tabKeyCode {
            return true
        }
        if modifiers == [.control, .command], keyCode == letterQKeyCode {
            return true
        }
        if modifiers.isEmpty, keyCode == launchpadKeyCode {
            return true
        }
        return false
    }
}
