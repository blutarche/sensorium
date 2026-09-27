import Foundation
import SensoriumClient
import SensoriumCore

/// `ViewerMenuPlan.windowMenuState`, the pure rule behind the Window menu's
/// Minimize, Zoom and Bring All to Front items -- verifiable without a real
/// window, unlike the traits (style mask, `isMiniaturized`, `isVisible`)
/// `ViewerMainMenuController.menuNeedsUpdate` reads them from.
func testViewerWindowMenuStateTests() {
    do {
        let ordinary = ViewerMenuPlan.windowMenuState(
            canMiniaturize: true,
            isMiniaturized: false,
            canZoom: true,
            hasVisibleWindow: true
        )
        expect(ordinary.minimizeEnabled, "an ordinary, not-yet-miniaturized window can be minimized")
        expect(ordinary.zoomEnabled, "an ordinary, resizable window can be zoomed")
        expect(ordinary.bringAllToFrontEnabled, "some window of the app is visible")

        print("PASS: an ordinary window enables Minimize, Zoom and Bring All to Front")
    }

    do {
        // `[.titled, .closable]` -- the launch window's own style mask --
        // carries neither `.miniaturizable` nor `.resizable`.
        let launchWindow = ViewerMenuPlan.windowMenuState(
            canMiniaturize: false,
            isMiniaturized: false,
            canZoom: false,
            hasVisibleWindow: true
        )
        expect(!launchWindow.minimizeEnabled, "a window with no .miniaturizable bit cannot be minimized")
        expect(!launchWindow.zoomEnabled, "a window with no .resizable bit cannot be zoomed")

        print("PASS: a [.titled, .closable] window disables both Minimize and Zoom")
    }

    do {
        let alreadyMiniaturized = ViewerMenuPlan.windowMenuState(
            canMiniaturize: true,
            isMiniaturized: true,
            canZoom: true,
            hasVisibleWindow: true
        )
        expect(!alreadyMiniaturized.minimizeEnabled, "a window already miniaturized cannot be minimized again")
        expect(alreadyMiniaturized.zoomEnabled, "being miniaturized says nothing about whether it can be zoomed")

        print("PASS: an already-miniaturized window disables only Minimize")
    }

    do {
        let noWindow = ViewerMenuPlan.windowMenuState(
            canMiniaturize: false,
            isMiniaturized: false,
            canZoom: false,
            hasVisibleWindow: false
        )
        expect(!noWindow.bringAllToFrontEnabled, "nothing to bring to front when no window of the app is visible")

        print("PASS: Bring All to Front is disabled when no window of the app is visible")
    }
}
