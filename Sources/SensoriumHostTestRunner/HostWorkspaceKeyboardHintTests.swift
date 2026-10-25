import AppKit
import Foundation
import SensoriumHost

/// The workspace's own keyboard hint, the one reminder of how to reach the
/// launcher and come back. Reached through `CanvasHostTestHooks`, a
/// `package`-access seam that stays visible in a release build, unlike
/// `@testable import`.
@MainActor
func runHostWorkspaceKeyboardHintTests() async {
    let placement = CanvasHostTestHooks.placementForTesting(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    let hint = CanvasHostTestHooks.workspaceKeyboardHint(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1200),
        canvas: placement
    )
    expect(
        hint == "\u{2318}L focuses the launcher \u{b7} Esc leaves it",
        // \u{2318} is the command-key glyph macOS itself shows in menus; \u{b7} is the middle dot the source string itself uses.
        "the keyboard hint names the shortcut with the \u{2318} glyph, says the launcher takes focus and that Esc leaves it, without naming an editor nothing on screen looks like -- got: \(hint)"
    )

    print("PASS: the workspace's keyboard hint reads \"\u{2318}L focuses the launcher · Esc leaves it\"")
}
