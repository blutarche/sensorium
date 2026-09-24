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

    print("PASS: the session window's chrome shows the panel, the strip, the notice and the diagnostics on the states that ask for them")
}

/// The chord that opens the session controls window on a desktop with no
/// menu bar to hang those choices off. Named beside the strip's own chord,
/// for the same reason: it belongs to the machine the person is sitting at.
func testSessionControlsChordTests() {
    let chord = SystemShortcutCatalog.sessionControlsToggle
    expect(
        SystemShortcutCatalog.shortcut(for: chord) == nil,
        "the session controls chord is never forwarded to the machine being worked on"
    )
    expect(
        chord != SystemShortcutCatalog.shortcutStripToggle && chord != SystemShortcutCatalog.escapeGesture,
        "it is not one of the two chords the viewer already keeps for itself"
    )
    expect(
        !ViewerKeyNames.sessionControls.isEmpty,
        "the chord is spelled out for the person who has to press it"
    )

    print("PASS: the session controls chord is the viewer's own, never forwarded, and spelled out for the person pressing it")
}
