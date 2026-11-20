#if os(Linux)

import Foundation
import SensoriumLinuxHost

private func readerOnA(_ bus: FakeDBus) -> ScreenSaverClient {
    ScreenSaverClient(bus: bus, timeout: 0.5)
}

func testLockStateReadsGetActiveAndTreatsFailureAsNotLocked() {
    let bus = FakeDBus()
    let client = readerOnA(bus)
    bus.react("ScreenSaver.GetActive", .reply([.bool(true)], fileDescriptor: nil))
    expect(client.isScreenLocked(), "an active screen saver is a locked screen")
    bus.react("ScreenSaver.GetActive", .reply([.bool(false)], fileDescriptor: nil))
    expect(!client.isScreenLocked(), "an inactive one is not")
    bus.react("ScreenSaver.GetActive", .fail(.remote(name: "org.freedesktop.DBus.Error.ServiceUnknown", message: "gone")))
    expect(!client.isScreenLocked(), "a failed read is not known to be locked")
    bus.react("ScreenSaver.GetActive", .reply([.string("yes")], fileDescriptor: nil))
    expect(!client.isScreenLocked(), "a reply of the wrong type is not known to be locked")

    let call = bus.calls(named: "ScreenSaver.GetActive")[0]
    expect(call.destination == "org.freedesktop.ScreenSaver", "the call goes to the screen saver service")
    expect(call.path == "/org/freedesktop/ScreenSaver", "on its object")
    expect(call.interface == "org.freedesktop.ScreenSaver", "on its interface")
    expect(bus.log.allSatisfy { $0.hasPrefix("sync ") }, "reads are synchronous calls")
}

func testIdleTimeIsReadInMillisecondsAndFailureIsUnavailable() {
    let bus = FakeDBus()
    let client = readerOnA(bus)
    bus.react("ScreenSaver.GetSessionIdleTime", .reply([.uint32(2500)], fileDescriptor: nil))
    expect(client.currentReading() == .idleFor(2.5), "2500 milliseconds is 2.5 seconds")
    bus.react("ScreenSaver.GetSessionIdleTime", .reply([.uint32(0)], fileDescriptor: nil))
    expect(client.currentReading() == .idleFor(0), "zero is someone just now")
    bus.react("ScreenSaver.GetSessionIdleTime", .fail(.remote(name: "org.freedesktop.DBus.Error.UnknownMethod", message: "no")))
    expect(client.currentReading() == .unavailable, "a failed read is unavailable, never a long idle time")
    bus.react("ScreenSaver.GetSessionIdleTime", .reply([], fileDescriptor: nil))
    expect(client.currentReading() == .unavailable, "an empty reply is unavailable")
}

func testRelockCallsLockAndReportsWhetherItWentThrough() {
    let bus = FakeDBus()
    let client = readerOnA(bus)
    expect(client.relock(), "a Lock that returns is a relock")
    expect(bus.calls(named: "ScreenSaver.Lock").count == 1, "Lock was called once")
    bus.react("ScreenSaver.Lock", .fail(.remote(name: "org.freedesktop.DBus.Error.NoReply", message: "no")))
    expect(!client.relock(), "a Lock that fails is reported")
}

func screenSaverTests() -> [NamedTest] { [
    ("lock state reads GetActive and treats failure as not locked", testLockStateReadsGetActiveAndTreatsFailureAsNotLocked),
    ("idle time is read in milliseconds and failure is unavailable", testIdleTimeIsReadInMillisecondsAndFailureIsUnavailable),
    ("relock calls Lock and reports whether it went through", testRelockCallsLockAndReportsWhetherItWentThrough)
] }

#endif
