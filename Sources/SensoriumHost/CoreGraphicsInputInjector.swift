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
/// Every posted event targets `.cgSessionEventTap`, not `.cghidEventTap`:
/// `.cghidEventTap` also resets the `hidSystemState` idle counter
/// `CoreGraphicsLocalActivitySignal` reads, so a viewer's own remote input
/// posted there would make the host believe a person is sitting at the
/// keyboard for as long as `HostScreenPresenceRule` then requires before
/// it treats this machine as unattended again.
///
/// One exception: a key matching `SystemHotkeyChord.isSystemHotkey` -- the
/// window server and Dock's own hotkeys, such as Mission Control or
/// Spotlight -- is posted at `.cghidEventTap` instead, because those
/// consumers act ahead of `.cgSessionEventTap` and never see an event posted
/// there at all. Sending one from the viewer therefore counts as local input
/// at the host for the same five minutes an ordinary key would not.
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
    private let source: CGEventSource
    private let postEvent: (CGEvent, CGEventTapLocation) -> Void
    private var modifiers: CGEventFlags = []
    private var heldButton: CanvasPointerButton?
    /// Where every relative-motion event is posted while captured. The
    /// system cursor never actually needs to move for the injected motion to
    /// be seen: `CGAssociateMouseAndMouseCursorPosition(false)` stops a
    /// posted move from dragging the visible cursor along, so this anchor can
    /// stay fixed at the canvas centre for the whole capture and only the
    /// event's raw delta fields carry the motion.
    private var capturedAnchor: CGPoint?

    /// `postEvent` is the seam a test uses to record which tap location an
    /// event was given, instead of calling the real `CGEvent.post`, which
    /// would inject a real synthetic event system-wide.
    public init(
        canvasDisplayID: CGDirectDisplayID,
        postEvent: @escaping (CGEvent, CGEventTapLocation) -> Void = { event, tap in event.post(tap: tap) }
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw CoreGraphicsInputInjectorError.eventSourceUnavailable
        }
        self.canvasDisplayID = canvasDisplayID
        self.source = source
        self.postEvent = postEvent
    }

    public func inject(_ event: SensoriumInputEvent) throws {
        switch event {
        case let .pointerMoved(x, y):
            try post(
                mouse: CoreGraphicsInputTranslation.motionType(heldButton: heldButton),
                button: CoreGraphicsInputTranslation.mouseButton(heldButton ?? .left),
                at: try globalPoint(x: x, y: y)
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
                at: anchor,
                relativeDeltaX: deltaX,
                relativeDeltaY: deltaY
            )
        case let .pointerButton(button, isDown, x, y):
            heldButton = isDown ? button : nil
            let point = try globalPoint(x: x, y: y)
            try post(
                mouse: CoreGraphicsInputTranslation.buttonType(button, isDown: isDown),
                button: CoreGraphicsInputTranslation.mouseButton(button),
                at: point
            )
        case let .scrolled(deltaX, deltaY, _, _, phase, momentumPhase):
            // A CGEvent scroll carries no location: macOS routes it to
            // whatever is under the one system cursor, which both session
            // canvases share. Standing the cursor on this canvas first is
            // what stops a scroll in one canvas's window from scrolling the
            // other. Posted every time rather than only on a change of
            // position: each surface has its own injector, so this one cannot
            // know whether the sibling injector has moved the cursor since.
            if let positioning = CoreGraphicsInputTranslation.cursorPositioning(for: event) {
                try post(
                    mouse: CoreGraphicsInputTranslation.motionType(heldButton: heldButton),
                    button: CoreGraphicsInputTranslation.mouseButton(heldButton ?? .left),
                    at: try globalPoint(x: positioning.x, y: positioning.y)
                )
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
            postEvent(scroll, .cgSessionEventTap)
        case let .pointerCaptureChanged(isCaptured):
            if isCaptured {
                let bounds = CGDisplayBounds(canvasDisplayID)
                guard bounds.width > 0, bounds.height > 0 else {
                    throw CoreGraphicsInputInjectorError.canvasDisplayUnavailable
                }
                capturedAnchor = CGPoint(x: bounds.midX, y: bounds.midY)
                CGAssociateMouseAndMouseCursorPosition(0)
            } else {
                CGAssociateMouseAndMouseCursorPosition(1)
                if let capturedAnchor {
                    CGWarpMouseCursorPosition(capturedAnchor)
                }
                capturedAnchor = nil
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
            let tap: CGEventTapLocation = SystemHotkeyChord.isSystemHotkey(keyCode: keyCode, modifiers: eventModifiers)
                ? .cghidEventTap
                : .cgSessionEventTap
            postEvent(key, tap)
        case .releaseAllInput:
            // Not a real release: this injector only remembers the single most
            // recent button and modifier flags, not every held key or the
            // location a correct mouse-up needs. HostSessionController holds
            // the authoritative, location-complete held state and turns
            // .releaseAllInput into real .pointerButton/.key release calls
            // through the cases above before it ever reaches here.
            modifiers = []
            heldButton = nil
        }
    }

    /// Canvas logical points are relative to the canvas; CGEvent wants global
    /// coordinates, which for the session canvas means its own display origin.
    private func globalPoint(x: Double, y: Double) throws -> CGPoint {
        let bounds = CGDisplayBounds(canvasDisplayID)
        guard bounds.width > 0, bounds.height > 0 else {
            throw CoreGraphicsInputInjectorError.canvasDisplayUnavailable
        }
        return CGPoint(x: bounds.origin.x + x, y: bounds.origin.y + y)
    }

    /// `relativeDeltaX`/`relativeDeltaY` carry captured-mode motion on top of
    /// an otherwise ordinary move event: `point` never changes across a
    /// capture (see `capturedAnchor`), so it is the raw delta fields, not the
    /// event's own position, that any app reading unaccelerated device
    /// motion actually sees.
    private func post(
        mouse type: CGEventType,
        button: CGMouseButton,
        at point: CGPoint,
        relativeDeltaX: Double? = nil,
        relativeDeltaY: Double? = nil
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
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(relativeDeltaX.rounded()))
        }
        if let relativeDeltaY {
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(relativeDeltaY.rounded()))
        }
        event.flags = modifiers
        postEvent(event, .cgSessionEventTap)
    }
}

@MainActor
public final class CoreGraphicsInputInjectorFactory: InputInjectingFactory {
    public init() {}

    public func make(canvasDisplayID: UInt32) throws -> any InputInjecting {
        try CoreGraphicsInputInjector(canvasDisplayID: canvasDisplayID)
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
        case .middle: .otherMouseDragged
        }
    }

    public static func buttonType(_ button: CanvasPointerButton, isDown: Bool) -> CGEventType {
        switch button {
        case .left:
            isDown ? .leftMouseDown : .leftMouseUp
        case .right:
            isDown ? .rightMouseDown : .rightMouseUp
        case .middle:
            isDown ? .otherMouseDown : .otherMouseUp
        }
    }

    public static func mouseButton(_ button: CanvasPointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
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
    /// not; every F-row key carries `.maskSecondaryFn` alone. Every other key
    /// carries neither.
    public static func nativeAuxiliaryFlags(forKeyCode keyCode: UInt16) -> CGEventFlags {
        if navigationClusterKeyCodes.contains(keyCode) || SystemHotkeyChord.arrowKeyCodes.contains(keyCode) {
            return [.maskSecondaryFn, .maskNumericPad]
        }
        if SystemHotkeyChord.functionKeyCodes.contains(keyCode) {
            return [.maskSecondaryFn]
        }
        return []
    }

    /// Home, End, Page Up, Page Down, forward delete: the rest of the
    /// navigation cluster the arrow keys belong to.
    private static let navigationClusterKeyCodes: Set<UInt16> = [115, 119, 116, 121, 117]
}
