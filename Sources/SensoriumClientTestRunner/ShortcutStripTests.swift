#if canImport(AppKit)
import AppKit
import SensoriumClient
import SensoriumCore

/// Every key code the strip is allowed to send, stated here independently of
/// the source so a typo in either one is a failure rather than a shared
/// mistake. Carbon virtual key codes, except 131, which is what macOS reports
/// for the Launchpad key.
private let permittedKeyCodes: Set<UInt16> = [126, 125, 124, 123, 103, 49, 131, 48, 12, 55, 59, 56, 58]

private let modifierKeyCodes: Set<UInt16> = [55, 59, 56, 58]

func testShortcutStripTests() {
    // A chord sent to the far machine must leave nothing held there. Every action
    // is checked as a whole sequence: each key goes down exactly once and comes
    // back up exactly once, the modifiers are the last thing released, and the
    // flags carried by the final event are empty -- so a person who presses
    // Mission Control does not end up with Control stuck down on the machine they
    // are working on.
    for action in ShortcutStripAction.allCases {
        let events = action.events()
        expect(!events.isEmpty, "\(action) sends at least one event")

        var downCounts: [UInt16: Int] = [:]
        var upCounts: [UInt16: Int] = [:]
        var lastModifiers: CanvasModifierFlags = []
        for event in events {
            guard case let .key(keyCode, isDown, modifiers) = event else {
                expect(false, "\(action) sends only key events")
                return
            }
            expect(
                permittedKeyCodes.contains(keyCode),
                "\(action) sends key code \(keyCode), which is not one the strip may send"
            )
            expect(
                modifiers.isSubset(of: CanvasModifierFlags.all),
                "\(action) sends only modifier flags the protocol carries"
            )
            if isDown {
                downCounts[keyCode, default: 0] += 1
            } else {
                upCounts[keyCode, default: 0] += 1
            }
            lastModifiers = modifiers
        }
        expect(downCounts == upCounts, "\(action) releases every key it pressed, exactly once each")
        expect(
            downCounts.values.allSatisfy { $0 == 1 },
            "\(action) presses each key exactly once"
        )
        expect(lastModifiers.isEmpty, "\(action) leaves no modifier held on the far machine")

        // The main key is the one that is not a modifier, and it must be
        // pressed while every modifier of the chord is already down and
        // released before any of them comes back up.
        let mainKeyIndices = events.indices.filter { index in
            guard case let .key(keyCode, _, _) = events[index] else { return false }
            return !modifierKeyCodes.contains(keyCode)
        }
        expect(mainKeyIndices.count == 2, "\(action) presses and releases exactly one main key")
        if let first = mainKeyIndices.first, let last = mainKeyIndices.last {
            let modifierDowns = events.prefix(first).count
            let modifierUps = events.count - last - 1
            expect(
                modifierDowns == modifierUps,
                "\(action) presses its modifiers before the main key and releases them after it"
            )
            expect(last == first + 1, "\(action) sends the main key's own down and up back to back")
        }
    }

    // The two chords whose exact wire sequence the strip exists to produce.
    // Cmd-Tab is the one a person cannot type into the canvas at all, and
    // Ctrl-Cmd-Q is the one with two modifiers, which is where a release
    // order could go wrong unnoticed.
    expect(
        ShortcutStripAction.switchApp.events() == [
            .key(keyCode: 55, isDown: true, modifiers: [.command]),
            .key(keyCode: 48, isDown: true, modifiers: [.command]),
            .key(keyCode: 48, isDown: false, modifiers: [.command]),
            .key(keyCode: 55, isDown: false, modifiers: [])
        ],
        "Switch App sends Command down, Tab down and up, Command up"
    )
    expect(
        ShortcutStripAction.lockScreen.events() == [
            .key(keyCode: 59, isDown: true, modifiers: [.control]),
            .key(keyCode: 55, isDown: true, modifiers: [.control, .command]),
            .key(keyCode: 12, isDown: true, modifiers: [.control, .command]),
            .key(keyCode: 12, isDown: false, modifiers: [.control, .command]),
            .key(keyCode: 55, isDown: false, modifiers: [.control]),
            .key(keyCode: 59, isDown: false, modifiers: [])
        ],
        "Lock Screen releases its two modifiers in the reverse of the order it pressed them"
    )
    expect(
        ShortcutStripAction.showDesktop.events() == [
            .key(keyCode: 103, isDown: true, modifiers: []),
            .key(keyCode: 103, isDown: false, modifiers: [])
        ],
        "a chord with no modifier is one key down and up"
    )
    expect(
        ShortcutStripAction.launchpad.events().contains {
            $0 == .key(keyCode: 131, isDown: true, modifiers: [])
        },
        "Launchpad sends the key code macOS reports for the Launchpad key"
    )

    // What a person reads before pressing. The strip has no room to explain
    // itself, so the label has to be short and the tooltip has to name both
    // the chord and the machine it is going to.
    var seenTitles: Set<String> = []
    for action in ShortcutStripAction.allCases {
        expect(!action.title.isEmpty, "\(action) has a label")
        expect(seenTitles.insert(action.title).inserted, "\(action)'s label is not used twice")
        expect(
            action.tooltip(hostName: "Studio").contains("Studio"),
            "\(action)'s tooltip names the machine it sends to"
        )
    }
    expect(
        ShortcutStripAction.missionControl.tooltip(hostName: "Studio") == "Sends Control-Up to Studio",
        "the tooltip says what is sent and where it goes"
    )

    // A four-finger swipe moves between the host's desktops, and that gesture
    // can never reach a captured screen, so the strip is where it lives
    // instead. The two buttons sit right after the other window-management
    // ones, before the strip moves on to launching and finding things.
    expect(
        ShortcutStripAction.allCases == [
            .missionControl, .applicationWindows, .desktopLeft, .desktopRight,
            .showDesktop, .spotlight, .launchpad, .switchApp, .lockScreen, .quitApp
        ],
        "Desktop Left and Desktop Right sit right after App Windows"
    )
    expect(
        ShortcutStripAction.desktopLeft.tooltip(hostName: "Studio") == "Sends Control-Left to Studio",
        "Desktop Left sends Control-Left"
    )
    expect(
        ShortcutStripAction.desktopRight.tooltip(hostName: "Studio") == "Sends Control-Right to Studio",
        "Desktop Right sends Control-Right"
    )
    expect(
        !ShortcutStripAction.desktopLeft.needsConfirmation && !ShortcutStripAction.desktopRight.needsConfirmation,
        "moving between desktops is cheap to mis-click, so neither asks first"
    )

    // Locking a machine you are working on remotely, or quitting the app in
    // front of you there, is not something to do on a mis-click.
    for action in ShortcutStripAction.allCases {
        let expected = action == .lockScreen || action == .quitApp
        expect(
            action.needsConfirmation == expected,
            "\(action) asks first only when the thing it does is disruptive"
        )
        let confirmation = action.confirmation(hostName: "Studio")
        expect(
            (confirmation != nil) == expected,
            "\(action) offers a confirmation exactly when it needs one"
        )
        if let confirmation {
            expect(
                confirmation.question.contains("Studio"),
                "\(action)'s confirmation names the machine it would act on"
            )
            expect(!confirmation.confirmTitle.isEmpty, "\(action)'s confirmation has a button that goes ahead")
            expect(confirmation.cancelTitle == "Cancel", "\(action)'s confirmation has a way out")
        }
    }

    print("PASS: every shortcut the strip sends is a balanced chord that leaves no key held on the far machine")
}

func testShortcutStripVisibilityTests() {
    let hide = ShortcutStripModel.hideDelaySeconds

    // The handle is the whole of what a live session puts over the picture:
    // one small tab at the top, and nothing at all when there is no session to
    // send shortcuts to.
    var model = ShortcutStripModel()
    expect(!model.isHandleVisible, "there is no handle before the session is live")
    model.phaseChanged(.live, now: 0)
    expect(model.isHandleVisible, "a live session shows the handle")
    expect(model.visibility == .hidden, "a live session starts with only the handle over the picture")

    // Hovering the handle opens the strip at once. There is no delay to wait
    // out: the handle is a visible target, so the pointer being on it is
    // already the deliberate approach a delay would have been proving.
    model.pointerOverHandle(true, now: 0)
    expect(model.visibility == .shown, "hovering the handle opens the strip with no delay")

    // Leaving hides it, but not instantly: a pointer that slips off the strip
    // on the way to a button must not have it vanish underneath.
    model.pointerOverStrip(true, now: 1)
    model.pointerOverHandle(false, now: 1)
    expect(model.visibility == .shown, "moving from the handle onto the strip keeps it open")
    model.pointerOverStrip(false, now: 2)
    expect(model.visibility == .hiding, "leaving the strip starts the hide")
    model.tick(now: 2 + hide - 0.01)
    expect(model.visibility == .hiding, "the strip stays up until the hide delay is up")
    model.tick(now: 2 + hide)
    expect(model.visibility == .hidden, "the strip closes a second after the pointer leaves")

    var returning = ShortcutStripModel()
    returning.phaseChanged(.live, now: 0)
    returning.pointerOverHandle(true, now: 0)
    returning.pointerOverHandle(false, now: 1)
    returning.pointerOverStrip(true, now: 1.2)
    expect(returning.visibility == .shown, "coming back before the hide finishes keeps the strip up")
    returning.tick(now: 1 + hide)
    expect(returning.visibility == .shown, "the abandoned hide does not fire under the pointer")

    // A click on the handle is the other way in, and the way back out. The
    // pointer is still on the handle after the closing click, and that must
    // not immediately reopen what the click just closed.
    var clicking = ShortcutStripModel()
    clicking.phaseChanged(.live, now: 0)
    clicking.pointerOverHandle(true, now: 0)
    clicking.handleClicked()
    expect(clicking.visibility == .hidden, "clicking the handle again closes the strip")
    clicking.pointerOverHandle(true, now: 0.1)
    expect(clicking.visibility == .hidden, "a pointer still resting on the handle does not reopen it")
    clicking.pointerOverHandle(false, now: 0.2)
    clicking.pointerOverHandle(true, now: 0.3)
    expect(clicking.visibility == .shown, "hovering the handle afresh opens it again")
    clicking.handleClicked()
    expect(clicking.visibility == .hidden, "and the click closes it again")

    var clickOpens = ShortcutStripModel()
    clickOpens.phaseChanged(.live, now: 0)
    clickOpens.handleClicked()
    expect(clickOpens.visibility == .shown, "clicking the handle opens the strip")

    // Escape is the keyboard's way out of a strip the pointer is in. It is
    // taken only there: anywhere else it is an ordinary keystroke the machine
    // being worked on is entitled to.
    var escaping = ShortcutStripModel()
    escaping.phaseChanged(.live, now: 0)
    expect(!escaping.escapePressed(), "Escape over the picture is not the strip's to take")
    escaping.pointerOverHandle(true, now: 0)
    escaping.pointerOverStrip(true, now: 0)
    escaping.pointerOverHandle(false, now: 0)
    expect(escaping.escapePressed(), "Escape over the open strip closes it")
    expect(escaping.visibility == .hidden, "and the strip is gone at once, with no hide delay")
    expect(!escaping.escapePressed(), "a strip already closed takes no further Escape")

    // The strip sends input to a machine, so it exists only while there is a
    // live session to send to. A session that drops takes it away at once
    // rather than leaving buttons over a frozen picture.
    var offline = ShortcutStripModel()
    offline.pointerOverHandle(true, now: 0)
    expect(offline.visibility == .hidden, "nothing opens before the session is live")
    offline.handleClicked()
    expect(offline.visibility == .hidden, "there is no handle to click before the session is live")
    offline.toggleRequested()
    expect(offline.visibility == .hidden, "the chord opens nothing before the session is live")
    offline.phaseChanged(.live, now: 10)
    expect(offline.visibility == .hidden, "a session going live opens nothing on its own")
    offline.toggleRequested()
    expect(offline.visibility == .shown, "the chord opens the strip at once")
    offline.toggleRequested()
    expect(offline.visibility == .hidden, "the chord closes it again")
    offline.toggleRequested()
    offline.phaseChanged(.reconnecting, now: 20)
    expect(offline.visibility == .hidden, "a session that drops takes the strip with it")
    expect(!offline.isHandleVisible, "and the handle with it")

    // A strip on its way out is still on its way out. The chord or a click on
    // the tab during that second brings it back, rather than closing what is
    // already closing and leaving the pointer with nothing to show for it.
    var reopening = ShortcutStripModel()
    reopening.phaseChanged(.live, now: 0)
    reopening.pointerOverHandle(true, now: 0)
    reopening.pointerOverHandle(false, now: 1)
    expect(reopening.visibility == .hiding, "the pointer left, so the strip is on its way out")
    reopening.toggleRequested()
    expect(reopening.visibility == .shown, "the chord during the hide brings the strip back")
    reopening.pointerOverHandle(true, now: 1.1)
    reopening.pointerOverHandle(false, now: 1.2)
    expect(reopening.visibility == .hiding, "and it starts hiding again once the pointer leaves")
    reopening.handleClicked()
    expect(reopening.visibility == .shown, "a click on the tab during the hide brings it back too")

    // Closing on purpose forgets where the pointer was. What is left behind
    // has to be the same state as a strip closed with the pointer on the tab
    // alone, or the strip carries a belief about the pointer that outlived it.
    var closedOverStrip = ShortcutStripModel()
    closedOverStrip.phaseChanged(.live, now: 0)
    closedOverStrip.pointerOverHandle(true, now: 0)
    closedOverStrip.pointerOverStrip(true, now: 0)
    closedOverStrip.handleClicked()
    var closedOverHandle = ShortcutStripModel()
    closedOverHandle.phaseChanged(.live, now: 0)
    closedOverHandle.pointerOverHandle(true, now: 0)
    closedOverHandle.handleClicked()
    expect(
        closedOverStrip == closedOverHandle,
        "a strip closed on purpose remembers nothing about where the pointer was"
    )

    // A press either fires or asks. Asking replaces the row with one question,
    // and the answer is what fires -- so a mis-click on Lock Screen costs a
    // click on Cancel and nothing else.
    var confirming = ShortcutStripModel()
    confirming.phaseChanged(.live, now: 0)
    expect(confirming.press(.spotlight) == nil, "a strip nobody can see sends nothing")
    confirming.toggleRequested()
    expect(confirming.press(.spotlight) == .send(.spotlight), "an ordinary shortcut fires on the press")
    expect(confirming.visibility == .shown, "firing one leaves the strip as it was")
    expect(
        confirming.press(.lockScreen) == .askToConfirm,
        "a disruptive shortcut asks first"
    )
    expect(confirming.visibility == .confirming(.lockScreen), "the strip shows the question it asked")
    confirming.cancelPending()
    expect(confirming.visibility == .shown, "cancelling puts the buttons back")
    expect(confirming.confirmPending() == nil, "there is nothing left to confirm after a cancel")
    _ = confirming.press(.quitApp)
    expect(confirming.confirmPending() == .quitApp, "confirming fires the shortcut that was asked about")
    expect(confirming.visibility == .shown, "answering the question puts the buttons back")

    // A question that scrolls off with the strip is not a question anyone
    // answered, and it must not be waiting the next time the strip opens.
    var abandoned = ShortcutStripModel()
    abandoned.phaseChanged(.live, now: 0)
    abandoned.pointerOverHandle(true, now: 0)
    abandoned.pointerOverStrip(true, now: 0)
    _ = abandoned.press(.lockScreen)
    expect(abandoned.visibility == .confirming(.lockScreen), "the question is up")
    abandoned.pointerOverHandle(false, now: 1)
    abandoned.pointerOverStrip(false, now: 1)
    expect(abandoned.visibility == .hiding, "the pointer leaving hides the strip, question and all")
    abandoned.pointerOverStrip(true, now: 1.5)
    expect(
        abandoned.visibility == .confirming(.lockScreen),
        "a pointer that comes straight back finds the question it left"
    )
    abandoned.pointerOverStrip(false, now: 2)
    abandoned.tick(now: 2 + hide)
    expect(abandoned.visibility == .hidden, "the strip closed with a question on it")
    abandoned.toggleRequested()
    expect(abandoned.visibility == .shown, "the strip comes back with its buttons, not the abandoned question")
    expect(abandoned.confirmPending() == nil, "a question nobody answered is not still waiting")

    print("PASS: the handle opens the strip at once, and it closes a second after the pointer leaves")
}

/// The pin button's own effect on the model: a strip that stays open no
/// matter where the pointer goes, until unpinned puts the ordinary hover
/// behaviour back.
func testShortcutStripPinTests() {
    let hide = ShortcutStripModel.hideDelaySeconds

    var pinned = ShortcutStripModel()
    expect(!pinned.isPinned, "a fresh strip starts unpinned")
    pinned.phaseChanged(.live, now: 0)
    pinned.pointerOverHandle(true, now: 0)
    expect(pinned.visibility == .shown, "hovering the handle opens the strip as usual")
    pinned.togglePinRequested(now: 0)
    expect(pinned.isPinned, "the pin button turns pinning on")
    expect(
        !pinned.showsHandle,
        "the hover handle hides once a shown strip is pinned -- pinning already found it without it"
    )
    pinned.pointerOverHandle(false, now: 1)
    expect(
        pinned.visibility == .shown,
        "a pinned strip ignores the pointer leaving and stays open"
    )
    pinned.tick(now: 1 + hide)
    expect(
        pinned.visibility == .shown,
        "there is no hide delay to expire either, since none was ever started"
    )

    // Unpinning puts the ordinary hover behaviour straight back. The pointer
    // is already away from the strip at that moment, so the hide starts at
    // once rather than waiting for a motion event that may never arrive.
    pinned.togglePinRequested(now: 2)
    expect(!pinned.isPinned, "the same button unpins it")
    expect(pinned.visibility == .hiding, "unpin restores hover closing, and the pointer is already away")
    expect(pinned.showsHandle, "and the handle pill is back now that the strip is no longer pinned")
    pinned.tick(now: 2 + hide)
    expect(pinned.visibility == .hidden, "and the ordinary hide delay runs its course from there")

    // The chord and Escape still reach a pinned strip -- only the pointer
    // leaving is ignored.
    var closable = ShortcutStripModel()
    closable.phaseChanged(.live, now: 0)
    closable.pointerOverHandle(true, now: 0)
    closable.togglePinRequested(now: 0)
    closable.toggleRequested()
    expect(closable.visibility == .hidden, "the chord closes a pinned strip")
    closable.toggleRequested()
    closable.pointerOverStrip(true, now: 1)
    closable.pointerOverHandle(false, now: 1)
    expect(closable.escapePressed(), "and so does Escape, while the pointer is on the pinned strip")
    expect(closable.visibility == .hidden, "with nothing left waiting to hide")
    expect(
        closable.showsHandle,
        "the pill is back once Escape closes a pinned strip, even though the pin itself is untouched"
    )

    print("PASS: a pinned strip ignores the pointer leaving, and unpinning restores hover closing")
}

/// The pin's whole point: it survives a disconnect. A model built from a
/// pin remembered as on must start open without any hover, and nothing the
/// session itself does on the way to and from live -- connecting,
/// reconnecting, going live again -- may take that open strip away.
func testShortcutStripPinSurvivesReconnectTests() {
    let remembered = ShortcutStripModel(isPinned: true)
    expect(remembered.isPinned, "a model built from a remembered pin is pinned")
    expect(
        remembered.visibility == .shown,
        "and starts shown without needing a hover, so it is open the moment the session goes live"
    )

    var session = remembered
    session.phaseChanged(.connecting, now: 0)
    expect(session.visibility == .shown, "connecting does not close a pinned strip")
    session.phaseChanged(.live, now: 1)
    expect(session.visibility == .shown, "going live for the first time leaves a pinned strip open")
    session.phaseChanged(.reconnecting, now: 2)
    expect(session.visibility == .shown, "a reconnect in flight does not close a pinned strip")
    session.phaseChanged(.live, now: 3)
    expect(session.visibility == .shown, "and it is still open once the reconnect completes")
    session.phaseChanged(.lost, now: 4)
    expect(session.visibility == .shown, "nor does losing the session take it away")

    // Escape still reaches a pinned strip, but the pin itself is a decision
    // for the pin button alone: nothing here clears `isPinned`, so the next
    // model built from the same remembered choice starts open again.
    session.pointerOverStrip(true, now: 5)
    session.phaseChanged(.live, now: 5)
    expect(session.escapePressed(), "escape closes even a pinned strip")
    expect(session.visibility == .hidden, "and this session's strip stays closed")
    expect(session.isPinned, "but the pin itself is untouched by escape")

    let nextConnect = ShortcutStripModel(isPinned: session.isPinned)
    expect(
        nextConnect.visibility == .shown,
        "a model built fresh from that same remembered pin starts shown again"
    )

    print("PASS: a pinned strip survives connecting, reconnecting and losing the session, and comes back after Escape")
}

func testShortcutStripSendsWholeChordsTests() async {
    // A chord goes out in one call, in order, on the same path ordinary typing
    // takes -- there is no second input route for these buttons.
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    await viewport.sendKeySequence(ShortcutStripAction.missionControl.events())
    let sent = await sink.events
    expect(
        sent == ShortcutStripAction.missionControl.events(),
        "the chord reaches the host in the order the action produced it"
    )

    // Half a chord is worse than none: it is how a modifier ends up held on a
    // machine nobody is sitting at. A canvas that is not ready refuses all of it.
    let closed = RecordingInputSink()
    let closedViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: closed
    )
    let delivery = await closedViewport.sendKeySequence(ShortcutStripAction.switchApp.events())
    expect(delivery == .droppedNotConnected, "a session with no canvas refuses the chord")
    expect(await closed.events.isEmpty, "and sends no part of it")

    // A link that goes down between a modifier and the key it modifies is the
    // case the one readiness check cannot cover: the modifier is already on the
    // far machine. Whatever is still held is released on the way out, in the
    // reverse of the order it went down, and nothing further is pressed.
    let failing = FailingAfterInputSink(successes: 1)
    let failingViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: failing
    )
    await failingViewport.canvasDidBecomeReady()
    let interrupted = await failingViewport.sendKeySequence(ShortcutStripAction.missionControl.events())
    expect(interrupted == .droppedNotConnected, "a chord interrupted mid-flight reports the failure")
    let attempted = await failing.attempts
    expect(
        attempted == [
            .key(keyCode: 59, isDown: true, modifiers: [.control]),
            .key(keyCode: 126, isDown: true, modifiers: [.control]),
            .key(keyCode: 59, isDown: false, modifiers: [])
        ],
        "the modifier already pressed is released on the way out, and nothing else is pressed"
    )
    expect(
        !attempted.dropFirst(2).contains { event in
            guard case let .key(_, isDown, _) = event else { return false }
            return isDown
        },
        "no key goes down after the send that failed"
    )

    // Two modifiers is where a release order can go wrong unnoticed. Failing
    // once the main key is down leaves all three held, and each comes back up
    // carrying what is still held after it -- the main key first, then the
    // modifiers in the reverse of the order they went down.
    let twoModifiers = FailingAfterInputSink(successes: 3)
    let twoModifierViewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: twoModifiers
    )
    await twoModifierViewport.canvasDidBecomeReady()
    await twoModifierViewport.sendKeySequence(ShortcutStripAction.lockScreen.events())
    expect(
        await twoModifiers.attempts == [
            .key(keyCode: 59, isDown: true, modifiers: [.control]),
            .key(keyCode: 55, isDown: true, modifiers: [.control, .command]),
            .key(keyCode: 12, isDown: true, modifiers: [.control, .command]),
            // The send that failed. Q is held on the far machine whether or not
            // this one got out, so the release below tries it again rather
            // than assuming it did.
            .key(keyCode: 12, isDown: false, modifiers: [.control, .command]),
            .key(keyCode: 12, isDown: false, modifiers: [.control, .command]),
            .key(keyCode: 55, isDown: false, modifiers: [.control]),
            .key(keyCode: 59, isDown: false, modifiers: [])
        ],
        "a two-modifier chord releases the main key first and the modifiers in reverse"
    )

    print("PASS: a shortcut strip press sends its whole chord in one call, or none of it")
}

/// Fails every send after the first `successes`, and records what it was asked
/// to send either way -- an attempt that threw is exactly what the release path
/// has to be measured on.
actor FailingAfterInputSink: CanvasInputSending {
    private(set) var attempts: [SensoriumInputEvent] = []
    private let successes: Int

    init(successes: Int) {
        self.successes = successes
    }

    func sendInput(_ event: SensoriumInputEvent) async throws {
        attempts.append(event)
        guard attempts.count <= successes else {
            throw ClientSessionError.notConnected
        }
    }

    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws {}

    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {}
}

/// Where the handle actually lands in a laid-out view, and what it does to the
/// pointer and the keyboard -- the three things the model cannot say, because
/// they are geometry and responder behaviour rather than state.
@MainActor
func testShortcutStripHandleTests() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
    let strip = ShortcutStripView(hostName: "Studio")
    container.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        strip.topAnchor.constraint(equalTo: container.topAnchor)
    ])
    strip.phaseChanged(.live)
    container.layoutSubtreeIfNeeded()

    let centre = container.bounds.midX
    // The container is not flipped, so a distance measured down from the top
    // edge is a subtraction rather than an addition.
    func point(_ x: CGFloat, fromTop: CGFloat) -> NSPoint {
        NSPoint(x: x, y: container.bounds.maxY - fromTop)
    }

    // The handle is a small tab at the top centre, and it is there before
    // anything is hovered: it is the only thing that makes the strip findable.
    guard let handle = strip.hitTest(point(centre, fromTop: 10)) else {
        expect(false, "a live session shows a handle at the top centre")
        return
    }
    // In full screen the first few points of the window are where the menu bar
    // comes back. Anything the strip put there could be aimed at only by
    // summoning the menu bar over it, so the strip puts nothing there and
    // takes no click there either.
    for fromTop in [0.0, 3.0, 5.5] as [CGFloat] {
        expect(
            strip.hitTest(point(centre, fromTop: fromTop)) == nil,
            "a closed strip takes no click \(fromTop) points from the top edge"
        )
    }
    expect(strip.hitTest(point(centre, fromTop: 15)) == nil, "the handle is a few points tall and no more")
    expect(strip.hitTest(point(centre - 17, fromTop: 10)) === handle, "the handle is wide enough to aim at")
    expect(strip.hitTest(point(centre + 17, fromTop: 10)) === handle, "on both sides of centre")
    expect(
        strip.hitTest(point(centre - 30, fromTop: 10)) == nil,
        "and it is a tab, not a band across the whole window"
    )
    expect(
        strip.hitTest(point(centre, fromTop: 24)) == nil,
        "a closed strip takes no click anywhere but its handle"
    )
    expect(!handle.acceptsFirstResponder, "the handle never takes the keyboard away from the picture")
    expect(
        strip.coversPointInSuperview(point(centre, fromTop: 10)),
        "pointer motion over the handle stays on this machine"
    )
    expect(
        !strip.coversPointInSuperview(point(centre, fromTop: 3)),
        "motion in the top few points is the picture's, not the strip's"
    )
    expect(
        !strip.coversPointInSuperview(point(centre, fromTop: 24)),
        "and so is motion below the closed handle"
    )

    // Open, and the top of the window stays just as clear.
    strip.toggleRequested()
    container.layoutSubtreeIfNeeded()
    var buttons: [NSButton] = []
    func collect(_ view: NSView) {
        if let button = view as? NSButton {
            buttons.append(button)
        }
        for subview in view.subviews {
            collect(subview)
        }
    }
    collect(strip)
    expect(!buttons.isEmpty, "the open strip has buttons")
    for button in buttons {
        let fromTop = strip.bounds.maxY - strip.convert(button.bounds, from: button).maxY
        expect(fromTop >= 6, "no button of the strip is in the top 6 points of the window")
        expect(!button.acceptsFirstResponder, "no button of the strip takes the keyboard")
    }
    for fromTop in [0.0, 3.0, 5.5] as [CGFloat] {
        expect(
            strip.hitTest(point(centre, fromTop: fromTop)) == nil,
            "an open strip takes no click \(fromTop) points from the top edge either"
        )
        expect(
            !strip.coversPointInSuperview(point(centre, fromTop: fromTop)),
            "and takes none of the pointer's motion there"
        )
    }
    expect(
        strip.hitTest(point(centre, fromTop: 10)) === handle,
        "the handle stays where it was, so the click that opened the strip closes it"
    )

    // Nothing at all over a picture there is no session behind.
    strip.phaseChanged(.reconnecting)
    container.layoutSubtreeIfNeeded()
    expect(strip.hitTest(point(centre, fromTop: 10)) == nil, "a session that is not live shows no handle")
    expect(
        !strip.coversPointInSuperview(point(centre, fromTop: 10)),
        "and takes none of the pointer's motion"
    )

    print("PASS: the handle is a small tab below the top edge that takes neither the keyboard nor the picture")
}

/// A viewer window narrower than the strip's own button row must not drag the
/// handle off centre with it: the handle is the one thing that must always be
/// where a person expects a tab at the top of a window to be, no matter how
/// many shortcuts the row has grown to hold.
@MainActor
func testShortcutStripHandleStaysCenteredWhenNarrow() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    let strip = ShortcutStripView(hostName: "Studio")
    container.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        strip.topAnchor.constraint(equalTo: container.topAnchor)
    ])
    strip.phaseChanged(.live)
    container.layoutSubtreeIfNeeded()

    let centre = container.bounds.midX
    func point(_ x: CGFloat, fromTop: CGFloat) -> NSPoint {
        NSPoint(x: x, y: container.bounds.maxY - fromTop)
    }

    guard let handle = strip.hitTest(point(centre, fromTop: 10)) else {
        expect(false, "a live session shows a handle at the top centre even in a narrow window")
        return
    }
    expect(
        strip.hitTest(point(centre - 17, fromTop: 10)) === handle,
        "the handle is centred and wide enough to aim at in a narrow window"
    )
    expect(
        strip.hitTest(point(centre + 17, fromTop: 10)) === handle,
        "on both sides of centre in a narrow window"
    )

    print("PASS: the handle stays centred and clickable in a window narrower than the strip's own button row")
}

/// The strip's row of buttons, in the layout a person actually sees: an icon
/// naming each shortcut, equal widths so the row reads as one group, and the
/// whole row centred rather than pinned to one edge.
@MainActor
func testShortcutStripButtonAppearanceTests() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 700))
    let strip = ShortcutStripView(hostName: "Studio")
    container.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        strip.topAnchor.constraint(equalTo: container.topAnchor)
    ])
    strip.phaseChanged(.live)
    strip.toggleRequested()
    container.layoutSubtreeIfNeeded()

    var buttons: [NSButton] = []
    func collect(_ view: NSView) {
        if let button = view as? NSButton, button.toolTip?.hasPrefix("Sends") == true {
            buttons.append(button)
        }
        for subview in view.subviews {
            collect(subview)
        }
    }
    collect(strip)
    expect(buttons.count == ShortcutStripAction.allCases.count, "one button per shortcut action")

    let frames = buttons.map { strip.convert($0.bounds, from: $0) }
    let widths = Set(frames.map { ($0.width * 100).rounded() / 100 })
    expect(widths.count == 1, "every shortcut button is the same width")

    for button in buttons {
        expect(
            button.subviews.contains { $0 is NSImageView },
            "\(button.toolTip ?? "a shortcut button") shows its shortcut's icon"
        )
    }

    let rowMinX = frames.map(\.minX).min() ?? 0
    let rowMaxX = frames.map(\.maxX).max() ?? 0
    let rowMid = (rowMinX + rowMaxX) / 2
    expect(abs(rowMid - strip.bounds.midX) < 1, "the row of shortcut buttons is centred in the strip")

    print("PASS: the shortcut strip's buttons are equal width, iconed, and centred as a row")
}

/// The pin button lives in its own cluster at the trailing edge, outside the
/// centred group of action buttons, and its tooltip names what pressing it
/// does next rather than a fixed label.
@MainActor
func testShortcutStripPinButtonAppearanceTests() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 700))
    let strip = ShortcutStripView(hostName: "Studio", pinMemoryStore: InMemoryShortcutStripPinMemoryStore())
    container.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        strip.topAnchor.constraint(equalTo: container.topAnchor)
    ])
    strip.phaseChanged(.live)
    strip.toggleRequested()
    container.layoutSubtreeIfNeeded()

    func findButton(byToolTipPrefix prefix: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.toolTip?.hasPrefix(prefix) == true {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(byToolTipPrefix: prefix, in: subview) {
                return found
            }
        }
        return nil
    }

    guard let pinButton = findButton(byToolTipPrefix: "Keep open", in: strip) else {
        expect(false, "the strip shows a pin button tooltipped \"Keep open\" before it is pinned")
        return
    }
    expect(
        pinButton.subviews.contains { $0 is NSImageView },
        "the pin button shows an icon like every other button on the strip"
    )

    let actionButtons = collectButtonsWithToolTipPrefix("Sends")(strip)
    let actionFrames = actionButtons.map { strip.convert($0.bounds, from: $0) }
    let actionMaxX = actionFrames.map(\.maxX).max() ?? 0
    let pinFrame = strip.convert(pinButton.bounds, from: pinButton)
    expect(
        pinFrame.minX > actionMaxX,
        "the pin button sits to the right of every action button's own cluster"
    )

    pinButton.performClick(nil)
    expect(
        pinButton.toolTip == "Let close",
        "clicking the pin button once turns pinning on, and the tooltip says what pressing it again would do"
    )
    pinButton.performClick(nil)
    expect(pinButton.toolTip == "Keep open", "clicking it again turns pinning back off")

    print("PASS: the pin button sits in its own cluster right of the action buttons, and its tooltip tracks its state")
}

@MainActor
private func collectButtonsWithToolTipPrefix(_ prefix: String) -> (NSView) -> [NSButton] {
    func collect(_ view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton, button.toolTip?.hasPrefix(prefix) == true {
            found.append(button)
        }
        for subview in view.subviews {
            found.append(contentsOf: collect(subview))
        }
        return found
    }
    return collect
}

/// Every SF Symbol name an action names must actually resolve on this
/// machine, and no two actions may point at nothing.
@MainActor
func testShortcutStripSymbolsTests() {
    var seen: Set<String> = []
    for action in ShortcutStripAction.allCases {
        expect(!action.symbolName.isEmpty, "\(action) names a symbol")
        expect(
            NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil,
            "\(action)'s symbol name \"\(action.symbolName)\" resolves to an SF Symbol"
        )
        seen.insert(action.symbolName)
    }
    expect(seen.count == ShortcutStripAction.allCases.count, "no two actions share a symbol")

    print("PASS: every shortcut strip action names an SF Symbol that resolves")
}

/// Which mouse presses and releases belong to the machine being worked on,
/// once the viewer has chrome of its own over the picture.
func testCanvasChromeClickPolicyTests() {
    var policy = CanvasChromeClickPolicy()
    expect(
        !policy.shouldForwardPress(.left, isOverChrome: true),
        "a press on the viewer's own chrome is not the far machine's"
    )
    expect(!policy.shouldForwardRelease(.left), "and neither is the release that ends it")
    expect(
        policy.shouldForwardPress(.left, isOverChrome: false),
        "a press on the picture is"
    )
    expect(policy.shouldForwardRelease(.left), "together with the release that ends it")
    expect(!policy.shouldForwardRelease(.left), "a release with no press behind it belongs to nobody")

    // A press that started on the picture is released wherever the pointer
    // ends up. A button left down on a machine nobody is sitting at is worse
    // than a stray click, so the release is never the thing that gets dropped.
    expect(policy.shouldForwardPress(.right, isOverChrome: false), "a right press on the picture goes out")
    expect(
        policy.shouldForwardRelease(.right),
        "and is released even though the pointer ended up over the strip"
    )

    // Buttons are tracked apart: one suppressed press must not swallow
    // another button's release.
    expect(policy.shouldForwardPress(.left, isOverChrome: false), "the left press goes out")
    expect(!policy.shouldForwardPress(.middle, isOverChrome: true), "the middle press does not")
    expect(!policy.shouldForwardRelease(.middle), "so neither does its release")
    expect(policy.shouldForwardRelease(.left), "and the left release still does")

    print("PASS: a click on the viewer's own chrome sends neither half of itself to the far machine")
}

/// The same rule where it actually matters: the canvas view, driven by the
/// events AppKit delivers, with the shortcut strip's own band reported as
/// chrome.
@MainActor
func testCanvasSurfaceChromeClickTests() async {
    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport)
    let surface = CanvasSurfaceView(
        router: router,
        shortcutRouter: SystemShortcutRouter(mode: .default),
        accessibilityGranted: false,
        surfaceID: 0
    )
    surface.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
    _ = await router.route(.boundsChanged(width: 960, height: 600))
    // The strip's own band across the top, reported the way the window
    // controller reports it. The view is not flipped, so this is the top.
    surface.isPointerOverViewerChrome = { $0.y >= 550 }

    func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            expect(false, "AppKit refused a synthetic \(type) event")
            fatalError("unreachable")
        }
        return event
    }
    // The forwarding path hands each event to an actor, so the sends land a
    // few hops after the call that made them.
    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    let overStrip = NSPoint(x: 480, y: 580)
    let overPicture = NSPoint(x: 480, y: 200)

    surface.mouseDown(with: event(.leftMouseDown, overStrip))
    surface.mouseUp(with: event(.leftMouseUp, overStrip))
    surface.rightMouseDown(with: event(.rightMouseDown, overStrip))
    surface.rightMouseUp(with: event(.rightMouseUp, overStrip))
    surface.otherMouseDown(with: event(.otherMouseDown, overStrip))
    surface.otherMouseUp(with: event(.otherMouseUp, overStrip))
    await settle()
    expect(
        await sink.events.isEmpty,
        "no half of a click on the strip reaches the machine being worked on"
    )

    // A drag that starts on the picture and ends over the strip still
    // releases: what must never happen is a button left held down there.
    surface.mouseDown(with: event(.leftMouseDown, overPicture))
    surface.mouseUp(with: event(.leftMouseUp, overStrip))
    await settle()
    let sent = await sink.events
    let buttons = sent.compactMap { sentEvent -> Bool? in
        guard case let .pointerButton(_, isDown, _, _) = sentEvent else { return nil }
        return isDown
    }
    expect(buttons == [true, false], "a press on the picture is released wherever the pointer ended up")

    print("PASS: the canvas view sends neither half of a click aimed at the viewer's own chrome")
}
#endif
