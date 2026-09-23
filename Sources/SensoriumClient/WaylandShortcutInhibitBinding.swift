import Foundation

/// Stands in for the window a shortcut interceptor will inhibit, before that
/// window exists.
///
/// The viewer builds one `SystemShortcutForwarder` per session and hands it an
/// interceptor at that moment, but the session's window is opened a step
/// later -- so the interceptor is pointed at this, and this is pointed at the
/// window as soon as there is one. Held weakly: the window outlives nothing
/// here, and a closed one must not be asked to give the compositor's shortcuts
/// back.
@MainActor
public final class WaylandShortcutInhibitBinding: WaylandShortcutInhibiting {
    public weak var window: (any WaylandShortcutInhibiting)?

    public init() {}

    public func requestShortcutInhibitor() -> Bool {
        window?.requestShortcutInhibitor() ?? false
    }

    public func destroyShortcutInhibitor() {
        window?.destroyShortcutInhibitor()
    }
}
