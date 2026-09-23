import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// While the host screen is locked, `CoreGraphicsInputInjector` posts every
/// event at `.cghidEventTap` instead of `.cgSessionEventTap`, on the same
/// reasoning as the system hotkey exception `SystemHotkeyChordTests` covers:
/// a consumer ahead of the session tap never sees an event posted there.
@MainActor
func runLockScreenInputTapTests() async {
    do {
        // Locked: key, pointer, and scroll all reach the hid tap
        let recorder = RecordedTapPosts()
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            lockStateReader: FakeScreenLockState(locked: true),
            hostInjectedHIDActivity: clock,
            postEvent: { event, tap in recorder.record(tap) }
        )

        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        try! injector.inject(.pointerMoved(x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.scrolled(
            deltaX: 1, deltaY: 1, x: 10, y: 10, phase: nil, momentumPhase: nil
        ))

        expect(
            recorder.all().allSatisfy { $0 == .cghidEventTap },
            "every event posted while the screen is locked reaches the hid tap, not the session tap"
        )
        expect(
            clock.recordCount == 4,
            "each of the four posted events above records once into the host-injected hid activity"
        )
        expect(
            clock.sampleCount == 4,
            "each of the four posted events above samples before it records, so an earlier real person is not lost"
        )
        expect(
            clock.callLog == Array(repeating: ["sample", "record"], count: 4).flatMap { $0 },
            "sampling always precedes recording for each post, never the reverse"
        )

        print("PASS: a locked screen routes every key, pointer, and scroll event to the hid tap")
    }

    do {
        // Unlocked: routing is exactly what it was before locked-screen support existed
        let recorder = RecordedTapPosts()
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: clock,
            postEvent: { event, tap in recorder.record(tap) }
        )

        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        expect(recorder.all() == [.cgSessionEventTap], "an ordinary key stays on the session tap while unlocked")

        recorder.reset()
        try! injector.inject(.pointerMoved(x: 10, y: 10))
        expect(recorder.all() == [.cgSessionEventTap], "a pointer move stays on the session tap while unlocked")

        recorder.reset()
        try! injector.inject(.scrolled(deltaX: 1, deltaY: 1, x: 10, y: 10, phase: nil, momentumPhase: nil))
        expect(
            recorder.all().allSatisfy { $0 == .cgSessionEventTap },
            "a scroll's cursor-positioning move and the scroll itself both stay on the session tap while unlocked"
        )

        recorder.reset()
        try! injector.inject(.key(keyCode: 126, isDown: true, modifiers: [.control]))
        expect(
            recorder.all() == [.cghidEventTap],
            "a system hotkey still reaches the hid tap while unlocked, unaffected by lock routing"
        )

        expect(
            clock.recordCount == 1,
            "only the system hotkey above posts at the hid tap while unlocked, so it alone records"
        )
        expect(clock.sampleCount == 1, "the system hotkey samples before it records, the same as any other hid-tap post")
        expect(clock.callLog == ["sample", "record"], "the system hotkey samples before it records, never the reverse")

        print("PASS: an unlocked screen leaves ordinary and system-hotkey tap routing unchanged")
    }

    do {
        // Locked, but the canvas display named at construction is gone: the
        // throwing coordinate lookup must run before any self-post
        // accounting, or a pointer move that never actually posts would
        // still consume a sample and record a post that was never sent.
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: 0xFFFF_FFFE, // no real display ever has this ID
            lockStateReader: FakeScreenLockState(locked: true),
            hostInjectedHIDActivity: clock,
            postEvent: { _, _ in expect(false, "canvasDisplayUnavailable must be thrown before anything posts") }
        )

        var thrown: CoreGraphicsInputInjectorError?
        do {
            try injector.inject(.pointerMoved(x: 10, y: 10))
        } catch {
            thrown = error as? CoreGraphicsInputInjectorError
        }
        expect(thrown == .canvasDisplayUnavailable, "a pointer move against a display that is gone is refused")
        expect(clock.sampleCount == 0, "a pointer move that never posts records no self-post sample")
        expect(clock.recordCount == 0, "a pointer move that never posts records no self-post")

        thrown = nil
        do {
            try injector.inject(.scrolled(deltaX: 1, deltaY: 1, x: 10, y: 10, phase: nil, momentumPhase: nil))
        } catch {
            thrown = error as? CoreGraphicsInputInjectorError
        }
        expect(thrown == .canvasDisplayUnavailable, "a scroll against a display that is gone is refused")
        expect(clock.sampleCount == 0, "a scroll that never posts records no self-post sample")
        expect(clock.recordCount == 0, "a scroll that never posts records no self-post")

        print("PASS: a pointer move or scroll refused for a missing canvas display records no self-post")
    }
}

/// Counts `recordPost()` calls instead of measuring real time, so a test can
/// check the injector records exactly the posts it should, without racing a
/// real clock.
private final class SpyHostInjectedHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    private(set) var recordCount = 0
    private(set) var sampleCount = 0
    /// "sample" and "record" in call order, so a test can catch the two
    /// ever happening out of order, not only the right count of each.
    private(set) var callLog: [String] = []

    func recordPost() {
        recordCount += 1
        callLog.append("record")
    }

    func secondsSinceLastPost() -> TimeInterval? { nil }

    func sampleBeforePost() {
        sampleCount += 1
        callLog.append("sample")
    }

    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

/// The tap location every post the injector under test made, in order.
private final class RecordedTapPosts {
    private var taps: [CGEventTapLocation] = []

    func record(_ tap: CGEventTapLocation) {
        taps.append(tap)
    }

    func all() -> [CGEventTapLocation] {
        taps
    }

    func reset() {
        taps.removeAll()
    }
}
