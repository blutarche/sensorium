import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import SensoriumHost

/// The live indication (badge, menu bar, Host Setup line) and the
/// append-only session log. Nothing here wires a
/// real host-screen session -- that needs `HostSessionController` and
/// `HostSessionCoordinator`, so every assertion drives the presentation and
/// storage types directly, the same testing this repository already gives
/// arming and the selection guard.
@MainActor
func runHostScreenIndicationTests() async {
    do {
        // The operator activity case and its strings
        let servingHostScreen = HostOperatorStatus(
            connection: .servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        ).presentation(now: Date())

        expect(servingHostScreen.indicator == .servingHostScreen, "a live host-screen session reports its own indicator, distinct from `.serving`")
        expect(
            servingHostScreen.menuBarTitle == "Kestrel Laptop Pro",
            "the menu bar shows title text naming the connected device -- design §6.4: canvas mode's serving state is deliberately quiet, this mode must not be"
        )
        expect(
            !servingHostScreen.detail.contains("a virtual display only"),
            "the canvas-mode privacy sentence is unreachable here: this mode exists because that sentence would be false"
        )
        expect(
            servingHostScreen.detail.contains("Built-in Display"),
            "the presentation names the real display being driven, not a generic claim"
        )
        expect(
            servingHostScreen.pairingCode == nil,
            "the peer name that feeds the menu-bar title must never leak into the pairing-code field -- they are unrelated facts that happen to share a `String?` shape"
        )

        let canvasServing = HostOperatorStatus(
            connection: .serving(peerName: "Kestrel Laptop Pro"),
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        ).presentation(now: Date())
        expect(
            canvasServing.detail == "It sees and controls a virtual display, not this machine\u{2019}s own screen.",
            "canvas mode's own privacy sentence is unchanged in substance, narrowed only in where it applies, "
                + "it does not delete it -- got: \(canvasServing.detail)"
        )
        expect(canvasServing.menuBarTitle == nil, "canvas-mode serving still shows no menu-bar title, unchanged")

        print("PASS: a live host-screen session reports its activity, indicator and title, and hides the canvas-mode privacy sentence")
    }

    do {
        // A closed connection resets host-screen activity the same
        // way it already resets canvas-mode serving.
        let store = HostOperatorStatusStore(
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        )
        store.beginHosting(address: "100.64.1.9")
        store.setConnection(.servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        store.apply(.closed(reason: nil), from: HostConnectionToken())
        expect(
            store.status.connection == .hosting(address: "100.64.1.9"),
            "a closed connection returns the host to hosting-on-its-address from a host-screen session, exactly as it already does from a canvas one"
        )

        print("PASS: a closed connection ends host-screen activity the same way it already ends canvas-mode serving")
    }

    do {
        // The session log survives a process boundary, the same way
        // HostScreenArmingStore already does.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-session-log-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HostScreenSessionLogStore(url: url)
        expect(store.records().isEmpty, "a store with nothing written reads back as empty, not an error")
        expect(store.lastRecord == nil, "nothing to report as the last session when none has ever run")

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let id = store.beginSession(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display", startedAt: started)

        // A second instance constructed while the session is still live --
        // this machine's host GUI reading `lastRecord` for its own window,
        // independent of whichever object began the session -- must not
        // mistake a still-legitimate open record for an abandoned one just
        // because it did not begin it itself. Reconciliation is a launch
        // action, not a construction one; a second instance that never
        // calls it must see the record exactly as the first left it.
        let reopenedMidSession = HostScreenSessionLogStore(url: url)
        expect(
            reopenedMidSession.lastRecord?.outcome == nil,
            "a second store instance that never reconciles sees the still-open record exactly as it is, not rewritten out from under the session that is genuinely still running"
        )

        let ended = started.addingTimeInterval(1_800)
        store.endSession(id, endedAt: ended)
        let reopenedAfterStop = HostScreenSessionLogStore(url: url)
        expect(
            reopenedAfterStop.lastRecord == HostScreenSessionRecord(
                id: id, deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
                startedAt: started, outcome: .stopped(at: ended)
            ),
            "a second store instance at the same URL reads back exactly the clean-stopped record the first one wrote"
        )

        store.endSession(id, endedAt: ended.addingTimeInterval(60))
        expect(
            store.lastRecord?.outcome == .stopped(at: ended),
            "ending an already-ended session changes nothing -- the first, real stop time is not overwritten by a later, spurious call"
        )
        store.endSession(HostScreenSessionRecord.ID(), endedAt: ended)
        expect(
            store.records().count == 1,
            "ending a session id this store never began is not an error and creates no phantom record"
        )

        print("PASS: the session log round-trips a clean stop, and a session still open on load is reconciled to a not-clean marker")
    }

    do {
        // A session abandoned by a real crash -- no `endSession` call
        // at all, not even a wrong one -- is still reconciled, and
        // that reconciliation itself persists rather than only living
        // in the reconciling instance's memory.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-session-log-crash-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let crashed = HostScreenSessionLogStore(url: url)
        _ = crashed.beginSession(deviceName: "Kestrel Laptop Pro", displayLabel: "External Display", startedAt: Date())
        // No `endSession` call, and no reconcile call either. `crashed` is
        // simply never touched again -- standing in for the process that
        // held it disappearing, since nothing this store's own API can do
        // distinguishes "still running" from "gone."

        let nextLaunch = HostScreenSessionLogStore(url: url)
        nextLaunch.reconcileAbandonedSessionsAtLaunch() // what `sensoriumd` calls once, at hosting startup
        let thirdInstance = HostScreenSessionLogStore(url: url)
        expect(
            thirdInstance.lastRecord?.outcome == .endedWithoutCleanStop,
            "the reconciliation a later instance performs is written back to disk, not just held in that instance's own memory -- a third instance still sees it"
        )

        print("PASS: a session abandoned by a crash is reconciled to a marker that persists across later reopenings")
    }

    do {
        // Never input content: a regression test against the record
        // shape growing a field this design forbids, not only a
        // claim about the fields it happens to have today.
        let record = HostScreenSessionRecord(
            deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
            startedAt: Date(timeIntervalSince1970: 0), outcome: .stopped(at: Date(timeIntervalSince1970: 60))
        )
        guard let data = try? JSONEncoder().encode(record),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            expect(false, "the record itself must encode")
            return
        }
        let forbidden = ["input", "key", "pointer", "click", "keystroke", "frame", "pixel", "address", "ip"]
        for field in object.keys {
            expect(
                !forbidden.contains { field.lowercased().contains($0) },
                "field \(field) looks like input, frame, or address content, which design §6.4 says this record must never carry"
            )
        }
        expect(
            Set(object.keys) == Set(["id", "deviceName", "displayLabel", "startedAt", "outcome"]),
            "the record carries exactly device, display, start, and outcome -- nothing else, so a reviewer auditing this file's shape sees the whole contract in one assertion"
        )

        print("PASS: the session record encodes device, display, start and outcome, and nothing resembling input, frame or address content")
    }

    do {
        // The Host Setup line, and its three distinct outcomes.
        expect(
            HostScreenSessionLogPresentation.line(for: nil) == nil,
            "host screen having never run on this machine shows no line at all, not an empty or fabricated one"
        )

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let stoppedLine = HostScreenSessionLogPresentation.line(for: HostScreenSessionRecord(
            deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
            startedAt: started, outcome: .stopped(at: started.addingTimeInterval(1_800))
        ))
        expect(
            stoppedLine?.contains("Kestrel Laptop Pro") == true && stoppedLine?.contains("Built-in Display") == true,
            "a cleanly stopped session names the device and the display"
        )
        expect(stoppedLine?.contains("ended without a clean stop") == false, "a cleanly stopped session is never worded as an abnormal one")
        expect(
            stoppedLine?.contains("2023") == true && stoppedLine?.contains("BE") == false,
            "the date is forced to the Gregorian calendar regardless of the system's own calendar setting -- a machine set to Buddhist, Japanese, or another calendar must not print a session year in it with nothing marking that it is not the Gregorian one"
        )

        // Fixed locale and time zone: the range wording itself, not just
        // that a year is present, is what a same-day/cross-day session must
        // get right, and that has to hold independent of the machine
        // running the test.
        let fixedLocale = Locale(identifier: "en_GB")
        let fixedZone = TimeZone(identifier: "UTC")!
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = fixedZone
        func utcDate(day: Int, hour: Int, minute: Int) -> Date {
            utcCalendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour, minute: minute))!
        }

        let sameDayLine = HostScreenSessionLogPresentation.line(
            for: HostScreenSessionRecord(
                deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
                startedAt: utcDate(day: 15, hour: 5, minute: 13),
                outcome: .stopped(at: utcDate(day: 15, hour: 5, minute: 43))
            ),
            locale: fixedLocale,
            timeZone: fixedZone
        )
        expect(
            sameDayLine == "Kestrel Laptop Pro used Built-in Display from 15 Nov 2023, 05:13 to 05:43.",
            "a same-day session reads as one sentence -- device, display, date once, both times joined with \"to\", "
                + "the same shape the cross-day and still-running siblings use -- not a comma-run of device, "
                + "display, date, times \(sameDayLine ?? "nil")"
        )

        let crossDayLine = HostScreenSessionLogPresentation.line(
            for: HostScreenSessionRecord(
                deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
                startedAt: utcDate(day: 15, hour: 23, minute: 50),
                outcome: .stopped(at: utcDate(day: 16, hour: 0, minute: 20))
            ),
            locale: fixedLocale,
            timeZone: fixedZone
        )
        expect(
            crossDayLine == "Kestrel Laptop Pro used Built-in Display from 15 Nov 2023, 23:50 to 16 Nov 2023, 00:20.",
            "a range crossing midnight names both dates, since the end time alone would not say which day it fell on \(crossDayLine ?? "nil")"
        )

        let abandonedLine = HostScreenSessionLogPresentation.line(for: HostScreenSessionRecord(
            deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
            startedAt: started, outcome: .endedWithoutCleanStop
        ))
        expect(
            abandonedLine?.hasPrefix("Kestrel Laptop Pro used Built-in Display from ") == true,
            "an abandoned session still names the device, the display, and when it started, as one sentence \(abandonedLine ?? "nil")"
        )
        expect(
            abandonedLine?.contains(". Sensorium Host stopped before the session ended, so the end time is unknown.") == true,
            "a session reconciled from a crash says so in words, rather than inventing a stop time it does not have"
        )

        let stillRunningLine = HostScreenSessionLogPresentation.line(
            for: HostScreenSessionRecord(
                deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display",
                startedAt: utcDate(day: 15, hour: 5, minute: 13), outcome: nil
            ),
            locale: fixedLocale,
            timeZone: fixedZone
        )
        expect(
            stillRunningLine == "Kestrel Laptop Pro used Built-in Display from 15 Nov 2023, 05:13; it is still running.",
            "a session this store's own process is still serving reads the same sentence shape as the other two "
                + "outcomes \(stillRunningLine ?? "nil")"
        )

        print("PASS: the Host Setup last-screen-session line names the device and display in one sentence, whatever the outcome")
    }

    do {
        // The badge: stop is one action a test observes as state,
        // not only as a closure that may or may not have been wired.
        let content = HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        let state = HostScreenBadgeState(content: content)
        expect(state.isExpanded, "a badge starts expanded -- design §6.4: 'it opens expanded for a few seconds before shrinking, so somebody in the room sees it begin'")
        expect(!state.hasStopped, "a fresh badge has not stopped anything")

        var stopCallCount = 0
        state.onStop = { stopCallCount += 1 }
        state.stopTapped()
        expect(state.hasStopped, "tapping Stop is directly observable on the state object itself, not only through whether a callback happened to be wired")
        expect(stopCallCount == 1, "the injected teardown callback runs exactly once, whatever wires the real teardown into it")

        state.stopTapped()
        expect(stopCallCount == 1, "a second tap -- a double click, or one that lands after teardown already began -- does not run the stop effect twice")

        state.shrink()
        expect(!state.isExpanded, "shrink collapses the badge independently of whether the session has stopped")

        print("PASS: the badge's Stop is idempotent, and its effect is observable state rather than only a closure's side effect")
    }

    do {
        // The badge's second line reads as this device's own action,
        // not a passive claim that could be misread as the connected
        // device sharing something of its own.
        func field<T>(_ name: String, of object: Any) -> T {
            for child in Mirror(reflecting: object).children {
                if child.label == name, let value = child.value as? T {
                    return value
                }
            }
            fatalError("no stored property named \(name) of type \(T.self)")
        }
        let content = HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        let state = HostScreenBadgeState(content: content)
        let controller = HostScreenBadgeWindowController(state: state)
        let displayLabel: NSTextField = field("displayLabel", of: controller)
        expect(
            displayLabel.stringValue == "Sees and controls Built-in Display",
            "the second line names what this device is doing to the display, not a bare \"Sharing\" claim that "
                + "reads as if the connected device were sharing its own screen -- got: \(displayLabel.stringValue)"
        )

        print("PASS: the badge's second line reads \"Sees and controls <display>\"")
    }

    do {
        // The badge window: no native close control exists for a
        // local or, since host-screen mode drops key confinement,
        // remotely injected click to dismiss the one window Sensorium
        // places on a physical display.
        let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let controller = HostScreenBadgeWindowController(state: state)
        expect(!controller.hasNativeCloseControl, "the badge window's style mask carries no .closable bit -- there is no close button for any click, local or injected, to hit")

        print("PASS: the badge window has no native close control")
    }

    do {
        // Shrunk keeps every element -- device name, display, Stop --
        // at smaller type and tighter insets, so the window is
        // visibly smaller yet still names what the invariant requires.
        func labels(in view: NSView) -> [String] {
            view.subviews.flatMap { subview -> [String] in
                if let field = subview as? NSTextField { return [field.attributedStringValue.string] }
                return labels(in: subview)
            }
        }
        func hasButton(in view: NSView) -> Bool {
            view.subviews.contains { $0 is NSButton || hasButton(in: $0) }
        }
        // The controller is returned too: it owns the window and is what
        // re-lays it out, exactly as `HostScreenAccountableMedia` keeps it
        // alive for the session.
        func badge(startsExpanded: Bool) -> (state: HostScreenBadgeState, controller: HostScreenBadgeWindowController, window: NSWindow) {
            let state = HostScreenBadgeState(
                content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
                startsExpanded: startsExpanded
            )
            let controller = HostScreenBadgeWindowController(state: state)
            return (state, controller, CanvasHostTestHooks.hostScreenBadgeWindow(controller))
        }

        let expanded = badge(startsExpanded: true)
        let shrunk = badge(startsExpanded: false)
        let expandedSize = expanded.window.contentView?.fittingSize ?? .zero
        let shrunkSize = shrunk.window.contentView?.fittingSize ?? .zero
        expect(
            shrunkSize.height < expandedSize.height,
            "the shrunk badge is strictly shorter than the expanded one -- design §6.4's 'opens expanded for a few seconds before shrinking' has to be visible -- got expanded \(expandedSize), shrunk \(shrunkSize)"
        )
        expect(
            expanded.window.frame.height > shrunk.window.frame.height,
            "the window itself follows its content's height -- got expanded \(expanded.window.frame.size), shrunk \(shrunk.window.frame.size)"
        )
        for (name, window, size) in [("expanded", expanded.window, expandedSize), ("shrunk", shrunk.window, shrunkSize)] {
            guard let content = window.contentView else { fatalError("the \(name) badge window has no content view") }
            let texts = labels(in: content)
            expect(
                texts.contains("Kestrel Laptop Pro") && texts.contains("Sees and controls Built-in Display"),
                "the \(name) badge names the connected device and the display it sees -- got: \(texts)"
            )
            expect(hasButton(in: content), "the \(name) badge keeps its Stop button")
            expect(
                size.width <= window.frame.width && size.height <= window.frame.height,
                "the \(name) badge window is large enough for its content -- content \(size), window \(window.frame.size)"
            )
        }

        let heightBeforeShrink = expanded.window.frame.height
        expanded.state.shrink()
        expect(
            expanded.window.frame.height == shrunk.window.frame.height && expanded.window.frame.height < heightBeforeShrink,
            "shrinking the state re-lays out the window that shows it -- got \(expanded.window.frame.height) after shrink, versus \(shrunk.window.frame.height) built shrunk"
        )

        print("PASS: the shrunk badge is visibly smaller than the expanded one and still names the device, the display and Stop")
    }

    do {
        // The badge says which app is sharing: an eyebrow line above
        // the device name, in both states, smaller when shrunk.
        func eyebrow(startsExpanded: Bool) -> NSTextField? {
            let state = HostScreenBadgeState(
                content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
                startsExpanded: startsExpanded
            )
            let controller = HostScreenBadgeWindowController(state: state)
            let window = CanvasHostTestHooks.hostScreenBadgeWindow(controller)
            func find(in view: NSView) -> NSTextField? {
                for subview in view.subviews {
                    if let field = subview as? NSTextField, field.attributedStringValue.string == "SENSORIUM HOST" { return field }
                    if let found = find(in: subview) { return found }
                }
                return nil
            }
            return window.contentView.flatMap(find)
        }
        guard let expandedEyebrow = eyebrow(startsExpanded: true), let shrunkEyebrow = eyebrow(startsExpanded: false) else {
            expect(false, "both badge states carry an eyebrow reading SENSORIUM HOST above the device name")
            return
        }
        let expandedSize = expandedEyebrow.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil).flatMap { ($0 as? NSFont)?.pointSize } ?? 0
        let shrunkSize = shrunkEyebrow.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil).flatMap { ($0 as? NSFont)?.pointSize } ?? 0
        expect(
            shrunkSize > 0 && shrunkSize < expandedSize,
            "the eyebrow shrinks with the rest of the badge -- got expanded \(expandedSize)pt, shrunk \(shrunkSize)pt"
        )

        print("PASS: the badge's eyebrow names Sensorium Host in both states")
    }

    do {
        // Collapsing is a pure transition on the state object itself --
        // no window, no screen, so a test can drive it directly and read
        // the answer straight back. So is recording a drag's landing
        // spot: a plain fact about the state, independent of any window.
        let content = HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        let state = HostScreenBadgeState(content: content)
        expect(!state.isCollapsed, "a fresh badge starts expanded, not collapsed to its corner pill")
        expect(state.origin == nil, "a fresh badge has no origin of its own until something sets one")

        var layoutCallCount = 0
        state.onExpansionChange = { layoutCallCount += 1 }
        state.toggleCollapsed()
        expect(state.isCollapsed, "toggling an expanded badge collapses it")
        expect(layoutCallCount == 1, "collapsing tells whatever draws the state to re-lay itself out")

        state.setCollapsed(true)
        expect(layoutCallCount == 1, "setting the same collapsed state again is a no-op -- it does not fire a second, redundant layout pass")

        state.toggleCollapsed()
        expect(!state.isCollapsed, "toggling a collapsed badge expands it back")
        expect(layoutCallCount == 2, "expanding it back fires layout again")

        state.setOrigin(CGPoint(x: 40, y: 60))
        expect(state.origin == CGPoint(x: 40, y: 60), "a drag's ending origin is recorded on the state")

        print("PASS: HostScreenBadgeState's collapse toggle is idempotent and observable, and its origin is a plain recorded fact")
    }

    do {
        // Clamping and the default placement, given only a screen frame
        // and a candidate origin -- the same pure functions
        // `HostScreenBadgeWindowController` calls on every layout pass
        // and every real mouse-up.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 200, height: 28)
        let margin: CGFloat = 12

        let defaultOrigin = HostScreenBadgeState.defaultOrigin(windowSize: windowSize, in: screen, margin: margin)
        expect(
            defaultOrigin == CGPoint(x: screen.maxX - windowSize.width - margin, y: screen.maxY - windowSize.height - margin),
            "a display with no memory places the badge top-right, inset by the margin on both axes -- got \(defaultOrigin)"
        )

        expect(
            HostScreenBadgeState.clampedOrigin(CGPoint(x: -500, y: 500), windowSize: windowSize, in: screen) == CGPoint(x: screen.minX, y: 500),
            "an origin dropped off the left edge clamps back to the screen's own left edge"
        )
        expect(
            HostScreenBadgeState.clampedOrigin(CGPoint(x: 3000, y: 500), windowSize: windowSize, in: screen)
                == CGPoint(x: screen.maxX - windowSize.width, y: 500),
            "an origin dropped off the right edge clamps back so the window's own far edge meets the screen's"
        )
        expect(
            HostScreenBadgeState.clampedOrigin(CGPoint(x: 500, y: -500), windowSize: windowSize, in: screen) == CGPoint(x: 500, y: screen.minY),
            "an origin dropped off the bottom edge clamps back to the screen's own bottom edge"
        )
        expect(
            HostScreenBadgeState.clampedOrigin(CGPoint(x: 500, y: 3000), windowSize: windowSize, in: screen)
                == CGPoint(x: 500, y: screen.maxY - windowSize.height),
            "an origin dropped off the top edge clamps back so the window's own top edge meets the screen's"
        )
        expect(
            HostScreenBadgeState.clampedOrigin(CGPoint(x: 500, y: 500), windowSize: windowSize, in: screen) == CGPoint(x: 500, y: 500),
            "an origin already fully inside the screen is left exactly where it was"
        )

        let tinyScreen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clamped = HostScreenBadgeState.defaultOrigin(windowSize: CGSize(width: 200, height: 28), in: tinyScreen, margin: margin)
        expect(
            clamped.x >= tinyScreen.minX && clamped.x <= tinyScreen.maxX,
            "a window wider than the screen it is placed on still resolves to an origin inside that screen's own bounds, rather than one that would push it off the far edge -- got \(clamped)"
        )

        print("PASS: the badge's origin clamps back into its screen from every side, and a display with no memory defaults top-right")
    }

    do {
        // The pure decision behind every mouse-up on the badge's
        // background: how far a pointer must move before it counts as a
        // drag rather than a click.
        expect(
            !HostScreenBadgeState.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 101, y: 101), threshold: 3),
            "a couple of points of pointer jitter is still a click, not a drag"
        )
        expect(
            HostScreenBadgeState.isDrag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 100), threshold: 3),
            "a pointer that moved well past the threshold counts as a drag"
        )

        print("PASS: a small pointer movement stays a click, only a movement past the threshold counts as a drag")
    }

    do {
        // The badge's position on disk: it round-trips through a second
        // store instance at the same URL, the same way
        // HostScreenSessionLogStore's records already do, and a display
        // this store has never seen resolves to no position rather than
        // an error.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-badge-position-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HostScreenBadgePositionStore(url: url)
        let display = HostScreenDisplayIdentity(vendorNumber: 0x1234, modelNumber: 0x5678)
        let otherDisplay = HostScreenDisplayIdentity(vendorNumber: 0xAAAA, modelNumber: 0xBBBB)
        expect(store.position(for: display) == nil, "a display this store has never remembered a drop for reads back as nothing, not an error")

        store.setPosition(HostScreenBadgePosition(offsetFromFrameOrigin: CGPoint(x: 37, y: 51)), for: display)
        let reopened = HostScreenBadgePositionStore(url: url)
        expect(
            reopened.position(for: display) == HostScreenBadgePosition(offsetFromFrameOrigin: CGPoint(x: 37, y: 51)),
            "a second store instance at the same URL reads back exactly the position the first one wrote"
        )
        expect(
            reopened.position(for: otherDisplay) == nil,
            "a different display's identity gets its own remembered spot -- it does not inherit this one's"
        )

        store.setPosition(HostScreenBadgePosition(offsetFromFrameOrigin: CGPoint(x: 90, y: 12)), for: display)
        expect(
            HostScreenBadgePositionStore(url: url).position(for: display) == HostScreenBadgePosition(offsetFromFrameOrigin: CGPoint(x: 90, y: 12)),
            "dropping the badge again on the same display overwrites its remembered spot rather than keeping the first one"
        )

        print("PASS: the badge's position on disk round-trips per display, and a display never dropped on reads back as nothing")
    }

    do {
        // The controller itself: a fresh badge with nothing remembered
        // for this machine's real main screen defaults top-right, a badge
        // built against a store that already has a position for that
        // screen starts there instead, collapsing and expanding keep the
        // window's own origin fixed, and a geometry change re-clamps an
        // origin that has drifted out of bounds.
        guard let screen = NSScreen.main else {
            expect(false, "no NSScreen.main in this test environment -- the badge window controller needs a real screen to lay out against")
            return
        }
        func realDisplayIdentity(for screen: NSScreen) -> HostScreenDisplayIdentity? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return HostScreenDisplayIdentity(vendorNumber: CGDisplayVendorNumber(id), modelNumber: CGDisplayModelNumber(id))
        }
        let visibleFrame = screen.visibleFrame
        let fullFrame = screen.frame

        let freshURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-badge-position-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: freshURL) }
        let freshStore = HostScreenBadgePositionStore(url: freshURL)
        let freshState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let freshController = HostScreenBadgeWindowController(state: freshState, positionStore: freshStore)
        let freshWindow = CanvasHostTestHooks.hostScreenBadgeWindow(freshController)
        let expectedDefault = HostScreenBadgeState.defaultOrigin(windowSize: freshWindow.frame.size, in: visibleFrame, margin: 12)
        expect(
            freshWindow.frame.origin == expectedDefault,
            "a badge with nothing remembered for this display starts at the default top-right placement -- got \(freshWindow.frame.origin), expected \(expectedDefault)"
        )

        if let identity = realDisplayIdentity(for: screen) {
            let seededURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sensorium-host-screen-badge-position-seeded-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: seededURL) }
            let seededStore = HostScreenBadgePositionStore(url: seededURL)
            seededStore.setPosition(HostScreenBadgePosition(offsetFromFrameOrigin: CGPoint(x: 37, y: 51)), for: identity)
            let seededState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
            let seededController = HostScreenBadgeWindowController(state: seededState, positionStore: seededStore)
            let seededWindow = CanvasHostTestHooks.hostScreenBadgeWindow(seededController)
            expect(
                seededWindow.frame.origin == CGPoint(x: fullFrame.minX + 37, y: fullFrame.minY + 51),
                "a badge built against a store that remembers a drop for this real display starts exactly there, read against the display's full frame -- got \(seededWindow.frame.origin)"
            )
        } else {
            expect(false, "NSScreen.main carries no NSScreenNumber device description key to identify it by")
        }

        let anchorState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let anchorController = HostScreenBadgeWindowController(state: anchorState, restoresPersistedLayout: false)
        let expandedOrigin = CanvasHostTestHooks.hostScreenBadgeWindow(anchorController).frame.origin
        anchorState.toggleCollapsed()
        let collapsedOrigin = CanvasHostTestHooks.hostScreenBadgeWindow(anchorController).frame.origin
        expect(
            collapsedOrigin == expandedOrigin,
            "collapsing keeps the window's own origin fixed even though its height shrinks -- expanded \(expandedOrigin), collapsed \(collapsedOrigin)"
        )
        anchorState.toggleCollapsed()
        let reexpandedOrigin = CanvasHostTestHooks.hostScreenBadgeWindow(anchorController).frame.origin
        expect(
            reexpandedOrigin == expandedOrigin,
            "expanding back keeps the same origin too -- the badge never jumps across a collapse/expand round trip"
        )

        let driftedState = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            origin: CGPoint(x: fullFrame.maxX + 5_000, y: fullFrame.maxY + 5_000)
        )
        let driftedController = HostScreenBadgeWindowController(state: driftedState, restoresPersistedLayout: false)
        driftedController.handleScreenParametersChange()
        let reclamped = driftedState.origin ?? .zero
        expect(
            reclamped.x <= fullFrame.maxX && reclamped.y <= fullFrame.maxY,
            "an origin left far outside the screen by an earlier geometry change is re-clamped back inside its full frame -- got \(reclamped)"
        )

        print("PASS: the badge defaults top-right, restores a remembered drop for the real display, keeps its origin across collapse/expand, and re-clamps on a geometry change")
    }

    do {
        // The collapsed pill itself: no eyebrow, no display line,
        // a status dot, the device name, and Stop -- the full second
        // line moves to the window's tooltip instead of vanishing.
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview -> [NSTextField] in
                if let field = subview as? NSTextField { return [field] }
                return labels(in: subview)
            }
        }
        func hasButton(in view: NSView) -> Bool {
            view.subviews.contains { $0 is NSButton || hasButton(in: $0) }
        }
        let state = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let controller = HostScreenBadgeWindowController(state: state, restoresPersistedLayout: false)
        let expandedWindow = CanvasHostTestHooks.hostScreenBadgeWindow(controller)
        let expandedHeight = expandedWindow.frame.height

        state.toggleCollapsed()
        let collapsedWindow = CanvasHostTestHooks.hostScreenBadgeWindow(controller)
        expect(
            collapsedWindow.frame.height < expandedHeight,
            "the collapsed pill is strictly shorter than the expanded badge -- got expanded \(expandedHeight), collapsed \(collapsedWindow.frame.height)"
        )
        if let content = collapsedWindow.contentView {
            let visibleTexts = labels(in: content).filter { !$0.isHidden }.map(\.stringValue)
            expect(
                visibleTexts.contains("Kestrel Laptop Pro"),
                "the collapsed pill still names the device -- got: \(visibleTexts)"
            )
            expect(
                !visibleTexts.contains("SENSORIUM HOST") && !visibleTexts.contains("Sees and controls Built-in Display"),
                "the collapsed pill drops the eyebrow and the display line -- got: \(visibleTexts)"
            )
            expect(
                hasButton(in: content),
                "the collapsed pill keeps its Stop button"
            )
            expect(
                content.toolTip == "Sees and controls Built-in Display",
                "the full second line moves to the pill's tooltip rather than disappearing -- got: \(String(describing: content.toolTip))"
            )
        } else {
            expect(false, "the collapsed badge window has no content view")
        }

        print("PASS: the collapsed badge names only the device, keeps Stop, and carries the display line as a tooltip")
    }

    do {
        // The badge window's level: it must stay visible above the Dock
        // and the menu bar, since it can be dropped directly on either.
        let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let controller = HostScreenBadgeWindowController(state: state)
        let window = CanvasHostTestHooks.hostScreenBadgeWindow(controller)
        let overlayLevel = Int(CGWindowLevelForKey(.overlayWindow))
        expect(
            window.level.rawValue >= overlayLevel,
            "the badge window's level is at or above the overlay level, so it stays visible over the Dock and menu bar wherever it is placed -- got \(window.level.rawValue), need at least \(overlayLevel)"
        )

        print("PASS: the badge window's level sits at or above the overlay level")
    }

    do {
        // A drop into the menu-bar strip -- flush with the very top of the
        // display -- must stay exactly there, since the badge clamps
        // against the display's full frame.
        guard let screen = NSScreen.main else {
            expect(false, "no NSScreen.main in this test environment -- the badge window controller needs a real screen to lay out against")
            return
        }
        func realDisplayIdentity(for screen: NSScreen) -> HostScreenDisplayIdentity? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return HostScreenDisplayIdentity(vendorNumber: CGDisplayVendorNumber(id), modelNumber: CGDisplayModelNumber(id))
        }
        guard let identity = realDisplayIdentity(for: screen) else {
            expect(false, "NSScreen.main carries no NSScreenNumber device description key to identify it by")
            return
        }
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        guard fullFrame.maxY > visibleFrame.maxY else {
            expect(false, "this screen reports no menu-bar strip to test the full-frame clamp against")
            return
        }

        // Measure this badge's own size first, from a controller with
        // nothing persisted, so the offset below lands it flush with the
        // top of the full frame whatever that size turns out to be.
        let measuringState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let measuringController = HostScreenBadgeWindowController(state: measuringState, restoresPersistedLayout: false)
        let windowSize = CanvasHostTestHooks.hostScreenBadgeWindow(measuringController).frame.size

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-badge-position-fullframe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostScreenBadgePositionStore(url: url)
        let flushWithTop = CGPoint(x: 40, y: fullFrame.height - windowSize.height)
        store.setPosition(HostScreenBadgePosition(offsetFromFrameOrigin: flushWithTop), for: identity)

        let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let controller = HostScreenBadgeWindowController(state: state, positionStore: store)
        let window = CanvasHostTestHooks.hostScreenBadgeWindow(controller)
        let expectedOrigin = CGPoint(x: fullFrame.minX + flushWithTop.x, y: fullFrame.minY + flushWithTop.y)
        expect(
            window.frame.origin == expectedOrigin,
            "a persisted drop flush with the top of the full frame stays there -- got \(window.frame.origin), expected \(expectedOrigin)"
        )
        expect(
            window.frame.maxY > visibleFrame.maxY,
            "the placement genuinely reaches above the visible frame's own top edge, into the menu-bar strip, or this test proves nothing -- window top \(window.frame.maxY), visible frame top \(visibleFrame.maxY)"
        )

        print("PASS: a persisted position inside the menu-bar strip is honoured, since the clamp bounds against the display's full frame")
    }

    do {
        // The border gradient: pure geometry behind its rotation, the two
        // tokens driving its colour, and its rotation duration -- all
        // testable without a window.
        let start = HostScreenBadgeState.borderGradientRotationKeyframes(sampleCount: 4, radius: 0.5, phaseOffset: 0)
        expect(start.count == 5, "sampleCount + 1 points come back, closing the loop with one extra sample -- got \(start.count)")
        func close(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 0.0001) -> Bool {
            abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
        }
        expect(close(start[0], CGPoint(x: 1.0, y: 0.5)), "the first sample sits at phaseOffset 0, one radius to the right of centre -- got \(start[0])")
        expect(close(start[1], CGPoint(x: 0.5, y: 1.0)), "a quarter turn later the sample sits one radius above centre -- got \(start[1])")
        expect(close(start[2], CGPoint(x: 0.0, y: 0.5)), "half a turn later the sample sits one radius to the left of centre -- got \(start[2])")
        expect(close(start[4], start[0]), "the last sample closes the loop back onto the first, so a repeating keyframe animation has no seam -- got \(start[4]) vs \(start[0])")

        expect(
            HostScreenBadgeState.borderGradientColors == [CanvasDesign.accent, CanvasDesign.accent2],
            "the border sweeps from the primary accent to the secondary accent, in that order"
        )
        expect(CanvasDesign.accent2 == DesignColor(hex: 0xF0A8D0), "the secondary accent is the soft pink token")
        expect(HostScreenBadgeState.borderGradientRotationDuration == 6, "one full sweep of the border takes six seconds")

        print("PASS: the border gradient's rotation keyframes trace a circle around the badge's centre, and its colours and duration are the primary and secondary accents")
    }

    do {
        // The collapsed pill's pulse: its own duration and opacity range,
        // and the flag saying when it should be running.
        expect(HostScreenBadgeState.collapsedPulseDuration == 1.2, "one breath of the collapsed pill takes 1.2 seconds")
        expect(
            HostScreenBadgeState.collapsedPulseOpacityRange.from == 1.0 && HostScreenBadgeState.collapsedPulseOpacityRange.to == 0.6,
            "the pill's fill breathes from fully opaque down to 0.6 and back"
        )

        let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        expect(!state.collapsedPulses, "an expanded badge is not pulsing")
        state.setCollapsed(true)
        expect(state.collapsedPulses, "collapsing starts the pulse")
        state.setCollapsed(false)
        expect(!state.collapsedPulses, "expanding back stops the pulse")

        print("PASS: the collapsed pill's pulse duration and opacity range are fixed, and it pulses exactly while the pill is collapsed")
    }

    do {
        // The live badge: the border rotates unless Reduce Motion is on,
        // and the collapsed pill's fill pulses unless Reduce Motion is on.
        func mirrorField<T>(_ name: String, of object: Any) -> T {
            for child in Mirror(reflecting: object).children {
                if child.label == name, let value = child.value as? T {
                    return value
                }
            }
            fatalError("no stored property named \(name) of type \(T.self)")
        }

        let motionState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let movingController = HostScreenBadgeWindowController(state: motionState, restoresPersistedLayout: false, prefersReducedMotion: { false })
        let movingBorder: CAGradientLayer = mirrorField("borderGradientLayer", of: movingController)
        expect(
            movingBorder.animation(forKey: "borderGradientStartPointRotation") != nil
                && movingBorder.animation(forKey: "borderGradientEndPointRotation") != nil,
            "with Reduce Motion off, the border gradient's start and end points both carry a running rotation"
        )

        let stillState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let stillController = HostScreenBadgeWindowController(state: stillState, restoresPersistedLayout: false, prefersReducedMotion: { true })
        let stillBorder: CAGradientLayer = mirrorField("borderGradientLayer", of: stillController)
        expect(
            stillBorder.animation(forKey: "borderGradientStartPointRotation") == nil
                && stillBorder.animation(forKey: "borderGradientEndPointRotation") == nil,
            "with Reduce Motion on, the border gradient carries no rotation"
        )
        expect(
            stillBorder.startPoint == CGPoint(x: 0, y: 0) && stillBorder.endPoint == CGPoint(x: 1, y: 1),
            "with Reduce Motion on, the border still shows a fixed diagonal gradient rather than none at all -- got \(stillBorder.startPoint) to \(stillBorder.endPoint)"
        )

        let pulsingState = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            startsCollapsed: true
        )
        let pulsingController = HostScreenBadgeWindowController(state: pulsingState, restoresPersistedLayout: false, prefersReducedMotion: { false })
        let pulsingLayer = CanvasHostTestHooks.hostScreenBadgeWindow(pulsingController).contentView?.layer
        expect(
            pulsingLayer?.animation(forKey: "collapsedPillOpacityPulse") != nil,
            "a collapsed pill with Reduce Motion off carries a running opacity pulse"
        )

        let expandedState = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        let expandedController = HostScreenBadgeWindowController(state: expandedState, restoresPersistedLayout: false, prefersReducedMotion: { false })
        let expandedLayer = CanvasHostTestHooks.hostScreenBadgeWindow(expandedController).contentView?.layer
        expect(
            expandedLayer?.animation(forKey: "collapsedPillOpacityPulse") == nil,
            "an expanded badge never pulses -- only the collapsed pill does"
        )

        let stillPulseState = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            startsCollapsed: true
        )
        let stillPulseController = HostScreenBadgeWindowController(state: stillPulseState, restoresPersistedLayout: false, prefersReducedMotion: { true })
        let stillPulseLayer = CanvasHostTestHooks.hostScreenBadgeWindow(stillPulseController).contentView?.layer
        expect(
            stillPulseLayer?.animation(forKey: "collapsedPillOpacityPulse") == nil && stillPulseLayer?.opacity == 1,
            "a collapsed pill with Reduce Motion on stays at full opacity, not pulsing"
        )

        print("PASS: the border gradient rotates and the collapsed pill's fill pulses unless Reduce Motion is on, in which case both hold still")
    }
}
