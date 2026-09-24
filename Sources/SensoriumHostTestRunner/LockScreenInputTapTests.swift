import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// While the host screen is locked, a host-screen `CoreGraphicsInputInjector`
/// posts every event at `.cghidEventTap` instead of `.cgSessionEventTap`, on
/// the same reasoning as the system hotkey exception `SystemHotkeyChordTests`
/// covers: a consumer ahead of the session tap never sees an event posted
/// there. A session-canvas injector posts nothing while locked.
@MainActor
func runLockScreenInputTapTests() async {
    do {
        // Locked: key, pointer, and scroll all reach the hid tap
        let recorder = RecordedTapPosts()
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .hostScreen,
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
            sessionKind: .hostScreen,
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
        // A session canvas never reaches the lock screen: while locked it posts nothing at all
        let recorder = RecordedTapPosts()
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .sessionCanvas,
            lockStateReader: FakeScreenLockState(locked: true),
            hostInjectedHIDActivity: clock,
            postEvent: { _, tap in recorder.record(tap) }
        )

        let events: [(SensoriumInputEvent, String)] = [
            (.key(keyCode: 0, isDown: true, modifiers: []), "key"),
            (.key(keyCode: 126, isDown: true, modifiers: [.control]), "system hotkey"),
            (.pointerMoved(x: 10, y: 10), "pointer move"),
            (.pointerButton(button: .left, isDown: true, x: 10, y: 10), "pointer button"),
            (.scrolled(deltaX: 1, deltaY: 1, x: 10, y: 10, phase: nil, momentumPhase: nil), "scroll")
        ]
        for (event, name) in events {
            var suppressed = false
            do {
                try injector.inject(event)
            } catch is InputInjectionSuppressed {
                suppressed = true
            } catch {
                expect(false, "a locked session canvas reports a \(name) as suppressed, not \(error)")
            }
            expect(suppressed, "a session canvas reports a \(name) as suppressed while the screen is locked")
            expect(recorder.all().isEmpty, "a session canvas posts no \(name) while the screen is locked")
        }
        expect(clock.sampleCount == 0 && clock.recordCount == 0, "and records no host-injected hid activity")

        print("PASS: a session canvas posts nothing while the screen is locked")
    }

    do {
        // A session canvas while unlocked: exactly the session tap, as before
        let recorder = RecordedTapPosts()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .sessionCanvas,
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: SpyHostInjectedHIDActivity(),
            postEvent: { _, tap in recorder.record(tap) }
        )

        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        try! injector.inject(.pointerMoved(x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.scrolled(deltaX: 1, deltaY: 1, x: 10, y: 10, phase: nil, momentumPhase: nil))
        expect(!recorder.all().isEmpty, "a session canvas posts while the screen is unlocked")
        expect(
            recorder.all().allSatisfy { $0 == .cgSessionEventTap },
            "a session canvas posts every ordinary event at the session tap while unlocked"
        )

        print("PASS: a session canvas posts at the session tap while the screen is unlocked")
    }

    for releasePath in ["the next key-up", "teardown"] {
        // A key-up a locked canvas swallowed leaves the key held, so it is
        // still released once the screen unlocks
        let lockState = FlippableLockState(locked: false)
        let keys = RecordedKeyPosts()
        let factory = RealCanvasInjectorFactory(lockState: lockState, keys: keys)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjectorFactory: factory,
            keyConfinement: .unconfined
        )
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))

        _ = try! controller.handle(.input(.key(keyCode: 0, isDown: true, modifiers: []), surfaceID: nil))
        lockState.setLocked(true)
        _ = try! controller.handle(.input(.key(keyCode: 0, isDown: false, modifiers: []), surfaceID: nil))
        expect(keys.all() == [.init(keyCode: 0, isDown: true)], "the key-up is not posted while the canvas's screen is locked")

        lockState.setLocked(false)
        if releasePath == "teardown" {
            _ = try! controller.handle(.goodbye(reason: "client-disconnected"))
        } else {
            _ = try! controller.handle(.input(.key(keyCode: 0, isDown: false, modifiers: []), surfaceID: nil))
        }
        expect(
            keys.all() == [.init(keyCode: 0, isDown: true), .init(keyCode: 0, isDown: false)],
            "after unlock, \(releasePath) posts the key-up the locked screen swallowed"
        )

        print("PASS: a key-up swallowed while locked stays held and \(releasePath) releases it after unlock")
    }

    do {
        // Locked, but the canvas display named at construction is gone: the
        // throwing coordinate lookup must run before any self-post
        // accounting, or a pointer move that never actually posts would
        // still consume a sample and record a post that was never sent.
        let clock = SpyHostInjectedHIDActivity()
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: 0xFFFF_FFFE, // no real display ever has this ID
            sessionKind: .hostScreen,
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

/// Builds the real injector for a session canvas, posting into a recorder
/// instead of the system, so a controller's held-input bookkeeping can be
/// checked against what the injector actually posted.
@MainActor
private final class RealCanvasInjectorFactory: InputInjectingFactory {
    private let lockState: FlippableLockState
    private let keys: RecordedKeyPosts
    init(lockState: FlippableLockState, keys: RecordedKeyPosts) {
        self.lockState = lockState
        self.keys = keys
    }
    func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        try CoreGraphicsInputInjector(
            canvasDisplayID: canvasDisplayID,
            sessionKind: sessionKind,
            lockStateReader: lockState,
            hostInjectedHIDActivity: SpyHostInjectedHIDActivity(),
            postEvent: { [keys] event, _ in keys.record(event) }
        )
    }
}

private final class RecordedKeyPosts: @unchecked Sendable {
    struct Post: Equatable {
        let keyCode: Int64
        let isDown: Bool
    }
    private var posts: [Post] = []

    func record(_ event: CGEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return }
        posts.append(Post(keyCode: event.getIntegerValueField(.keyboardEventKeycode), isDown: event.type == .keyDown))
    }

    func all() -> [Post] { posts }
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
