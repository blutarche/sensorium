#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

@MainActor
private final class FakeMenuCommandTarget: ViewerMenuCommandTarget {
    let viewerWindowState: ViewerWindowState
    let isPointerCaptured = false
    let streamScaleMenuState = DisplayScaleMenuState(items: [], clampNotice: nil)
    let displayCountMenuState = DisplayCountMenuState(items: [])
    let isClipboardSharingEnabled = true
    private(set) var clipboardToggleCount = 0

    init(hasKeyFocus: Bool) {
        viewerWindowState = ViewerWindowState(surfaceID: 0, hasKeyFocus: hasKeyFocus, isFullscreen: false)
    }

    func toggleTelemetryOverlay() {}
    func togglePointerCapture() {}
    func toggleClipboardSharing() { clipboardToggleCount += 1 }
    func selectStreamScale(_ preference: StreamScalePreference) {}
    func selectDisplayCount(_ count: Int) {}
}

/// `ViewerMainMenuController.unregister` is what `closeWindows()` calls for
/// every window controller it registered, so a session that ends -- a
/// successful pair-again included -- does not leave the shared menu holding
/// windows nobody can see or close.
@MainActor
func testViewerMainMenuUnregisterTests() async {
    do {
        let controller = ViewerMainMenuController(onQuit: {}, onShowYourMachines: {})
        let target = FakeMenuCommandTarget(hasKeyFocus: true)
        controller.register(target)

        let toggleClipboardSharing = NSSelectorFromString("toggleClipboardSharing:")
        _ = controller.perform(toggleClipboardSharing, with: nil)
        expect(
            target.clipboardToggleCount == 1,
            "a registered, focused target receives the dispatched action, got \(target.clipboardToggleCount)"
        )

        controller.unregister(target)
        _ = controller.perform(toggleClipboardSharing, with: nil)
        expect(
            target.clipboardToggleCount == 1,
            "an unregistered target is no longer dispatched to, got \(target.clipboardToggleCount)"
        )

        print("PASS: unregister removes a target from dispatch")
    }
}
#endif
