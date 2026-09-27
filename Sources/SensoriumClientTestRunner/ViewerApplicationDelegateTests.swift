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
#endif
