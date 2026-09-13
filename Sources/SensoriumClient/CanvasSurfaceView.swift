#if canImport(AppKit)
import AppKit
import CoreGraphics
import SensoriumCore

/// AppKit adapter with no policy of its own: it converts view geometry and
/// pointer events into `CanvasSurfaceEvent` values and hands them to the
/// router, which owns every decision. Nothing here is exercised by the
/// verification runners because instantiating an `NSView` requires a window
/// server connection.
@MainActor
public final class CanvasSurfaceView: NSView {
    private let router: CanvasSurfaceEventRouter
    private let shortcutRouter: SystemShortcutRouter
    private let accessibilityGranted: Bool
    private let surfaceID: UInt32
    private var trackingArea: NSTrackingArea?
    /// Whether this view has hidden the cursor and switched to sending raw
    /// relative motion. Toggled explicitly by `togglePointerCapture()`, and
    /// always cleared by the escape gesture in `claim(_:isDown:)` -- the
    /// user must never be left with a hidden, captured cursor and no way out.
    private var isCapturingPointer = false
    /// Read by the View menu, so its title can say which mode this window is
    /// actually in instead of only offering a "Toggle" nobody could see the
    /// state of.
    public var isPointerCaptured: Bool { isCapturingPointer }
    /// Owns whether the local hardware cursor is hidden right now -- see
    /// `CanvasCursorVisibilityPolicy`.
    private var cursorPolicy = CanvasCursorVisibilityPolicy()
    /// Which presses and releases belong to the far machine, once the viewer
    /// has chrome of its own over the picture -- see
    /// `CanvasChromeClickPolicy`.
    private var chromeClicks = CanvasChromeClickPolicy()

    /// Owns whether the physical mouse is associated with the cursor
    /// position -- see `CanvasPointerAssociationPolicy`. Driven only by
    /// capture, unlike `cursorPolicy`: the pointer sitting over a key window
    /// in ordinary absolute mode never needs the physical mouse disconnected.
    private var associationPolicy = CanvasPointerAssociationPolicy()

    /// Set by the window controller once it exists, since the view is built
    /// during that controller's own initialisation.
    public var onReleaseToLocalMac: (() -> Void)?

    /// Asked, in this view's own coordinates, before any pointer motion is
    /// forwarded: true while a control of the viewer's own -- the shortcut
    /// strip -- is under the pointer. This view's tracking area covers its
    /// whole bounds, including whatever is drawn over it, so without this the
    /// far machine's pointer would follow a hand that is aiming at a button up
    /// here. Unset means nothing is ever over the canvas.
    public var isPointerOverViewerChrome: ((NSPoint) -> Bool)?

    /// The pointer left the canvas altogether. Reported because leaving by the
    /// top edge produces no further motion inside the view, and chrome that
    /// reveals itself on approach would otherwise have no way to know the hand
    /// is gone.
    public var onPointerExited: (() -> Void)?

    /// How much of the top edge is reserved by the viewer's own chrome --
    /// the pinned shortcut strip -- and given back to it rather than to the
    /// video. Zero unless that strip is pinned open; the window controller
    /// sets this live as the pin state changes, with no session restart.
    /// See `ShortcutStripLayoutPolicy`.
    public var videoTopInset: CGFloat = 0 {
        didSet {
            guard videoTopInset != oldValue else { return }
            forwardVideoGeometry()
        }
    }

    /// This view's own bounds, minus whatever band `videoTopInset` reserves
    /// at the top. Anchored at this view's own origin: the video and the
    /// session HUD are inset from the top only, never moved sideways or up
    /// from the bottom, so a point already measured against this view's
    /// bounds needs no further translation to land in this rect too.
    public var videoBounds: NSRect {
        NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: ShortcutStripLayoutPolicy.videoHeight(fullHeight: bounds.height, topInset: videoTopInset)
        )
    }

    /// `accessibilityGranted` is a snapshot, and only ever a report: the
    /// chords whose routing depends on it are the ones the WindowServer
    /// consumes, which by definition never reach this view.
    public init(
        router: CanvasSurfaceEventRouter,
        shortcutRouter: SystemShortcutRouter,
        accessibilityGranted: Bool,
        surfaceID: UInt32
    ) {
        self.router = router
        self.shortcutRouter = shortcutRouter
        self.accessibilityGranted = accessibilityGranted
        self.surfaceID = surfaceID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasSurfaceView is created programmatically")
    }

    public override var acceptsFirstResponder: Bool { true }

    /// A click is delivered by position; a key only ever reaches the window's
    /// first responder, and AppKit does not move first-responder status into a
    /// plain view when one is clicked. Without this, a window whose keyboard
    /// focus sits anywhere else keeps delivering clicks to this canvas while
    /// swallowing every key -- and clicking the canvas is exactly when the
    /// person means the keys to go there too.
    private func takeKeyboardFocus() {
        guard window?.firstResponder !== self else { return }
        window?.makeFirstResponder(self)
    }

    public override func layout() {
        super.layout()
        forwardVideoGeometry()
    }

    /// The autoresizing path AppKit always takes when the window is resized,
    /// which `layout()` alone does not guarantee for a view with no
    /// constraints of its own.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        forwardVideoGeometry()
    }

    /// What `layout()`, `setFrameSize(_:)` and `videoTopInset` all resolve
    /// to: the video area's own size in points, and its own drawable in
    /// backing pixels -- never this view's full bounds, which the pinned
    /// strip's band may have eaten into.
    private func forwardVideoGeometry() {
        let size = videoBounds.size
        forward(.boundsChanged(width: Double(size.width), height: Double(size.height)))
        forwardDrawableSize()
    }

    /// Dragging the viewer between a Retina and a non-Retina display changes
    /// the drawable's pixel size without changing its size in points.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        forwardDrawableSize()
    }

    /// Backing pixels, not points: on a 2x display a 960x600-point view is a
    /// 1920x1200 drawable, and it is the pixels that decide what resolution is
    /// worth streaming. Reported from every hook that can change them; the
    /// viewport forwards only what actually changes the quantized scale, so a
    /// repeat costs nothing.
    private func forwardDrawableSize() {
        let backing = convertToBacking(videoBounds).size
        forward(.drawableSizeChanged(
            pixelWidth: Double(backing.width),
            pixelHeight: Double(backing.height)
        ))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        forwardMotion(event)
    }

    public override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    public override func mouseDragged(with event: NSEvent) {
        forwardMotion(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        forwardMotion(event)
    }

    public override func mouseDown(with event: NSEvent) {
        press(.left, event)
    }

    public override func mouseUp(with event: NSEvent) {
        release(.left, event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        press(.right, event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        release(.right, event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        press(.middle, event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        release(.middle, event)
    }

    /// A press aimed at the viewer's own chrome is not one the far machine
    /// asked for, the same way motion and scrolling over it are not. It does
    /// not take the keyboard back either: whatever was typing keeps the
    /// keyboard, since nothing about this press was aimed at the picture.
    private func press(_ button: CanvasPointerButton, _ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard chromeClicks.shouldForwardPress(button, isOverChrome: isOverViewerChrome(location)) else { return }
        takeKeyboardFocus()
        forwardButton(button, isDown: true, event)
    }

    /// Released on the strength of where the press was, not where the pointer
    /// is now -- see `CanvasChromeClickPolicy`.
    private func release(_ button: CanvasPointerButton, _ event: NSEvent) {
        guard chromeClicks.shouldForwardRelease(button) else { return }
        forwardButton(button, isDown: false, event)
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        // A scroll aimed at the viewer's own chrome is not one the far machine
        // asked for, the same way motion over it is not.
        if isOverViewerChrome(location) {
            return
        }
        forward(.scrolled(
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            x: Double(location.x),
            y: Double(location.y),
            phase: CanvasScrollPhase(event.phase),
            momentumPhase: CanvasScrollMomentumPhase(event.momentumPhase)
        ))
    }

    public override func keyDown(with event: NSEvent) {
        guard claim(event, isDown: true) else {
            super.keyDown(with: event)
            return
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard claim(event, isDown: false) else {
            super.keyUp(with: event)
            return
        }
    }

    /// The menu bar is offered a key equivalent before the key window's
    /// `keyDown:` runs, so Cmd-Q and Cmd-H -- menu items and forwardable
    /// catalog entries at once -- acted on this machine even when the mode said
    /// they belonged to the remote workstation. When the same routing policy
    /// that governs forwarding says this chord goes to the host, the canvas
    /// takes it here and the menu never sees it.
    ///
    /// Everything else is handed straight back, including the escape gesture:
    /// `claim(_:isDown:)` below is what releases a captured pointer, and it
    /// must stay the one place that gesture is honoured.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let chord = KeyChord(
            keyCode: event.keyCode,
            modifiers: CanvasModifierFlags(appKitFlags: event.modifierFlags)
        )
        guard shortcutRouter.claimsKeyEquivalent(
            chord: chord,
            viewer: viewerWindowState(),
            accessibilityGranted: accessibilityGranted
        ) else {
            return super.performKeyEquivalent(with: event)
        }
        // Key-down only; AppKit never dispatches a key-up as a key
        // equivalent, and the matching up still arrives at `keyUp(with:)`.
        forwardKey(event, isDown: true)
        return true
    }

    /// Returns whether the key was taken for the remote canvas. When it was
    /// not, the caller passes it on so the local machine's own handling — menus,
    /// the responder chain — still gets it.
    private func claim(_ event: NSEvent, isDown: Bool) -> Bool {
        let chord = KeyChord(
            keyCode: event.keyCode,
            modifiers: CanvasModifierFlags(appKitFlags: event.modifierFlags)
        )
        switch shortcutRouter.decide(
            chord: chord,
            viewer: viewerWindowState(),
            accessibilityGranted: accessibilityGranted
        ) {
        case .forwardToHost:
            forwardKey(event, isDown: isDown)
            return true
        case .releaseToLocalMachine:
            // Only on the way down; the matching key-up must not fire it twice.
            if isDown {
                // The unmistakable way out of a hidden, captured cursor: this
                // gesture already means "give the user back their local machine"
                // for keyboard focus, so it must mean the same for the
                // pointer too, regardless of whether a capture toggle exists.
                if isCapturingPointer {
                    togglePointerCapture()
                }
                onReleaseToLocalMac?()
            }
            return true
        case .deliverToLocalMachine, .notForwardedAccessibilityRequired:
            return false
        }
    }

    private func viewerWindowState() -> ViewerWindowState {
        ViewerWindowState(
            surfaceID: surfaceID,
            hasKeyFocus: window?.isKeyWindow ?? false,
            isFullscreen: window?.styleMask.contains(.fullScreen) ?? false
        )
    }

    public override func flagsChanged(with event: NSEvent) {
        forward(.modifiersChanged(
            keyCode: event.keyCode,
            modifiers: CanvasModifierFlags(appKitFlags: event.modifierFlags)
        ))
    }

    /// Hides the cursor and starts sending raw relative motion instead of
    /// absolute canvas position, or gives both back. Explicit by
    /// construction: nothing else in this view enters or leaves the mode on
    /// its own, and `claim(_:isDown:)`'s escape-gesture branch above is the
    /// one guaranteed way out regardless of who called this.
    public func togglePointerCapture() {
        isCapturingPointer.toggle()
        applyCursorTransition(cursorPolicy.capturingPointerChanged(isCapturingPointer))
        // Warp before disassociating, while the physical mouse and the
        // cursor are still connected, so the warp itself is not fought by
        // the OS -- see `CanvasPointerAssociationPolicy` for what an
        // unbalanced disassociate costs.
        if isCapturingPointer {
            warpCursorToViewCenter()
        }
        applyAssociationTransition(associationPolicy.capturingPointerChanged(isCapturingPointer))
        forward(.pointerCaptureChanged(isCaptured: isCapturingPointer))
    }

    /// The other way out, alongside the escape gesture: the window
    /// controller calls this whenever the viewer loses key focus or the app
    /// deactivates, so alt-tabbing away can never leave the local machine with a
    /// cursor hidden over a window the user is no longer looking at.
    /// Idempotent, so it costs nothing when capture was already off.
    public func endPointerCaptureIfNeeded() {
        guard isCapturingPointer else { return }
        togglePointerCapture()
    }

    /// Reports whether the session status overlay (Connecting, Reconnecting,
    /// Lost, Ended, refusals) is covering the canvas, so its buttons are
    /// never hidden under a captured local cursor.
    public func sessionOverlayVisibilityChanged(_ visible: Bool) {
        applyCursorTransition(cursorPolicy.overlayVisibilityChanged(visible))
    }

    /// The last-resort exit, for when the window itself is going away and no
    /// further `mouseExited` or resign-key notification is coming to restore
    /// the cursor naturally: closing the window and tearing down the session.
    /// Idempotent, like `endPointerCaptureIfNeeded`.
    public func forceRestoreCursor() {
        endPointerCaptureIfNeeded()
        applyCursorTransition(cursorPolicy.reset())
        applyAssociationTransition(associationPolicy.reset())
    }

    private func applyCursorTransition(_ transition: CanvasCursorVisibilityPolicy.Transition) {
        switch transition {
        case .hide: NSCursor.hide()
        case .unhide: NSCursor.unhide()
        case .none: break
        }
    }

    /// `CGAssociateMouseAndMouseCursorPosition(0)` disconnects the physical
    /// mouse from the cursor machine-wide, not just from this session: while
    /// disassociated, moving the mouse anywhere on this machine -- over another
    /// app, over another display -- moves nothing on screen. It is what makes
    /// relative-motion capture possible (the real cursor can no longer run
    /// into a screen edge and stop generating deltas), and it is exactly why
    /// every path that can end capture must call this, once, before this view
    /// is done with the mode: an unbalanced disassociate leaves the user's
    /// physical mouse dead, with nothing on screen to click and fix it.
    private func applyAssociationTransition(_ transition: CanvasPointerAssociationPolicy.Transition) {
        switch transition {
        case .disassociate: CGAssociateMouseAndMouseCursorPosition(0)
        case .associate: CGAssociateMouseAndMouseCursorPosition(1)
        case .none: break
        }
    }

    /// Where re-association leaves the pointer: the OS keeps reporting the
    /// last position the cursor had while it was still connected, which
    /// without this would be wherever it happened to sit when capture began
    /// -- plausibly a screen edge. Warping here, before disassociating,
    /// means every capture session starts and ends at the same predictable
    /// point instead.
    private func warpCursorToViewCenter() {
        guard let window, let screenHeight = NSScreen.screens.first?.frame.height else {
            return
        }
        let viewCenterInWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let screenPoint = window.convertPoint(toScreen: viewCenterInWindow)
        // `CGWarpMouseCursorPosition` takes the CoreGraphics global display
        // space, origin top-left of the primary screen; AppKit's screen
        // coordinates have origin bottom-left, so the y-axis is flipped
        // against the primary screen's own height.
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y))
    }

    /// True for a point the viewer's own chrome is showing something over --
    /// either what `isPointerOverViewerChrome` reports (the strip and its
    /// handle) or a point above the video area's own top edge, which the
    /// strip's reserved band has emptied of picture even where the strip
    /// itself, drawn only within `ShortcutStripView.topClearance` of the very
    /// top, does not claim the click.
    private func isOverViewerChrome(_ point: NSPoint) -> Bool {
        if isPointerOverViewerChrome?(point) == true { return true }
        return point.y > videoBounds.height
    }

    private func forwardMotion(_ event: NSEvent) {
        if isOverViewerChrome(convert(event.locationInWindow, from: nil)) {
            return
        }
        if isCapturingPointer {
            forwardRelative(event)
        } else {
            forwardPointer(event)
        }
    }

    /// `NSEvent.deltaX/deltaY` are raw, unaccelerated device movement -- not
    /// derived from cursor position -- so they keep reporting real motion
    /// even once a hidden cursor has run into the edge of the local screen.
    /// Positive-down is already the convention both AppKit's delta and
    /// CoreGraphics's `kCGMouseEventDeltaY` share, unlike absolute position,
    /// so nothing here needs flipping the way `forwardPointer` flips y.
    private func forwardRelative(_ event: NSEvent) {
        forward(.pointerMovedRelative(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY)))
    }

    private func forwardPointer(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        forward(.pointerMoved(x: Double(location.x), y: Double(location.y)))
    }

    private func forwardButton(_ button: CanvasPointerButton, isDown: Bool, _ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        forward(.pointerButton(
            button: button,
            isDown: isDown,
            x: Double(location.x),
            y: Double(location.y)
        ))
    }

    private func forwardKey(_ event: NSEvent, isDown: Bool) {
        forward(.key(
            keyCode: event.keyCode,
            isDown: isDown,
            modifiers: CanvasModifierFlags(appKitFlags: event.modifierFlags)
        ))
    }

    private func forward(_ event: CanvasSurfaceEvent) {
        let router = router
        Task { await router.route(event) }
    }
}
#endif
