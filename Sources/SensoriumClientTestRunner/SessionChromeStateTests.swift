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

/// A strip closed by Escape or the chord while the pointer rests on the
/// handle's spot stays closed. The handle comes back up under the pointer at
/// that moment, and a compositor reports the pointer entering it; taking that
/// for a fresh approach would open the strip again at once.
func testSessionChromeHandleSpotTests() {
    func liveChrome() -> SessionChromeState {
        var chrome = SessionChromeState()
        var machine = ViewerSessionStateMachine(hostName: "studio")
        chrome.apply(status: machine.handle(.connectStarted), now: 0)
        chrome.apply(status: machine.handle(.canvasReady), now: 1)
        return chrome
    }

    var chrome = liveChrome()
    chrome.toggleStripRequested(now: 2)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 3)
    chrome.pointerOnStrip(isOnHandleSpot: true, now: 3.1)
    expect(chrome.escapePressed(), "Escape closes an open strip the pointer is on")
    expect(!chrome.isStripVisible, "and it is closed")
    expect(chrome.isHandleVisible, "the handle is back")
    chrome.pointerOverHandle(true, now: 3.2)
    expect(!chrome.isStripVisible, "a pointer that never left the handle's spot does not open the strip again")
    chrome.pointerOverHandle(false, now: 4)
    chrome.pointerOverHandle(true, now: 5)
    expect(chrome.isStripVisible, "once it has gone and come back, the handle opens the strip as it always does")

    var chord = liveChrome()
    chord.toggleStripRequested(now: 2)
    chord.pointerOnStrip(isOnHandleSpot: true, now: 3)
    chord.toggleStripRequested(now: 4)
    chord.pointerOverHandle(true, now: 4)
    expect(!chord.isStripVisible, "the chord closes it for good under a pointer on the spot, too")

    var wandering = liveChrome()
    wandering.toggleStripRequested(now: 2)
    wandering.pointerOnStrip(isOnHandleSpot: true, now: 3)
    wandering.pointerOnStrip(isOnHandleSpot: false, now: 3.1)
    expect(wandering.escapePressed(), "Escape closes it from anywhere on the strip")
    wandering.pointerOverHandle(true, now: 4)
    expect(wandering.isStripVisible, "a pointer that had moved off the spot is a fresh approach when it reaches the handle")

    var leaving = liveChrome()
    leaving.toggleStripRequested(now: 2)
    leaving.pointerOnStrip(isOnHandleSpot: true, now: 3)
    leaving.pointerLeftStrip(now: 4)
    expect(leaving.isStripVisible, "a pointer that just left has not closed the strip yet")
    expect(leaving.nextDeadline == 4 + ShortcutStripModel.hideDelaySeconds, "it closes on the strip's own delay, though the pointer left from the spot")
    leaving.tick(now: 4 + ShortcutStripModel.hideDelaySeconds)
    expect(!leaving.isStripVisible, "and is closed once that is up")

    print("PASS: a strip closed with the pointer on the handle's spot stays closed, and one left from the spot still closes on its delay")
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
