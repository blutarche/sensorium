import AppKit
import SensoriumCore

/// The standard menu this app installs as `NSApp.mainMenu`, for whichever of
/// its own windows is key. Apple documents `.accessory` apps as never
/// drawing a menu bar at all, so this guarantees the standard key
/// equivalents -- Cmd-Q through the clean-quit path below, Cmd-W, Cmd-H, the
/// six editing chords reaching a focused text field -- which
/// `NSApplication.sendEvent(_:)` matches against `mainMenu` regardless of
/// activation policy; it does not promise a visible bar while this app stays
/// `.accessory`. Installed once, at launch, exactly like the status item's
/// own menu.
@MainActor
public final class HostMainMenuController: NSObject {
    private let quit: () -> Void

    public init(quit: @escaping () -> Void) {
        self.quit = quit
        super.init()
    }

    public func install(into application: NSApplication) {
        let bar = NSMenu()
        bar.addItem(menuHolder(appMenu()))
        bar.addItem(menuHolder(editMenu()))
        bar.addItem(menuHolder(windowMenu()))
        application.mainMenu = bar
    }

    private func menuHolder(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        // Not the nil-target `orderFrontStandardAboutPanel:`, whose default
        // options draw a plain panel: this app's own credit line comes only
        // from `SensoriumCredit.standardAboutPanelOptions`, the same panel
        // the status item's own About item opens.
        let aboutItem = NSMenuItem(title: "About Sensorium Host", action: #selector(performAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hide Sensorium Host", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        // Not `#selector(NSApplication.terminate(_:))`: quitting this app
        // must tear down every canvas display it created first, the same
        // clean path the status item's own Quit already takes.
        let quitItem = NSMenuItem(title: "Quit Sensorium Host", action: #selector(performQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Left to the responder chain: nothing this app draws implements
        // these, so a window with no text field focused disables them all
        // on its own, the same automatic enabling any system Edit menu uses.
        menu.autoenablesItems = true
        menu.addItem(NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a"))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        return menu
    }

    @objc
    private func performAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: SensoriumCredit.standardAboutPanelOptions)
    }

    @objc
    private func performQuit() {
        quit()
    }
}
