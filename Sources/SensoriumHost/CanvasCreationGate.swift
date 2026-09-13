import Foundation

/// Another canvas creation is already in flight on the same gate.
public enum CanvasCreationGateError: Error, Equatable {
    case creationInProgress
}

/// Serialises the one operation that must never overlap: placing the session
/// workspace on a virtual display whose registration with WindowServer is
/// still asynchronous.
///
/// The wait for that registration (`CanvasDisplayReadiness.awaitReady`) pumps
/// the real AppKit run loop so pending CoreGraphics/AppKit notifications can
/// be delivered. Two overlapping creations sharing process-global
/// CoreGraphics display state is what corrupts the display-ID allocator:
/// releasing a virtual display while its registration is still in flight has
/// been observed to leave every later `CGDisplayBounds` call on this process
/// reporting zero, permanently, until restart.
///
/// A request that arrives while one is already in flight is rejected
/// outright rather than queued: this gate never touches display state on
/// rejection, so the caller has nothing of its own to unwind, and a personal
/// multi-machine setup is exactly the situation where two of the user's own
/// machines can race a connection.
///
/// A nested `RunLoop.main.run(mode:before:)` services run-loop sources but
/// never the main dispatch queue, and every canvas request and release
/// arrives as a main-queue job, so no second call can reach this gate while a
/// pump holds the main actor. The guard is kept because that rests on an
/// undocumented CoreFoundation reentrancy rule an async `main` would reverse
/// silently, and the hazard corrupts the process display-ID allocator for its
/// whole lifetime.
@MainActor
public final class CanvasCreationGate {
    private var isCreating = false
    /// Release work that arrived while `isCreating` was true, queued rather
    /// than run inline. See `runAfterCreation`.
    private var deferredUntilCreationEnds: [() -> Void] = []

    public init() {}

    /// Runs `work` if no other creation is in flight, otherwise throws
    /// `CanvasCreationGateError.creationInProgress` without invoking `work`
    /// at all. `work` is expected to pump the run loop and may itself hand
    /// control back to a second, reentrant call to `run` on this same gate —
    /// that reentrant call is exactly the case this rejects.
    public func run<T>(_ work: () throws -> T) throws -> T {
        guard !isCreating else {
            throw CanvasCreationGateError.creationInProgress
        }
        isCreating = true
        defer {
            isCreating = false
            runDeferred()
        }
        return try work()
    }

    /// Runs `work` immediately when no creation is in flight. Unlike `run`,
    /// a caller arriving while one *is* in flight is never rejected: `work`
    /// is queued and runs once the in-flight `run` call returns, so a
    /// release this deferral guards can never be dropped or leaked, only
    /// delayed. Queueing rather than throwing is what makes this safe under
    /// the same-thread reentrancy `run` documents: a call arriving from
    /// inside `run`'s own `work` closure queues here and returns
    /// immediately, so there is nothing to block on and nothing that can
    /// deadlock.
    public func runAfterCreation(_ work: @escaping () -> Void) {
        if isCreating {
            deferredUntilCreationEnds.append(work)
        } else {
            work()
        }
    }

    private func runDeferred() {
        guard !deferredUntilCreationEnds.isEmpty else { return }
        let pending = deferredUntilCreationEnds
        deferredUntilCreationEnds = []
        for work in pending {
            work()
        }
    }
}
