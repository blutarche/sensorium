import Foundation
import SensoriumCore

/// The pointer buttons a Wayland compositor reports, which are the Linux
/// `BTN_*` codes from `input-event-codes.h`, and the three the protocol
/// carries. Anything else -- side, extra, forward, back, task -- has no place
/// on the wire, so it is dropped here rather than translated to a button the
/// far machine would act on.
public enum WaylandPointerButtonMap {
    private static let left: UInt32 = 0x110
    private static let right: UInt32 = 0x111
    private static let middle: UInt32 = 0x112

    public static func button(forEvdev code: UInt32) -> CanvasPointerButton? {
        switch code {
        case left: .left
        case right: .right
        case middle: .middle
        default: nil
        }
    }
}

/// Which of a pointer's two scroll axes an axis report is about.
public enum WaylandScrollAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

/// What produced a scroll: `wl_pointer.axis_source`. Only a finger on a
/// touchpad reports a gesture with a beginning and an end; a wheel notch is a
/// discrete event with no phase of its own.
public enum WaylandScrollAxisSource: Equatable, Sendable {
    case wheel
    case finger
    case continuous
    case wheelTilt
}

/// Accumulates one `wl_pointer.frame` -- the axis values, the source, and any
/// axis stop inside it -- into the single scroll event that frame means.
///
/// A compositor delivers a scroll as several events that only mean something
/// together, and the frame is where they are complete. Emitting per axis
/// event instead would put two half-scrolls on the wire for one diagonal
/// swipe.
public struct WaylandScrollFrameAccumulator: Equatable, Sendable {
    /// How far one wheel notch scrolls, in the points the host scrolls by.
    /// libinput's wheel click is a notional 10 to 15 units rather than a
    /// measured distance, and the host applies the value as pixels, so a
    /// figure has to be chosen here: 10 is the low end of that range, which
    /// keeps a notch close to one line of text rather than a jump.
    public static let pointsPerWheelNotch: Double = 10

    private var source: WaylandScrollAxisSource?
    private var vertical: Double?
    private var horizontal: Double?
    private var verticalValue120: Int32?
    private var horizontalValue120: Int32?
    private var stopped = false
    /// Whether a finger gesture is already under way, so the next frame of it
    /// continues rather than begins.
    private var isGestureInProgress = false

    public init() {}

    public mutating func axisSource(_ source: WaylandScrollAxisSource) {
        self.source = source
    }

    public mutating func axis(_ axis: WaylandScrollAxis, value: Double) {
        switch axis {
        case .vertical: vertical = (vertical ?? 0) + value
        case .horizontal: horizontal = (horizontal ?? 0) + value
        }
    }

    /// `wl_pointer.axis_value120`, which a v8 pointer sends alongside the
    /// notional axis value for a wheel. 120 is one notch.
    public mutating func axisValue120(_ axis: WaylandScrollAxis, value120: Int32) {
        switch axis {
        case .vertical: verticalValue120 = (verticalValue120 ?? 0) + value120
        case .horizontal: horizontalValue120 = (horizontalValue120 ?? 0) + value120
        }
    }

    /// Which axis stopped does not change the answer: a frame carries one
    /// gesture, and a stop on either axis is that gesture ending.
    public mutating func axisStop(_ axis: WaylandScrollAxis) {
        stopped = true
    }

    /// The scroll this frame means, at the pointer's last known surface-local
    /// position, or nil when the frame carried no scroll at all -- which is
    /// most frames, since every motion and button event ends in one too.
    public mutating func frame(x: Double, y: Double) -> CanvasSurfaceEvent? {
        defer { clearFrame() }
        let source = source
        guard vertical != nil || horizontal != nil || verticalValue120 != nil
                || horizontalValue120 != nil || stopped else {
            return nil
        }
        let phase = phaseForThisFrame(source: source)
        // Wayland's positive axis value means the content moves up, and the
        // wire's positive delta means the content moves down, which is the
        // convention the host already applies.
        return .scrolled(
            deltaX: -delta(axisValue: horizontal, value120: horizontalValue120, source: source),
            deltaY: -delta(axisValue: vertical, value120: verticalValue120, source: source),
            x: x,
            y: y,
            phase: phase,
            // A compositor delivers what the device reported and synthesises
            // no kinetic scrolling of its own, so there is never a momentum
            // phase to carry.
            momentumPhase: nil
        )
    }

    private func delta(axisValue: Double?, value120: Int32?, source: WaylandScrollAxisSource?) -> Double {
        if source == .wheel, let value120 {
            return Double(value120) / 120 * Self.pointsPerWheelNotch
        }
        return axisValue ?? 0
    }

    private mutating func phaseForThisFrame(source: WaylandScrollAxisSource?) -> CanvasScrollPhase? {
        guard source == .finger else { return nil }
        if stopped {
            isGestureInProgress = false
            return .ended
        }
        guard isGestureInProgress else {
            isGestureInProgress = true
            return .began
        }
        return .changed
    }

    private mutating func clearFrame() {
        source = nil
        vertical = nil
        horizontal = nil
        verticalValue120 = nil
        horizontalValue120 = nil
        stopped = false
    }
}

/// When a held key should repeat, from the rate and delay the compositor
/// reported in `wl_keyboard.repeat_info`.
///
/// Wayland leaves repeat to the client: the compositor sends one key-down and
/// one key-up, and every repeat in between is the client's own to produce.
/// This computes only when the next repeat is due, so the schedule is
/// checkable without a timer; arming the timer is the window's job.
public struct KeyRepeatSchedule: Equatable, Sendable {
    /// Repeats per second. Zero is the compositor saying this seat does not
    /// repeat at all.
    public private(set) var rate: Int = 0
    /// How long a key must be held before the first repeat.
    public private(set) var delayMilliseconds: Int = 0
    /// The key currently due to repeat, if any.
    public private(set) var repeatingKey: UInt32?

    public init() {}

    public mutating func setRepeatInfo(rate: Int, delayMilliseconds: Int) {
        self.rate = max(rate, 0)
        self.delayMilliseconds = max(delayMilliseconds, 0)
    }

    /// Arms the schedule for a key that just went down, and answers how long
    /// until its first repeat. Nil when nothing should repeat: a modifier
    /// key, or a seat whose rate is zero.
    ///
    /// A modifier leaves whatever is already armed alone -- holding a letter
    /// and then pressing Shift is one hand typing a capital, not a reason for
    /// the letter to stop repeating.
    @discardableResult
    public mutating func keyDown(evdev: UInt32, isModifier: Bool) -> Int? {
        guard !isModifier else { return nil }
        guard rate > 0 else {
            repeatingKey = nil
            return nil
        }
        repeatingKey = evdev
        return delayMilliseconds
    }

    /// Answers whether this release stopped a repeat that was armed. A
    /// release of anything else leaves the schedule alone: the key that took
    /// the repeat over keeps it.
    @discardableResult
    public mutating func keyUp(evdev: UInt32) -> Bool {
        guard repeatingKey == evdev else { return false }
        repeatingKey = nil
        return true
    }

    /// The keyboard left this surface. Nothing may keep repeating into a
    /// window the person is no longer typing into.
    @discardableResult
    public mutating func focusLost() -> Bool {
        guard repeatingKey != nil else { return false }
        repeatingKey = nil
        return true
    }

    /// One repeat falling due: the key to send again, and how long until the
    /// next one. Nil when nothing is armed any more.
    public mutating func fire() -> (key: UInt32, nextDelayMilliseconds: Int)? {
        guard let repeatingKey, rate > 0 else { return nil }
        return (repeatingKey, max(1000 / rate, 1))
    }
}
