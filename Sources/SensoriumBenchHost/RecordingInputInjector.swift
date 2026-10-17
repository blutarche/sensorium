import Foundation
import SensoriumCore
import SensoriumHost

/// The latest pointer position the viewer sent, read by the frame source on
/// its own queue and written by the injector on the main actor.
final class BenchPointer: @unchecked Sendable {
    private let lock = NSLock()
    private var x = 0.0
    private var y = 0.0

    func move(toX newX: Double, y newY: Double) {
        lock.lock()
        defer { lock.unlock() }
        x = newX
        y = newY
    }

    func move(byX deltaX: Double, y deltaY: Double) {
        lock.lock()
        defer { lock.unlock() }
        x += deltaX
        y += deltaY
    }

    var position: (x: Double, y: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (x, y)
    }
}

/// Takes every input event the viewer sends and posts none of them. It
/// succeeds, so the host still echoes `inputApplied` and the viewer's input
/// round-trip measurement stays alive; the pointer position it records is
/// what moves the synthetic desktop.
@MainActor
final class RecordingInputInjector: InputInjecting {
    private let pointer: BenchPointer
    private(set) var eventCount = 0

    init(pointer: BenchPointer) {
        self.pointer = pointer
    }

    func inject(_ event: SensoriumInputEvent) throws {
        eventCount += 1
        switch event {
        case let .pointerMoved(x, y):
            pointer.move(toX: x, y: y)
        case let .pointerButton(_, _, x, y):
            pointer.move(toX: x, y: y)
        case let .scrolled(_, _, x, y, _, _, _, _):
            pointer.move(toX: x, y: y)
        case let .pointerMovedRelative(deltaX, deltaY):
            pointer.move(byX: deltaX, y: deltaY)
        case .key, .releaseAllInput, .pointerCaptureChanged:
            break
        }
    }
}

@MainActor
final class RecordingInputInjectorFactory: InputInjectingFactory {
    let injector: RecordingInputInjector

    init(injector: RecordingInputInjector) {
        self.injector = injector
    }

    func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        injector
    }
}

/// A session canvas that is a number and nothing else: no display is created.
@MainActor
final class BenchVirtualDisplayAdapter: VirtualDisplayAdapter {
    private let displayID: UInt32

    init(displayID: UInt32) {
        self.displayID = displayID
    }

    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        VirtualDisplayHandle(rawValue: displayID)
    }

    func release(_ handle: VirtualDisplayHandle) {}
}
