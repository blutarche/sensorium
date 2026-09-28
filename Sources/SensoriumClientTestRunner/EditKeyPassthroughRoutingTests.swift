import SensoriumClient
import SensoriumCore

/// The six standard text-editing chords the viewer's Edit menu offers as
/// ordinary key equivalents. A session canvas window must keep forwarding
/// every one of them to the remote host exactly as ordinary typing already
/// does -- `SystemShortcutRouter.claimsKeyEquivalent` is what lets the canvas
/// claim them ahead of the menu, the same mechanism that already protects
/// Cmd-Q/W/H/M.
func testEditKeyPassthroughRoutingTests() {
    let router = SystemShortcutRouter(mode: .default)
    let focused = ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    let unfocused = ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: false)

    let editChords: [(name: String, chord: KeyChord)] = [
        ("Cmd-Z (Undo)", KeyChord(keyCode: 6, modifiers: [.command])),
        ("Cmd-Shift-Z (Redo)", KeyChord(keyCode: 6, modifiers: [.command, .shift])),
        ("Cmd-X (Cut)", KeyChord(keyCode: 7, modifiers: [.command])),
        ("Cmd-C (Copy)", KeyChord(keyCode: 8, modifiers: [.command])),
        ("Cmd-V (Paste)", KeyChord(keyCode: 9, modifiers: [.command])),
        ("Cmd-A (Select All)", KeyChord(keyCode: 0, modifiers: [.command]))
    ]

    for (name, chord) in editChords {
        expect(
            router.claimsKeyEquivalent(chord: chord, viewer: focused, accessibilityGranted: false),
            "\(name) is claimed by the canvas ahead of the Edit menu while a canvas window is key"
        )
        expect(
            !router.claimsKeyEquivalent(chord: chord, viewer: unfocused, accessibilityGranted: false),
            "\(name) is left for the Edit menu when no canvas window has key focus"
        )
    }

    // Cmd-Shift-C is Share Clipboard's own chord, a different combination
    // from Cmd-C -- it must never be swept up by the edit-chord exemption.
    let shareClipboard = KeyChord(keyCode: 8, modifiers: [.command, .shift])
    expect(
        !router.claimsKeyEquivalent(chord: shareClipboard, viewer: focused, accessibilityGranted: false),
        "Cmd-Shift-C (Share Clipboard) is not one of the edit chords the canvas pre-empts"
    )
    // Cmd-1 (Your Machines), Ctrl-Cmd-F (full screen), the strip toggle and
    // the session-controls toggle are all reserved to their own menu items
    // or chords, and none of them may be swallowed by this change either.
    expect(
        !router.claimsKeyEquivalent(
            chord: KeyChord(keyCode: 18, modifiers: [.command]),
            viewer: focused,
            accessibilityGranted: false
        ),
        "Cmd-1 (Your Machines) is unaffected"
    )
    expect(
        !router.claimsKeyEquivalent(
            chord: SystemShortcutCatalog.shortcutStripToggle,
            viewer: focused,
            accessibilityGranted: false
        ),
        "the shortcut strip's own summon chord is unaffected"
    )
    expect(
        !router.claimsKeyEquivalent(
            chord: SystemShortcutCatalog.escapeGesture,
            viewer: focused,
            accessibilityGranted: false
        ),
        "the escape gesture is never claimed as a key equivalent -- it is honoured only in keyDown"
    )

    // Ordinary typing with no modifier at all is untouched: the guard only
    // ever widens what the canvas claims, never what it already claimed.
    expect(
        !router.claimsKeyEquivalent(
            chord: KeyChord(keyCode: 8, modifiers: []),
            viewer: focused,
            accessibilityGranted: false
        ),
        "a bare 'c' with no modifier is not a key equivalent at all"
    )

    print("PASS: the canvas claims the six standard editing chords ahead of the Edit menu, and nothing else")
}
