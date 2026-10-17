import AppKit
import CoreGraphics
import Foundation
import SensoriumCore

public enum CoreGraphicsInputInjectorError: Error, Equatable {
    case eventSourceUnavailable
    case eventCreationFailed
    case canvasDisplayUnavailable
}

/// Posts input into the session-owned canvas only. Coordinates arrive in canvas
/// logical points and are translated through that display's own bounds, so a
/// physical display is never addressed.
///
/// Every posted event targets `.cgSessionEventTap` unless one of the two
/// exceptions below applies.
///
/// One exception: a key matching `SystemHotkeyChord.isSystemHotkey` -- the
/// window server and Dock's own hotkeys, such as Mission Control or
/// Spotlight -- is posted at `.cghidEventTap` instead, because those
/// consumers act ahead of `.cgSessionEventTap` and never see an event posted
/// there at all.
///
/// A second exception: while `lockStateReader` reports the screen locked, a
/// `.hostScreen` injector posts every event -- key, pointer, and scroll
/// alike -- at `.cghidEventTap` instead of `.cgSessionEventTap`, the same tap
/// the system-hotkey exception above uses. A `.sessionCanvas` injector posts
/// nothing at all while the screen is locked: only a host-screen session,
/// with its arming, indicator and session log, may reach the lock screen.
///
/// A post can reset the `hidSystemState` idle counter
/// `CoreGraphicsLocalActivitySignal` reads, the same way a real key at the
/// machine does: a key event posted at `.cgSessionEventTap` reset it on a
/// real host, as a post at `.cghidEventTap` does. So every post, at either
/// tap and of any event type, samples `hostInjectedHIDActivity`
/// immediately before it is posted and records into it, so
/// `SelfPostDiscountingLocalActivitySignal` can tell the viewer's input apart
/// from a real person later -- and so a real person's own input just before
/// one of these posts is not lost to it.
///
/// A key on the navigation cluster (arrows, Home, End, Page Up/Down, forward
/// delete) or the F-row also carries `CoreGraphicsInputTranslation
/// .nativeAuxiliaryFlags` on top of whatever modifiers the viewer held: real
/// hardware sets these bits on that event whether or not fn is actually held,
/// and the window server's own hotkey matching reads them -- without them,
/// nothing this class posts for those keys reaches it at all, tap location
/// notwithstanding.
///
/// Posting requires the user to grant Accessibility permission to the host app.
/// Nothing in this repository grants, requests, or exercises that permission.
@MainActor
public final class CoreGraphicsInputInjector: InputInjecting {
    private let canvasDisplayID: CGDirectDisplayID
    private let sessionKind: InputSessionKind
    private let source: CGEventSource
    private let postEvent: (CGEvent, CGEventTapLocation) -> Void
    private let associateMouseAndCursor: (Bool) -> Void
    private let warpCursor: (CGPoint) -> Void
    /// How far, in points, a press may land from the previous one and still
    /// count as part of the same click run. macOS does not publish its own value.
    private static let doubleClickTolerance: CGFloat = 4

    private let lockStateReader: any ScreenLockStateReading
    private let hostInjectedHIDActivity: any HostInjectedHIDActivity
    private let doubleClickInterval: TimeInterval
    private let now: () -> TimeInterval
    private var modifiers: CGEventFlags = []
    /// When each pressed-and-not-yet-released key last went down. A key-down
    /// for one of these, soon after the last, is the viewer resending a held
    /// key, which a physical keyboard reports as an auto-repeat.
    private var heldKeyDownTimes: [UInt16: TimeInterval] = [:]
    /// Longer than the delay-until-repeat viewers use by default, so only a
    /// viewer resending a held key qualifies; a key whose release was lost
    /// stops looking held.
    private static let autoRepeatWindow: TimeInterval = 2
    /// The click count of each held button's press, carried on its release and
    /// on every drag of it until then. A button is held while it has an entry.
    private var heldClickCounts: [CanvasPointerButton: Int64] = [:]
    private var lastPress: (button: CanvasPointerButton, point: CGPoint, time: TimeInterval, count: Int64)?
    /// The button macOS reports motion for while several are held: the
    /// lowest-numbered one.
    private var heldButton: CanvasPointerButton? {
        [CanvasPointerButton.left, .right, .middle, .back, .forward].first { heldClickCounts[$0] != nil }
    }
    /// Where every relative-motion event is posted while captured. The
    /// system cursor never actually needs to move for the injected motion to
    /// be seen: `CGAssociateMouseAndMouseCursorPosition(false)` stops a
    /// posted move from dragging the visible cursor along, so this anchor can
    /// stay fixed at the canvas centre for the whole capture and only the
    /// event's raw delta fields carry the motion.
    private var capturedAnchor: CGPoint?
    /// Sub-point motion not yet posted, per axis. The event delta fields are
    /// integers, so the fraction left over by rounding is added to the next
    /// event's delta instead of being lost.
    private var capturedRemainder = CGVector.zero

    /// `postEvent` is the seam a test uses to record which tap location an
    /// event was given, instead of calling the real `CGEvent.post`, which
    /// would inject a real synthetic event system-wide. `associateMouseAndCursor`
    /// and `warpCursor` are the same kind of seam for the two calls that move
    /// the machine's real cursor when a capture starts and ends.
    public init(
        canvasDisplayID: CGDirectDisplayID,
        sessionKind: InputSessionKind,
        lockStateReader: any ScreenLockStateReading = CGSessionScreenLockState(),
        hostInjectedHIDActivity: any HostInjectedHIDActivity = MutableHostInjectedHIDActivity.shared,
        doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        postEvent: @escaping (CGEvent, CGEventTapLocation) -> Void = { event, tap in event.post(tap: tap) },
        associateMouseAndCursor: @escaping (Bool) -> Void = { _ = CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) },
        warpCursor: @escaping (CGPoint) -> Void = { _ = CGWarpMouseCursorPosition($0) }
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw CoreGraphicsInputInjectorError.eventSourceUnavailable
        }
        self.canvasDisplayID = canvasDisplayID
        self.sessionKind = sessionKind
        self.source = source
        self.lockStateReader = lockStateReader
        self.hostInjectedHIDActivity = hostInjectedHIDActivity
        self.postEvent = postEvent
        self.associateMouseAndCursor = associateMouseAndCursor
        self.warpCursor = warpCursor
        self.doubleClickInterval = doubleClickInterval
        self.now = now
    }

    public func inject(_ event: SensoriumInputEvent) throws {
        if sessionKind == .sessionCanvas, Self.posts(event), lockStateReader.isScreenLocked() {
            throw InputInjectionSuppressed()
        }
        switch event {
        case let .pointerMoved(x, y):
            let point = try globalPoint(x: x, y: y)
            try post(
                mouse: CoreGraphicsInputTranslation.motionType(heldButton: heldButton),
                button: CoreGraphicsInputTranslation.mouseButton(heldButton ?? .left),
                buttonNumber: heldButton.flatMap(CoreGraphicsInputTranslation.otherButtonNumber),
                at: point,
                clickState: heldButton.flatMap { heldClickCounts[$0] },
                tap: tapLocation()
            )
        case let .pointerMovedRelative(deltaX, deltaY):
            // A race, not a protocol violation: the viewer always sends
            // `pointerCaptureChanged(true)` before its first relative move,
            // but a delayed or reordered delivery could land one first. There
            // is no anchor to post it at yet, so it is dropped rather than
            // guessed at.
            guard let anchor = capturedAnchor else { return }
            try post(
                mouse: CoreGraphicsInputTranslation.motionType(heldButton: heldButton),
                button: CoreGraphicsInputTranslation.mouseButton(heldButton ?? .left),
                buttonNumber: heldButton.flatMap(CoreGraphicsInputTranslation.otherButtonNumber),
                at: anchor,
                relativeDeltaX: deltaX,
                relativeDeltaY: deltaY,
                clickState: heldButton.flatMap { heldClickCounts[$0] },
                tap: tapLocation()
            )
        case let .pointerButton(button, isDown, x, y):
            let point = try globalPoint(x: x, y: y)
            if isDown {
                heldClickCounts[button] = clickCount(forPressOf: button, at: point)
            }
            let pressCount = heldClickCounts[button] ?? 1
            if !isDown {
                heldClickCounts[button] = nil
            }
            try post(
                mouse: CoreGraphicsInputTranslation.buttonType(button, isDown: isDown),
                button: CoreGraphicsInputTranslation.mouseButton(button),
                buttonNumber: CoreGraphicsInputTranslation.otherButtonNumber(button),
                at: point,
                clickState: pressCount,
                tap: tapLocation()
            )
        case let .scrolled(deltaX, deltaY, _, _, phase, momentumPhase):
            // A CGEvent scroll carries no location: macOS routes it to
            // whatever is under the one system cursor, which both session
            // canvases share. Standing the cursor on this canvas first is
            // what stops a scroll in one canvas's window from scrolling the
            // other. Posted every time rather than only on a change of
            // position: each surface has its own injector, so this one cannot
            // know whether the sibling injector has moved the cursor since.
            var cursorPoint: CGPoint?
            if let positioning = CoreGraphicsInputTranslation.cursorPositioning(for: event) {
                cursorPoint = try globalPoint(x: positioning.x, y: positioning.y)
            }
            guard let scroll = CoreGraphicsInputTranslation.scrollEvent(
                source: source,
                deltaX: deltaX,
                deltaY: deltaY,
                phase: phase,
                momentumPhase: momentumPhase
            ) else {
                throw CoreGraphicsInputInjectorError.eventCreationFailed
            }
            scroll.flags = modifiers
            let tap = tapLocation()
            if let cursorPoint {
                try post(
                    mouse: CoreGraphicsInputTranslation.motionType(heldButton: heldButton),
                    button: CoreGraphicsInputTranslation.mouseButton(heldButton ?? .left),
                    at: cursorPoint,
                    tap: tap
                )
            }
            send(scroll, tap: tap)
        case let .pointerCaptureChanged(isCaptured):
            if isCaptured {
                let bounds = CGDisplayBounds(canvasDisplayID)
                guard bounds.width > 0, bounds.height > 0 else {
                    throw CoreGraphicsInputInjectorError.canvasDisplayUnavailable
                }
                capturedAnchor = CGPoint(x: bounds.midX, y: bounds.midY)
                capturedRemainder = .zero
                associateMouseAndCursor(false)
            } else {
                associateMouseAndCursor(true)
                if let capturedAnchor {
                    warpCursor(capturedAnchor)
                }
                capturedAnchor = nil
                capturedRemainder = .zero
            }
        case let .key(keyCode, isDown, eventModifiers):
            modifiers = CoreGraphicsInputTranslation.flags(eventModifiers)
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                throw CoreGraphicsInputInjectorError.eventCreationFailed
            }
            // The extra native flags are this one posted event's business, not
            // the held-modifier state `modifiers` carries forward onto the
            // next pointer or scroll event: a pointer move must never pick up
            // .maskSecondaryFn just because the last key injected was an
            // arrow key.
            key.flags = modifiers.union(CoreGraphicsInputTranslation.nativeAuxiliaryFlags(forKeyCode: keyCode))
            if isDown {
                let time = now()
                let previous = heldKeyDownTimes.updateValue(time, forKey: keyCode)
                let isRepeat = previous.map { time - $0 <= Self.autoRepeatWindow } ?? false
                    && !CoreGraphicsInputTranslation.modifierKeyCodes.contains(keyCode)
                key.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
            } else {
                heldKeyDownTimes[keyCode] = nil
            }
            let isSystemHotkey = SystemHotkeyChord.isSystemHotkey(keyCode: keyCode, modifiers: eventModifiers)
            send(key, tap: isSystemHotkey ? .cghidEventTap : tapLocation())
        case .releaseAllInput:
            // Not a real release: this injector only remembers the single most
            // recent button and modifier flags, not every held key or the
            // location a correct mouse-up needs. HostSessionController holds
            // the authoritative, location-complete held state and turns
            // .releaseAllInput into real .pointerButton/.key release calls
            // through the cases above before it ever reaches here.
            modifiers = []
            heldClickCounts = [:]
            heldKeyDownTimes = [:]
        }
    }

    /// `.cghidEventTap` while a host-screen session's screen is locked,
    /// `.cgSessionEventTap` otherwise -- see the type's own doc comment for
    /// why.
    private func tapLocation() -> CGEventTapLocation {
        guard sessionKind == .hostScreen, lockStateReader.isScreenLocked() else { return .cgSessionEventTap }
        return .cghidEventTap
    }

    /// The only place this class posts, so no post can skip the sample and
    /// record the type's doc comment explains.
    private func send(_ event: CGEvent, tap: CGEventTapLocation) {
        hostInjectedHIDActivity.sampleBeforePost()
        hostInjectedHIDActivity.recordPost()
        postEvent(event, tap)
    }

    private static func posts(_ event: SensoriumInputEvent) -> Bool {
        switch event {
        case .pointerMoved, .pointerMovedRelative, .pointerButton, .scrolled, .key:
            true
        case .pointerCaptureChanged, .releaseAllInput:
            false
        }
    }

    /// `CGDisplayBounds` is half-open, so a point on maxX belongs to the next display;
    /// 1/64 is exact in binary and survives the window server's single-precision coordinates.
    private static let edgeInset: CGFloat = 1.0 / 64

    /// Canvas logical points are relative to the canvas; CGEvent wants global
    /// coordinates, which for the session canvas means its own display origin.
    private func globalPoint(x: Double, y: Double) throws -> CGPoint {
        let bounds = CGDisplayBounds(canvasDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            throw CoreGraphicsInputInjectorError.canvasDisplayUnavailable
        }
        return CGPoint(
            x: min(max(bounds.origin.x + x, bounds.minX), bounds.maxX - Self.edgeInset),
            y: min(max(bounds.origin.y + y, bounds.minY), bounds.maxY - Self.edgeInset)
        )
    }

    /// A press continues the previous one's run of clicks when it is the same
    /// button, inside the host's double-click interval, and close to where the
    /// previous press landed.
    private func clickCount(forPressOf button: CanvasPointerButton, at point: CGPoint) -> Int64 {
        let time = now()
        var count: Int64 = 1
        if let last = lastPress,
           last.button == button,
           time - last.time <= doubleClickInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= Self.doubleClickTolerance {
            count = last.count + 1
        }
        lastPress = (button, point, time, count)
        return count
    }

    /// `relativeDeltaX`/`relativeDeltaY` carry captured-mode motion on top of
    /// an otherwise ordinary move event: `point` never changes across a
    /// capture (see `capturedAnchor`), so it is the raw delta fields, not the
    /// event's own position, that any app reading unaccelerated device
    /// motion actually sees.
    private func post(
        mouse type: CGEventType,
        button: CGMouseButton,
        buttonNumber: Int64? = nil,
        at point: CGPoint,
        relativeDeltaX: Double? = nil,
        relativeDeltaY: Double? = nil,
        clickState: Int64? = nil,
        tap: CGEventTapLocation
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw CoreGraphicsInputInjectorError.eventCreationFailed
        }
        if let relativeDeltaX {
            let total = relativeDeltaX + capturedRemainder.dx
            let posted = total.rounded()
            capturedRemainder.dx = total - posted
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(posted))
        }
        if let relativeDeltaY {
            let total = relativeDeltaY + capturedRemainder.dy
            let posted = total.rounded()
            capturedRemainder.dy = total - posted
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(posted))
        }
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if let buttonNumber {
            event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        }
        event.flags = modifiers
        send(event, tap: tap)
    }
}

@MainActor
public final class CoreGraphicsInputInjectorFactory: InputInjectingFactory {
    private let lockStateReader: any ScreenLockStateReading
    private let hostInjectedHIDActivity: any HostInjectedHIDActivity

    public init(
        lockStateReader: any ScreenLockStateReading = CGSessionScreenLockState(),
        hostInjectedHIDActivity: any HostInjectedHIDActivity = MutableHostInjectedHIDActivity.shared
    ) {
        self.lockStateReader = lockStateReader
        self.hostInjectedHIDActivity = hostInjectedHIDActivity
    }

    public func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        try CoreGraphicsInputInjector(
            canvasDisplayID: canvasDisplayID,
            sessionKind: sessionKind,
            lockStateReader: lockStateReader,
            hostInjectedHIDActivity: hostInjectedHIDActivity
        )
    }
}

/// Pure translation from protocol input to CoreGraphics event vocabulary. Kept
/// separate from posting so it can be verified without an event tap.
public enum CoreGraphicsInputTranslation {
    public static func motionType(heldButton: CanvasPointerButton?) -> CGEventType {
        switch heldButton {
        case .none: .mouseMoved
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle, .back, .forward: .otherMouseDragged
        }
    }

    public static func buttonType(_ button: CanvasPointerButton, isDown: Bool) -> CGEventType {
        switch button {
        case .left:
            isDown ? .leftMouseDown : .leftMouseUp
        case .right:
            isDown ? .rightMouseDown : .rightMouseUp
        case .middle, .back, .forward:
            isDown ? .otherMouseDown : .otherMouseUp
        }
    }

    public static func mouseButton(_ button: CanvasPointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle, .back, .forward: .center
        }
    }

    /// The button number an other-mouse event carries, which is how macOS
    /// tells the middle button from the side buttons: `CGMouseButton` names
    /// only the first three. `nil` for left and right, whose event types
    /// already say which button they are.
    public static func otherButtonNumber(_ button: CanvasPointerButton) -> Int64? {
        switch button {
        case .left, .right: nil
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }

    /// Where the system cursor must be standing before `event` is posted, in
    /// canvas logical points, or `nil` when the event needs no repositioning.
    ///
    /// Only a scroll needs it. A pointer move or button press carries its own
    /// location and positions itself. A key event carries no location at all
    /// and macOS routes it by process-wide keyboard focus, which the two
    /// canvases also share — moving the cursor does not move keyboard focus,
    /// so there is nothing this can return that would fix it.
    public static func cursorPositioning(for event: SensoriumInputEvent) -> CGPoint? {
        switch event {
        case let .scrolled(_, _, x, y, _, _):
            CGPoint(x: x, y: y)
        case .pointerMoved, .pointerMovedRelative, .pointerButton, .key, .releaseAllInput, .pointerCaptureChanged:
            nil
        }
    }

    /// Builds the scroll event CoreGraphics posts for a `.scrolled` input.
    ///
    /// Trackpad deltas routinely arrive as a fraction of a pixel, and the
    /// integer wheel fields `CGEvent(scrollWheelEvent2Source:)` takes floor
    /// those to zero. The exact delta goes into
    /// `kCGScrollWheelEventFixedPtDeltaAxis1/2`, the fixed-point fields any
    /// app doing pixel rather than line-based scrolling reads, so no
    /// fractional remainder has to be carried per axis and per surface.
    public static func scrollEvent(
        source: CGEventSource,
        deltaX: Double,
        deltaY: Double,
        phase: CanvasScrollPhase?,
        momentumPhase: CanvasScrollMomentumPhase?
    ) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(deltaY.rounded())),
            wheel2: Int32(clamping: Int(deltaX.rounded())),
            wheel3: 0
        ) else {
            return nil
        }
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgScrollPhase(phase).rawValue))
        }
        if let momentumPhase {
            event.setIntegerValueField(
                .scrollWheelEventMomentumPhase,
                value: Int64(cgMomentumScrollPhase(momentumPhase).rawValue)
            )
        }
        return event
    }

    public static func cgScrollPhase(_ phase: CanvasScrollPhase) -> CGScrollPhase {
        switch phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        case .mayBegin: .mayBegin
        }
    }

    public static func cgMomentumScrollPhase(_ phase: CanvasScrollMomentumPhase) -> CGMomentumScrollPhase {
        switch phase {
        case .begin:
            return .begin
        case .continue:
            // `kCGMomentumScrollPhaseContinue`: the Swift name the Clang
            // importer gives this case is not a usable identifier here
            // (`continue` is a statement keyword, and none of the usual
            // escapes for a keyword-named case resolve), so it is built from
            // its documented raw value instead.
            return CGMomentumScrollPhase(rawValue: 2) ?? .begin
        case .end:
            return .end
        }
    }

    public static func flags(_ modifiers: CanvasModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        return flags
    }

    /// The extra `CGEventFlags` bits a real keyboard sets on these keys that
    /// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` never adds on its
    /// own, confirmed against a live keyboard: without them, Control-Up
    /// reached nothing at the window server at all; with them, it did, and
    /// F11 alone with `.maskSecondaryFn` moved every on-screen window off
    /// canvas (Show Desktop) and back. Every key on the navigation cluster
    /// (arrows, Home, End, Page Up/Down, forward delete) carries
    /// `.maskSecondaryFn` and `.maskNumericPad` on real hardware, fn held or
    /// not; every F-row key carries `.maskSecondaryFn` alone; every keypad key
    /// carries `.maskNumericPad` alone. Every other key carries none of them.
    public static func nativeAuxiliaryFlags(forKeyCode keyCode: UInt16) -> CGEventFlags {
        if navigationClusterKeyCodes.contains(keyCode) || SystemHotkeyChord.arrowKeyCodes.contains(keyCode) {
            return [.maskSecondaryFn, .maskNumericPad]
        }
        if keypadKeyCodes.contains(keyCode) {
            return [.maskNumericPad]
        }
        if SystemHotkeyChord.functionKeyCodes.contains(keyCode) {
            return [.maskSecondaryFn]
        }
        return []
    }

    /// Command, Shift, Caps Lock, Option, Control (both sides) and fn: keys a
    /// keyboard reports through flag changes, which never auto-repeat.
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// The keypad keys, `kVK_ANSI_KeypadDecimal` through `kVK_ANSI_Keypad9`:
    /// real hardware sets `.maskNumericPad` on these, fn or not.
    private static let keypadKeyCodes: Set<UInt16> = [
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92
    ]

    /// Home, End, Page Up, Page Down, forward delete: the rest of the
    /// navigation cluster the arrow keys belong to.
    private static let navigationClusterKeyCodes: Set<UInt16> = [115, 119, 116, 121, 117]
}
