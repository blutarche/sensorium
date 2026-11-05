#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumClient
import SensoriumCore

/// The update line sits beneath whichever step is showing, as on macOS: the
/// 12-point muted line, in the warning colour for a failure, with **Restart
/// Now** beside it only when offered. The Sensorium menu carries **Check for
/// Updates…** and **Check for Updates Automatically** once an updater exists.
@MainActor
func testGtkYourMachinesUpdateLineTests() {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: Your Machines' update line needs a scratch Wayland display; set SENSORIUM_GTK_WINDOW_TESTS=1 to check it")
        return
    }
    let host = SavedHost(
        displayName: "Loft",
        host: "mini.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([1]),
        tlsCertificateHash: Data([2])
    )
    let window = GtkYourMachinesWindow(store: InMemorySavedHostStore(hosts: [host]))
    defer { window.hide() }
    var shows = 0
    window.onDidShow = { shows += 1 }
    window.show()
    updateLinePump(seconds: 0.2)
    expect(shows == 1, "the window reports each time it is shown")

    let line = sensorium_gtk_widget(window.updateLineWidget)
    let label = sensorium_gtk_widget(window.updateLabelWidget)
    let restart = sensorium_gtk_widget(window.restartNowWidget)
    let content = gtk_window_get_child(sensorium_gtk_window(window.toplevel))
    expect(gtk_widget_get_last_child(content) == line, "the line is beneath the steps, outside every page")
    expect(gtk_widget_get_visible(line) == 0, "there is no update line until there is something to say")

    var restarts = 0
    window.onRestartNow = { restarts += 1 }
    let ready = "Sensorium 0.5.0 is ready."
    window.setUpdateLine(ViewerUpdateLine(text: ready, offersRestartNow: true))
    updateLinePump(seconds: 0.1)
    expect(gtk_widget_get_visible(line) != 0 && gtk_widget_get_visible(restart) != 0, "a ready update shows its line with Restart Now")
    expect(gtk_label_get_text(sensorium_gtk_label(window.updateLabelWidget)).map { String(cString: $0) } == ready, "the line says what the model says")
    expect(gtk_widget_has_css_class(label, GtkViewerStyle.Class.detail) != 0, "in the 12-point muted line")
    expect(gtk_widget_has_css_class(label, GtkViewerStyle.Class.warn) == 0, "not the warning colour")
    expect(gtk_widget_has_css_class(restart, GtkViewerStyle.Class.secondary) != 0, "Restart Now is a secondary button")
    let restartTitle = gtk_button_get_label(sensorium_gtk_button(window.restartNowWidget)).map { String(cString: $0) }
    expect(restartTitle == ViewerUpdateLine.restartNowTitle, "titled Restart Now, got \(String(describing: restartTitle))")
    _ = gtk_widget_activate(restart)
    expect(restarts == 1, "Restart Now asks for the restart")

    window.setUpdateLine(ViewerUpdateLine(text: ready, offersRestartNow: false))
    expect(gtk_widget_get_visible(line) != 0 && gtk_widget_get_visible(restart) == 0, "during a session the line stays and Restart Now does not")

    window.setUpdateLine(ViewerUpdateLine(
        text: "Sensorium could not update: the download did not match the release. It keeps running 0.4.0.",
        offersRestartNow: false,
        isFailure: true
    ))
    expect(gtk_widget_has_css_class(label, GtkViewerStyle.Class.warn) != 0, "a failure is drawn in the warning colour")
    window.setUpdateLine(ViewerUpdateLine(text: ready, offersRestartNow: false))
    expect(gtk_widget_has_css_class(label, GtkViewerStyle.Class.warn) == 0, "and the next line that is not a failure is muted again")
    window.setUpdateLine(nil)
    expect(gtk_widget_get_visible(line) == 0, "and the line goes once there is nothing to say")

    var checks = 0
    var automatic: [Bool] = []
    window.onCheckForUpdates = { checks += 1 }
    window.onSetChecksAutomatically = { automatic.append($0) }
    window.checksForUpdatesAutomatically = true
    var state = ViewerMenuBarState(canFullScreen: false, zoomEnabled: false)
    state.checksForUpdatesAutomatically = true
    expect(
        window.menuBar.rows() == ViewerMenuPlan.rows(of: LinuxViewerMenu.bar(state)),
        "the Sensorium menu carries the update items exactly as the shared model does"
    )
    expect(window.menuBar.activate(title: "Check for Updates\u{2026}") && checks == 1, "Check for Updates\u{2026} checks")
    expect(
        window.menuBar.activate(title: "Check for Updates Automatically") && automatic == [false],
        "a checked Check for Updates Automatically turns automatic checks off, got \(automatic)"
    )
    print("PASS: Your Machines shows the update line beneath every step and carries the update menu items")
}

private func updateLinePump(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(5_000)
    }
}
#else
func testGtkYourMachinesUpdateLineTests() {}
#endif
