import AppKit
import Foundation
import SensoriumHost

/// The editor's own body text should start at the same x origin as the
/// keyboard hint printed above it, so the panel reads as one left edge.
/// Reached through `CanvasHostTestHooks`, a `package`-access seam that stays
/// visible in a release build, unlike `@testable import`.
@MainActor
func runHostWorkspaceEditorTextOriginTests() async {
    let placement = CanvasHostTestHooks.placementForTesting(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    let origins = CanvasHostTestHooks.workspaceEditorTextOriginX(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1200),
        canvas: placement
    )
    expect(
        origins.textOriginX == origins.hintMinX,
        "the editor's body text should start at the same x origin as the keyboard hint above it"
            + " -- text starts at \(origins.textOriginX), hint starts at \(origins.hintMinX)"
    )

    print("PASS: the workspace editor's body text shares the keyboard hint's left edge")
}
