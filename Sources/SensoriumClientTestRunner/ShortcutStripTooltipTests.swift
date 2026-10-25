import Foundation
import SensoriumClient
import SensoriumCore

/// What every strip tooltip says, on both platforms: an action names what it
/// does, the machine it does it on, and the chord it sends; the handle names
/// the machine and the chord that opens the strip; the pin says what pressing
/// it would do.
func testShortcutStripTooltipCopyTests() {
    expect(
        ShortcutStripAction.showDesktop.tooltip(hostName: "Workstation") == "Show Desktop on Workstation (F11)",
        "an action's tooltip is its label, the machine, then the chord"
    )
    for action in ShortcutStripAction.allCases {
        expect(
            action.tooltip(hostName: "Workstation") == "\(action.title) on Workstation (\(action.chordDescription))",
            "\(action)'s tooltip follows the one pattern"
        )
        expect(
            ShortcutStripTooltipTarget.action(action).text(hostName: "Workstation", isPinned: false)
                == action.tooltip(hostName: "Workstation"),
            "\(action)'s tooltip target says what the action itself says"
        )
    }
    expect(
        ShortcutStripTooltipTarget.handle.text(hostName: "Workstation", isPinned: false)
            == "Shortcuts for Workstation (\(ViewerKeyNames.shortcutStrip))",
        "the handle names the machine and the chord that opens the strip"
    )
    expect(
        ShortcutStripTooltipTarget.pin.text(hostName: "Workstation", isPinned: false) == "Keep open",
        "an unpinned pin offers to keep the strip open"
    )
    expect(
        ShortcutStripTooltipTarget.pin.text(hostName: "Workstation", isPinned: true) == "Let close",
        "a pinned pin offers to let it close"
    )
    print("PASS: every strip tooltip names what it does, and every action names its machine and chord")
}

/// A Linux strip tooltip appears once the pointer has rested on one item for
/// half a second, and goes on a press, on leaving the item, and when what it
/// names leaves the screen.
func testShortcutStripTooltipTimingTests() {
    let delay = ShortcutStripTooltip.delaySeconds
    expect(delay == 0.5, "a tooltip waits half a second")

    var chrome = SessionChromeState()
    var machine = ViewerSessionStateMachine(hostName: "Workstation")
    chrome.apply(status: machine.handle(.canvasReady), now: 0)
    chrome.toggleStripRequested(now: 0)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 0)

    chrome.pointerRests(onTooltipTarget: .action(.showDesktop), now: 1)
    expect(chrome.stripTooltip == nil, "no tooltip before the pointer has rested")
    expect(chrome.nextDeadline == 1 + delay, "the window is woken when the rest is long enough")
    chrome.tick(now: 1 + delay - 0.01)
    expect(chrome.stripTooltip == nil, "not a moment early")
    chrome.tick(now: 1 + delay)
    expect(chrome.stripTooltip == .action(.showDesktop), "the tooltip for the item under the pointer appears")
    expect(chrome.nextDeadline == nil, "and nothing is left to wake for")

    chrome.pointerRests(onTooltipTarget: .action(.showDesktop), now: 2)
    expect(chrome.stripTooltip == .action(.showDesktop), "moving within the same item keeps it")

    chrome.pointerRests(onTooltipTarget: .action(.spotlight), now: 3)
    expect(chrome.stripTooltip == nil, "moving to another item hides it")
    chrome.tick(now: 3 + delay)
    expect(chrome.stripTooltip == .action(.spotlight), "and the next item's appears after its own rest")

    chrome.pointerRests(onTooltipTarget: nil, now: 4)
    expect(chrome.stripTooltip == nil, "leaving the item hides it")
    expect(chrome.nextDeadline == nil, "and leaves nothing to wake for")

    chrome.pointerRests(onTooltipTarget: .action(.showDesktop), now: 5)
    chrome.tick(now: 5 + delay)
    _ = chrome.pressStrip(.showDesktop)
    expect(chrome.stripTooltip == nil, "a press hides it")
    chrome.pointerRests(onTooltipTarget: .action(.showDesktop), now: 6)
    chrome.tick(now: 7)
    expect(chrome.stripTooltip == nil, "and it stays hidden while the pointer stays on the item it pressed")
    chrome.pointerRests(onTooltipTarget: nil, now: 8)
    chrome.pointerRests(onTooltipTarget: .action(.showDesktop), now: 8)
    chrome.tick(now: 8 + delay)
    expect(chrome.stripTooltip == .action(.showDesktop), "until the pointer leaves and comes back")

    expect(chrome.escapePressed(), "Escape closes the strip the pointer is in")
    expect(chrome.stripTooltip == nil, "and the strip closing takes its tooltip with it")
    chrome.toggleStripRequested(now: 10)
    chrome.tick(now: 11)
    expect(chrome.stripTooltip == nil, "a strip opened again does not bring back a tooltip nobody rested for")

    chrome.pointerOnStrip(isOnHandleSpot: false, now: 12)
    chrome.pointerRests(onTooltipTarget: .action(.lockScreen), now: 12)
    chrome.tick(now: 12 + delay)
    expect(chrome.pressStrip(.lockScreen) == .askToConfirm, "Lock Screen asks first")
    chrome.pointerRests(onTooltipTarget: .action(.quitApp), now: 13)
    chrome.tick(now: 13 + delay)
    expect(chrome.stripTooltip == nil, "the question replaces the actions, so none of them has a tooltip")
    chrome.pointerRests(onTooltipTarget: .pin, now: 14)
    chrome.tick(now: 14 + delay)
    expect(chrome.stripTooltip == .pin, "the pin stays beside the question, and keeps its tooltip")
    chrome.togglePinRequested(now: 15)
    expect(chrome.stripTooltip == nil, "pressing the pin hides its tooltip")
    chrome.cancelPendingStripAction()
    chrome.togglePinRequested(now: 15)

    chrome.pointerRests(onTooltipTarget: .handle, now: 16)
    chrome.tick(now: 16 + delay)
    expect(chrome.stripTooltip == nil, "an open strip covers the handle, so the handle has no tooltip")

    chrome.toggleStripRequested(now: 17)
    expect(!chrome.isStripVisible && chrome.isHandleVisible, "the chord closes the strip and the handle is back")
    chrome.pointerRests(onTooltipTarget: .handle, now: 18)
    chrome.tick(now: 18 + delay)
    expect(chrome.stripTooltip == .handle, "the handle has its tooltip while it shows")

    chrome.pointerOverHandle(true, now: 19)
    chrome.pointerOnStrip(isOnHandleSpot: true, now: 19)
    expect(chrome.isStripVisible, "hovering the handle opens the strip immediately")
    expect(chrome.escapePressed(), "Escape closes the strip over the handle spot")
    chrome.pointerOverHandle(true, now: 19)
    chrome.pointerRests(onTooltipTarget: .handle, now: 19)
    chrome.tick(now: 19.5)
    expect(chrome.stripTooltip == .handle, "the handle tooltip appears after deliberate close suppresses reopening")

    chrome.apply(status: machine.handle(.sessionEnded), now: 20)
    expect(chrome.stripTooltip == nil, "a session that is not live has no handle, and no tooltip")
    print("PASS: a strip tooltip waits half a second, and goes on a press, on leaving, and with what it names")
}

/// Below the item it names, above it when there is no room below, and never
/// past the window's left or right edge.
func testShortcutStripTooltipPlacementTests() {
    let item = ViewerChromeRect(x: 600, y: 10, width: 28, height: 28)
    let below = WaylandOverlayLayout.tooltip(below: item, width: 200, height: 24, windowWidth: 1280, windowHeight: 800)
    let gap = WaylandOverlayLayout.tooltipGap
    expect(below.y == item.y + item.height + gap, "the tooltip sits just below the item, got \(below)")
    expect(below.x == 514, "centred on the item, got \(below)")
    expect(below.width == 200 && below.height == 24, "at the size it measured, got \(below)")

    let low = ViewerChromeRect(x: 600, y: 770, width: 28, height: 28)
    let above = WaylandOverlayLayout.tooltip(below: low, width: 200, height: 24, windowWidth: 1280, windowHeight: 800)
    expect(above.y + above.height == low.y - gap, "with no room below it flips above the item, got \(above)")

    let atRight = ViewerChromeRect(x: 1240, y: 10, width: 28, height: 28)
    let right = WaylandOverlayLayout.tooltip(below: atRight, width: 200, height: 24, windowWidth: 1280, windowHeight: 800)
    expect(right.x + right.width <= 1280 - gap, "an item at the right edge keeps its tooltip inside the window, got \(right)")

    let atLeft = ViewerChromeRect(x: 4, y: 10, width: 28, height: 28)
    let left = WaylandOverlayLayout.tooltip(below: atLeft, width: 200, height: 24, windowWidth: 1280, windowHeight: 800)
    expect(left.x >= gap, "and so does one at the left edge, got \(left)")

    let odd = ViewerChromeRect(x: 600.5, y: 10, width: 28, height: 28)
    let snapped = WaylandOverlayLayout.tooltip(below: odd, width: 201, height: 24, windowWidth: 1280, windowHeight: 800)
    expect(
        snapped.x == snapped.x.rounded() && snapped.y == snapped.y.rounded(),
        "it sits on whole logical units, as a subsurface does, got \(snapped)"
    )
    print("PASS: a strip tooltip sits below its item, flips above it at the bottom, and stays inside the window")
}

@MainActor
func testShortcutStripEscapeRoutingTests() {
    final class Keyboard: WaylandKeyTranslating {
        var modifiers: CanvasModifierFlags = []
        var translations = 0
        func key(evdev: UInt32, isDown: Bool) -> CanvasSurfaceEvent? {
            translations += 1
            return .key(keyCode: 53, isDown: isDown, modifiers: modifiers)
        }
        func character(evdev: UInt32) -> String? { nil }
    }
    let keyboard = Keyboard()
    var forwarded = WaylandForwardedKeys()
    var chrome = SessionChromeState()
    var machine = ViewerSessionStateMachine(hostName: "Workstation")
    chrome.apply(status: machine.handle(.canvasReady), now: 0)
    chrome.toggleStripRequested(now: 0)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 0)
    func key(_ down: Bool) -> WaylandKeyDestination {
        WaylandKeyPath.destination(evdev: 1, isDown: down, keyboard: keyboard, menu: nil,
                                   forwarded: &forwarded, chrome: &chrome)
    }
    expect(key(true) == .dropped, "Escape over the open strip is consumed")
    expect(!chrome.isStripVisible, "Escape closes an unpinned strip")
    expect(key(true) == .dropped, "a repeated consumed Escape stays local")
    keyboard.modifiers = [.shift]
    expect(key(false) == .dropped, "the release stays local even if modifiers changed")
    expect(keyboard.translations == 3, "each key is translated exactly once")
    keyboard.modifiers = []
    expect(key(true) == .canvas(.key(keyCode: 53, isDown: true, modifiers: [])), "closed chrome leaves Escape to the host")
    forwarded.noteForwarded(evdev: 1)
    chrome.toggleStripRequested(now: 0)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 0)
    expect(key(false) == .canvas(.key(keyCode: 53, isDown: false, modifiers: [])), "the host receives a release owed before the strip opened")
    chrome.togglePinRequested(now: 0)
    expect(key(true) == .dropped, "Escape over a pinned strip is consumed, matching the shared model")
    expect(!chrome.isStripVisible, "Escape closes a pinned strip too")
    expect(key(false) == .dropped, "a pinned strip's consumed release stays local")
    chrome.toggleStripRequested(now: 0)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 0)
    _ = chrome.pressStrip(.lockScreen)
    expect(key(true) == .dropped, "a pinned confirmation consumes Escape")
    expect(!chrome.isStripVisible, "the pinned confirmation closes")
    forwarded.removeAll()
    expect(key(false) == .canvas(.key(keyCode: 53, isDown: false, modifiers: [])), "focus loss clears consumed-key memory")
    print("PASS: Linux Escape closes eligible strips, consumes repeats and release, and preserves host releases")
}

#if canImport(CCairo)
@MainActor
func testShortcutStripTooltipPaintTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = root.appendingPathComponent("Artifacts/r6-tooltip-tests/\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }
    var chrome = SessionChromeState()
    var machine = ViewerSessionStateMachine(hostName: "Workstation")
    chrome.apply(status: machine.handle(.canvasReady), now: 0)
    chrome.toggleStripRequested(now: 0)
    chrome.pointerOnStrip(isOnHandleSpot: false, now: 0)
    let width = 1280.0
    let entries = SessionChromeRenderPreview.stripButtonRects(hostName: "Workstation", width: width)
    expect(entries.count == 11, "every action and the pin have hit regions")
    for entry in entries {
        let target = SessionChromeRenderPreview.stripTooltipTarget(
            atX: entry.x + entry.width / 2, y: entry.y + entry.height / 2,
            visibility: .shown, hostName: "Workstation", width: width)
        expect(target != nil, "every painted strip item is a tooltip target")
        chrome.pointerRests(onTooltipTarget: target, now: 0)
        chrome.tick(now: 0.499)
        expect(chrome.stripTooltip == nil, "a hit-tested item waits the full delay")
        chrome.tick(now: 0.5)
        expect(chrome.stripTooltip == target, "a hit-tested item shows after 500ms")
        chrome.pointerRests(onTooltipTarget: nil, now: 0.6)
    }
    for target in [ShortcutStripTooltipTarget.action(.showDesktop), .pin, .handle] {
        if target == .handle { _ = chrome.escapePressed() }
        chrome.pointerRests(onTooltipTarget: target, now: 1)
        chrome.tick(now: 1.5)
        let rect = SessionChromeRenderPreview.stripTooltipRect(state: chrome, hostName: "Workstation", windowWidth: width, windowHeight: 800)
        expect(rect != nil, "the shown tooltip has shipping paint geometry")
        expect((rect?.x ?? -1) >= 0 && (rect?.width ?? 2000) <= width, "tooltip stays inside the window")
        for scale in [1.0, 1.5] {
            let hidden = output.appendingPathComponent("hidden.png")
            let shown = output.appendingPathComponent("shown.png")
            expect(SessionChromeRenderPreview.renderComposite(state: chrome, hostName: "Workstation", windowWidth: width, windowHeight: 800, scale: scale, to: shown), "shown tooltip renders")
            var noTooltip = chrome
            noTooltip.stripPointerPressed()
            expect(SessionChromeRenderPreview.renderComposite(state: noTooltip, hostName: "Workstation", windowWidth: width, windowHeight: 800, scale: scale, to: hidden), "pressed tooltip renders")
            expect((try! Data(contentsOf: shown)) != (try! Data(contentsOf: hidden)), "a delayed tooltip adds actual pixels at \(scale)x")
        }
        chrome.pointerRests(onTooltipTarget: nil, now: 2)
    }
    print("PASS: all strip hit regions schedule tooltips and Cairo paints action, pin and handle tooltips at 1x and 1.5x")
}
#else
@MainActor
func testShortcutStripTooltipPaintTests() {}
#endif
