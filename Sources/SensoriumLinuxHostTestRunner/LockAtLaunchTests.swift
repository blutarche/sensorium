#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

private func testTheSessionAgeComesFromLogindsMonotonicStartTime() async {
    let bus = FakeDBus()
    bus.setProperty("org.freedesktop.login1.Session", "TimestampMonotonic", .uint64(40_000_000))
    let age = await LogindSessionAge.read(bus: bus, monotonicMicroseconds: { 100_000_000 })
    expect(age == 60, "a session that began at 40 s of uptime is 60 s old at 100 s, saw \(String(describing: age))")
    let call = bus.calls.first
    expect(call?.destination == "org.freedesktop.login1", "the read goes to logind")
    expect(call?.path == "/org/freedesktop/login1/session/auto", "for the caller's own session")

    let unanswered = await LogindSessionAge.read(bus: FakeDBus(), monotonicMicroseconds: { 100_000_000 })
    expect(unanswered == nil, "a session logind cannot describe has no age")
}

private func testAnUntouchedSessionIsLockedAtLaunch() async {
    let saver = ScriptedScreenSaver()
    let monitor = ScreenSaverMonitor(reading: saver)
    saver.set(idle: .idleFor(59.5))
    monitor.refresh()
    let outcome = LinuxLockAtLaunch.apply(lockState: monitor, activity: monitor, sessionAge: 60, relocker: saver)
    expect(outcome == .locked, "idle since the session began reads as automatic login, saw \(outcome)")
    expect(saver.relockCount == 1, "the screen was locked once")
}

private func testATouchedLockedOrAgelessSessionIsLeftAlone() async {
    let saver = ScriptedScreenSaver()
    let monitor = ScreenSaverMonitor(reading: saver)
    saver.set(idle: .idleFor(5))
    monitor.refresh()
    expect(
        LinuxLockAtLaunch.apply(lockState: monitor, activity: monitor, sessionAge: 600, relocker: saver) == .notNeeded,
        "someone used the session since it began"
    )
    saver.set(idle: .idleFor(600))
    monitor.refresh()
    expect(
        LinuxLockAtLaunch.apply(lockState: monitor, activity: monitor, sessionAge: nil, relocker: saver) == .notNeeded,
        "with no known session age the host never locks"
    )
    saver.set(locked: true)
    monitor.refresh()
    expect(
        LinuxLockAtLaunch.apply(lockState: monitor, activity: monitor, sessionAge: 600, relocker: saver) == .notNeeded,
        "an already locked screen has nothing to do"
    )
    expect(saver.relockCount == 0, "nothing was locked")
}

func lockAtLaunchTests() -> [NamedTest] { [
    ("the session age comes from logind's monotonic start time", testTheSessionAgeComesFromLogindsMonotonicStartTime),
    ("an untouched session is locked at launch", testAnUntouchedSessionIsLockedAtLaunch),
    ("a touched, locked or ageless session is left alone at launch", testATouchedLockedOrAgelessSessionIsLeftAlone)
] }
#endif
