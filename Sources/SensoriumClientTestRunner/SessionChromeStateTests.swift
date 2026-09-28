import Foundation
import SensoriumClient
import SensoriumCore

/// What the session window's chrome is showing at any moment, and what each
/// thing the viewer pushes at it changes. One value, so the four overlays a
/// Wayland window draws are decided without a compositor and drawn from a
/// state a runner can hold in its hand.
func testSessionChromeStateTests() {
    var chrome = SessionChromeState()
    var machine = ViewerSessionStateMachine(hostName: "studio")

    chrome.apply(status: machine.handle(.connectStarted), now: 0)
    expect(chrome.isStatusPanelVisible, "a session that is not live shows its status panel")
    expect(!chrome.isHandleVisible, "there is nothing to send a shortcut to before the session is live")
    expect(chrome.isScrimVisible, "a scrim belongs behind the panel even with no picture underneath yet")
    expect(chrome.isScrimOpaque, "the first connect has no picture yet, so that scrim is the opaque fill, not the translucent one")

    chrome.apply(status: machine.handle(.canvasReady), now: 1)
    expect(!chrome.isStatusPanelVisible, "a live session shows nothing over the picture")
    expect(chrome.isHandleVisible, "a live session leaves the handle, which is the one way into the strip")
    expect(!chrome.isStripVisible, "the strip itself stays closed until it is asked for")

    chrome.toggleStripRequested(now: 1)
    expect(chrome.isStripVisible, "the summoning chord opens the strip")
    chrome.toggleStripRequested(now: 1)
    expect(!chrome.isStripVisible, "the same chord closes it again")

    chrome.pointerOverHandle(true, now: 2)
    expect(chrome.isStripVisible, "hovering the handle opens the strip at once")
    chrome.pointerOverHandle(false, now: 2)
    expect(chrome.isStripVisible, "a pointer that just left has not closed it yet")
    expect(chrome.nextDeadline == 2 + ShortcutStripModel.hideDelaySeconds, "it closes on the strip's own delay")
    chrome.tick(now: 2 + ShortcutStripModel.hideDelaySeconds)
    expect(!chrome.isStripVisible, "and it is closed once that delay is up")

    chrome.showNotice("The host refused a second display.", now: 10)
    expect(chrome.notice == "The host refused a second display.", "a refusal is shown as a transient notice")
    chrome.tick(now: 10 + WaylandOverlayLayout.noticeAutoDismissSeconds - 0.5)
    expect(chrome.notice != nil, "the notice stays up long enough to read")
    chrome.tick(now: 10 + WaylandOverlayLayout.noticeAutoDismissSeconds)
    expect(chrome.notice == nil, "and takes itself away afterwards")

    expect(!chrome.isDiagnosticsVisible, "the diagnostics panel is off until it is asked for")
    chrome.toggleDiagnosticsRequested()
    expect(chrome.isDiagnosticsVisible, "the diagnostics chord shows it")
    chrome.toggleDiagnosticsRequested()
    expect(!chrome.isDiagnosticsVisible, "and hides it again")

    chrome.apply(status: machine.handle(.sessionEnded), now: 20)
    expect(chrome.isStatusPanelVisible, "a lost session brings the panel back")
    expect(!chrome.isHandleVisible && !chrome.isStripVisible, "and takes the strip and its handle away with it")
    expect(chrome.isScrimVisible, "a session that was live leaves a picture behind, so the panel now sits on a scrim")
    expect(!chrome.isScrimOpaque, "and that scrim is the translucent one, marking the frozen picture behind it as stale")

    print("PASS: the session window's chrome shows the panel, the strip, the notice and the diagnostics on the states that ask for them")
}

/// The session controls live in the menu bar now, so Control-Shift-Command-K
/// is ordinary typing again and reaches the machine being worked on.
func testSessionControlsChordTests() {
    let event = CanvasSurfaceEvent.key(keyCode: 40, isDown: true, modifiers: [.command, .control, .shift])
    expect(
        WaylandKeyPath.destination(for: event) == .canvas(event),
        "Control-Shift-Command-K goes to the canvas, got \(WaylandKeyPath.destination(for: event))"
    )

    print("PASS: the old session controls chord is no longer kept by the viewer")
}
