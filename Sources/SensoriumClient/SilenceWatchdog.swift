import Foundation
import SensoriumCore

/// Notices a stretch of time with nothing received, independently of
/// whatever idle timeout the transport itself offers -- a QUIC idle timeout
/// only fires once the OS itself gives up on the socket, which in the field
/// can run far longer than the interval it was configured with.
///
/// `start()`, `heard()`, and `stop()` are meant to be called from whichever
/// queue owns the connection's receive completions, so state is
/// lock-guarded rather than actor-isolated. `onSilence` fires at most once,
/// off that same watchdog task, never while the lock is held.
public final class SilenceWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeoutNanoseconds: Int64
    private let now: @Sendable () -> Int64
    private let onSilence: @Sendable () -> Void
    private var lastHeardNanoseconds: Int64 = 0
    private var running = false
    private var fired = false
    private var task: Task<Void, Never>?

    public init(
        timeout: Duration,
        now: @escaping @Sendable () -> Int64 = MonotonicClock.nowNanoseconds,
        onSilence: @escaping @Sendable () -> Void
    ) {
        timeoutNanoseconds = Self.nanoseconds(for: timeout)
        self.now = now
        self.onSilence = onSilence
    }

    /// Idempotent: a watchdog already running, or one that has already
    /// fired, ignores a second call.
    public func start() {
        lock.lock()
        guard !running, !fired else {
            lock.unlock()
            return
        }
        running = true
        lastHeardNanoseconds = now()
        lock.unlock()
        let watchTask = Task { [weak self] in
            guard let self else { return }
            await self.watch()
        }
        lock.lock()
        task = watchTask
        lock.unlock()
    }

    /// Pushes the deadline back out to a full timeout from now.
    public func heard() {
        lock.lock()
        defer { lock.unlock() }
        lastHeardNanoseconds = now()
    }

    /// Idempotent. A stop before the deadline is what keeps a watchdog from
    /// ever firing.
    public func stop() {
        lock.lock()
        running = false
        let runningTask = task
        task = nil
        lock.unlock()
        runningTask?.cancel()
    }

    private func watch() async {
        while isRunning {
            let remaining = remainingNanoseconds()
            guard remaining > 0 else {
                if tryFire() {
                    onSilence()
                }
                return
            }
            do {
                try await Task.sleep(for: .nanoseconds(remaining))
            } catch {
                return
            }
        }
    }

    /// Locking is confined to plain, non-`async` methods like this one: an
    /// `NSLock` call written directly inside an `async` function's body is
    /// unavailable from an asynchronous context, since a suspension there
    /// could leave the lock held across an await.
    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func remainingNanoseconds() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return timeoutNanoseconds - (now() - lastHeardNanoseconds)
    }

    private func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard running, !fired else { return false }
        fired = true
        running = false
        return true
    }

    private static func nanoseconds(for duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
