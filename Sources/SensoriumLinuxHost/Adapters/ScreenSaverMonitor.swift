#if os(Linux)
import Foundation
import SensoriumHost

/// The two screen saver reads the monitor polls. `ScreenSaverClient` is the
/// real one; a test scripts its own.
public protocol ScreenSaverReading: Sendable {
    func isScreenLocked() -> Bool
    func currentReading() -> ScreenSaverIdleReading
}

extension ScreenSaverClient: ScreenSaverReading {}

/// The relock is the screen saver's own `Lock`.
extension ScreenSaverClient: HostScreenRelocking {}

/// The lock state and idle time of this desktop session, read on a poll off
/// the main thread and answered from the last read.
///
/// A host-screen session asks for the lock state on every forwarded input
/// event and samples idle time before every input post, so neither may wait
/// on a bus round trip. The lock state is polled every two seconds, as the
/// design asks. Idle time is polled more often and kept as the time of the
/// last local input, so a reading between polls keeps counting up. Local
/// input that falls between two polls and is then masked by the host's own
/// next post can be missed; the window is one idle poll interval.
public final class ScreenSaverMonitor: ScreenLockStateReading, HostLocalActivitySignal, @unchecked Sendable {
    private let reading: any ScreenSaverReading
    private let lockInterval: TimeInterval
    private let idleInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let queue = DispatchQueue(label: "sensorium.screen-saver-monitor")
    private let lock = NSLock()
    private var locked = false
    /// When the last local input happened, on `now`'s clock; nil when the
    /// last read failed or none has been made.
    private var lastInputTime: TimeInterval?
    private var timers: [DispatchSourceTimer] = []

    /// `now` is a monotonic clock in seconds, so a change of the wall clock
    /// cannot move the last input into the future.
    public init(
        reading: any ScreenSaverReading,
        lockInterval: TimeInterval = 2,
        idleInterval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.reading = reading
        self.lockInterval = lockInterval
        self.idleInterval = idleInterval
        self.now = now
    }

    deinit {
        for timer in timers {
            timer.cancel()
        }
    }

    /// Reads both once, then keeps polling until `stop()`.
    public func start() {
        refresh()
        let lockTimer = schedule(every: lockInterval) { [weak self] in self?.refreshLockState() }
        let idleTimer = schedule(every: idleInterval) { [weak self] in self?.refreshIdleTime() }
        let replaced = lock.withLock {
            defer { timers = [lockTimer, idleTimer] }
            return timers
        }
        for timer in replaced {
            timer.cancel()
        }
    }

    public func stop() {
        let stopped = lock.withLock {
            defer { timers = [] }
            return timers
        }
        for timer in stopped {
            timer.cancel()
        }
        // A poll already running finishes before this returns.
        queue.sync {}
    }

    /// Reads both now, on the caller's thread.
    public func refresh() {
        refreshLockState()
        refreshIdleTime()
    }

    public func isScreenLocked() -> Bool {
        lock.withLock { locked }
    }

    public func currentReading() -> HostLocalActivityReading {
        guard let lastInputTime = lock.withLock({ lastInputTime }) else {
            return .unavailable
        }
        return .idleFor(max(0, now() - lastInputTime))
    }

    private func refreshLockState() {
        let value = reading.isScreenLocked()
        lock.withLock { locked = value }
    }

    private func refreshIdleTime() {
        let sampledAt = now()
        let value: TimeInterval?
        switch reading.currentReading() {
        case let .idleFor(seconds): value = sampledAt - seconds
        case .unavailable: value = nil
        }
        lock.withLock { lastInputTime = value }
    }

    private func schedule(every interval: TimeInterval, _ work: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return timer
    }
}
#endif
