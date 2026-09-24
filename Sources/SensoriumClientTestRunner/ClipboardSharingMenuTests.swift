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
        // `ClipboardSyncEngine.sharingEnabledByDefault`, the state every
        // session actually starts at.
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
            clipboardItem.state == (ClipboardSyncEngine.sharingEnabledByDefault ? .on : .off),
            "with no focused target, the Clipboard item must fall back to sharingEnabledByDefault"
        )
        expect(clipboardItem.state == .on, "which is on: a session starts with sharing on")
        let staticItem = ViewerMenuPlan.menus.first { $0.title == "View" }?.items.first { $0.command == .toggleClipboardSharing }
        expect(
            staticItem?.isSelected == ClipboardSyncEngine.sharingEnabledByDefault,
            "the menu plan's own static state is the same default"
        )

        print("PASS: with no focused target, the Clipboard item reads the default every session starts at, which is on")
    }

    do {
        let limit = ClipboardPolicy.maximumContentBytes
        let sixPointTwoMB = Int(6.2 * 1024 * 1024)
        expect(
            ClipboardRefusalCopy.line(for: .tooLarge(byteCount: sixPointTwoMB, limit: limit))
                == "Clipboard not shared: 6.2 MB is over the 4 MB limit.",
            "a copy over the limit names both sizes in plain words -- got \(String(describing: ClipboardRefusalCopy.line(for: .tooLarge(byteCount: sixPointTwoMB, limit: limit))))"
        )
        expect(
            ClipboardRefusalCopy.line(for: .tooLarge(byteCount: limit + 1, limit: limit))
                == "Clipboard not shared: 4.1 MB is over the 4 MB limit.",
            "a copy just over the limit never reads as the same size as the limit"
        )
        expect(
            ClipboardRefusalCopy.line(for: .tooLarge(byteCount: 3000, limit: 2048))
                == "Clipboard not shared: 3 KB is over the 2 KB limit.",
            "smaller sizes are named in KB"
        )
        expect(
            ClipboardRefusalCopy.line(for: .excludedType)
                == "Clipboard not shared: the app that copied it marked it private, or it is a file.",
            "a marked copy is named for what marked it"
        )
        expect(
            ClipboardRefusalCopy.line(for: .unsupportedContent)
                == "Clipboard not shared: only text and images are shared.",
            "an unsupported copy says what is shared"
        )
        expect(ClipboardRefusalCopy.line(for: .syncDisabled) == nil, "sharing being off is not a notice")
        expect(ClipboardRefusalCopy.line(for: .sessionNotActive) == nil, "nor is a refusal that only describes the session")

        expect(
            ClientSessionRunner.clipboardRefusal(for: .clipboardRefused(.excludedType)) == .excludedType,
            "the host's clipboardRefused reaches the viewer's notice path"
        )
        expect(
            ClientSessionRunner.clipboardRefusal(for: .clipboardSharing(enabled: true)) == nil,
            "and nothing else does"
        )

        print("PASS: a clipboard refusal from either machine becomes one plain sentence, and sharing being off never does")
    }
}
#endif
