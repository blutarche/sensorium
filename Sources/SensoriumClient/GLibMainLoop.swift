#if canImport(CGLib)
import CGLib
import CGLibDispatchBridge
import Foundation

/// The event loop a Linux viewer runs on.
///
/// Wayland, EGL and this process's own Swift concurrency all have to be driven
/// from one thread, and only one of them can own the blocking call that waits
/// for work. GLib's main loop owns it, and Dispatch's main queue is attached
/// to the same context, so a `DispatchQueue.main.async` block and a
/// `@MainActor` job both run on the thread inside `run()` -- which is the
/// thread that holds the Wayland connection and the GL context.
///
/// `run()` must be called from the main actor, and before that actor has ever
/// suspended. The attachment works by handing GLib the descriptor Dispatch
/// signals when the main queue has work, and Dispatch only offers that
/// descriptor while the main queue is still bound to the thread it started on.
/// The first suspension of the main actor hands the queue to Dispatch's own
/// drain instead, after which the descriptor is gone and nothing scheduled
/// would ever reach the loop. A loop entered in time can be stopped and
/// re-entered freely, and ordinary `await` works again once it has returned.
public enum GLibMainLoop {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loop: OpaquePointer?
    nonisolated(unsafe) private static var hasAttached = false
    nonisolated(unsafe) private static var isAttached = false

    /// Attaches the Dispatch main queue to the default context, and reports
    /// whether it took. Done once per process, and done by `run()` too, so a
    /// caller only needs this to find out early -- before scheduling the work
    /// the loop is meant to carry -- whether this process is still in time.
    @MainActor
    @discardableResult
    public static func attachMainQueue() -> Bool {
        if hasAttached { return isAttached }
        hasAttached = true
        isAttached = sensorium_attach_dispatch_main_queue() != 0
        if !isAttached {
            print("Sensorium: the main queue could not be attached to the GLib main loop -- scheduled work will not run on the loop's own thread")
        }
        return isAttached
    }

    /// Runs until `stop()`. Returns when the loop has ended.
    @MainActor
    public static func run() {
        attachMainQueue()
        guard let created = g_main_loop_new(nil, 0) else {
            print("Sensorium: a GLib main loop could not be created")
            return
        }
        lock.lock()
        loop = created
        lock.unlock()
        g_main_loop_run(created)
        lock.lock()
        loop = nil
        lock.unlock()
        g_main_loop_unref(created)
    }

    /// Ends the running loop. Safe from any thread, and a no-op when no loop
    /// is running.
    public static func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let running = loop else { return }
        g_main_loop_quit(running)
    }

    public static var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loop != nil
    }
}
#endif
