import SensoriumCore

/// Destination for decoded frames of the owned session canvas.
public protocol CanvasFramePresenting: Sendable {
    func present(_ frame: DecodedFrame) async
}

/// Destination for input already expressed in owned-canvas logical coordinates.
/// No physical-display coordinate crosses this boundary.
public protocol CanvasInputSending: Sendable {
    func sendInput(_ event: SensoriumInputEvent) async throws
    /// Reports the viewer's real backing-pixel drawable size, from which the
    /// host derives the resolution it streams, and the user's own cap on that
    /// resolution (`nil` for no cap).
    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws
    /// Reports a person's own choice of stream scale, or a return to
    /// `.automatic` -- see `StreamScalePreference`.
    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws
}

extension ClientSessionController: CanvasInputSending {}

/// What became of a viewer drawable-size report.
public enum ViewerScaleDelivery: Equatable, Sendable {
    /// The host was told, and will stream at this fraction of the canvas's
    /// native resolution once the size settles.
    case sent(Double)
    /// The size still derives the scale the host is already streaming, so
    /// nothing was sent and the encoder is not disturbed.
    case unchanged
    case invalid
    case droppedNotConnected
    case droppedFailed
}

/// What became of a `setStreamScalePreference` call. A sibling to
/// `ViewerScaleDelivery` rather than a reuse of it: that type's `.sent`
/// carries the geometry-derived scale a drawable-size report produced, which
/// a preference -- `.automatic` has no single scale of its own, and a
/// `.fixed` choice is exactly what was asked, never a derived answer -- has
/// no equivalent value for.
public enum StreamScalePreferenceDelivery: Equatable, Sendable {
    case sent
    /// The preference already matches what the host was last told, so
    /// nothing was sent.
    case unchanged
    case invalid
    case droppedNotConnected
    case droppedFailed
}

public enum PointerDelivery: Equatable, Sendable {
    case delivered(CanvasInputPoint)
    case deliveredWithoutLocation
    case coalesced
    case droppedNoViewport
    case droppedInvalidLocation
    case droppedNotConnected
    case droppedFailed
    /// The event repeats what the router already forwarded, so nothing needs
    /// forwarding again. Produced for a `drawableSizeChanged` that names the
    /// size already reported. Deliberately not produced for
    /// `modifiersChanged`: an aggregate-mask comparison drops a real key-up
    /// when two keys share one modifier bit, so every `flagsChanged`
    /// delivery is forwarded.
    case droppedNoChange
}

/// Owns the viewer presentation surface geometry and routes its pointer motion
/// through the canvas mapper into an authenticated session.
public actor ClientViewportController: CanvasLifecycleObserving {
    private var mapper: VirtualCanvasInputMapper
    private var pointerSink: any CanvasInputSending
    private let framePresenter: (any CanvasFramePresenting)?
    private var isCanvasReady = false
    private var viewportWidth: Double = 0
    private var viewportHeight: Double = 0
    private var isSending = false
    private var pendingPoint: CanvasInputPoint?
    // Before the first decoded frame arrives there is nothing to letterbox
    // against; the canvas's own aspect ratio is the only size known, so it
    // stands in until a real frame reports the source that is actually
    // presented. The host's stream resolution is configurable elsewhere and
    // this is never assumed to stay 1920x1200 once frames start arriving.
    private var sourceWidth: Double
    private var sourceHeight: Double
    /// The viewer's real backing-pixel size, kept so a reconnect can tell the
    /// fresh host session what this window actually needs without waiting for
    /// the user to resize it.
    private var drawablePixelWidth: Double?
    private var drawablePixelHeight: Double?
    /// The stream scale the host is believed to be using. A session starts at
    /// `StreamScalePolicy.defaultScale`, which is what a host that never heard
    /// of this message streams.
    private var hostStreamScale = StreamScalePolicy.defaultScale
    /// This canvas's own choice of stream scale -- `.automatic` follows the
    /// viewer's own geometry; `.fixed` asks the host to hold that exact scale, ignoring
    /// geometry entirely. Persisted elsewhere (`SavedHost`); this is only the
    /// value currently in force for this window.
    private var streamScalePreference: StreamScalePreference = .automatic
    /// The preference the host has actually been told, so a choice that has
    /// not changed is not resent.
    private var reportedStreamScalePreference: StreamScalePreference?

    public init(
        mapper: VirtualCanvasInputMapper,
        pointerSink: any CanvasInputSending,
        framePresenter: (any CanvasFramePresenting)? = nil,
        initialStreamScalePreference: StreamScalePreference = .automatic
    ) {
        self.mapper = mapper
        self.pointerSink = pointerSink
        self.framePresenter = framePresenter
        sourceWidth = mapper.logicalWidth
        sourceHeight = mapper.logicalHeight
        streamScalePreference = initialStreamScalePreference
    }

    public func canvasDidBecomeReady() async {
        isCanvasReady = true
        // A fresh host session starts at the default scale whatever this
        // window's size is, so an enlarged viewer must say so again or it
        // would silently go back to an upscaled, soft picture.
        hostStreamScale = StreamScalePolicy.defaultScale
        reportedStreamScalePreference = nil
        if let drawablePixelWidth, let drawablePixelHeight {
            _ = await setDrawableSize(pixelWidth: drawablePixelWidth, pixelHeight: drawablePixelHeight)
        }
        // Automatic is already what a fresh host session starts at, so there
        // is nothing to say; a standing fixed choice must be told again, the
        // same reasoning the drawable-size resend above already follows.
        if streamScalePreference != .automatic {
            _ = await sendStreamScalePreference()
        }
    }

    /// A reconnect builds a fresh authenticated session behind the same window.
    /// Arming stays with `canvasDidBecomeReady`, so the replacement cannot
    /// inherit the lost session's readiness.
    public func replacePointerSink(_ sink: any CanvasInputSending) {
        pointerSink = sink
        isCanvasReady = false
        pendingPoint = nil
        hostStreamScale = StreamScalePolicy.defaultScale
        reportedStreamScalePreference = nil
    }

    public func canvasDidEnd() {
        isCanvasReady = false
        pendingPoint = nil
    }

    /// A host-screen connect's surface is whatever size the host's real
    /// display is, never the session-canvas preset, and a return to the
    /// virtual display restores that preset. `updateMapper` is awaited to
    /// completion before `canvasDidBecomeReady()`: this actor is reentrant
    /// across that suspension, so a pointer event queued inside it already
    /// sees the gate open and must map through a mapper that is already
    /// correct. `sourceWidth`/`sourceHeight` reset with it.
    ///
    /// Also re-derives this window's already-known drawable pixels against
    /// the new geometry and resends them if the quantized scale moved -- the
    /// only caller of this method outside a fresh connect is a live
    /// display-mode change, which never calls `setDrawableSize` again on its
    /// own, so the resend has to live here or the host keeps applying
    /// whatever scale the mode it just left was streaming.
    public func updateMapper(geometry: SessionSurfaceGeometry) async {
        mapper = VirtualCanvasInputMapper(
            logicalWidth: Double(geometry.logicalWidth),
            logicalHeight: Double(geometry.logicalHeight)
        )
        sourceWidth = Double(geometry.logicalWidth)
        sourceHeight = Double(geometry.logicalHeight)
        // Before a connect has opened the gate this is a no-op --
        // `setDrawableSize` refuses to send while `isCanvasReady` is false --
        // and `canvasDidBecomeReady()`'s own resend, right after this call
        // returns, is what covers that case instead.
        if let drawablePixelWidth, let drawablePixelHeight {
            _ = await setDrawableSize(pixelWidth: drawablePixelWidth, pixelHeight: drawablePixelHeight)
        }
    }

    public func presentDecodedFrame(_ frame: DecodedFrame) async {
        let width = Double(frame.width)
        let height = Double(frame.height)
        if width > 0, height > 0 {
            sourceWidth = width
            sourceHeight = height
        }
        guard isCanvasReady, let framePresenter else {
            return
        }
        await framePresenter.present(frame)
    }

    /// The viewer's drawable in real backing pixels — not points. Reported to
    /// the host only when it actually changes the quantized stream scale, so
    /// dragging a window edge cannot churn the host's encoder and a
    /// default-sized window sends nothing at all.
    @discardableResult
    public func setDrawableSize(pixelWidth: Double, pixelHeight: Double) async -> ViewerScaleDelivery {
        guard let scale = StreamScalePolicy.scale(
            drawablePixelWidth: pixelWidth,
            drawablePixelHeight: pixelHeight,
            canvasLogicalWidth: mapper.logicalWidth,
            canvasLogicalHeight: mapper.logicalHeight
        ) else {
            return .invalid
        }
        drawablePixelWidth = pixelWidth
        drawablePixelHeight = pixelHeight
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        guard scale != hostStreamScale else {
            return .unchanged
        }
        do {
            try await pointerSink.sendViewerDrawableSize(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                maximumScale: nil
            )
        } catch ClientSessionError.notConnected {
            return .droppedNotConnected
        } catch {
            return .droppedFailed
        }
        hostStreamScale = scale
        return .sent(scale)
    }

    /// Chooses this canvas's own stream scale, or hands the decision back to
    /// the viewer's own geometry with `.automatic`. The host honours a
    /// `.fixed` choice exactly, ignoring geometry entirely, until a learned
    /// sustainability ceiling holds it back -- see `StreamScalePreference`.
    ///
    /// Sent immediately rather than waiting for the next resize: a choice the
    /// host has not been told is not a choice at all, and the window may
    /// never be resized again.
    @discardableResult
    public func setStreamScalePreference(_ preference: StreamScalePreference) async -> StreamScalePreferenceDelivery {
        if case let .fixed(scale) = preference, !StreamScalePolicy.isPlausibleMaximumScale(scale) {
            return .invalid
        }
        streamScalePreference = preference
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        return await sendStreamScalePreference()
    }

    @discardableResult
    private func sendStreamScalePreference() async -> StreamScalePreferenceDelivery {
        guard streamScalePreference != reportedStreamScalePreference else {
            return .unchanged
        }
        do {
            try await pointerSink.sendStreamScalePreference(streamScalePreference)
        } catch ClientSessionError.notConnected {
            return .droppedNotConnected
        } catch {
            return .droppedFailed
        }
        reportedStreamScalePreference = streamScalePreference
        return .sent
    }

    /// The scale this viewer's own geometry last asked the host for. Read by
    /// the session HUD, which is the only place it can be set against what
    /// the host says it actually applied.
    public var requestedStreamScale: Double { hostStreamScale }

    /// The pixel width/height `requestedStreamScale` was derived from -- what
    /// this machine last sent as its own drawable size. Read by the session
    /// HUD so it can name both machines' own numbers when the host's echoed
    /// request disagrees with this one. `nil` before any drawable size has
    /// been sent.
    public var requestedDrawablePixelWidth: Double? { drawablePixelWidth }
    public var requestedDrawablePixelHeight: Double? { drawablePixelHeight }

    /// This canvas's own current choice, for the Display menu and the HUD to
    /// read back -- see `setStreamScalePreference`.
    public var currentStreamScalePreference: StreamScalePreference { streamScalePreference }

    public func setViewportSize(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            viewportWidth = 0
            viewportHeight = 0
            return
        }
        viewportWidth = width
        viewportHeight = height
    }

    @discardableResult
    public func movePointer(x: Double, y: Double) async -> PointerDelivery {
        guard viewportWidth > 0, viewportHeight > 0 else {
            return .droppedNoViewport
        }
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        let point = mapper.map(
            x: x,
            y: y,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        guard !isSending else {
            pendingPoint = point
            return .coalesced
        }
        isSending = true
        defer { isSending = false }

        var next: CanvasInputPoint? = point
        var outcome: PointerDelivery?
        while let current = next {
            let result = await deliver(current)
            if outcome == nil {
                outcome = result
            }
            guard case .delivered = result else {
                pendingPoint = nil
                break
            }
            next = pendingPoint
            pendingPoint = nil
        }
        return outcome ?? .droppedFailed
    }

    /// Discrete input is never coalesced: dropping a button or key would strand
    /// it held on the host.
    @discardableResult
    public func sendButton(
        button: CanvasPointerButton,
        isDown: Bool,
        x: Double,
        y: Double
    ) async -> PointerDelivery {
        await sendLocated(x: x, y: y) { point in
            .pointerButton(button: button, isDown: isDown, x: point.x, y: point.y)
        }
    }

    @discardableResult
    public func sendScroll(
        deltaX: Double,
        deltaY: Double,
        x: Double,
        y: Double,
        phase: CanvasScrollPhase?,
        momentumPhase: CanvasScrollMomentumPhase?
    ) async -> PointerDelivery {
        guard deltaX.isFinite, deltaY.isFinite else {
            return .droppedInvalidLocation
        }
        return await sendLocated(x: x, y: y) { point in
            .scrolled(
                deltaX: deltaX,
                deltaY: deltaY,
                x: point.x,
                y: point.y,
                phase: phase,
                momentumPhase: momentumPhase
            )
        }
    }

    /// Raw motion from a captured pointer. Carries no canvas coordinate, so
    /// unlike `movePointer` this needs no viewport size and is never
    /// coalesced -- each delta is relative to the last, and dropping one
    /// would lose real motion rather than a stale intermediate position.
    @discardableResult
    public func sendRelativeMotion(deltaX: Double, deltaY: Double) async -> PointerDelivery {
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        guard deltaX.isFinite, deltaY.isFinite else {
            return .droppedInvalidLocation
        }
        return await deliver(.pointerMovedRelative(deltaX: deltaX, deltaY: deltaY), at: nil)
    }

    @discardableResult
    public func sendPointerCaptureChanged(isCaptured: Bool) async -> PointerDelivery {
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        return await deliver(.pointerCaptureChanged(isCaptured: isCaptured), at: nil)
    }

    @discardableResult
    public func sendKey(
        keyCode: UInt16,
        isDown: Bool,
        modifiers: CanvasModifierFlags
    ) async -> PointerDelivery {
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        return await deliver(.key(keyCode: keyCode, isDown: isDown, modifiers: modifiers), at: nil)
    }

    /// A whole chord in one call. Used by the shortcut strip.
    ///
    /// A chord that is half delivered is how a modifier ends up held on a machine
    /// nobody is sitting at, and there are two ways for that to happen. A
    /// canvas that is not ready refuses the sequence before any of it is sent.
    /// A send that fails partway cannot be refused in advance -- by then the
    /// modifier is already on the far machine -- so the keys still believed held
    /// are released on the way out and nothing further is pressed. Those
    /// releases are best effort: the link that just failed may not carry them
    /// either, and there is nothing better to try.
    @discardableResult
    public func sendKeySequence(_ events: [SensoriumInputEvent]) async -> PointerDelivery {
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        var held: Set<UInt16> = []
        var delivery = PointerDelivery.deliveredWithoutLocation
        for (index, event) in events.enumerated() {
            delivery = await deliver(event, at: nil)
            switch delivery {
            case .droppedNotConnected, .droppedFailed:
                await release(held: held, from: events[index...])
                return delivery
            default:
                break
            }
            guard case let .key(keyCode, isDown, _) = event else { continue }
            if isDown {
                held.insert(keyCode)
            } else {
                held.remove(keyCode)
            }
        }
        return delivery
    }

    /// The chord's own remaining key-ups, for the keys that actually went down.
    /// Taken from the sequence rather than built here: the events that release
    /// this chord are already in it, in the right order and carrying the right
    /// modifier flags -- the main key first, the modifiers last.
    private func release(held: Set<UInt16>, from remainder: ArraySlice<SensoriumInputEvent>) async {
        for event in remainder {
            guard case let .key(keyCode, isDown, _) = event, !isDown, held.contains(keyCode) else {
                continue
            }
            _ = await deliver(event, at: nil)
        }
    }

    /// Releases everything the host believes is held on the owned canvas.
    /// Used when the viewer loses focus so a key or button the user let go of
    /// on the local machine does not stay stuck down remotely.
    @discardableResult
    public func releaseAllInput() async -> PointerDelivery {
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        return await deliver(.releaseAllInput, at: nil)
    }

    private func sendLocated(
        x: Double,
        y: Double,
        makeEvent: (CanvasInputPoint) -> SensoriumInputEvent
    ) async -> PointerDelivery {
        guard viewportWidth > 0, viewportHeight > 0 else {
            return .droppedNoViewport
        }
        guard isCanvasReady else {
            return .droppedNotConnected
        }
        guard x.isFinite, y.isFinite else {
            return .droppedInvalidLocation
        }
        let point = mapper.map(
            x: x,
            y: y,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        return await deliver(makeEvent(point), at: point)
    }

    private func deliver(_ point: CanvasInputPoint) async -> PointerDelivery {
        await deliver(.pointerMoved(x: point.x, y: point.y), at: point)
    }

    private func deliver(
        _ event: SensoriumInputEvent,
        at point: CanvasInputPoint?
    ) async -> PointerDelivery {
        do {
            try await pointerSink.sendInput(event)
        } catch ClientSessionError.notConnected {
            return .droppedNotConnected
        } catch {
            return .droppedFailed
        }
        guard let point else {
            return .deliveredWithoutLocation
        }
        return .delivered(point)
    }
}
