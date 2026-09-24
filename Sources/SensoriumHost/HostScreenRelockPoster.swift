import CoreGraphics
import Foundation

/// Locks this machine's screen, the way a person at the keyboard would.
public protocol HostScreenRelocking: Sendable {
    /// Posts the relock shortcut. Returns whether both of its events were
    /// actually built and posted, not whether the OS went on to lock the
    /// screen, which nothing here can observe.
    @discardableResult
    func relock() -> Bool
}

/// Posts macOS's own Lock Screen shortcut, Control-Command-Q, so a machine a
/// host-screen session found or left unlocked locks again once that session
/// ends. Posted at `.cghidEventTap`, the same tap the system-hotkey and
/// locked-screen exceptions in `CoreGraphicsInputInjector` use, not
/// `.cgSessionEventTap`.
///
/// Each of the two posted events samples `hostInjectedHIDActivity`
/// immediately before it posts, then records into it, so
/// `SelfPostDiscountingLocalActivitySignal` can tell this relock keystroke
/// apart from a real person's later -- and so a real person's own input
/// just before it is not lost to it.
public struct CoreGraphicsHostScreenRelockPoster: HostScreenRelocking {
    /// `kVK_ANSI_Q`.
    static let lockScreenKeyCode: UInt16 = 12

    /// The seam a test uses to record what this posted, instead of calling
    /// the real `CGEvent.post`, which would inject a real synthetic event
    /// system-wide.
    private let postEvent: @Sendable (CGEvent, CGEventTapLocation) -> Void
    private let hostInjectedHIDActivity: any HostInjectedHIDActivity

    public init(
        hostInjectedHIDActivity: any HostInjectedHIDActivity = MutableHostInjectedHIDActivity.shared,
        postEvent: @escaping @Sendable (CGEvent, CGEventTapLocation) -> Void = { event, tap in event.post(tap: tap) }
    ) {
        self.hostInjectedHIDActivity = hostInjectedHIDActivity
        self.postEvent = postEvent
    }

    @discardableResult
    public func relock() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.lockScreenKeyCode,
                keyDown: isDown
            ) else {
                return false
            }
            event.flags = [.maskControl, .maskCommand]
            hostInjectedHIDActivity.sampleBeforePost()
            hostInjectedHIDActivity.recordPost()
            postEvent(event, .cghidEventTap)
        }
        return true
    }
}
