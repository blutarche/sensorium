import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// `SystemHotkeyChord` decides which injected keys the window server or Dock
/// would never see at `.cgSessionEventTap` -- the tap every other key uses --
/// and `CoreGraphicsInputInjector` posts exactly those at `.cghidEventTap`
/// instead. Wrong in either direction breaks something a person on the
/// viewer's shortcut strip is looking straight at: too narrow and Mission
/// Control stays dead, too wide and an ordinary app shortcut starts racing
/// the window server for a key that was never meant for it.
@MainActor
func runSystemHotkeyChordTests() async {
    do {
        // Every chord the viewer's shortcut strip sends is recognised
        let recognisedChords: [(name: String, keyCode: UInt16, modifiers: CanvasModifierFlags)] = [
            ("Mission Control (Control-Up)", 126, [.control]),
            ("App Windows (Control-Down)", 125, [.control]),
            ("Desktop Left (Control-Left)", 123, [.control]),
            ("Desktop Right (Control-Right)", 124, [.control]),
            ("Show Desktop (F11)", 103, []),
            ("Spotlight (Command-Space)", 49, [.command]),
            ("Launchpad", 131, []),
            ("Switch App (Command-Tab)", 48, [.command]),
            ("Lock Screen (Control-Command-Q)", 12, [.control, .command])
        ]
        for chord in recognisedChords {
            expect(
                SystemHotkeyChord.isSystemHotkey(keyCode: chord.keyCode, modifiers: chord.modifiers),
                "\(chord.name) is recognised as a system hotkey"
            )
        }

        // Every other F-key the rule lists, not just the one the strip sends.
        let everyFunctionKeyCode: Set<UInt16> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
            103, 111, 105, 107, 113, 106, 64, 79, 80, 90
        ]
        for keyCode in everyFunctionKeyCode {
            expect(
                SystemHotkeyChord.isSystemHotkey(keyCode: keyCode, modifiers: []),
                "F-key virtual code \(keyCode) with no modifier is recognised (fn never arrives over the wire)"
            )
        }

        print("PASS: every chord the shortcut strip sends is recognised as a system hotkey")
    }

    do {
        // An ordinary key, and an ordinary app shortcut that merely shares a key, is not
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 0, modifiers: []),
            "the letter A with no modifier is an ordinary key, not a system hotkey"
        )
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 126, modifiers: []),
            "the up arrow alone, with no Control held, is ordinary navigation"
        )
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 126, modifiers: [.shift]),
            "Shift-Up is a text-selection chord, not Control-Up"
        )
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 103, modifiers: [.shift]),
            "an app's own Shift-F11 shortcut is not Show Desktop's plain F11"
        )
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 12, modifiers: [.command]),
            "plain Command-Q (Quit App) is left alone; only Control-Command-Q (Lock Screen) is a system hotkey"
        )
        expect(
            !SystemHotkeyChord.isSystemHotkey(keyCode: 49, modifiers: [.command, .shift]),
            "Command-Shift-Space is not Spotlight's own Command-Space"
        )

        print("PASS: an ordinary key or an app shortcut that merely shares a key is never treated as a system hotkey")
    }

    do {
        // The injector posts a recognised key at the hid tap, and everything else at the session tap
        let recorder = RecordedPosts()
        // An explicit no-op, not the default `MutableHostInjectedHIDActivity.shared`:
        // Control-Up below really does post at `.cghidEventTap`, and the shared
        // singleton must never carry state one test group leaves behind into
        // another that reads real `hidSystemState` through it.
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: 0,
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: NoOpHostInjectedHIDActivity(),
            postEvent: { event, tap in recorder.record(event.type, tap) }
        )

        try! injector.inject(.key(keyCode: 126, isDown: true, modifiers: [.control]))
        try! injector.inject(.key(keyCode: 126, isDown: false, modifiers: [.control]))
        expect(
            recorder.all().map(\.tap) == [.cghidEventTap, .cghidEventTap],
            "Control-Up's key down and key up both reach the hid tap, so the chord is complete there"
        )

        recorder.reset()
        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        expect(
            recorder.all().map(\.tap) == [.cgSessionEventTap],
            "an ordinary key is posted at the session tap, unchanged"
        )

        print("PASS: the injector routes a recognised system hotkey to the hid tap and leaves everything else alone")
    }

    do {
        // nativeAuxiliaryFlags: the bits a real keyboard sets that our synthetic event never does
        let navigationClusterKeyCodes: [UInt16] = [123, 124, 125, 126, 115, 119, 116, 121, 117]
        for keyCode in navigationClusterKeyCodes {
            expect(
                CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: keyCode) == [.maskSecondaryFn, .maskNumericPad],
                "navigation-cluster key \(keyCode) carries fn and numeric-pad, exactly what a live keyboard reported"
            )
        }
        expect(
            CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: 103) == [.maskSecondaryFn],
            "an F-row key (F11) carries fn alone, confirmed live to be what moves Show Desktop"
        )
        expect(
            CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: 0) == [],
            "an ordinary letter key carries neither bit"
        )

        print("PASS: nativeAuxiliaryFlags matches a real keyboard for the navigation cluster and the F-row, and nothing else")
    }

    do {
        // The injector sets those bits on the posted event, without leaking them onto later pointer input
        let recorder = RecordedPosts()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: 0,
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: NoOpHostInjectedHIDActivity(),
            postEvent: { event, tap in recorder.record(event.type, tap, event.flags) }
        )

        try! injector.inject(.key(keyCode: 126, isDown: true, modifiers: [.control]))
        expect(
            recorder.all().last?.flags == [.maskControl, .maskSecondaryFn, .maskNumericPad],
            "Control-Up's own posted key event carries Control plus the live-confirmed fn and numeric-pad bits"
        )

        recorder.reset()
        try! injector.inject(.key(keyCode: 115, isDown: true, modifiers: []))
        expect(
            recorder.all().last?.flags == [.maskSecondaryFn, .maskNumericPad],
            "Home, not a recognised system hotkey and so still posted at the session tap, still carries the same bits"
        )
        expect(
            recorder.all().last?.tap == .cgSessionEventTap,
            "Home does not need the hid tap; only the flags are about matching real hardware"
        )

        recorder.reset()
        try! injector.inject(.key(keyCode: 126, isDown: true, modifiers: [.control]))
        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: [.shift]))
        expect(
            recorder.all().first?.flags == [.maskControl, .maskSecondaryFn, .maskNumericPad],
            "the arrow key's own event carries the auxiliary bits"
        )
        expect(
            recorder.all().last?.flags == [.maskShift],
            "an ordinary key right after an arrow key never picks up fn or numeric-pad from that arrow's own posted event"
        )

        print("PASS: the injector's native auxiliary flags land only on the key event that needs them")
    }
}

/// Every `(CGEventType, CGEventTapLocation, CGEventFlags)` triple the
/// injector under test posted, through the seam that stands in for
/// `CGEvent.post` so this suite never injects a real synthetic event.
private final class RecordedPosts {
    private var posts: [(type: CGEventType, tap: CGEventTapLocation, flags: CGEventFlags)] = []

    func record(_ type: CGEventType, _ tap: CGEventTapLocation, _ flags: CGEventFlags = []) {
        posts.append((type, tap, flags))
    }

    func all() -> [(type: CGEventType, tap: CGEventTapLocation, flags: CGEventFlags)] {
        posts
    }

    func reset() {
        posts.removeAll()
    }
}

/// Stands in for `MutableHostInjectedHIDActivity.shared` so a test that posts
/// at the hid tap never writes into the process-wide singleton, which would
/// otherwise carry that state into whatever test group reads it next.
private final class NoOpHostInjectedHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}
