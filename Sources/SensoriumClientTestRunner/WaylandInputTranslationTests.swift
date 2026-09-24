import Foundation
import SensoriumClient
import SensoriumCore

/// The pointer button codes a Wayland compositor delivers are the Linux
/// `BTN_*` values, and only the three the protocol carries are forwarded.
@MainActor
func testWaylandPointerButtonMapTests() {
    expect(WaylandPointerButtonMap.button(forEvdev: 0x110) == .left, "BTN_LEFT maps to the left button")
    expect(WaylandPointerButtonMap.button(forEvdev: 0x111) == .right, "BTN_RIGHT maps to the right button")
    expect(WaylandPointerButtonMap.button(forEvdev: 0x112) == .middle, "BTN_MIDDLE maps to the middle button")
    expect(WaylandPointerButtonMap.button(forEvdev: 0x113) == nil, "BTN_SIDE is dropped")
    expect(WaylandPointerButtonMap.button(forEvdev: 0x116) == nil, "BTN_TASK is dropped")

    print("PASS: the Wayland pointer button map carries the three protocol buttons and drops the rest")
}

/// One `wl_pointer.frame` is one scroll event: the axis reports inside it are
/// accumulated, the sign is flipped onto the wire's convention, and the
/// gesture phase a finger source reports is carried with it.
@MainActor
func testWaylandScrollFrameTests() {
    var finger = WaylandScrollFrameAccumulator()
    finger.axisSource(.finger)
    finger.axis(.vertical, value: 12)
    expect(
        finger.frame(x: 100, y: 200)
            == .scrolled(deltaX: 0, deltaY: -12, x: 100, y: 200, phase: .began, momentumPhase: nil),
        "the first frame of a finger gesture scrolls by the negated axis value and begins the phase"
    )
    finger.axisSource(.finger)
    finger.axis(.vertical, value: 3)
    finger.axis(.horizontal, value: -4)
    expect(
        finger.frame(x: 100, y: 200)
            == .scrolled(deltaX: 4, deltaY: -3, x: 100, y: 200, phase: .changed, momentumPhase: nil),
        "a later frame of the same finger gesture continues it and negates both axes"
    )
    finger.axisSource(.finger)
    finger.axisStop(.vertical)
    expect(
        finger.frame(x: 100, y: 200)
            == .scrolled(deltaX: 0, deltaY: 0, x: 100, y: 200, phase: .ended, momentumPhase: nil),
        "axis_stop ends the finger gesture"
    )
    finger.axisSource(.finger)
    finger.axis(.vertical, value: 5)
    expect(
        finger.frame(x: 100, y: 200)
            == .scrolled(deltaX: 0, deltaY: -5, x: 100, y: 200, phase: .began, momentumPhase: nil),
        "the next finger gesture after a stop begins again"
    )

    var wheel = WaylandScrollFrameAccumulator()
    wheel.axisSource(.wheel)
    wheel.axis(.vertical, value: 15)
    wheel.axisValue120(.vertical, value120: 240)
    expect(
        wheel.frame(x: 10, y: 20)
            == .scrolled(deltaX: 0, deltaY: -20, x: 10, y: 20, phase: nil, momentumPhase: nil),
        "a wheel frame carrying value120 scrolls two notches and ignores the notional axis value"
    )
    wheel.axisSource(.wheel)
    wheel.axisValue120(.vertical, value120: -120)
    expect(
        wheel.frame(x: 10, y: 20)
            == .scrolled(deltaX: 0, deltaY: 10, x: 10, y: 20, phase: nil, momentumPhase: nil),
        "a wheel notch the other way scrolls one notch the other way"
    )
    wheel.axisSource(.wheel)
    wheel.axis(.vertical, value: 15)
    expect(
        wheel.frame(x: 10, y: 20)
            == .scrolled(deltaX: 0, deltaY: -15, x: 10, y: 20, phase: nil, momentumPhase: nil),
        "a wheel frame with no value120 scrolls by the axis value itself"
    )

    var idle = WaylandScrollFrameAccumulator()
    idle.axisSource(.wheel)
    expect(idle.frame(x: 0, y: 0) == nil, "a frame carrying no axis report at all scrolls nothing")

    var continuous = WaylandScrollFrameAccumulator()
    continuous.axisSource(.continuous)
    continuous.axis(.vertical, value: 7)
    expect(
        continuous.frame(x: 1, y: 2)
            == .scrolled(deltaX: 0, deltaY: -7, x: 1, y: 2, phase: nil, momentumPhase: nil),
        "a continuous source scrolls by the axis value with no phase"
    )

    print("PASS: a Wayland axis frame becomes one scroll event with the wire's sign, units and phase")
}

/// Key repeat is the compositor's rate and delay applied to whichever
/// non-modifier key is held, computed without a clock so the schedule is
/// checkable on its own.
@MainActor
func testKeyRepeatScheduleTests() {
    var schedule = KeyRepeatSchedule()
    schedule.setRepeatInfo(rate: 25, delayMilliseconds: 600)
    expect(schedule.keyDown(evdev: 30, isModifier: false) == 600, "the first repeat waits the compositor's delay")
    expect(schedule.fire()?.key == 30, "the armed key is the one that repeats")
    expect(schedule.fire()?.nextDelayMilliseconds == 40, "later repeats arrive at the compositor's rate")

    expect(schedule.keyDown(evdev: 31, isModifier: false) == 600, "a second key takes the repeat over")
    expect(schedule.fire()?.key == 31, "the key that repeats is the one pressed last")
    expect(schedule.keyUp(evdev: 30) == false, "releasing the key that lost the repeat stops nothing")
    expect(schedule.keyUp(evdev: 31) == true, "releasing the repeating key stops it")
    expect(schedule.fire() == nil, "nothing repeats once the key is up")

    expect(schedule.keyDown(evdev: 42, isModifier: true) == nil, "a modifier key never repeats")
    expect(schedule.keyDown(evdev: 30, isModifier: false) == 600, "an ordinary key arms again after a modifier")
    expect(schedule.keyDown(evdev: 42, isModifier: true) == nil, "a modifier pressed over a held key still never repeats")
    expect(schedule.fire()?.key == 30, "a modifier pressed over a held key leaves that key repeating")
    expect(schedule.focusLost() == true, "focus leaving stops the repeat")
    expect(schedule.fire() == nil, "nothing repeats once focus is gone")

    var disabled = KeyRepeatSchedule()
    disabled.setRepeatInfo(rate: 0, delayMilliseconds: 600)
    expect(disabled.keyDown(evdev: 30, isModifier: false) == nil, "rate 0 disables repeat entirely")
    expect(disabled.fire() == nil, "a disabled schedule fires nothing")

    print("PASS: the key repeat schedule waits the delay, repeats at the rate, and stops on release and focus loss")
}
