import SensoriumCore

/// A pointer event as an AppKit view reports it: coordinates are in view points
/// with the origin at the bottom-left corner.
public enum CanvasSurfaceEvent: Equatable, Sendable {
    case boundsChanged(width: Double, height: Double)
    /// The view's drawable in real backing pixels, which is what decides the
    /// resolution worth streaming. Separate from `boundsChanged` because that
    /// carries points, and a point is two pixels on the viewer's display.
    case drawableSizeChanged(pixelWidth: Double, pixelHeight: Double)
    case pointerMoved(x: Double, y: Double)
    /// Raw, unaccelerated motion from a captured pointer -- see
    /// `pointerCaptureChanged`. Not a canvas coordinate, so there is nothing
    /// here for `CanvasSurfaceEventRouter` to flip or bound against a
    /// viewport.
    case pointerMovedRelative(deltaX: Double, deltaY: Double)
    case pointerButton(button: CanvasPointerButton, isDown: Bool, x: Double, y: Double)
    case scrolled(
        deltaX: Double,
        deltaY: Double,
        x: Double,
        y: Double,
        phase: CanvasScrollPhase?,
        momentumPhase: CanvasScrollMomentumPhase?
    )
    case key(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags)
    /// The view has hidden its cursor and switched to relative motion, or
    /// just given it back. Carries no coordinate of its own.
    case pointerCaptureChanged(isCaptured: Bool)
    /// Reported for `NSEvent.flagsChanged`: a modifier key changed by itself,
    /// with no accompanying `keyDown`/`keyUp`. `modifiers` is the full flag
    /// state after the change; whether `keyCode` went down or up is derived
    /// by comparing it against the router's last known state.
    case modifiersChanged(keyCode: UInt16, modifiers: CanvasModifierFlags)
    /// The viewer window lost key status or the app deactivated.
    case focusLost
}

/// Translates AppKit surface events into owned-canvas pointer motion. Holds no
/// AppKit object, so the translation is verifiable without a window.
public actor CanvasSurfaceEventRouter {
    private let viewport: ClientViewportController
    private var surfaceHeight: Double = 0
    /// Which physical modifier keyCodes are currently believed held.
    /// `CanvasModifierFlags` has no left/right distinction, so releasing
    /// Right Shift while Left Shift is held leaves the aggregate mask
    /// unchanged and a mask-diff drops that release. Tracking presence per
    /// keyCode makes each physical key independent. macOS delivers exactly
    /// one `flagsChanged` per transition.
    private var heldModifierKeyCodes: Set<UInt16> = []
    /// The last drawable size actually forwarded. `CanvasSurfaceView` reports
    /// the drawable from every hook that can change it, and one of them is
    /// `layout()`, which AppKit runs whenever anything in the viewer window is
    /// laid out again -- a telemetry tick into the session HUD is enough, so
    /// an unchanged repeat arrives on a timer for the life of the session.
    /// Forwarding one would re-derive the scale the window's geometry
    /// justifies and overwrite whatever scale is actually in force.
    private var lastDrawablePixelSize: (width: Double, height: Double)?

    public init(viewport: ClientViewportController) {
        self.viewport = viewport
    }

    @discardableResult
    public func route(_ event: CanvasSurfaceEvent) async -> PointerDelivery {
        switch event {
        case let .boundsChanged(width, height):
            surfaceHeight = height
            await viewport.setViewportSize(width: width, height: height)
            return .droppedNoViewport
        case let .drawableSizeChanged(pixelWidth, pixelHeight):
            guard lastDrawablePixelSize?.width != pixelWidth
                    || lastDrawablePixelSize?.height != pixelHeight else {
                return .droppedNoChange
            }
            lastDrawablePixelSize = (pixelWidth, pixelHeight)
            await viewport.setDrawableSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return .droppedNoViewport
        case let .pointerMoved(x, y):
            guard surfaceHeight > 0 else {
                return .droppedNoViewport
            }
            guard x.isFinite, y.isFinite else {
                return .droppedInvalidLocation
            }
            return await viewport.movePointer(x: x, y: surfaceHeight - y)
        case let .pointerMovedRelative(deltaX, deltaY):
            return await viewport.sendRelativeMotion(deltaX: deltaX, deltaY: deltaY)
        case let .pointerButton(button, isDown, x, y):
            guard let flipped = flip(x: x, y: y) else {
                return surfaceHeight > 0 ? .droppedInvalidLocation : .droppedNoViewport
            }
            return await viewport.sendButton(
                button: button,
                isDown: isDown,
                x: flipped.x,
                y: flipped.y
            )
        case let .scrolled(deltaX, deltaY, x, y, phase, momentumPhase):
            guard let flipped = flip(x: x, y: y) else {
                return surfaceHeight > 0 ? .droppedInvalidLocation : .droppedNoViewport
            }
            return await viewport.sendScroll(
                deltaX: deltaX,
                deltaY: deltaY,
                x: flipped.x,
                y: flipped.y,
                phase: phase,
                momentumPhase: momentumPhase
            )
        case let .pointerCaptureChanged(isCaptured):
            return await viewport.sendPointerCaptureChanged(isCaptured: isCaptured)
        case let .key(keyCode, isDown, modifiers):
            return await viewport.sendKey(keyCode: keyCode, isDown: isDown, modifiers: modifiers)
        case let .modifiersChanged(keyCode, modifiers):
            let isDown = !heldModifierKeyCodes.contains(keyCode)
            if isDown {
                heldModifierKeyCodes.insert(keyCode)
            } else {
                heldModifierKeyCodes.remove(keyCode)
            }
            return await viewport.sendKey(keyCode: keyCode, isDown: isDown, modifiers: modifiers)
        case .focusLost:
            return await viewport.releaseAllInput()
        }
    }

    private func flip(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard surfaceHeight > 0, x.isFinite, y.isFinite else {
            return nil
        }
        return (x, surfaceHeight - y)
    }
}
