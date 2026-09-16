import Foundation
import SensoriumClient

/// Counts how many times `onSilence` actually ran, lock-guarded since the
/// watchdog calls it off its own task.
private final class SilenceFireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
func testSilenceWatchdogTests() async {
    do {
        // The regression this guards: a connection that reached `.ready` but
        // was never armed (pairing's retyped-digit wait, a session's own
        // pre-live handshake) must survive well past what would have been
        // the timeout had it been armed.
        let fired = SilenceFireCounter()
        _ = SilenceWatchdog(timeout: .milliseconds(20), onSilence: { fired.increment() })
        try? await Task.sleep(for: .milliseconds(90))
        expect(fired.value == 0, "a watchdog that is never started never fires -- got \(fired.value)")
        print("PASS: a watchdog that is never started does not fire")
    }

    do {
        let fired = SilenceFireCounter()
        let watchdog = SilenceWatchdog(timeout: .milliseconds(30), onSilence: { fired.increment() })
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(90))
        expect(fired.value == 1, "a watchdog with nothing heard fires once the timeout elapses -- got \(fired.value)")
        watchdog.stop()
        print("PASS: fires after the timeout with nothing heard")
    }

    do {
        let fired = SilenceFireCounter()
        let watchdog = SilenceWatchdog(timeout: .milliseconds(60), onSilence: { fired.increment() })
        watchdog.start()
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(30))
            watchdog.heard()
        }
        expect(fired.value == 0, "heard() arriving inside the window keeps the watchdog from firing -- got \(fired.value)")
        watchdog.stop()
        print("PASS: does not fire while heard() keeps arriving within the timeout")
    }

    do {
        let fired = SilenceFireCounter()
        let watchdog = SilenceWatchdog(timeout: .milliseconds(20), onSilence: { fired.increment() })
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(80))
        try? await Task.sleep(for: .milliseconds(80))
        expect(fired.value == 1, "onSilence never fires more than once -- got \(fired.value)")
        watchdog.stop()
        print("PASS: fires at most once")
    }

    do {
        let fired = SilenceFireCounter()
        let watchdog = SilenceWatchdog(timeout: .milliseconds(30), onSilence: { fired.increment() })
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(10))
        watchdog.stop()
        try? await Task.sleep(for: .milliseconds(60))
        expect(fired.value == 0, "stopping before the deadline prevents the fire -- got \(fired.value)")
        print("PASS: stop() before the deadline prevents firing")
    }
}
