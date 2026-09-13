import Foundation

/// Every canvas display this process created and has not given back.
///
/// A virtual display outlives the process that created it. No public API
/// removes another process's display, so a host that ends without releasing
/// its canvases leaves them online, still holding their identities, until the
/// machine is restarted -- and every later host launch has to step past them.
/// This is what the deliberate quit path and the termination-signal handlers
/// both run so that never happens: the adapter records each canvas here as it
/// creates it and drops it again as it releases it, and shutting down releases
/// whatever is left.
///
/// Separate from `HostShutdownRegistry`, which ends live sessions: those
/// teardowns are asynchronous, and a signal handler has no opportunity to
/// await anything. Releasing a display is synchronous, so this can always
/// finish before the process exits.
@MainActor
public final class CanvasShutdown {
    public typealias Release = @MainActor (VirtualDisplayHandle) -> Void

    private var live: [(handle: VirtualDisplayHandle, release: Release)] = []

    public init() {}

    /// How many canvases this process would still have to release if it ended
    /// right now.
    public var liveCanvasCount: Int { live.count }

    public func record(_ handle: VirtualDisplayHandle, release: @escaping Release) {
        live.append((handle: handle, release: release))
    }

    public func forget(_ handle: VirtualDisplayHandle) {
        live.removeAll { $0.handle == handle }
    }

    /// Releases every canvas still held, and can be called any number of
    /// times: the list is emptied before anything is released, so a quit and
    /// a termination signal arriving together cannot ask for the same display
    /// twice, and neither can a release that comes back through `forget`.
    public func releaseEverything() {
        let pending = live
        live.removeAll()
        for entry in pending {
            entry.release(entry.handle)
        }
    }
}
