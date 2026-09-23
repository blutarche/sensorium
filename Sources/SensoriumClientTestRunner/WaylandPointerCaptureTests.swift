import Foundation
import SensoriumClient
import SensoriumCore

/// A compositor that records what the viewer asked of it instead of locking
/// anything, so the capture state machine is checkable with no Wayland
/// connection, no seat and no pointer.
@MainActor
private final class ScriptedPointerLock: WaylandPointerLocking {
    private(set) var lockCount = 0
    private(set) var unlockCount = 0

    func lockPointer() {
        lockCount += 1
    }

    func unlockPointer() {
        unlockCount += 1
    }
}

/// Captured-pointer mode on Wayland: the lock is requested once, the
/// compositor can end it at any time, and every exit -- the escape gesture,
/// the compositor, the window going away -- has to leave the bookkeeping
/// balanced.
@MainActor
func testWaylandPointerCaptureTests() {
    let compositor = ScriptedPointerLock()
    var routed: [CanvasSurfaceEvent] = []
    let capture = WaylandPointerCaptureController(locking: compositor) { routed.append($0) }

    capture.toggle()
    expect(capture.isCapturing, "toggling capture on enters captured-pointer mode")
    expect(compositor.lockCount == 1, "entering captured-pointer mode locks the pointer once")
    expect(
        routed == [.pointerCaptureChanged(isCaptured: true)],
        "entering captured-pointer mode tells the host the pointer is captured"
    )

    capture.compositorEndedLock()
    expect(!capture.isCapturing, "a compositor that ended the lock ends capture")
    expect(compositor.unlockCount == 1, "the lock the compositor ended is still torn down here once")
    expect(
        routed == [.pointerCaptureChanged(isCaptured: true), .pointerCaptureChanged(isCaptured: false)],
        "a compositor that ended the lock tells the host the pointer is free"
    )
    capture.compositorEndedLock()
    expect(routed.count == 2, "a second unlock from the compositor reports nothing further")
    expect(compositor.unlockCount == 1, "a second unlock from the compositor tears nothing down twice")

    routed.removeAll()
    capture.toggle()
    capture.endIfNeeded()
    expect(!capture.isCapturing, "the escape gesture's exit ends capture")
    expect(
        routed == [.pointerCaptureChanged(isCaptured: true), .pointerCaptureChanged(isCaptured: false)],
        "the escape gesture's exit tells the host the pointer is free"
    )
    capture.endIfNeeded()
    expect(routed.count == 2, "ending capture that is already off reports nothing")

    routed.removeAll()
    capture.toggle()
    expect(
        capture.lockConfirmationDeadlinePassed(),
        "a lock the compositor never confirmed is treated as refused"
    )
    expect(!capture.isCapturing, "a refused lock leaves captured-pointer mode")
    capture.toggle()
    capture.compositorConfirmedLock()
    expect(
        !capture.lockConfirmationDeadlinePassed(),
        "a lock the compositor confirmed is not treated as refused"
    )
    expect(capture.isCapturing, "a confirmed lock stays in captured-pointer mode")

    capture.reset()
    expect(!capture.isCapturing, "tearing the window down mid-capture leaves captured-pointer mode")
    expect(capture.isBalanced, "tearing the window down mid-capture leaves the pointer associated again")
    expect(
        compositor.lockCount == compositor.unlockCount,
        "every lock this window requested was torn down again"
    )

    print("PASS: Wayland captured-pointer mode locks once, ends on the compositor's word, and stays balanced through every exit")
}
