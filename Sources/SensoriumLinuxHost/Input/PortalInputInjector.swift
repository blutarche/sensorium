#if os(Linux)

import Foundation
import SensoriumCore

public enum PortalInputInjectorError: Error, Equatable, Sendable {
    /// The viewer sent a macOS virtual keycode the host has no key for.
    case unmappedKey(UInt16)
    /// A coordinate or delta that is not a finite number.
    case invalidValue
}

/// Closures the host calls around every input post it makes, so its idle-time
/// bookkeeping can tell its own input from a person's: `sampleBeforePost`
/// immediately before each post, `recordPost` immediately after.
public struct PortalInputPostObserver: Sendable {
    public var sampleBeforePost: @Sendable () -> Void
    public var recordPost: @Sendable () -> Void

    public init(
        sampleBeforePost: @escaping @Sendable () -> Void = {},
        recordPost: @escaping @Sendable () -> Void = {}
    ) {
        self.sampleBeforePost = sampleBeforePost
        self.recordPost = recordPost
    }
}

/// Turns the wire's input events into portal `Notify*` calls on one granted
/// monitor.
///
/// It tracks what it has pressed so `releaseAll` can undo exactly that. The
/// shapes match `InputInjecting` in `SensoriumHost` (`inject(_:)` throws and
/// takes a `SensoriumInputEvent`) so an adapter between them is trivial.
public final class PortalInputInjector: @unchecked Sendable {
    private struct ModifierClass {
        let flag: CanvasModifierFlags
        /// The key pressed when this class has to be added around another key.
        let left: Int32
        /// Every evdev key that counts as this class being held.
        let keys: Set<Int32>
    }

    /// In the order modifiers are pressed around a key. They are released in
    /// the reverse order.
    private static let modifierClasses: [ModifierClass] = [
        ModifierClass(flag: .shift, left: 42, keys: [42, 54]),
        ModifierClass(flag: .control, left: 29, keys: [29, 97]),
        ModifierClass(flag: .option, left: 56, keys: [56, 100]),
        ModifierClass(flag: .command, left: 125, keys: [125, 126])
    ]

    /// macOS virtual keycodes of the modifier keys the viewer sends as keys:
    /// right and left Command, Shift, Option and Control.
    private static let modifierVirtualKeys: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    private static let capsLockVirtualKey: UInt16 = 57

    /// The 26 ANSI letter keys, the ones Caps Lock capitalizes.
    private static let letterVirtualKeys: Set<UInt16> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        31, 32, 34, 35, 37, 38, 40, 45, 46
    ]

    private static let shiftClass = modifierClasses[0]

    /// A wheel line is this many points when a smooth scroll carries the part
    /// of a line the discrete steps cannot.
    private static let pointsPerLine = 10.0

    private let sink: any PortalInputSink
    private let geometry: PortalCaptureGeometry
    private let observer: PortalInputPostObserver
    private let lock = NSLock()

    /// Evdev keys the viewer pressed and the host still holds down.
    private var heldKeys: Set<Int32> = []
    /// Modifier keys this injector pressed on its own around other keys, each
    /// with the viewer keys it is held for.
    private var wrapperOwners: [Int32: Set<UInt16>] = [:]
    private var heldButtons: Set<Int32> = []
    /// The viewer's Caps Lock state as of the last key that said.
    private var capsLockOn = false
    private var pointerCaptured = false
    private var lastPosition: (x: Double, y: Double)?

    public init(
        sink: any PortalInputSink,
        geometry: PortalCaptureGeometry,
        observer: PortalInputPostObserver = PortalInputPostObserver()
    ) {
        self.sink = sink
        self.geometry = geometry
        self.observer = observer
    }

    /// Whether no key or button is still down.
    public var isIdle: Bool {
        lock.withLock { heldKeys.isEmpty && wrapperOwners.isEmpty && heldButtons.isEmpty }
    }

    public func inject(_ event: SensoriumInputEvent) throws {
        try lock.withLock {
            switch event {
            case let .pointerMoved(x, y):
                try movePointer(x: x, y: y)
            case let .pointerMovedRelative(deltaX, deltaY):
                guard pointerCaptured else { return }
                guard deltaX.isFinite, deltaY.isFinite else { throw PortalInputInjectorError.invalidValue }
                try post { try sink.notifyPointerMotion(dx: deltaX, dy: deltaY) }
                lastPosition = nil
            case let .pointerButton(button, isDown, x, y):
                try movePointer(x: x, y: y)
                try changeButton(Self.evdevButton(for: button), isDown: isDown)
            case let .scrolled(deltaX, deltaY, x, y, phase, _, lineDeltaX, lineDeltaY):
                try scroll(
                    deltaX: deltaX, deltaY: deltaY, x: x, y: y,
                    phase: phase, lineDeltaX: lineDeltaX, lineDeltaY: lineDeltaY
                )
            case let .key(keyCode, isDown, modifiers, capsLock):
                try changeKey(keyCode, isDown: isDown, flags: modifiers, capsLock: capsLock)
            case .releaseAllInput:
                try releaseHeldInput()
            case let .pointerCaptureChanged(isCaptured):
                pointerCaptured = isCaptured
            }
        }
    }

    /// Releases every button and key the host still holds, wrapper modifiers
    /// included. One that fails stays held, the rest are still released, and
    /// the first failure is thrown. Safe to call again.
    public func releaseAll() throws {
        try lock.withLock { try releaseHeldInput() }
    }

    // MARK: Posting

    /// The one place a post is made, so every post is sampled and recorded.
    private func post(_ send: () throws -> Void) throws {
        observer.sampleBeforePost()
        try send()
        observer.recordPost()
    }

    private func postKey(_ evdev: Int32, pressed: Bool) throws {
        try post { try sink.notifyKeyboardKeycode(evdevKeycode: evdev, pressed: pressed) }
    }

    // MARK: Pointer

    private static func evdevButton(for button: CanvasPointerButton) -> Int32 {
        switch button {
        case .left: 0x110
        case .right: 0x111
        case .middle: 0x112
        case .back: 0x113
        case .forward: 0x114
        }
    }

    private func movePointer(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw PortalInputInjectorError.invalidValue }
        let target = geometry.clamped(x: x, y: y)
        if let last = lastPosition, last.x == target.x, last.y == target.y {
            return
        }
        try post { try sink.notifyPointerMotionAbsolute(stream: geometry.streamNodeID, x: target.x, y: target.y) }
        lastPosition = target
    }

    private func changeButton(_ button: Int32, isDown: Bool) throws {
        if isDown {
            guard !heldButtons.contains(button) else { return }
            try post { try sink.notifyPointerButton(evdevButton: button, pressed: true) }
            heldButtons.insert(button)
        } else {
            guard heldButtons.contains(button) else { return }
            try post { try sink.notifyPointerButton(evdevButton: button, pressed: false) }
            heldButtons.remove(button)
        }
    }

    /// The wire's scroll deltas point the other way from the portal's: the
    /// wire's positive delta moves content down, the portal's positive axis
    /// value scrolls down. Each is negated.
    ///
    /// A wheel's lines go as whole discrete steps, toward zero. The fraction a
    /// high-resolution wheel adds goes as smooth motion at ten points a line,
    /// since a discrete step cannot carry it.
    private func scroll(
        deltaX: Double, deltaY: Double, x: Double, y: Double,
        phase: CanvasScrollPhase?, lineDeltaX: Double?, lineDeltaY: Double?
    ) throws {
        guard deltaX.isFinite, deltaY.isFinite else { throw PortalInputInjectorError.invalidValue }
        try movePointer(x: x, y: y)
        // A scroll with no gesture phase is one wheel event, over at once.
        let finish = phase == nil || phase == .ended || phase == .cancelled

        guard let lineDeltaX, let lineDeltaY else {
            try post { try sink.notifyPointerAxis(dx: -deltaX, dy: -deltaY, finish: finish) }
            return
        }
        guard lineDeltaX.isFinite, lineDeltaY.isFinite else { throw PortalInputInjectorError.invalidValue }
        let wholeX = lineDeltaX.rounded(.towardZero)
        let wholeY = lineDeltaY.rounded(.towardZero)
        if wholeY != 0 {
            try post { try sink.notifyPointerAxisDiscrete(axis: .vertical, steps: Int32(clamping: Int(-wholeY))) }
        }
        if wholeX != 0 {
            try post { try sink.notifyPointerAxisDiscrete(axis: .horizontal, steps: Int32(clamping: Int(-wholeX))) }
        }
        let remainderX = -(lineDeltaX - wholeX) * Self.pointsPerLine
        let remainderY = -(lineDeltaY - wholeY) * Self.pointsPerLine
        if remainderX != 0 || remainderY != 0 {
            try post { try sink.notifyPointerAxis(dx: remainderX, dy: remainderY, finish: finish) }
        }
    }

    // MARK: Keys

    private func isHeldByViewer(_ modifier: ModifierClass) -> Bool {
        !heldKeys.isDisjoint(with: modifier.keys)
    }

    private func changeKey(_ keyCode: UInt16, isDown: Bool, flags: CanvasModifierFlags, capsLock: Bool?) throws {
        if let capsLock {
            capsLockOn = capsLock
        }
        // The host's own Caps Lock is never toggled; the viewer's state is
        // applied as Shift around letters instead.
        if keyCode == Self.capsLockVirtualKey {
            return
        }
        guard let evdev = MacOSKeyToEvdev.evdevCode(forMacOSKeyCode: keyCode).map(Int32.init) else {
            throw PortalInputInjectorError.unmappedKey(keyCode)
        }

        if Self.modifierVirtualKeys.contains(keyCode) {
            try changeModifierKey(evdev, isDown: isDown)
            return
        }

        if isDown {
            try pressWrappers(for: keyCode, flags: flags)
            try postKey(evdev, pressed: true)
            heldKeys.insert(evdev)
        } else {
            guard heldKeys.contains(evdev) else { return }
            try postKey(evdev, pressed: false)
            heldKeys.remove(evdev)
            try releaseWrappers(ownedBy: keyCode)
        }
    }

    /// A modifier the viewer presses itself. If a wrapper already holds that
    /// very key down, the viewer's press and release take over and release it
    /// without a second post.
    private func changeModifierKey(_ evdev: Int32, isDown: Bool) throws {
        if isDown {
            if wrapperOwners[evdev] == nil {
                try postKey(evdev, pressed: true)
            }
            heldKeys.insert(evdev)
        } else {
            guard heldKeys.contains(evdev) else { return }
            if wrapperOwners[evdev] == nil {
                try postKey(evdev, pressed: false)
            }
            heldKeys.remove(evdev)
        }
    }

    /// Presses, for a key going down, each modifier its flags name that the
    /// viewer is not holding, and Shift for a letter while Caps Lock is on.
    private func pressWrappers(for keyCode: UInt16, flags: CanvasModifierFlags) throws {
        let capitalize = capsLockOn && Self.letterVirtualKeys.contains(keyCode)
        for modifier in Self.modifierClasses {
            let wanted = flags.contains(modifier.flag) || (capitalize && modifier.flag == Self.shiftClass.flag)
            guard wanted, !isHeldByViewer(modifier) else { continue }
            if wrapperOwners[modifier.left] == nil {
                try postKey(modifier.left, pressed: true)
                wrapperOwners[modifier.left] = [keyCode]
            } else {
                wrapperOwners[modifier.left]?.insert(keyCode)
            }
        }
    }

    private func releaseWrappers(ownedBy keyCode: UInt16) throws {
        for modifier in Self.modifierClasses.reversed() {
            guard var owners = wrapperOwners[modifier.left], owners.contains(keyCode) else { continue }
            owners.remove(keyCode)
            if owners.isEmpty {
                try postKey(modifier.left, pressed: false)
                wrapperOwners[modifier.left] = nil
            } else {
                wrapperOwners[modifier.left] = owners
            }
        }
    }

    // MARK: Release

    private func releaseHeldInput() throws {
        var firstFailure: Error?
        func attempt(_ work: () throws -> Void) {
            do {
                try work()
            } catch {
                firstFailure = firstFailure ?? error
            }
        }

        for button in heldButtons.sorted() {
            attempt {
                try post { try sink.notifyPointerButton(evdevButton: button, pressed: false) }
                heldButtons.remove(button)
            }
        }
        let modifierKeys = Self.modifierClasses.reduce(into: Set<Int32>()) { $0.formUnion($1.keys) }
        for key in heldKeys.subtracting(modifierKeys).sorted() {
            attempt {
                try postKey(key, pressed: false)
                heldKeys.remove(key)
            }
        }
        for modifier in Self.modifierClasses.reversed() where wrapperOwners[modifier.left] != nil {
            attempt {
                try postKey(modifier.left, pressed: false)
                wrapperOwners[modifier.left] = nil
            }
        }
        for key in heldKeys.intersection(modifierKeys).sorted() {
            attempt {
                try postKey(key, pressed: false)
                heldKeys.remove(key)
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }
}

#endif
