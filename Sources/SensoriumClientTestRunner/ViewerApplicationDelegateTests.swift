#if canImport(AppKit)
import AppKit
import SensoriumClient

/// Clicking the Dock icon with no window open is how a person who closed
/// every canvas and the Your Machines window gets back to the list --
/// `applicationShouldHandleReopen(_:hasVisibleWindows:)` is the one hook
/// AppKit offers for it.
@MainActor
func testViewerApplicationDelegateTests() {
    var reopenCount = 0
    let delegate = ViewerApplicationDelegate(onReopenWithNoWindows: { reopenCount += 1 })

    let handledWithNone = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
    expect(handledWithNone, "with no windows open, the delegate takes over the reopen")
    expect(reopenCount == 1, "and fires the callback exactly once, got \(reopenCount)")

    let handledWithSome = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
    expect(handledWithSome, "with a window already open, AppKit's own default reopen behaviour still runs")
    expect(reopenCount == 1, "and the callback does not fire again, got \(reopenCount)")

    print("PASS: reopening with no windows brings back the Your Machines list")
}

/// A quit from the Dock, a logout or shutdown, or an Apple Event reaches the
/// app only as `applicationShouldTerminate(_:)`. Work that must finish first
/// holds AppKit back until it says to go ahead.
@MainActor
func testViewerApplicationDelegateTerminateTests() {
    var replies: [Bool] = []
    let delegate = ViewerApplicationDelegate(onReopenWithNoWindows: {}, replyToTerminate: { replies.append($0) })
    expect(
        delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
        "with nothing to run first, AppKit terminates at once"
    )

    var asked = 0
    delegate.beforeTerminate = { _ in
        asked += 1
        return true
    }
    expect(
        delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
        "work that finished on the spot lets AppKit terminate at once"
    )
    expect(asked == 1, "and is run once per request, got \(asked)")

    var proceed: (@MainActor () -> Void)?
    delegate.beforeTerminate = { next in
        proceed = next
        return false
    }
    expect(
        delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
        "work still under way holds AppKit back"
    )
    expect(replies.isEmpty, "and AppKit is not answered yet, got \(replies)")
    proceed?()
    expect(replies == [true], "once the work is done, AppKit is told to go ahead, got \(replies)")
    print("PASS: a quit from outside the app runs the work that must come first, and waits for it")
}
#endif
