import AppKit
import Foundation
import SensoriumHost

/// The standard main menu bar this app draws while one of its own windows is
/// key: an App menu with the usual credits and quit, an Edit menu left to
/// the responder chain's own automatic enabling, and a Window menu for
/// whichever window is key. The app stays `.accessory`, so none of this adds
/// a Dock icon; it only appears once a window of this app's own is key.
@MainActor
func runHostMainMenuTests() async {
    var quitCount = 0
    let controller = HostMainMenuController(quit: { quitCount += 1 })
    let application = NSApplication.shared
    controller.install(into: application)

    guard let bar = application.mainMenu else {
        expect(false, "install(into:) sets the application's main menu")
        return
    }
    let titles = bar.items.map { $0.submenu?.title ?? $0.title }
    expect(titles.count == 3, "the menu bar has an App, Edit and Window menu, got \(titles)")

    guard let appMenu = bar.items.first?.submenu else {
        expect(false, "the App menu exists")
        return
    }
    let appTitles = appMenu.items.map(\.title)
    expect(
        appTitles == [
            "About Sensorium Host", "", "Hide Sensorium Host", "Hide Others", "Show All", "", "Quit Sensorium Host"
        ],
        "the App menu offers About, Hide, Hide Others, Show All and Quit in the standard order, got \(appTitles)"
    )
    guard let aboutItem = appMenu.items.first(where: { $0.title == "About Sensorium Host" }) else {
        expect(false, "About exists")
        return
    }
    expect(
        aboutItem.target === controller,
        "About is not the nil-target orderFrontStandardAboutPanel:, whose default options draw a plain panel -- "
            + "it must open the same credited panel the status item's own About item does"
    )
    guard let quitItem = appMenu.items.first(where: { $0.title == "Quit Sensorium Host" }) else {
        expect(false, "Quit exists")
        return
    }
    expect(quitItem.keyEquivalent == "q", "Quit is Cmd-Q, got \"\(quitItem.keyEquivalent)\"")
    _ = quitItem.target?.perform(quitItem.action, with: nil)
    expect(quitCount == 1, "Quit goes through the host's own clean-quit path, got \(quitCount) calls")

    guard let editMenu = bar.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
        expect(false, "the Edit menu exists")
        return
    }
    expect(
        editMenu.autoenablesItems,
        "the Edit menu enables and disables its items automatically, by whatever implements them in the responder chain"
    )
    let editTitles = editMenu.items.map(\.title)
    expect(
        editTitles == ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All"],
        "the Edit menu offers the six standard commands in the standard order, got \(editTitles)"
    )

    guard let windowMenu = bar.items.first(where: { $0.submenu?.title == "Window" })?.submenu else {
        expect(false, "the Window menu exists")
        return
    }
    let windowTitles = windowMenu.items.map(\.title)
    expect(
        windowTitles == ["Close", "Minimize", "Zoom"],
        "the Window menu is Close, Minimize, Zoom, got \(windowTitles)"
    )
    guard let closeItem = windowMenu.items.first(where: { $0.title == "Close" }),
          let minimizeItem = windowMenu.items.first(where: { $0.title == "Minimize" }) else {
        expect(false, "Close and Minimize exist")
        return
    }
    expect(closeItem.keyEquivalent == "w", "Close is Cmd-W, got \"\(closeItem.keyEquivalent)\"")
    expect(minimizeItem.keyEquivalent == "m", "Minimize is Cmd-M, got \"\(minimizeItem.keyEquivalent)\"")

    print("PASS: the host's own windows get a standard App, Edit and Window menu, with Quit going through the clean-quit path")
}
