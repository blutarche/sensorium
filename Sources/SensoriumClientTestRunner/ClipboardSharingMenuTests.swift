#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore

/// docs/ux-spec.md's "Clipboard: on or off" -- the View menu's own checkbox
/// item, and the pure toggle decision `ClientCanvasWindowController` asks
/// for rather than computing inline (that class is never constructed by any
/// runner -- building it opens a window and creates a Metal device -- so the
/// decision has to live somewhere a test can reach it, the same reasoning
/// `DisplayCountMenuPlan` and `pointerCaptureTitle` already follow).
@MainActor
func testClipboardSharingMenuTests() async {
    do {
        let viewMenu = ViewerMenuPlan.menus.first { $0.title == "View" }
        let item = viewMenu?.items.first { $0.command == .toggleClipboardSharing }
        expect(item != nil, "the View menu offers a Clipboard row docs/ux-spec.md's own \"Clipboard: on or off\" control")
        expect(item?.title.localizedCaseInsensitiveContains("clipboard") == true, "named for what it does, not left as a bare 'Toggle'")
        expect(
            !(item?.title.lowercased().contains("canvas") ?? true) && !(item?.title.lowercased().contains("surface") ?? true),
            "no internal vocabulary in a menu title docs/ux-spec.md's own visual pass would flag"
        )

        print("PASS: the View menu offers a Clipboard row naming what it does, with no internal vocabulary")
    }

    do {
        expect(
            ClipboardSharingToggle.nextValue(currentlyEnabled: true) == false,
            "toggling an enabled session off is the opposite of what it currently caches"
        )
        expect(
            ClipboardSharingToggle.nextValue(currentlyEnabled: false) == true,
            "toggling a disabled session back on is the opposite the other way"
        )

        print("PASS: the Clipboard toggle always sends the opposite of what this window currently caches")
    }

    do {
        // No window has ever had focus yet -- the app just launched, or the
        // View menu opens before a session connects -- so
        // `ViewerMainMenuController` has no `ViewerMenuCommandTarget` to
        // read `isClipboardSharingEnabled` from. That fallback must read
        // `ClipboardSyncEngine.sharingEnabledByDefault`, the same off
        // default every session actually starts at, not a hardcoded on
        // that would show a checkmark for a state nothing has enabled.
        let controller = ViewerMainMenuController(onQuit: {}, onShowYourMachines: {})
        let app = NSApplication.shared
        controller.install(into: app)
        guard let viewMenu = app.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu else {
            fatalError("install() did not build a View menu")
        }
        controller.menuNeedsUpdate(viewMenu)
        let toggleClipboardSharing = NSSelectorFromString("toggleClipboardSharing:")
        guard let clipboardItem = viewMenu.items.first(where: { $0.action == toggleClipboardSharing }) else {
            fatalError("the View menu has no Clipboard item")
        }
        expect(
            clipboardItem.state == .off,
            "with no focused target, the Clipboard item must fall back to sharingEnabledByDefault, not read as checked on"
        )

        print("PASS: with no focused target, the Clipboard item reads off, matching the default every session starts at")
    }
}
#endif
