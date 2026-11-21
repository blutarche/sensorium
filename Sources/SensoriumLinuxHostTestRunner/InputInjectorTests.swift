#if os(Linux)

import Foundation
import SensoriumCore
import SensoriumLinuxHost

enum SinkEvent: Hashable {
    case absolute(stream: UInt32, x: Double, y: Double)
    case relative(dx: Double, dy: Double)
    case button(Int32, Bool)
    case axis(dx: Double, dy: Double, finish: Bool)
    case discrete(PortalAxis, Int32)
    case key(Int32, Bool)
}

struct SinkRefusal: Error {}

final class RecordingSink: PortalInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SinkEvent] = []
    private var refusing: (@Sendable (SinkEvent) -> Bool)?

    var events: [SinkEvent] { lock.withLock { recorded } }

    func refuse(when predicate: (@Sendable (SinkEvent) -> Bool)?) {
        lock.withLock { refusing = predicate }
    }

    func clear() {
        lock.withLock { recorded = [] }
    }

    private func record(_ event: SinkEvent) throws {
        try lock.withLock {
            if let refusing, refusing(event) { throw SinkRefusal() }
            recorded.append(event)
        }
    }

    func notifyPointerMotionAbsolute(stream: UInt32, x: Double, y: Double) throws {
        try record(.absolute(stream: stream, x: x, y: y))
    }

    func notifyPointerMotion(dx: Double, dy: Double) throws { try record(.relative(dx: dx, dy: dy)) }
    func notifyPointerButton(evdevButton: Int32, pressed: Bool) throws { try record(.button(evdevButton, pressed)) }
    func notifyPointerAxis(dx: Double, dy: Double, finish: Bool) throws { try record(.axis(dx: dx, dy: dy, finish: finish)) }
    func notifyPointerAxisDiscrete(axis: PortalAxis, steps: Int32) throws { try record(.discrete(axis, steps)) }
    func notifyKeyboardKeycode(evdevKeycode: Int32, pressed: Bool) throws { try record(.key(evdevKeycode, pressed)) }
}

let monitorGeometry = PortalCaptureGeometry(
    streamNodeID: 57,
    logicalWidth: 1920,
    logicalHeight: 1080,
    identitySeed: "monitor-a"
)

private func makeInjector(
    _ sink: RecordingSink,
    observer: PortalInputPostObserver = PortalInputPostObserver()
) -> PortalInputInjector {
    PortalInputInjector(sink: sink, geometry: monitorGeometry, observer: observer)
}

private func key(_ keyCode: UInt16, _ down: Bool, _ modifiers: CanvasModifierFlags = [], caps: Bool? = nil) -> SensoriumInputEvent {
    .key(keyCode: keyCode, isDown: down, modifiers: modifiers, capsLock: caps)
}

// Evdev codes the tests name.
private let evA: Int32 = 30
private let evB: Int32 = 48
private let ev1: Int32 = 2
private let evLeftShift: Int32 = 42
private let evLeftCtrl: Int32 = 29
private let evLeftAlt: Int32 = 56
private let evLeftMeta: Int32 = 125
// macOS virtual keycodes the tests name.
private let vkA: UInt16 = 0
private let vkB: UInt16 = 11
private let vk1: UInt16 = 18
private let vkCommand: UInt16 = 55
private let vkShift: UInt16 = 56
private let vkCapsLock: UInt16 = 57

func testAKeyWithFlagsButNoModifierKeyDownGetsTheModifiersPressedAroundIt() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, [.command]))
    try injector.inject(key(vkA, false, [.command]))
    expect(
        sink.events == [.key(evLeftMeta, true), .key(evA, true), .key(evA, false), .key(evLeftMeta, false)],
        "Command is pressed before the key and released after it, got \(sink.events)"
    )
    expect(injector.isIdle, "nothing is left held")
}

func testSeveralFlagsAreWrappedInAFixedOrderAndReleasedInReverse() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, [.shift, .control, .option, .command]))
    try injector.inject(key(vkA, false, [.shift, .control, .option, .command]))
    expect(
        sink.events == [
            .key(evLeftShift, true), .key(evLeftCtrl, true), .key(evLeftAlt, true), .key(evLeftMeta, true),
            .key(evA, true), .key(evA, false),
            .key(evLeftMeta, false), .key(evLeftAlt, false), .key(evLeftCtrl, false), .key(evLeftShift, false)
        ],
        "modifiers go down in a fixed order and up in reverse, got \(sink.events)"
    )
}

func testAModifierKeyAlreadyDownIsNotPressedAgain() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkCommand, true, [.command]))
    try injector.inject(key(vkA, true, [.command]))
    try injector.inject(key(vkA, false, [.command]))
    try injector.inject(key(vkCommand, false, []))
    expect(
        sink.events == [.key(evLeftMeta, true), .key(evA, true), .key(evA, false), .key(evLeftMeta, false)],
        "a held Command key is the modifier; no second press is added, got \(sink.events)"
    )
}

func testASharedWrapperModifierIsReleasedOnlyAfterTheLastKeyItWrapped() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, [.control]))
    try injector.inject(key(vkB, true, [.control]))
    try injector.inject(key(vkA, false, [.control]))
    expect(!sink.events.contains(.key(evLeftCtrl, false)), "Control stays down while the second key is down")
    try injector.inject(key(vkB, false, [.control]))
    expect(
        sink.events == [
            .key(evLeftCtrl, true), .key(evA, true), .key(evB, true), .key(evA, false), .key(evB, false),
            .key(evLeftCtrl, false)
        ],
        "Control is pressed once and released after the last wrapped key, got \(sink.events)"
    )
}

func testCapsLockHoldsShiftAroundLettersOnly() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, [], caps: true))
    try injector.inject(key(vkA, false, [], caps: true))
    expect(
        sink.events == [.key(evLeftShift, true), .key(evA, true), .key(evA, false), .key(evLeftShift, false)],
        "a letter with Caps Lock on is wrapped in Shift, got \(sink.events)"
    )
    sink.clear()
    try injector.inject(key(vk1, true, [], caps: true))
    try injector.inject(key(vk1, false, [], caps: true))
    expect(sink.events == [.key(ev1, true), .key(ev1, false)], "a digit is not shifted by Caps Lock, got \(sink.events)")
}

func testCapsLockStateIsRememberedUntilTheViewerSaysOtherwise() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkB, true, [], caps: true))
    try injector.inject(key(vkB, false, [], caps: nil))
    sink.clear()
    try injector.inject(key(vkA, true, [], caps: nil))
    expect(sink.events == [.key(evLeftShift, true), .key(evA, true)], "a key with no field takes the last state, got \(sink.events)")
    try injector.inject(key(vkA, false, [], caps: nil))
    sink.clear()
    try injector.inject(key(vkA, true, [], caps: false))
    expect(sink.events == [.key(evA, true)], "Caps Lock off stops the wrapping, got \(sink.events)")
}

func testCapsLockWithShiftFlagIsWrappedOnceAndWithShiftHeldNotAtAll() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, [.shift], caps: true))
    try injector.inject(key(vkA, false, [.shift], caps: true))
    expect(
        sink.events == [.key(evLeftShift, true), .key(evA, true), .key(evA, false), .key(evLeftShift, false)],
        "Caps Lock and a Shift flag press Shift once, got \(sink.events)"
    )
    sink.clear()
    try injector.inject(key(vkShift, true, [.shift], caps: true))
    try injector.inject(key(vkA, true, [.shift], caps: true))
    expect(sink.events == [.key(evLeftShift, true), .key(evA, true)], "a held Shift key is not pressed again, got \(sink.events)")
}

func testTheCapsLockKeyItselfIsNeverPosted() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkCapsLock, true, [], caps: true))
    try injector.inject(key(vkCapsLock, false, [], caps: false))
    expect(sink.events.isEmpty, "the host's own Caps Lock is never toggled, got \(sink.events)")
}

func testAnUnmappedKeyIsRefusedAndNothingIsHeld() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    do {
        try injector.inject(key(0xFFFF, true, [.command]))
        expect(false, "an unmapped key is an error")
    } catch let error as PortalInputInjectorError {
        expect(error == .unmappedKey(0xFFFF), "the error names the key, got \(error)")
    }
    expect(sink.events.isEmpty && injector.isIdle, "no wrapper modifier was left pressed")
}

func testReleaseAllReleasesEveryKeyAndButtonAndIsIdempotent() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkShift, true, [.shift]))
    try injector.inject(key(vkA, true, [.control], caps: false))
    try injector.inject(.pointerButton(button: .left, isDown: true, x: 10, y: 10))
    try injector.inject(.pointerButton(button: .back, isDown: true, x: 10, y: 10))
    expect(!injector.isIdle, "keys and buttons are held")
    sink.clear()

    try injector.releaseAll()
    let released = Set(sink.events)
    expect(
        released == [.button(272, false), .button(275, false), .key(evA, false), .key(evLeftCtrl, false), .key(evLeftShift, false)],
        "every held key, wrapper modifier and button is released, got \(sink.events)"
    )
    expect(sink.events.count == 5, "each is released once, got \(sink.events)")
    expect(injector.isIdle, "nothing is left held")

    sink.clear()
    try injector.releaseAll()
    expect(sink.events.isEmpty, "a second releaseAll posts nothing")
}

func testReleaseAllKeepsReleasingAfterAFailureAndKeepsTheFailedOneHeld() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, []))
    try injector.inject(key(vkB, true, []))
    sink.clear()
    sink.refuse(when: { $0 == .key(evA, false) })
    do {
        try injector.releaseAll()
        expect(false, "a failed release is reported")
    } catch is SinkRefusal {}
    expect(sink.events == [.key(evB, false)], "the other key was still released, got \(sink.events)")
    expect(!injector.isIdle, "the key that failed is still held")
    sink.refuse(when: nil)
    try injector.releaseAll()
    expect(injector.isIdle && sink.events.last == .key(evA, false), "a retry releases it")
}

func testReleaseAllInputEventReleasesToo() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, true, []))
    sink.clear()
    try injector.inject(.releaseAllInput)
    expect(sink.events == [.key(evA, false)], "the wire's releaseAllInput releases held keys, got \(sink.events)")
}

func testAKeyUpForAKeyNeverPressedPostsNothing() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(key(vkA, false, []))
    expect(sink.events.isEmpty, "a stray release is not forwarded, got \(sink.events)")
}

func testButtonsMapToEvdevCodesAndMoveThePointerFirst() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    let expected: [(CanvasPointerButton, Int32)] = [(.left, 272), (.right, 273), (.middle, 274), (.back, 275), (.forward, 276)]
    for (index, (button, code)) in expected.enumerated() {
        sink.clear()
        try injector.inject(.pointerButton(button: button, isDown: true, x: 100, y: 200))
        try injector.inject(.pointerButton(button: button, isDown: false, x: 100, y: 200))
        // The pointer is moved only when it is not already there.
        let move: [SinkEvent] = index == 0 ? [.absolute(stream: 57, x: 100, y: 200)] : []
        expect(
            sink.events == move + [.button(code, true), .button(code, false)],
            "\(button) is evdev \(code), moving the pointer first only when needed, got \(sink.events)"
        )
    }
}

func testPointerMotionIsInLogicalCoordinatesAndClampedToTheMonitor() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(.pointerMoved(x: 640.5, y: 360.25))
    try injector.inject(.pointerMoved(x: -5, y: 5000))
    expect(sink.events.count == 2, "two moves were sent")
    expect(sink.events[0] == .absolute(stream: 57, x: 640.5, y: 360.25), "logical coordinates pass through unscaled")
    if case let .absolute(_, x, y) = sink.events[1] {
        expect(x == 0, "x clamps to the left edge")
        expect(y < 1080 && y > 1079.9, "y clamps just inside the bottom edge, got \(y)")
    } else {
        expect(false, "the second event is an absolute move")
    }
}

func testNonFiniteCoordinatesAreRefused() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    for event in [
        SensoriumInputEvent.pointerMoved(x: .nan, y: 1),
        .pointerMoved(x: 1, y: .infinity),
        .pointerButton(button: .left, isDown: true, x: .nan, y: 0)
    ] {
        do {
            try injector.inject(event)
            expect(false, "\(event) is refused")
        } catch let error as PortalInputInjectorError {
            expect(error == .invalidValue, "the error is invalidValue, got \(error)")
        }
    }
    expect(sink.events.isEmpty && injector.isIdle, "nothing was sent or held")
}

func testRelativeMotionIsSentOnlyWhileThePointerIsCaptured() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(.pointerMovedRelative(deltaX: 3, deltaY: 4))
    expect(sink.events.isEmpty, "relative motion before capture is dropped")
    try injector.inject(.pointerCaptureChanged(isCaptured: true))
    try injector.inject(.pointerMovedRelative(deltaX: 3, deltaY: -4))
    expect(sink.events == [.relative(dx: 3, dy: -4)], "captured motion is relative, got \(sink.events)")
    try injector.inject(.pointerCaptureChanged(isCaptured: false))
    try injector.inject(.pointerMovedRelative(deltaX: 1, deltaY: 1))
    expect(sink.events.count == 1, "motion after release is dropped")
}

private func scroll(
    _ dx: Double,
    _ dy: Double,
    phase: CanvasScrollPhase? = nil,
    lines: (Double, Double)? = nil
) -> SensoriumInputEvent {
    .scrolled(
        deltaX: dx, deltaY: dy, x: 50, y: 60, phase: phase, momentumPhase: nil,
        lineDeltaX: lines?.0, lineDeltaY: lines?.1
    )
}

func testPointScrollsFlipTheWireSignAndFinishWithTheGesture() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(scroll(0, 12, phase: .changed))
    try injector.inject(scroll(-4, 0, phase: .ended))
    try injector.inject(scroll(0, 10, phase: nil))
    expect(
        sink.events == [
            .absolute(stream: 57, x: 50, y: 60),
            .axis(dx: 0, dy: -12, finish: false),
            .axis(dx: 4, dy: 0, finish: true),
            .axis(dx: 0, dy: -10, finish: true)
        ],
        "the wire's down is the portal's negative, and a gesture with no phase finishes at once, got \(sink.events)"
    )
}

func testLineScrollsAreWholeDiscreteStepsPlusTheFractionAsSmoothMotion() throws {
    let sink = RecordingSink()
    let injector = makeInjector(sink)
    try injector.inject(scroll(0, 30, lines: (0, 3)))
    expect(
        sink.events == [.absolute(stream: 57, x: 50, y: 60), .discrete(.vertical, -3)],
        "three wheel notches down are three negative vertical steps, got \(sink.events)"
    )
    sink.clear()
    try injector.inject(scroll(-5, 0, lines: (-0.5, 0)))
    expect(
        sink.events == [.axis(dx: 5, dy: 0, finish: true)],
        "half a notch is smooth motion at ten points a line, got \(sink.events)"
    )
    sink.clear()
    try injector.inject(scroll(0, 0, lines: (2.25, -1.75)))
    expect(
        sink.events == [
            .discrete(.vertical, 1), .discrete(.horizontal, -2),
            .axis(dx: -2.5, dy: 7.5, finish: true)
        ],
        "whole lines go discrete toward zero and the fractions go smooth, got \(sink.events)"
    )
}

func testEveryPostGoesThroughTheObserver() throws {
    let counts = Counts()
    let sink = RecordingSink()
    let injector = makeInjector(sink, observer: PortalInputPostObserver(
        sampleBeforePost: { counts.before() },
        recordPost: { counts.after() }
    ))
    try injector.inject(.pointerMoved(x: 1, y: 1))
    try injector.inject(key(vkA, true, [.command]))
    expect(sink.events.count == 3, "a move, a wrapper press and a key press were sent")
    expect(counts.snapshot() == (3, 3), "each post is sampled before and recorded after, got \(counts.snapshot())")
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var beforeCount = 0
    private var afterCount = 0

    func before() { lock.withLock { beforeCount += 1 } }
    func after() { lock.withLock { afterCount += 1 } }
    func snapshot() -> (Int, Int) { lock.withLock { (beforeCount, afterCount) } }
}

func inputInjectorTests() -> [NamedTest] { [
    ("a key with flags but no modifier key down gets modifiers pressed around it", { try! testAKeyWithFlagsButNoModifierKeyDownGetsTheModifiersPressedAroundIt() }),
    ("several flags are wrapped in a fixed order and released in reverse", { try! testSeveralFlagsAreWrappedInAFixedOrderAndReleasedInReverse() }),
    ("a modifier key already down is not pressed again", { try! testAModifierKeyAlreadyDownIsNotPressedAgain() }),
    ("a shared wrapper modifier is released after the last key it wrapped", { try! testASharedWrapperModifierIsReleasedOnlyAfterTheLastKeyItWrapped() }),
    ("Caps Lock holds Shift around letters only", { try! testCapsLockHoldsShiftAroundLettersOnly() }),
    ("Caps Lock state is remembered until the viewer says otherwise", { try! testCapsLockStateIsRememberedUntilTheViewerSaysOtherwise() }),
    ("Caps Lock with a Shift flag presses Shift once, and not at all when Shift is held", { try! testCapsLockWithShiftFlagIsWrappedOnceAndWithShiftHeldNotAtAll() }),
    ("the Caps Lock key itself is never posted", { try! testTheCapsLockKeyItselfIsNeverPosted() }),
    ("an unmapped key is refused and nothing is held", { try! testAnUnmappedKeyIsRefusedAndNothingIsHeld() }),
    ("releaseAll releases every key and button and is idempotent", { try! testReleaseAllReleasesEveryKeyAndButtonAndIsIdempotent() }),
    ("releaseAll keeps going after a failure and keeps the failed key held", { try! testReleaseAllKeepsReleasingAfterAFailureAndKeepsTheFailedOneHeld() }),
    ("releaseAllInput releases held keys", { try! testReleaseAllInputEventReleasesToo() }),
    ("a key up for a key never pressed posts nothing", { try! testAKeyUpForAKeyNeverPressedPostsNothing() }),
    ("buttons map to evdev codes and move the pointer first", { try! testButtonsMapToEvdevCodesAndMoveThePointerFirst() }),
    ("pointer motion is in logical coordinates, clamped to the monitor", { try! testPointerMotionIsInLogicalCoordinatesAndClampedToTheMonitor() }),
    ("non-finite coordinates are refused", { try! testNonFiniteCoordinatesAreRefused() }),
    ("relative motion is sent only while the pointer is captured", { try! testRelativeMotionIsSentOnlyWhileThePointerIsCaptured() }),
    ("point scrolls flip the wire sign and finish with the gesture", { try! testPointScrollsFlipTheWireSignAndFinishWithTheGesture() }),
    ("line scrolls are whole discrete steps plus the fraction as smooth motion", { try! testLineScrollsAreWholeDiscreteStepsPlusTheFractionAsSmoothMotion() }),
    ("every post goes through the observer", { try! testEveryPostGoesThroughTheObserver() })
] }

#endif
