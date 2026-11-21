#if os(Linux)

import SensoriumClient
import SensoriumLinuxHost

/// The evdev codes the Linux viewer can send, a generous bound over the
/// `KEY_*` range its table covers.
private let evdevRange: ClosedRange<UInt32> = 0...0x2ff

private func forwardImage() -> [UInt16: [UInt32]] {
    var image: [UInt16: [UInt32]] = [:]
    for code in evdevRange {
        if let keyCode = EvdevKeycodeTable.macOSKeyCode(forEvdev: code) {
            image[keyCode, default: []].append(code)
        }
    }
    return image
}

func testKeyMapIsTotalOverTheForwardTablesImage() {
    let image = forwardImage()
    expect(image.count > 100, "the forward table has an image to cover")
    for keyCode in image.keys.sorted() {
        expect(
            MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: keyCode) != nil,
            "macOS key \(keyCode) maps to an evdev key"
        )
    }
}

func testKeyMapInvertsTheForwardTableWithoutAmbiguity() {
    let image = forwardImage()
    for (keyCode, preimages) in image {
        guard let evdev = MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: keyCode) else { continue }
        expect(
            EvdevKeycodeTable.macOSKeyCode(forEvdev: evdev) == keyCode,
            "macOS key \(keyCode) maps to an evdev key that maps back to it"
        )
        expect(preimages.contains(evdev), "macOS key \(keyCode) maps into its own preimage")
    }
    // The map holds nothing the forward table cannot produce, so no key is
    // invented here that the viewer would never have meant.
    for keyCode in UInt16(0)...UInt16(255) where MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: keyCode) != nil {
        expect(image[keyCode] != nil, "macOS key \(keyCode) is in the forward table's image")
    }
}

func testKeyMapChoicesWhereTwoEvdevKeysShareOneMacOSKey() {
    let ambiguous = forwardImage().filter { $0.value.count > 1 }.keys.sorted()
    // Every shared key is named and decided; a new collision in the viewer's
    // table fails here until someone chooses.
    expect(ambiguous == [104, 105, 107, 113], "the shared macOS keys are 104, 105, 107 and 113, got \(ambiguous)")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 105) == 99, "F13's slot posts Print Screen (KEY_SYSRQ)")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 107) == 70, "F14's slot posts Scroll Lock")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 113) == 119, "F15's slot posts Pause")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 104) == 92, "the Kana slot posts Henkan, the key right of the space bar")
}

func testKeyMapKnownKeys() {
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 0) == 30, "A")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 36) == 28, "Return")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 55) == 125, "Command is the left Super key")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 56) == 42, "Shift is left Shift")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 57) == 58, "Caps Lock is KEY_CAPSLOCK")
    expect(MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: 0xFFFF) == nil, "an unknown key maps to nothing")
}

func keyMapTests() -> [NamedTest] { [
    ("the key map covers every key the forward table can produce", testKeyMapIsTotalOverTheForwardTablesImage),
    ("the key map inverts the forward table without ambiguity", testKeyMapInvertsTheForwardTableWithoutAmbiguity),
    ("shared macOS keys resolve to the PC key", testKeyMapChoicesWhereTwoEvdevKeysShareOneMacOSKey),
    ("known keys map as expected", testKeyMapKnownKeys)
] }

#endif
