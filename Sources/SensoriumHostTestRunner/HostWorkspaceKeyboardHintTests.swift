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
        hint == "Command-L focuses the launcher \u{b7} Escape leaves it",
        // Spelled out: the command-key glyph smears at stream scale.
        "the keyboard hint names its keys in words, says the launcher takes focus and that Escape leaves it, without naming an editor nothing on screen looks like -- got: \(hint)"
    )

    print("PASS: the workspace's keyboard hint reads \"Command-L focuses the launcher · Escape leaves it\"")
}
