import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// macOS apps read a click's count from `mouseEventClickState`; the wire
/// carries none, so `CoreGraphicsInputInjector` counts successive presses
/// itself. Without it every click arrives as a single click and nothing
/// opens on a double-click.
@MainActor
func runClickCountTests() async {
    let interval: TimeInterval = 0.5

    func makeInjector(
        clock: ClickCountClock,
        posts: ClickCountPosts
    ) -> CoreGraphicsInputInjector {
        try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .hostScreen,
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: ClickCountHIDActivity(),
            doubleClickInterval: interval,
            now: { clock.now },
            postEvent: { event, _ in posts.record(event) }
        )
    }

    func click(
        _ injector: CoreGraphicsInputInjector,
        _ button: CanvasPointerButton = .left,
        x: Double = 10,
        y: Double = 10
    ) {
        try! injector.inject(.pointerButton(button: button, isDown: true, x: x, y: y))
        try! injector.inject(.pointerButton(button: button, isDown: false, x: x, y: y))
    }

    do {
        // Presses in quick succession at one point count up, down and up alike
        let clock = ClickCountClock()
        let posts = ClickCountPosts()
        let injector = makeInjector(clock: clock, posts: posts)

        click(injector)
        clock.now += 0.2
        click(injector)
        expect(posts.counts == [1, 1, 2, 2], "a second press within the interval is a double click, got \(posts.counts)")

        clock.now += 0.2
        click(injector)
        expect(
            posts.counts == [1, 1, 2, 2, 3, 3],
            "a third press within the interval of the second is a triple click, got \(posts.counts)"
        )

        print("PASS: quick successive clicks at one point count up on both the press and the release")
    }

    do {
        // A lapse resets the count
        let clock = ClickCountClock()
        let posts = ClickCountPosts()
        let injector = makeInjector(clock: clock, posts: posts)

        click(injector)
        clock.now += interval + 0.1
        click(injector)
        expect(posts.counts == [1, 1, 1, 1], "a press after the interval is a fresh single click, got \(posts.counts)")

        print("PASS: a press after the double-click interval starts over at one")
    }

    do {
        // Distance resets the count
        let clock = ClickCountClock()
        let posts = ClickCountPosts()
        let injector = makeInjector(clock: clock, posts: posts)

        click(injector, x: 10, y: 10)
        clock.now += 0.1
        click(injector, x: 200, y: 10)
        expect(posts.counts == [1, 1, 1, 1], "a press far from the last is a fresh single click, got \(posts.counts)")

        print("PASS: a press far from the previous one starts over at one")
    }

    do {
        // A different button resets the count
        let clock = ClickCountClock()
        let posts = ClickCountPosts()
        let injector = makeInjector(clock: clock, posts: posts)

        click(injector, .left)
        clock.now += 0.1
        click(injector, .right)
        expect(posts.counts == [1, 1, 1, 1], "a press of another button is a single click, got \(posts.counts)")

        print("PASS: a press of a different button starts over at one")
    }

    do {
        // A drag while held keeps the count of the press that began it
        let clock = ClickCountClock()
        let posts = ClickCountPosts()
        let injector = makeInjector(clock: clock, posts: posts)

        click(injector)
        clock.now += 0.1
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerMoved(x: 40, y: 10))
        expect(posts.counts == [1, 1, 2, 2], "a drag after a double-click press carries its count, got \(posts.counts)")
        expect(posts.types.last == .leftMouseDragged, "the move while held is a drag")

        print("PASS: a drag while the button is held carries the press's click count")
    }
}

private final class ClickCountClock: @unchecked Sendable {
    var now: TimeInterval = 1000
}

private final class ClickCountPosts: @unchecked Sendable {
    private(set) var counts: [Int64] = []
    private(set) var types: [CGEventType] = []

    func record(_ event: CGEvent) {
        counts.append(event.getIntegerValueField(.mouseEventClickState))
        types.append(event.type)
    }
}

private final class ClickCountHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}
