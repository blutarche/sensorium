import Foundation
import SensoriumClient
import SensoriumCore

/// docs/ux-spec.md line 96: a chord summons the shortcut strip without the
/// pointer. It is matched by whichever window layer is in front, so the chord
/// itself has to live somewhere both of them can read.
func testShortcutStripToggleChordTests() {
    expect(
        SystemShortcutCatalog.shortcutStripToggle == KeyChord(
            keyCode: 49, modifiers: [.command, .control, .shift]
        ),
        "the strip's summon chord is Command-Control-Shift-Space"
    )
    expect(
        !SystemShortcutCatalog.all.contains(where: { $0.chord == SystemShortcutCatalog.shortcutStripToggle }),
        "and is never forwarded, the same way the escape gesture never is"
    )
    print("PASS: the shortcut strip's summon chord is named once, in the catalog both window layers read")
}

/// The escape gesture is named in the Help menu, in the session HUD and in
/// the permission report, and the keys it names are spelled differently on
/// each platform.
func testViewerKeyNamesTests() {
    #if os(macOS)
    expect(
        ViewerKeyNames.escapeGesture == "Control-Option-Command-Escape",
        "macOS spells the escape gesture with its own modifier names, got \(ViewerKeyNames.escapeGesture)"
    )
    #else
    expect(
        ViewerKeyNames.escapeGesture == "Ctrl-Alt-Super-Escape",
        "elsewhere it is spelled for a PC keyboard, got \(ViewerKeyNames.escapeGesture)"
    )
    #endif

    let helpItem = ViewerMenuPlan.menus
        .first(where: { $0.title == "Help" })?
        .items.first
    expect(
        helpItem?.title == "Escape back to this machine: \(ViewerKeyNames.escapeGesture)",
        "and the Help menu names it from that one place, got \(String(describing: helpItem?.title))"
    )
    expect(
        ClientShortcutPermissionReport.lines(mode: .remoteWhenFocused, accessibilityGranted: true)
            .contains(where: { $0.contains(ViewerKeyNames.escapeGesture) }),
        "and so does the permission report"
    )
    print("PASS: every sentence naming the escape gesture spells it from one place")
}

/// The strip is drawn from SF Symbols on macOS and from the freedesktop icon
/// naming specification elsewhere, so every action needs a name in both
/// vocabularies or a button comes up blank.
func testShortcutStripIconNameTests() {
    for action in ShortcutStripAction.allCases {
        expect(!action.symbolName.isEmpty, "\(action.title) has an SF Symbol name")
        expect(!action.freedesktopIconName.isEmpty, "\(action.title) has a freedesktop icon name")
    }
    expect(
        Set(ShortcutStripAction.allCases.map(\.freedesktopIconName)).count == ShortcutStripAction.allCases.count,
        "and no two buttons draw the same icon"
    )
    print("PASS: every shortcut strip action names an icon in both vocabularies")
}
