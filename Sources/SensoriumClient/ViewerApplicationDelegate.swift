#if canImport(AppKit)
import AppKit

/// Reopening this app from its Dock icon with no window on screen -- every
/// canvas closed, and the Your Machines list dismissed too -- has nothing
/// else to bring back; `onReopenWithNoWindows` shows the list again.
/// `beforeTerminate` runs what must finish before AppKit ends the app.
@MainActor
public final class ViewerApplicationDelegate: NSObject, NSApplicationDelegate {
    private let onReopenWithNoWindows: () -> Void
    private let replyToTerminate: @MainActor (Bool) -> Void

    /// Runs when AppKit is asked to terminate the app: a quit from the Dock,
    /// a logout or shutdown, or an Apple Event, none of which passes through
    /// the viewer's own quit. Returns true when AppKit may terminate now, or
    /// false to have it wait until `proceed` is called.
    public var beforeTerminate: (@MainActor (_ proceed: @escaping @MainActor () -> Void) -> Bool)?

    public init(
        onReopenWithNoWindows: @escaping () -> Void,
        replyToTerminate: @escaping @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
    ) {
        self.onReopenWithNoWindows = onReopenWithNoWindows
        self.replyToTerminate = replyToTerminate
        super.init()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeTerminate else {
            return .terminateNow
        }
        let replyToTerminate = replyToTerminate
        return beforeTerminate { replyToTerminate(true) } ? .terminateNow : .terminateLater
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            onReopenWithNoWindows()
        }
        return true
    }
}
#endif
