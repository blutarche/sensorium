import AppKit
import Foundation
import SensoriumHost

/// Proves `RunLoopPresenceWaiting`'s own contract: an answer wins, a
/// timeout wins, and it never establishes a modal session, so every other
/// window's own Stop control stays clickable while it waits. Unlike the
/// panel itself, `wait` takes a plain predicate and no window at all, so
/// this is testable directly, without AppKit ever showing anything.
@MainActor
func runHostScreenPresenceWaitingTests() async {
    do {
        // A wait with nothing else on the main run loop's own
        // .default mode -- no timer, no window, nothing -- must
        // not busy-spin polling isResolved. This block has to run
        // first, before any test below reads NSApplication.shared:
        // doing so registers sources that give the mode something
        // to pump and masks the spin.
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        var isResolvedCalls = 0
        let start = Date()
        waiting.wait(until: start.addingTimeInterval(0.2)) {
            isResolvedCalls += 1
            return false
        }
        let elapsed = Date().timeIntervalSince(start)

        expect(elapsed >= 0.2 - 0.0001, "wait still honors its own deadline")
        expect(isResolvedCalls <= 20, "isResolved was called about once per 0.02s poll slice across a 0.2s wait, not spun -- a run loop mode with nothing to pump must not turn every slice into a busy loop")

        print("PASS: RunLoopPresenceWaiting does not busy-spin when the main run loop's .default mode has nothing else to pump")
    }

    do {
        // An answer that arrives before the deadline wins: wait
        // returns as soon as isResolved becomes true, not only once
        // the deadline itself passes.
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        var resolved = false
        let resolveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { resolved = true }
        }
        let start = Date()
        waiting.wait(until: start.addingTimeInterval(30)) { resolved }
        let elapsed = Date().timeIntervalSince(start)
        resolveTimer.invalidate()

        expect(resolved, "isResolved was true by the time wait returned")
        expect(elapsed < 30, "wait returned once resolved, not only once the far-off thirty-second deadline passed")

        print("PASS: RunLoopPresenceWaiting returns as soon as isResolved becomes true, not only at the deadline")
    }

    do {
        // A deadline that passes with isResolved never true still
        // returns -- never hangs -- and does so close to the
        // deadline, not the far-off bound above.
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        let start = Date()
        waiting.wait(until: start.addingTimeInterval(0.15)) { false }
        let elapsed = Date().timeIntervalSince(start)

        // A tenth of a millisecond of slack: `Date()` calls on either side
        // of the deadline comparison are themselves not free, and without
        // this, a run landing within that sliver reads as "returned before
        // its own deadline" for a reason that has nothing to do with
        // `wait`'s own correctness.
        expect(elapsed >= 0.15 - 0.0001, "wait never returns before its own deadline")
        expect(elapsed < 10, "wait returns close to its own deadline, not stuck waiting on something else")

        print("PASS: RunLoopPresenceWaiting returns once its own deadline passes, when isResolved never becomes true")
    }

    do {
        // Never modal, and other main-queue work still runs during
        // the wait -- proof this is not NSApp.runModal(for:) in
        // disguise, which would block both. Unrelated work running
        // does not itself resolve or cancel the wait.
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        var sawNonNilModalWindow = false
        let modalCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                // `NSApp` itself (the C global `NSApplication` sets as a
                // side effect of `.shared` being read at least once) is
                // nil in this bare command-line test runner, which never
                // creates an `NSApplication` -- unlike `sensoriumd`, which
                // always does before any of this code runs there.
                // `NSApplication.shared` is what actually creates and sets
                // it, safe to call here for exactly that reason.
                if NSApplication.shared.modalWindow != nil { sawNonNilModalWindow = true }
            }
        }
        // Stands in for "a Stop button on a different, unrelated session"
        // -- unrelated AppKit work scheduled while this wait is up.
        var unrelatedWorkRan = false
        let unrelatedWorkTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { unrelatedWorkRan = true }
        }

        let start = Date()
        waiting.wait(until: start.addingTimeInterval(0.2)) { false }
        let elapsed = Date().timeIntervalSince(start)
        modalCheckTimer.invalidate()
        unrelatedWorkTimer.invalidate()

        expect(!sawNonNilModalWindow, "RunLoopPresenceWaiting never establishes a modal session -- NSApp.modalWindow stays nil throughout the wait")
        expect(unrelatedWorkRan, "unrelated default-mode work scheduled during the wait still ran -- every other window stays responsive, unlike NSApp.runModal(for:)")
        expect(elapsed >= 0.2, "the unrelated work running, and no modal session existing, still did not resolve or cancel the wait early -- only isResolved and the deadline can")

        print("PASS: RunLoopPresenceWaiting never establishes a modal session, keeps unrelated default-mode work running, and neither is affected by the other")
    }

    do {
        // The real reason this type exists: a click queued for an
        // on-screen button must actually fire while `wait` pumps for
        // it. Servicing timers, as the blocks above prove, is not the
        // same as dispatching a real mouse-down/mouse-up pair to a
        // real window through NSApp's own event queue.
        setPresenceWaitingTestAccessoryPolicy()
        let target = PresenceWaitingClickTarget()
        let panel = makePresenceWaitingTestPanel(origin: NSPoint(x: 100, y: 100))
        let button = addPresenceWaitingTestButton(to: panel, target: target)
        panel.makeKeyAndOrderFront(nil)

        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        // Lets the window server finish placing `panel` before a click is
        // queued for it -- a click posted immediately after ordering a
        // window front can otherwise be hit-tested against a frame the
        // window has not actually settled into yet.
        waiting.wait(until: Date().addingTimeInterval(0.1)) { false }
        postPresenceWaitingTestClick(at: presenceWaitingTestButtonCenter(button), windowNumber: panel.windowNumber)
        waiting.wait(until: Date().addingTimeInterval(1)) { target.fired }
        panel.orderOut(nil)

        expect(target.fired, "a queued click on a real window's button fired while RunLoopPresenceWaiting pumped -- proof it dispatches real AppKit events, not only CFRunLoop timers")

        print("PASS: RunLoopPresenceWaiting dispatches a queued click to a real window's button")
    }

    do {
        // Non-modal, proven with a real click rather than a timer:
        // a click queued for a second, unrelated window still fires
        // while `wait` pumps for some other window's own predicate
        // that never becomes true -- the same guarantee a live Stop
        // control on a different connection's own window depends on.
        setPresenceWaitingTestAccessoryPolicy()
        let waitedOnTarget = PresenceWaitingClickTarget()
        let waitedOnPanel = makePresenceWaitingTestPanel(origin: NSPoint(x: 300, y: 300))
        _ = addPresenceWaitingTestButton(to: waitedOnPanel, target: waitedOnTarget)
        waitedOnPanel.makeKeyAndOrderFront(nil)

        let secondTarget = PresenceWaitingClickTarget()
        let secondPanel = makePresenceWaitingTestPanel(origin: NSPoint(x: 600, y: 300))
        let secondButton = addPresenceWaitingTestButton(to: secondPanel, target: secondTarget)
        secondPanel.orderFrontRegardless()

        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        // See the block above: let both windows settle before queuing the click.
        waiting.wait(until: Date().addingTimeInterval(0.1)) { false }
        postPresenceWaitingTestClick(
            at: presenceWaitingTestButtonCenter(secondButton),
            windowNumber: secondPanel.windowNumber
        )
        waiting.wait(until: Date().addingTimeInterval(0.3)) { waitedOnTarget.fired }
        waitedOnPanel.orderOut(nil)
        secondPanel.orderOut(nil)

        expect(!waitedOnTarget.fired, "nothing clicked the window wait was actually watching")
        expect(secondTarget.fired, "a click queued for a second, unrelated window still fired while wait pumped for a predicate that never resolved -- every other window stays responsive while this one waits")

        print("PASS: RunLoopPresenceWaiting delivers a click to a second window while pumping for a different window's own predicate")
    }
}

/// A bare command-line test runner starts with activation policy
/// `.prohibited`, under which a window can never become key -- `sensoriumd`
/// itself never runs this way (see its own `setActivationPolicy(.accessory)`
/// in `main.swift`), so a test proving a real click lands has to first put
/// this process into the same `.accessory` policy the real host process
/// already starts in, or the click below would fail for a reason that has
/// nothing to do with `RunLoopPresenceWaiting` itself. Never actually
/// activates this process -- production's own presence prompt never does
/// either (`.nonactivatingPanel`), and a click firing only because this
/// process happened to be the active app would prove less than it looks
/// like it proves.
@MainActor
private func setPresenceWaitingTestAccessoryPolicy() {
    NSApplication.shared.setActivationPolicy(.accessory)
}

/// Records whether the button it is wired to was actually clicked -- through
/// a real `NSButton` target/action pair, not a stand-in closure, since the
/// point of these tests is that `NSApp.sendEvent` really dispatched it.
@MainActor
private final class PresenceWaitingClickTarget {
    private(set) var fired = false

    @objc func fire() {
        fired = true
    }
}

/// A small, real, on-screen panel -- on-screen because a queued `NSEvent`
/// only reaches a window that the window server can actually route it to;
/// unlike every other test in this file, this one is about whether a real
/// click lands, so the window it lands on cannot stay off-screen the way
/// `HostScreenPresencePromptTests`'s own panels do.
/// `origin` matters: two panels both left at their default `(0, 0)` frame
/// collide, and macOS nudges the later one to a cascaded position after it
/// is ordered front -- moving it out from under the click coordinates this
/// file already computed against its original frame.
@MainActor
private func makePresenceWaitingTestPanel(origin: NSPoint) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    panel.setFrameOrigin(origin)
    return panel
}

@MainActor
private func addPresenceWaitingTestButton(to panel: NSPanel, target: PresenceWaitingClickTarget) -> NSButton {
    let button = NSButton(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
    button.target = target
    button.action = #selector(PresenceWaitingClickTarget.fire)
    panel.contentView?.addSubview(button)
    return button
}

@MainActor
private func presenceWaitingTestButtonCenter(_ button: NSButton) -> NSPoint {
    button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
}

/// Queues a left-click -- mouse-down immediately followed by mouse-up, the
/// pair a real `NSButton` requires to fire its action -- at `point` (window
/// coordinates) on the window numbered `windowNumber`, through the same
/// `NSApp.postEvent(_:atStart:)` queue a real click arrives on.
@MainActor
private func postPresenceWaitingTestClick(at point: NSPoint, windowNumber: Int) {
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("expected NSEvent.mouseEvent to build a synthetic \(type) event")
        }
        NSApplication.shared.postEvent(event, atStart: false)
    }
}
