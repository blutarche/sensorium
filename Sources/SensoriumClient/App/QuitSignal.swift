import Foundation
import SensoriumCore

/// One-shot latch so the session ends exactly once, whichever comes first: the
/// user quitting or the host disappearing.
public final class QuitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    public var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    public func onFire(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    public func fire() {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        let handlers = self.handlers
        self.handlers = []
        lock.unlock()
        for handler in handlers {
            handler()
        }
    }
}

/// The cause a host named on its way out, held until the ending is reported.
/// Written on the runner's own receive loop and read on the main actor, so it
/// carries its own lock, exactly as `QuitSignal` above does.
final class HostEndingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ViewerSessionFailure?

    var failure: ViewerSessionFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ failure: ViewerSessionFailure) {
        lock.lock()
        stored = failure
        lock.unlock()
    }
}

