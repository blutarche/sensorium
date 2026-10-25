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
    expect(
        ViewerKeyNames.pointerCapture == "Control-Option-Command-G",
        "and the pointer-capture toggle the same way, got \(ViewerKeyNames.pointerCapture)"
    )
    #else
    expect(
        ViewerKeyNames.escapeGesture == "Ctrl-Alt-Super-Escape",
        "elsewhere it is spelled for a PC keyboard, got \(ViewerKeyNames.escapeGesture)"
    )
    expect(
        ViewerKeyNames.pointerCapture == "Ctrl-Alt-Super-G",
        "and so is the pointer-capture toggle, got \(ViewerKeyNames.pointerCapture)"
    )
    #endif

    // The spelling follows the chord the View menu really carries.
    let captureItem = ViewerMenuPlan.menus
        .flatMap(\.items)
        .first(where: { $0.command == .togglePointerCapture })
    expect(
        captureItem?.keyEquivalent == "g" && captureItem?.modifiers == .viewerChord,
        "the toggle named in the HUD is the one the View menu binds, got "
            + "\(String(describing: captureItem?.keyEquivalent))"
    )

    let helpItem = ViewerMenuPlan.menus
        .first(where: { $0.title == "Help" })?
        .items.first
    expect(
        helpItem?.title == "Escape Back to This Machine: \(ViewerKeyNames.escapeGesture)",
        "and the Help menu names it from that one place, got \(String(describing: helpItem?.title))"
    )
    expect(
        ClientShortcutPermissionReport.lines(mode: .remoteWhenFocused, accessibilityGranted: true)
            .contains(where: { $0.contains(ViewerKeyNames.escapeGesture) }),
        "and so does the permission report"
    )
    print("PASS: every sentence naming the escape gesture spells it from one place")
}

/// The strip is drawn from SF Symbols on macOS, so every action needs a name
/// or a button comes up blank.
func testShortcutStripIconNameTests() {
    for action in ShortcutStripAction.allCases {
        expect(!action.symbolName.isEmpty, "\(action.title) has an SF Symbol name")
    }
    print("PASS: every shortcut strip action names an SF Symbol")
}

/// A platform with no Accessibility permission is not told about one, and
/// does not see another platform's shortcut names.
func testShortcutReportWithoutAccessibilityTests() {
    let lines = ClientShortcutPermissionReport.lines(
        mode: .remoteWhenFocused, accessibilityGranted: true, usesAccessibility: false
    )
    expect(lines.count == 2, "only the mode line and the escape line, got \(lines)")
    expect(lines.allSatisfy { !$0.contains("Accessibility") && !$0.contains("Cmd") }, "nothing names macOS")
    expect(lines.contains(where: { $0.contains(ViewerKeyNames.escapeGesture) }), "the escape line stays")
    expect(
        ClientShortcutPermissionReport.lines(
            mode: .remoteWhenFocused, accessibilityGranted: true, usesAccessibility: true
        ).contains(where: { $0.contains("Accessibility") }),
        "a platform that uses Accessibility still reports it"
    )
    #if os(macOS)
    expect(ClientShortcutPermissionReport.platformUsesAccessibility, "macOS uses Accessibility")
    #else
    expect(!ClientShortcutPermissionReport.platformUsesAccessibility, "this platform has no Accessibility")
    #endif
    print("PASS: the shortcut report names Accessibility only where it exists")
}

func testViewerFarewellTests() {
    expect(
        ViewerFarewell.line(sessionWasCanvas: true) == "Left; the virtual display has been released.",
        "a session canvas is released on leaving"
    )
    expect(
        ViewerFarewell.line(sessionWasCanvas: false) == "Left.",
        "a host screen has no virtual display to release"
    )
    print("PASS: the farewell mentions a virtual display only for a session canvas")
}
