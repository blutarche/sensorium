import AppKit
import Foundation
import SensoriumHost

/// What the session canvas's editor shows when it opens: prose in the body
/// face, in the product's own words for the surface.
@MainActor
func runHostWorkspaceEditorContentTests() async {
    let placement = CanvasHostTestHooks.placementForTesting(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    let editor = CanvasHostTestHooks.workspaceEditorContent(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1200),
        canvas: placement
    )

    expect(
        editor.font == CanvasDesign.font(.primary, size: 18),
        "the editor's text is prose, so it reads in the body face, not the mono one -- got \(String(describing: editor.font))"
    )
    expect(
        editor.text.hasPrefix("Your private desktop is ready.") && !editor.text.lowercased().contains("virtual"),
        "the editor names the surface by the product's own term, a private desktop -- got \(editor.text)"
    )

    print("PASS: the workspace editor opens with body-face prose that names the private desktop")
}
