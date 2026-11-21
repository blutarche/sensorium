#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

/// A scripted screen saver: what it answers, and how often it was asked.
final class ScriptedScreenSaver: ScreenSaverReading, HostScreenRelocking, @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var idle: ScreenSaverIdleReading = .idleFor(0)
    private var lockReads = 0
    private var idleReads = 0
    private var relocks = 0

    func set(locked: Bool) { lock.withLock { self.locked = locked } }
    func set(idle: ScreenSaverIdleReading) { lock.withLock { self.idle = idle } }
    var lockReadCount: Int { lock.withLock { lockReads } }
    var idleReadCount: Int { lock.withLock { idleReads } }
    var relockCount: Int { lock.withLock { relocks } }

    func isScreenLocked() -> Bool {
        lock.withLock {
            lockReads += 1
            return locked
        }
    }

    func currentReading() -> ScreenSaverIdleReading {
        lock.withLock {
            idleReads += 1
            return idle
        }
    }

    @discardableResult
    func relock() -> Bool {
        lock.withLock { relocks += 1 }
        return true
    }
}

/// A clock a test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(_ start: TimeInterval = 1000) { current = start }

    var now: TimeInterval { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private func testTheLockStateIsReadOnAPollAndAnsweredFromTheLastRead() {
    let saver = ScriptedScreenSaver()
    let monitor = ScreenSaverMonitor(reading: saver)
    saver.set(locked: true)
    monitor.refresh()
    let readsAfterRefresh = saver.lockReadCount
    expect(monitor.isScreenLocked(), "the poll saw the locked screen")
    expect(monitor.isScreenLocked(), "asked twice")
    expect(saver.lockReadCount == readsAfterRefresh, "answering reads no bus: a session asks on every input event")
    saver.set(locked: false)
    expect(monitor.isScreenLocked(), "nothing changes until the next poll")
    monitor.refresh()
    expect(!monitor.isScreenLocked(), "the next poll sees the unlock")
}

private func testIdleTimeKeepsCountingBetweenPolls() {
    let saver = ScriptedScreenSaver()
    let clock = ManualClock()
    let monitor = ScreenSaverMonitor(reading: saver, now: { clock.now })
    saver.set(idle: .idleFor(30))
    monitor.refresh()
    expect(monitor.currentReading() == .idleFor(30), "the poll's own reading, saw \(monitor.currentReading())")
    clock.advance(5)
    expect(monitor.currentReading() == .idleFor(35), "five seconds later the machine has been idle five seconds longer")

    saver.set(idle: .unavailable)
    monitor.refresh()
    expect(monitor.currentReading() == .unavailable, "a failed read is unavailable, never a long idle time")
    expect(ScreenSaverMonitor(reading: saver).currentReading() == .unavailable, "before any poll nothing is known")
}

private func testThePollRunsOnItsOwnUntilStopped() {
    let saver = ScriptedScreenSaver()
    let monitor = ScreenSaverMonitor(reading: saver, lockInterval: 0.05, idleInterval: 0.05)
    saver.set(locked: true)
    monitor.start()
    expect(monitor.isScreenLocked(), "start reads once before it returns, so the first session sees a real state")
    saver.set(locked: false)
    let deadline = Date().addingTimeInterval(2)
    while monitor.isScreenLocked(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    expect(!monitor.isScreenLocked(), "a later poll picked up the unlock on its own")
    monitor.stop()
    let reads = saver.lockReadCount
    Thread.sleep(forTimeInterval: 0.2)
    expect(saver.lockReadCount == reads, "a stopped monitor reads nothing more")
}

private func testTheRelockGoesThroughTheScreenSaverClient() {
    let bus = FakeDBus()
    let relocker: any HostScreenRelocking = ScreenSaverClient(bus: bus, timeout: 0.5)
    expect(relocker.relock(), "a Lock that returns is a relock")
    expect(bus.calls(named: "ScreenSaver.Lock").count == 1, "the relock is the screen saver's Lock")
}

func screenSaverAdapterTests() -> [(String, () throws -> Void)] { [
    ("the lock state is read on a poll and answered from the last read", testTheLockStateIsReadOnAPollAndAnsweredFromTheLastRead),
    ("idle time keeps counting between polls", testIdleTimeKeepsCountingBetweenPolls),
    ("the screen saver poll runs on its own until stopped", testThePollRunsOnItsOwnUntilStopped),
    ("the relock goes through the screen saver client", testTheRelockGoesThroughTheScreenSaverClient)
] }
#endif
