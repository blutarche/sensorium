#if canImport(AppKit)
import AppKit

/// Reopening this app from its Dock icon with no window on screen -- every
/// canvas closed, and the Your Machines list dismissed too -- has nothing
/// else to bring back; `onReopenWithNoWindows` shows the list again.
@MainActor
public final class ViewerApplicationDelegate: NSObject, NSApplicationDelegate {
    private let onReopenWithNoWindows: () -> Void

    public init(onReopenWithNoWindows: @escaping () -> Void) {
        self.onReopenWithNoWindows = onReopenWithNoWindows
        super.init()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            onReopenWithNoWindows()
        }
        return true
    }
}
#endif
