import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// Injected events must look like what the physical keyboard and mouse
/// produce, because apps read details a bare synthetic event leaves out: the
/// auto-repeat flag, which button a drag belongs to, sub-point motion, the
/// keypad flag, and a pointer that stays on its own display.
@MainActor
func runInjectedInputFidelityTests() async {
    func makeInjector(
        posts: FidelityPosts,
        cursor: FidelityCursor = FidelityCursor(),
        now: @escaping () -> TimeInterval = { 0 }
    ) -> CoreGraphicsInputInjector {
        try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .hostScreen,
            lockStateReader: FakeScreenLockState(locked: false),
            hostInjectedHIDActivity: FidelityHIDActivity(),
            now: now,
            postEvent: { event, _ in posts.record(event) },
            associateMouseAndCursor: { cursor.associations.append($0) },
            warpCursor: { cursor.warps.append($0) }
        )
    }

    do {
        // A key-down repeated with no key-up between is an auto-repeat
        let posts = FidelityPosts()
        let injector = makeInjector(posts: posts)
        try! injector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        try! injector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        try! injector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        try! injector.inject(.key(keyCode: 14, isDown: false, modifiers: []))
        try! injector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        expect(posts.autorepeats == [0, 1, 1, 0, 0], "repeat flags were \(posts.autorepeats)")

        // Modifier keys never count as repeats
        let modPosts = FidelityPosts()
        let modInjector = makeInjector(posts: modPosts)
        try! modInjector.inject(.key(keyCode: 55, isDown: true, modifiers: [.command]))
        try! modInjector.inject(.key(keyCode: 55, isDown: true, modifiers: [.command]))
        expect(modPosts.autorepeats == [0, 0], "modifier repeat flags were \(modPosts.autorepeats)")

        // Releasing everything forgets the held keys
        let resetPosts = FidelityPosts()
        let resetInjector = makeInjector(posts: resetPosts)
        try! resetInjector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        try! resetInjector.inject(.releaseAllInput)
        try! resetInjector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        expect(resetPosts.autorepeats == [0, 0], "post-release repeat flags were \(resetPosts.autorepeats)")
        print("PASS: a key-down for an already-held key is posted as an auto-repeat")

        // A key-down long after the previous one is a fresh press, not a repeat
        // (the viewer lost the key-up in between)
        var clock: TimeInterval = 100
        let stalePosts = FidelityPosts()
        let staleInjector = makeInjector(posts: stalePosts, now: { clock })
        try! staleInjector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        clock += 3
        try! staleInjector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        clock += 0.05
        try! staleInjector.inject(.key(keyCode: 14, isDown: true, modifiers: []))
        expect(stalePosts.autorepeats == [0, 0, 1], "stale repeat flags were \(stalePosts.autorepeats)")
        print("PASS: a key-down long after an unreleased one is a fresh press")
    }

    do {
        // Releasing one of two held buttons leaves the other's drag intact
        let posts = FidelityPosts()
        let injector = makeInjector(posts: posts)
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .right, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .right, isDown: false, x: 10, y: 10))
        try! injector.inject(.pointerMoved(x: 30, y: 10))
        expect(posts.types.last == .leftMouseDragged, "move with left still held was \(String(describing: posts.types.last))")

        // Motion prefers left, then right, then middle
        let order = FidelityPosts()
        let orderInjector = makeInjector(posts: order)
        try! orderInjector.inject(.pointerButton(button: .middle, isDown: true, x: 10, y: 10))
        try! orderInjector.inject(.pointerMoved(x: 20, y: 10))
        try! orderInjector.inject(.pointerButton(button: .right, isDown: true, x: 20, y: 10))
        try! orderInjector.inject(.pointerMoved(x: 30, y: 10))
        try! orderInjector.inject(.pointerButton(button: .left, isDown: true, x: 30, y: 10))
        try! orderInjector.inject(.pointerMoved(x: 40, y: 10))
        try! orderInjector.inject(.pointerButton(button: .left, isDown: false, x: 40, y: 10))
        try! orderInjector.inject(.pointerButton(button: .right, isDown: false, x: 40, y: 10))
        try! orderInjector.inject(.pointerMoved(x: 50, y: 10))
        try! orderInjector.inject(.pointerButton(button: .middle, isDown: false, x: 50, y: 10))
        try! orderInjector.inject(.pointerMoved(x: 60, y: 10))
        let drags = [1, 3, 5, 8, 10].map { order.types[$0] }
        expect(
            drags == [.otherMouseDragged, .rightMouseDragged, .leftMouseDragged, .otherMouseDragged, .mouseMoved],
            "drag types were \(drags)"
        )
        print("PASS: motion with several buttons held drags the lowest-numbered one")
    }

    do {
        // Click counts stay per button while another is held
        let posts = FidelityPosts()
        let injector = makeInjector(posts: posts)
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .left, isDown: false, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .right, isDown: true, x: 10, y: 10))
        try! injector.inject(.pointerButton(button: .right, isDown: false, x: 10, y: 10))
        try! injector.inject(.pointerMoved(x: 20, y: 10))
        expect(posts.counts == [1, 1, 2, 1, 1, 2], "click counts were \(posts.counts)")
        print("PASS: click counts survive overlapping buttons")
    }

    do {
        // Sub-point captured motion accumulates instead of being dropped
        let posts = FidelityPosts()
        let cursor = FidelityCursor()
        let injector = makeInjector(posts: posts, cursor: cursor)
        try! injector.inject(.pointerCaptureChanged(isCaptured: true))
        for _ in 0..<10 {
            try! injector.inject(.pointerMovedRelative(deltaX: 0.3, deltaY: -0.3))
        }
        try! injector.inject(.pointerCaptureChanged(isCaptured: false))
        let sumX = posts.deltaXs.reduce(0, +)
        let sumY = posts.deltaYs.reduce(0, +)
        expect(sumX == 3 && sumY == -3, "summed deltas were \(sumX), \(sumY)")
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        expect(cursor.associations == [false, true], "association calls were \(cursor.associations)")
        expect(cursor.warps == [center], "warp calls were \(cursor.warps)")

        // The remainder does not survive the end of a capture
        let again = FidelityPosts()
        let second = makeInjector(posts: again, cursor: FidelityCursor())
        try! second.inject(.pointerCaptureChanged(isCaptured: true))
        try! second.inject(.pointerMovedRelative(deltaX: 0.4, deltaY: 0.4))
        try! second.inject(.pointerCaptureChanged(isCaptured: false))
        try! second.inject(.pointerCaptureChanged(isCaptured: true))
        try! second.inject(.pointerMovedRelative(deltaX: 0.4, deltaY: 0.4))
        try! second.inject(.pointerCaptureChanged(isCaptured: false))
        expect(again.deltaXs == [0, 0], "deltas after a re-capture were \(again.deltaXs)")
        print("PASS: fractional captured motion is carried between events")
    }

    do {
        // Command-Shift-Tab reaches the Dock
        expect(
            SystemHotkeyChord.isSystemHotkey(keyCode: 48, modifiers: [.command, .shift]),
            "Command-Shift-Tab is a system hotkey"
        )
        print("PASS: Command-Shift-Tab is routed to the hid tap")
    }

    do {
        // Keypad keys carry the numeric-pad flag
        let keypad: [UInt16] = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for keyCode in keypad {
            expect(
                CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: keyCode).contains(.maskNumericPad),
                "keypad key \(keyCode) carries the numeric-pad flag"
            )
        }
        expect(
            !CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: 18).contains(.maskNumericPad),
            "the top-row 1 is not a keypad key"
        )
        print("PASS: keypad keys carry the numeric-pad flag")
    }

    do {
        // A pointer at the far edge stays strictly inside the display
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let posts = FidelityPosts()
        let injector = makeInjector(posts: posts)
        try! injector.inject(.pointerMoved(x: bounds.width, y: bounds.height))
        try! injector.inject(.pointerButton(button: .left, isDown: true, x: bounds.width, y: bounds.height))
        try! injector.inject(.pointerMoved(x: -5, y: -5))
        for point in posts.locations {
            expect(
                point.x >= bounds.minX && point.x < bounds.maxX && point.y >= bounds.minY && point.y < bounds.maxY,
                "posted point \(point) lies inside \(bounds)"
            )
        }
        print("PASS: edge points stay strictly inside the display bounds")
    }
}

private final class FidelityPosts: @unchecked Sendable {
    private(set) var types: [CGEventType] = []
    private(set) var counts: [Int64] = []
    private(set) var autorepeats: [Int64] = []
    private(set) var deltaXs: [Int64] = []
    private(set) var deltaYs: [Int64] = []
    private(set) var locations: [CGPoint] = []

    func record(_ event: CGEvent) {
        types.append(event.type)
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            autorepeats.append(event.getIntegerValueField(.keyboardEventAutorepeat))
        default:
            counts.append(event.getIntegerValueField(.mouseEventClickState))
            deltaXs.append(event.getIntegerValueField(.mouseEventDeltaX))
            deltaYs.append(event.getIntegerValueField(.mouseEventDeltaY))
            locations.append(event.location)
        }
    }
}

private final class FidelityCursor: @unchecked Sendable {
    var associations: [Bool] = []
    var warps: [CGPoint] = []
}

private final class FidelityHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}
