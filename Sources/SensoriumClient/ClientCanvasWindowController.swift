#if canImport(AppKit)
import AppKit
import SensoriumCore
import MetalKit

/// Assembles the pieces that make a session visible and controllable: a window
/// holding the Metal surface, the AppKit event view feeding the router, and the
/// decode path feeding the presenter.
///
/// Nothing here is exercised by the verification runners — building it opens a
/// window and creates a Metal device. Every decision it depends on lives in
/// `ClientViewportController` and `CanvasSurfaceEventRouter`, which are verified
/// without a window.
@MainActor
public final class ClientCanvasWindowController: @MainActor SessionCanvasWindow, SessionWindowChrome, ViewerMenuCommandTarget, @unchecked Sendable {
    private let window: NSWindow
    /// The address-derived title until `updateTitle(_:)` learns the host's
    /// own name from `canvasReady`; `attach(session:)` resets to whatever
    /// this currently holds, so a reconnect never shows a stale title from a
    /// previous host.
    private var title: String
    public let surfaceID: UInt32
    private let metalView: MTKView
    private let surfaceView: CanvasSurfaceView
    private let presenter: MetalFramePresenter
    private let viewport: ClientViewportController
    private let router: CanvasSurfaceEventRouter
    /// The session this window's input and focus reports go to. Replaced on
    /// reconnect, which is why it is not captured once into the observers.
    private var session: ClientSessionController
    /// Shared with every window in the session: focus deduplication is a
    /// property of the session, not of one window. `nil` means this window
    /// never reports focus, which leaves the host on fair share.
    private let focusReporter: ViewerFocusReporter?
    private var decoder: (any VideoDecoding)?
    /// How this window builds its decoder. Defaulted to VideoToolbox on
    /// macOS; a platform with another decoder passes its own.
    private let makeDecoder: VideoDecoderFactory
    /// Takes packets off the receive loop and decodes them on a queue of its
    /// own, so a slow decode on this machine never slows down reading the
    /// socket. `nil` before `startDecoding` and after `stopDecoding`.
    private var decodeQueue: VideoDecodeQueue?
    /// Keeps the newest decoded frame on its way to the presenter and gives up
    /// any the presenter never reached.
    private var coalescer: DecodedFrameCoalescer?
    /// What this window gave up rather than showed, in both places it can.
    /// Outlives one decode session: a reconnect behind this same window keeps
    /// counting.
    private let drops = ViewerFrameDropCounter()
    /// This window's video entry point, and the receipt ledger behind it.
    /// Owned by this window alone, never shared -- so two windows' receipts
    /// can never collide even though `FrameReceiptLedger` keys only by
    /// presentation time. Reachable without the main actor, which is what
    /// keeps arriving frames off the queue of work a window already has.
    public nonisolated let videoSink = SurfaceVideoSink()
    // NotificationCenter's own add/remove are thread-safe, and the tokens are
    // only ever removed, never inspected, so a nonisolated deinit is safe.
    nonisolated(unsafe) private var focusObservers: [NSObjectProtocol] = []
    /// Unobtrusive by default: hidden until summoned with Cmd-Shift-L, and
    /// never part of the remote-canvas input path -- this is thin AppKit
    /// glue over `SessionHUDPanel`, which owns every actual decision about
    /// what it shows and is verified without a window.
    private let sessionHUD = SessionHUDView()
    /// The top edge `metalView` and `sessionHUD` give up to the pinned
    /// shortcut strip's own band -- see `updateVideoTopInset(_:)`, which
    /// drives both constants from `ShortcutStripView.pinnedBandHeight`.
    private var metalViewTop: NSLayoutConstraint!
    private var sessionHUDTop: NSLayoutConstraint!
    // Never touches `surfaceView`'s claimed-shortcut path (`SystemShortcutRouter`),
    // so the summon gesture can never be forwarded to the host or interfere
    // with input the remote canvas is entitled to. Thread-safety note mirrors
    // `focusObservers` above: only ever removed, never inspected off-main.
    nonisolated(unsafe) private var telemetryToggleMonitor: Any?
    /// Same shape as `telemetryToggleMonitor`: a deliberately separate chord
    /// that never touches `SystemShortcutRouter`, so this window's own key
    /// forwarding is untouched by it. Unlike telemetry, this one does reach
    /// the wire -- `CanvasSurfaceView.togglePointerCapture()` is what sends
    /// `pointerCaptureChanged`.
    nonisolated(unsafe) private var pointerCaptureToggleMonitor: Any?
    /// The window's own answer to "is this picture still alive?". Every word
    /// and colour it shows comes from `ViewerSessionStateMachine`; this view
    /// only draws what it is handed.
    private let statusOverlay = ViewerSessionStatusOverlay()
    /// First show takes focus, later ones never do -- see
    /// `ViewerActivationPolicy`.
    private var activation = ViewerActivationPolicy()
    /// Decided once, at construction, because it depends on whether a frame
    /// was remembered before this window existed to move.
    private let placement: ViewerWindowPlacement
    /// The last `SessionHUDSnapshot`'s scale figures, kept so the Display
    /// menu -- built lazily on `menuNeedsUpdate`, off the main HUD tick --
    /// can read them synchronously instead of awaiting the viewport actor.
    private var cachedRequestedStreamScale: Double?
    private var cachedStreamScalePreference: StreamScalePreference = .automatic
    private var cachedAppliedStreamScale: Double?
    private var cachedSustainableScaleCeiling: Double?
    private var cachedClampedFromUserChoice: Double?
    /// docs/ux-spec.md's "Displays" count, cached the same way the
    /// resolution figures above are, and for the same reason: the Displays
    /// menu is built lazily, off the main HUD tick, and needs a synchronous
    /// answer.
    private var cachedDisplayCount = 1
    /// Whether the live session streams a host screen rather than a session
    /// canvas -- cached the same way `cachedDisplayCount` is, and read by
    /// `displayCountMenuState` to disable the Displays menu: the host's own
    /// mixed-session gate refuses a second display there, so the row offers
    /// nothing but a guaranteed refusal.
    private var cachedIsHostScreenSession = false
    /// docs/ux-spec.md's "Screen" menu -- what `hostScreenList` last offered
    /// on this session's canvas connection, and which token (if any) is the
    /// live target. Cached the same way `cachedDisplayCount` is: the menu is
    /// built lazily, off the main HUD tick, and needs a synchronous answer.
    private var cachedScreenMenuDisplays: [HostScreenListEntry] = []
    private var cachedScreenMenuSelectedToken: Data?
    /// The host screen's own display modes, and the one it is on, as the
    /// host last reported them. Cached for exactly the same reason the two
    /// lines above are.
    private var cachedHostScreenModes: [HostScreenModeEntry] = []
    private var cachedHostScreenModeID: String?
    /// This machine's own saved "Start with" preference, cached the same way
    /// `cachedDisplayCount` is and for the same reason: the menu is built
    /// lazily and needs a synchronous answer.
    private var cachedStartTargetPreference: StartTarget = .hostScreenWhenOffered
    /// docs/ux-spec.md's "Clipboard: on or off", cached the same way
    /// `cachedDisplayCount` is and for the same reason.
    private var cachedClipboardSharingEnabled = ClipboardSyncEngine.sharingEnabledByDefault
    /// The system shortcuts this machine takes for itself -- Mission Control,
    /// Spotlight, Command-Tab -- offered as buttons that send them to the
    /// machine being worked on instead. Closed but for its handle until that
    /// handle is hovered or clicked or the summoning chord is typed, and inert
    /// unless the session is live: `ShortcutStripModel` owns all of that.
    private let shortcutStrip: ShortcutStripView
    /// Serialises the strip's chords -- see `ShortcutChordQueue`.
    private let chords = ShortcutChordQueue()
    /// Drives the strip from where the pointer is. A monitor rather than a
    /// tracking area: the canvas view's own tracking area already covers the
    /// window, and one report of where the pointer is serves the handle and the
    /// open strip alike. Thread-safety note as for `focusObservers`: only ever
    /// removed.
    nonisolated(unsafe) private var shortcutStripPointerMonitor: Any?
    /// The strip's own summoning chord, and the Escape that closes it.
    /// Deliberately separate from `SystemShortcutRouter`, like the two monitors
    /// above: both are local to this machine and never reach the wire.
    nonisolated(unsafe) private var shortcutStripKeyMonitor: Any?
    /// A transient "something was refused" banner, distinct from
    /// `statusOverlay`: that overlay means the session itself is down, this
    /// means one request or one clipboard was refused and the session is
    /// otherwise fine.
    private let displayCountNotice = ViewerTransientNoticeView()
    /// Where this window's stream-scale choice is persisted, so it survives
    /// relaunch -- see `selectStreamScale`. `nil` for a caller with nothing to
    /// persist to (the probes, the verification runners' fakes).
    private let savedHostStore: (any SavedHostStoring)?
    /// Which saved machine this window is streaming from, so a stream-scale
    /// choice is written back to that machine's own entry and not to whichever
    /// one happens to be first in the list.
    private let savedHostPublicKey: Data?
    /// Retained here because `NSWindow.delegate` is weak, and set up at the
    /// end of `init` so it can reach `onCloseRequested`.
    private var closeDelegate: CanvasWindowCloseDelegate?
    /// What closing this window means. Closing this window is leaving the
    /// session, so it fires the same quit path an interrupt does; otherwise
    /// the process would keep running, windowless, still holding the host's
    /// canvas.
    public var onCloseRequested: (() -> Void)?

    /// `surfaceID` binds every input event, viewer-size report, and frame
    /// receipt this window produces to one owned canvas. Surface 0 (the
    /// default) sends through `session` directly; any other surface routes through
    /// `SurfaceScopedInputSink` so its events carry an explicit `surfaceID`.
    public init(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32 = 0,
        macName: String? = nil,
        focusReporter: ViewerFocusReporter? = nil,
        shortcutMode: SystemShortcutMode = .default,
        accessibility: any ClientAccessibilityAuthorization = SystemAccessibilityAuthorization(),
        initialStreamScalePreference: StreamScalePreference = .automatic,
        savedHostStore: (any SavedHostStoring)? = nil,
        savedHostPublicKey: Data? = nil,
        makeDecoder: @escaping VideoDecoderFactory = VideoToolboxDecoder.factory
    ) throws {
        self.makeDecoder = makeDecoder
        // Named for the person reading a tooltip, so it is the name they gave
        // that machine and not this window's title, which gains the address it
        // was reached at once the handshake says who answered.
        shortcutStrip = ShortcutStripView(hostName: macName ?? title)
        self.savedHostStore = savedHostStore
        self.savedHostPublicKey = savedHostPublicKey
        let preset = SavedHost.remoteCanvasPreset
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(preset.logicalWidth) / 2,
            height: CGFloat(preset.logicalHeight) / 2
        )
        self.surfaceID = surfaceID
        self.session = session
        self.focusReporter = focusReporter

        metalView = MTKView(frame: contentRect)
        presenter = try MetalFramePresenter(view: metalView, drops: drops)
        viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(preset.logicalWidth),
                logicalHeight: Double(preset.logicalHeight)
            ),
            pointerSink: Self.pointerSink(session: session, surfaceID: surfaceID),
            framePresenter: presenter,
            initialStreamScalePreference: initialStreamScalePreference
        )
        router = CanvasSurfaceEventRouter(viewport: viewport)
        surfaceView = CanvasSurfaceView(
            router: router,
            shortcutRouter: SystemShortcutRouter(mode: shortcutMode),
            accessibilityGranted: accessibility.isAccessibilityGranted,
            surfaceID: surfaceID
        )

        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = title
        window.title = title
        window.contentView = surfaceView
        // Ordinary manual resizing stays 16:10 so it never needs a letterbox;
        // the presenter still letterboxes for cases this can't cover, such as
        // going fullscreen on a differently-shaped physical display.
        window.contentAspectRatio = NSSize(
            width: CGFloat(preset.logicalWidth),
            height: CGFloat(preset.logicalHeight)
        )

        // AppKit remembers the frame under this name from here on; a window
        // that has one goes back where the user left it, and only a window
        // that has never been placed is positioned by us.
        let autosaveName = ViewerWindowPlacementPolicy.frameAutosaveName(surfaceID: surfaceID)
        placement = ViewerWindowPlacementPolicy.placement(
            surfaceID: surfaceID,
            hasSavedFrame: UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") != nil
        )
        _ = window.setFrameAutosaveName(autosaveName)
        switch placement {
        case .restoreSaved:
            _ = window.setFrameUsingName(autosaveName)
        case .center:
            window.center()
        case .cascade:
            // Needs the window it cascades off, which the viewer hands over
            // once both exist. See `cascadeIfUnplaced(from:)`.
            break
        }

        // Constraints, not an autoresizing mask: a pinned shortcut strip's
        // band gives this a top inset that changes live, with no frame of
        // its own to resize from -- see `updateVideoTopInset(_:)`.
        metalView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(metalView)
        metalViewTop = metalView.topAnchor.constraint(equalTo: surfaceView.topAnchor)
        NSLayoutConstraint.activate([
            metalViewTop,
            metalView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor)
        ])

        // Corner-pinned, not resized with the view: the panel's height is its
        // rows' business and must never depend on the window's. Constraints
        // rather than an autoresizing mask because the panel sizes itself
        // from its content, and a mask needs a frame nobody here can compute.
        // Pinned to the top-left, inset the same amount below the top as
        // `metalView` -- both give up the same band to a pinned strip.
        sessionHUD.isHidden = true
        surfaceView.addSubview(sessionHUD, positioned: .above, relativeTo: metalView)
        sessionHUDTop = sessionHUD.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: ViewerDesign.Space.xs)
        NSLayoutConstraint.activate([
            sessionHUD.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: ViewerDesign.Space.xs),
            sessionHUDTop
        ])

        // Topmost, so a dead session is never hidden behind anything -- the
        // HUD included: a panel of numbers sitting over "Connection lost.
        // Try again / Quit" would hide the only controls that end an outage.
        // Sized with the view because it dims the whole picture.
        statusOverlay.autoresizingMask = [.width, .height]
        statusOverlay.frame = surfaceView.bounds
        surfaceView.addSubview(statusOverlay, positioned: .above, relativeTo: sessionHUD)

        // Across the top edge, above the HUD and below the status overlay: a
        // session that is down has nothing to send these shortcuts to, and its
        // panel must not have a row of buttons over it. The strip keeps itself
        // off screen while the session is not live; the z-order says the same
        // thing a second way.
        surfaceView.addSubview(shortcutStrip, positioned: .above, relativeTo: sessionHUD)
        NSLayoutConstraint.activate([
            shortcutStrip.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            shortcutStrip.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            shortcutStrip.topAnchor.constraint(equalTo: surfaceView.topAnchor)
        ])
        shortcutStrip.onSend = { [weak self] action in
            self?.sendShortcut(action)
        }
        surfaceView.isPointerOverViewerChrome = { [weak self] point in
            self?.shortcutStrip.coversPointInSuperview(point) ?? false
        }
        surfaceView.onPointerExited = { [weak self] in
            self?.shortcutStrip.pointerLeftWindow()
        }
        // Live, with no session restart: the strip reports its own pinned
        // band height (zero unless pinned open), and this gives the video
        // and the HUD back exactly that much of the top edge.
        shortcutStrip.onPinnedBandHeightChanged = { [weak self] height in
            self?.updateVideoTopInset(height)
        }
        updateVideoTopInset(shortcutStrip.pinnedBandHeight)

        // Top-centred and topmost of all: a refusal is rare and must be seen
        // the moment it happens, over the HUD and over a live picture alike.
        displayCountNotice.isHidden = true
        surfaceView.addSubview(displayCountNotice, positioned: .above, relativeTo: statusOverlay)
        NSLayoutConstraint.activate([
            displayCountNotice.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: ViewerDesign.Space.md),
            displayCountNotice.centerXAnchor.constraint(equalTo: surfaceView.centerXAnchor)
        ])

        surfaceView.onReleaseToLocalMac = { [weak self] in
            self?.releaseToLocalMachine()
        }

        // A deliberately separate chord from everything `SystemShortcutRouter`
        // claims for the remote canvas: this only ever toggles local display,
        // never reaches the wire, and this window's own key-forwarding path
        // is untouched by it.
        telemetryToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "l" else {
                return event
            }
            self.toggleTelemetryOverlay()
            return nil
        }

        // Cmd-Shift-G ("grab"): explicit toggle for captured-pointer mode.
        // The escape gesture and losing focus (below) are the two
        // unconditional ways out. This chord and the View menu are the ways
        // in, and both go through `togglePointerCapture()` below so those two
        // exits cover either.
        pointerCaptureToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "g" else {
                return event
            }
            self.togglePointerCapture()
            return nil
        }

        // Where the pointer is, in the canvas view's own coordinates, which is
        // all the strip needs to know: what it is over is the strip's own
        // business. The event is passed through untouched -- the canvas still
        // gets the motion it is entitled to, and the strip's own tooltips still
        // need it.
        shortcutStripPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) {
            [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.surfaceView.convert(event.locationInWindow, from: nil)
            self.shortcutStrip.pointerMoved(to: self.surfaceView.bounds.contains(point) ? point : nil)
            return event
        }

        // Command-Control-Shift-Space summons the strip without the pointer,
        // and Escape closes one the pointer is in. Local to this machine and
        // swallowed here, like the two monitors above: neither reaches the
        // wire. An Escape the strip does not take is passed on untouched, since
        // it is then an ordinary keystroke for the machine being worked on.
        shortcutStripKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let toggle = SystemShortcutCatalog.shortcutStripToggle
            if CanvasModifierFlags(appKitFlags: modifiers) == toggle.modifiers,
               event.keyCode == toggle.keyCode {
                self.shortcutStrip.toggleRequested()
                return nil
            }
            if modifiers.isEmpty, event.keyCode == 53, self.shortcutStrip.escapePressed() {
                return nil
            }
            return event
        }

        // A raw SwiftPM binary has no Info.plist to imply this. Without it,
        // AppKit has no reason to hand this process keyboard focus, and a
        // real person's keystrokes would never reach `surfaceView`.
        NSApplication.shared.setActivationPolicy(.regular)

        // Switching away must release whatever is held on the canvas — a
        // Cmd-Tab away with Cmd still down must not leave it stuck on the
        // host. The router decides what "released" means; this only reports
        // the two ways the viewer stops being the keyboard's target.
        let router = router
        focusObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { await router.route(.focusLost) }
                Task { @MainActor [weak self] in
                    self?.surfaceView.endPointerCaptureIfNeeded()
                    // A window that is no longer key reports no more motion,
                    // so the strip would sit open until one arrived.
                    self?.shortcutStrip.pointerLeftWindow()
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { await router.route(.focusLost) }
                Task { @MainActor [weak self] in
                    self?.surfaceView.endPointerCaptureIfNeeded()
                    self?.report(self?.focusReporter?.viewerDidResignActive())
                }
            },
            // Which canvas the user is looking at. Reported on becoming key
            // rather than on resigning it: switching between the two canvas
            // windows resigns the first before the second becomes key, and
            // acting on that would report a no-focus state that never
            // happened, once per switch.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // Synchronously, not in a task: anything this hook sends is
                // then on the connection ahead of whatever is sent after the
                // notification is handled.
                MainActor.assumeIsolated {
                    self?.onDidBecomeKey?()
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.report(self.focusReporter?.viewerWindowDidBecomeKey(surfaceID: self.surfaceID))
                }
            }
        ]

        closeDelegate = CanvasWindowCloseDelegate { [weak self] in
            self?.onCloseRequested?()
        }
        window.delegate = closeDelegate
    }

    /// Offsets a second canvas from the first, by AppKit's own cascade step
    /// rather than a pixel count invented here. Does nothing once this window
    /// has a remembered frame: a canvas the user has already placed stays
    /// where they put it.
    public func cascadeIfUnplaced(from other: any SessionWindowChrome) {
        guard placement == .cascade, let other = other as? ClientCanvasWindowController else { return }
        // Cascading `other` from `.zero` moves nothing; it hands back where
        // the next window in the cascade belongs.
        let next = other.window.cascadeTopLeft(from: .zero)
        _ = window.cascadeTopLeft(from: next)
    }

    deinit {
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let telemetryToggleMonitor {
            NSEvent.removeMonitor(telemetryToggleMonitor)
        }
        if let pointerCaptureToggleMonitor {
            NSEvent.removeMonitor(pointerCaptureToggleMonitor)
        }
        if let shortcutStripPointerMonitor {
            NSEvent.removeMonitor(shortcutStripPointerMonitor)
        }
        if let shortcutStripKeyMonitor {
            NSEvent.removeMonitor(shortcutStripKeyMonitor)
        }
    }

    public func show() async {
        // A reconnect must restore the picture without ripping the user out of
        // whatever they moved on to locally, so only the first show activates.
        if activation.shouldActivate() {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else if !window.isVisible {
            window.orderFront(nil)
        }
        window.makeFirstResponder(surfaceView)
        // A reconnect reuses a window that is already key, so AppKit posts no
        // becomeKey notification for it. Without this the new host would never
        // be told which canvas is focused and would stay on fair share.
        if window.isKeyWindow {
            report(focusReporter?.viewerWindowDidBecomeKey(surfaceID: surfaceID))
        }
        await viewport.setViewportSize(
            width: Double(surfaceView.videoBounds.width),
            height: Double(surfaceView.videoBounds.height)
        )
    }

    /// Gives `metalView` and `sessionHUD` back exactly the top edge the
    /// pinned shortcut strip's own band is not claiming right now, and tells
    /// `surfaceView` the same amount so pointer mapping and the reported
    /// viewport size agree with where the video actually is. Auto Layout
    /// re-solves both constraints on the next pass, so this reads correctly
    /// through a fullscreen toggle or a window resize as well as a pin.
    private func updateVideoTopInset(_ inset: CGFloat) {
        metalViewTop.constant = inset
        sessionHUDTop.constant = inset + ViewerDesign.Space.xs
        surfaceView.videoTopInset = inset
    }

    /// Feeds one decoded frame path: packets in, pixel buffers out, presented
    /// only while the canvas is armed. The present timestamp is taken after the
    /// presenter returns, so the sample covers the draw and not just the handoff.
    ///
    /// `onDecodedFrame` sees every decoded frame, including ones with no
    /// timing sample, so a test can observe real decode output (pixel buffer
    /// dimensions included) independent of the latency/presentation gating.
    ///
    /// Neither step happens on the caller's thread. Packets go to a
    /// `VideoDecodeQueue`, which decodes them on a queue of its own so that
    /// reading the socket is never waiting on a decode, and decoded frames go
    /// to a `DecodedFrameCoalescer`, which keeps one waiting frame rather than
    /// a growing pile of presentation work. Both give up frames when this
    /// machine cannot keep up with what the host is sending, and both count
    /// what they gave up into `drops`.
    public func startDecoding(
        latency: SessionLatencyMonitor? = nil,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? = nil
    ) throws {
        let viewport = viewport
        let surfaceID = surfaceID
        // Measured where the frame really reaches the screen, not where it is
        // handed over: the presenter holds each frame until the refresh it
        // belongs on, and a session that reported the handover would leave
        // that hold out of every latency it shows.
        presenter.onFramePresented = { timing, presentedAtNanoseconds in
            guard let latency else { return }
            Task {
                await latency.recordPresentedFrame(
                    surfaceID: surfaceID,
                    timing: timing,
                    presentedAtNanoseconds: presentedAtNanoseconds
                )
            }
        }
        let pipeline = VideoDecodePipeline(
            receipts: videoSink.receipts,
            drops: drops,
            makeDecoder: makeDecoder,
            onDecodedFrame: onDecodedFrame
        ) { frame in
            await viewport.presentDecodedFrame(frame)
        }
        coalescer = pipeline.coalescer
        decoder = pipeline.decoder
        decodeQueue = pipeline.decodeQueue
        videoSink.attach(pipeline.decodeQueue)
    }

    /// Nonisolated, and holding nothing of the window's own: whoever read this
    /// packet off the socket hands it to the decoder here without ever waiting
    /// for the main actor, which is drawing, laying out chrome and handling
    /// input.
    public nonisolated func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        try videoSink.receive(packet, receivedAtNanoseconds: receivedAtNanoseconds)
    }

    /// How many frames this window gave up rather than showed, before decoding
    /// and before presentation together. Read on the session's telemetry tick.
    /// Packets given up before the decoder ever saw them. Read for the HUD,
    /// which names the two places apart because they cost different things.
    public var droppedBeforeDecodeCount: Int {
        drops.droppedBeforeDecode
    }

    /// Decoded frames a newer one replaced before the screen was drawn.
    public var droppedBeforePresentCount: Int {
        drops.droppedBeforePresent
    }

    public var droppedFrameCount: Int {
        drops.total
    }

    public func canvasObserver() -> ClientViewportController {
        viewport
    }

    /// Called once the host's own name is known, replacing whatever
    /// address-derived title the window opened with. See `ViewerWindowTitle`.
    public func updateTitle(_ title: String) {
        self.title = title
        window.title = title
    }

    public var viewerWindowState: ViewerWindowState {
        ViewerWindowState(
            surfaceID: surfaceID,
            hasKeyFocus: window.isKeyWindow,
            isFullscreen: window.styleMask.contains(.fullScreen)
        )
    }

    /// Delivered by `SystemShortcutForwarder` for the chords the WindowServer
    /// takes before this window's own key path could see them. Everything else
    /// still arrives through `CanvasSurfaceView`.
    public func forwardShortcut(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags) {
        let router = router
        Task { await router.route(.key(keyCode: keyCode, isDown: isDown, modifiers: modifiers)) }
    }

    /// One shortcut strip press: the whole chord, handed to the session's input
    /// path in a single call, behind a queue that holds the next press until
    /// this one has finished. Two chords in flight at once would let one
    /// press's key-up land inside the other's, which is a chord nobody typed.
    private func sendShortcut(_ action: ShortcutStripAction) {
        let viewport = viewport
        let events = action.events()
        let chords = chords
        Task {
            await chords.enqueue {
                await viewport.sendKeySequence(events)
            }
        }
    }

    /// The escape gesture's landing: leave fullscreen if that is what is
    /// trapping the user, otherwise step the whole viewer aside. Either way
    /// the canvas must not be left holding the modifiers that were down when
    /// the gesture was typed.
    public func releaseToLocalMachine() {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            NSApplication.shared.hide(nil)
        }
        let router = router
        Task { await router.route(.focusLost) }
    }

    /// Exposes the hosted `NSWindow` for callers that need to drive AppKit's
    /// own notification machinery directly — for example, posting a real
    /// `NSWindow.didResignKeyNotification` to exercise the exact observer
    /// registered above, rather than calling the router it wires to.
    public var hostedWindow: NSWindow {
        window
    }

    /// Points the existing window at a freshly authenticated session after a
    /// reconnect. The viewport stays disarmed until the new canvas is ready.
    public func attach(session: ClientSessionController) async {
        self.session = session
        // The new host has been told nothing, so the next transition — or
        // `show()` below — must report focus again from scratch.
        focusReporter?.reset()
        await viewport.replacePointerSink(Self.pointerSink(session: session, surfaceID: surfaceID))
        window.title = title
    }

    /// Puts one focus transition on the wire. A send that fails is a transport
    /// that is already ending; the session's own loops report that, and a
    /// scheduling hint is not worth a second error path.
    private func report(_ report: ViewerFocusReport?) {
        guard let report else { return }
        let session = session
        Task { try? await session.sendViewerFocus(surfaceID: report.surfaceID, hasViewerFocus: report.hasViewerFocus) }
    }

    private static func pointerSink(session: ClientSessionController, surfaceID: UInt32) -> any CanvasInputSending {
        surfaceID == 0 ? session : SurfaceScopedInputSink(session: session, surfaceID: surfaceID)
    }

    /// The one place the panel's visibility changes, so the Cmd-Shift-L
    /// monitor and the View menu are the same act rather than two.
    public func toggleTelemetryOverlay() {
        sessionHUD.isHidden.toggle()
    }

    /// Likewise for captured-pointer mode, and it matters more here: this
    /// calls `CanvasSurfaceView.togglePointerCapture()`, the same call the
    /// escape gesture and a lost key focus undo. Nothing may enter or leave
    /// that mode by another route, or one of those two exits would stop being
    /// unconditional.
    public func togglePointerCapture() {
        surfaceView.togglePointerCapture()
    }

    /// Renders whatever `SessionHUDPanel` decided; this method owns no
    /// staleness, threshold or wording logic of its own. Costs a few string
    /// writes while the panel is hidden — visibility is toggled only by the
    /// user's own Cmd-Shift-L chord and the View menu item above, never by
    /// this call.
    public func updateSessionHUD(_ snapshot: SessionHUDSnapshot) {
        cachedRequestedStreamScale = snapshot.requestedStreamScale
        cachedStreamScalePreference = snapshot.streamScalePreference
        switch snapshot.availability {
        case let .fresh(sample), let .stale(sample):
            cachedAppliedStreamScale = sample.appliedStreamScale
            cachedSustainableScaleCeiling = sample.sustainableScaleCeiling
            cachedClampedFromUserChoice = sample.clampedFromUserChoice
        case .unavailable:
            break
        }
        sessionHUD.apply(telemetry: snapshot)
    }

    /// The Display menu's rows and clamp notice, built from this window's
    /// last telemetry tick. Read synchronously by `menuNeedsUpdate`, not the
    /// viewport actor itself: see `cachedStreamScalePreference`.
    public var streamScaleMenuState: DisplayScaleMenuState {
        let preset = SavedHost.remoteCanvasPreset
        return DisplayScaleMenuState(
            items: DisplayScaleMenuPlan.items(
                selectedPreference: cachedStreamScalePreference,
                canvasLogicalWidth: Double(preset.logicalWidth),
                canvasLogicalHeight: Double(preset.logicalHeight)
            ),
            clampNotice: DisplayScaleMenuPlan.clampNotice(
                appliedStreamScale: cachedAppliedStreamScale,
                requestedStreamScale: cachedRequestedStreamScale,
                clampedFromUserChoice: cachedClampedFromUserChoice
            )
        )
    }

    /// The Displays menu's own rows, docs/ux-spec.md's "Displays: 1 or 2" --
    /// session-wide, so both windows of a two-display session answer the
    /// same state; see `updateDisplayCount(_:)`.
    public var displayCountMenuState: DisplayCountMenuState {
        DisplayCountMenuState(items: DisplayCountMenuPlan.items(
            selectedCount: cachedDisplayCount,
            isEnabled: !cachedIsHostScreenSession
        ))
    }

    /// The session's own current display count, kept here only so the menu
    /// (built lazily on `menuNeedsUpdate`) can answer synchronously -- the
    /// same reason `cachedStreamScalePreference` exists. Set by whoever owns
    /// the live session (`ClientSessionHost`), never decided here.
    public func updateDisplayCount(_ count: Int) {
        cachedDisplayCount = count
    }

    /// Whether the live session is streaming a host screen -- set by
    /// whoever owns the live session, the same reason `updateDisplayCount(_:)`
    /// exists, and read by `displayCountMenuState` above.
    public func updateIsHostScreenSession(_ isHostScreenSession: Bool) {
        cachedIsHostScreenSession = isHostScreenSession
    }

    /// The Displays menu's own action. Forwarded rather than acted on here:
    /// sending the choice, and reacting to the host's reply, both need the
    /// live connection this window does not hold -- see
    /// `ClientSessionHost.selectDisplayCount(_:)`.
    public func selectDisplayCount(_ count: Int) {
        onSelectDisplayCount?(count)
    }

    public var onSelectDisplayCount: ((Int) -> Void)?

    public var screenMenuState: ScreenMenuState {
        ScreenMenuState(
            items: ScreenMenuPlan.items(
                displays: cachedScreenMenuDisplays,
                selectedToken: cachedScreenMenuSelectedToken
            ),
            modes: ScreenMenuPlan.modeMenu(
                modes: cachedHostScreenModes,
                currentModeID: cachedHostScreenModeID,
                isHostScreenSessionLive: cachedIsHostScreenSession
            ),
            startWith: ScreenMenuPlan.startWithMenu(
                preference: cachedStartTargetPreference,
                offeredHostScreens: cachedScreenMenuDisplays,
                isHostScreenSessionLive: cachedIsHostScreenSession
            )
        )
    }

    /// This machine's own saved "Start with" preference, set by whoever owns
    /// the live session -- the same ownership `updateScreenMenu(displays:selectedToken:)`
    /// above already has.
    public func updateStartTargetPreference(_ preference: StartTarget) {
        cachedStartTargetPreference = preference
    }

    /// The "Start with" submenu's own action, forwarded for the same reason
    /// `selectRealScreen(token:)` above is: writing the choice back to the
    /// saved-machines store needs `ClientSessionHost`,
    /// which this window does not hold.
    public func selectStartTarget(_ target: StartTarget) {
        onSelectStartTarget?(target)
    }

    public var onSelectStartTarget: ((StartTarget) -> Void)?

    /// What the Screen menu offers and which row is checked, kept here the
    /// same way `updateDisplayCount(_:)`'s own count is: set by whoever owns
    /// the live session, so the menu (built lazily) can answer synchronously.
    public func updateScreenMenu(displays: [HostScreenListEntry], selectedToken: Data?) {
        cachedScreenMenuDisplays = displays
        cachedScreenMenuSelectedToken = selectedToken
    }

    /// The Screen menu's own action. Forwarded rather than acted on here,
    /// the same reasoning `selectDisplayCount(_:)` above follows: ending the
    /// current session and reconnecting with the chosen target both need the
    /// live connection this window does not hold -- see
    /// `ClientSessionHost`.
    public func selectRealScreen(token: Data?) {
        onSelectRealScreen?(token)
    }

    public var onSelectRealScreen: ((Data?) -> Void)?

    /// What the Resolution submenu offers and which row is checked, set by
    /// whoever owns the live session -- the same ownership
    /// `updateScreenMenu(displays:selectedToken:)` above already has.
    public func updateHostScreenModes(_ modes: [HostScreenModeEntry], currentModeID: String?) {
        cachedHostScreenModes = modes
        cachedHostScreenModeID = currentModeID
    }

    /// The Resolution submenu's own action, forwarded for the same reason
    /// `selectRealScreen(token:)` above is: the request goes out on a live
    /// connection this window does not hold.
    public func selectHostScreenMode(modeID: String) {
        onSelectHostScreenMode?(modeID)
    }

    public var onSelectHostScreenMode: ((String) -> Void)?

    /// docs/ux-spec.md's "Clipboard: on or off", read the same way
    /// `displayCountMenuState` is: from this window's own cache, not the
    /// live session, since the menu is built lazily and needs a synchronous
    /// answer.
    public var isClipboardSharingEnabled: Bool {
        cachedClipboardSharingEnabled
    }

    /// Set by whoever owns the live session, the same reason
    /// `updateDisplayCount(_:)` exists: this window has no session of its
    /// own to ask.
    public func updateClipboardSharingEnabled(_ enabled: Bool) {
        cachedClipboardSharingEnabled = enabled
    }

    /// The Clipboard item's own action. Forwarded rather than acted on
    /// here, the same reasoning `selectDisplayCount(_:)` above follows:
    /// flipping the local pasteboard engine and sending the choice on the
    /// wire both need the live connection this window does not hold -- see
    /// `ClientSessionHost`. `ClipboardSharingToggle.nextValue(currentlyEnabled:)`
    /// decides what is sent, not this method, so a test can pin that
    /// decision without constructing this class.
    public func toggleClipboardSharing() {
        onSelectClipboardSharing?(ClipboardSharingToggle.nextValue(currentlyEnabled: cachedClipboardSharingEnabled))
    }

    public var onSelectClipboardSharing: ((Bool) -> Void)?

    /// Runs every time this window takes key focus, synchronously on the
    /// main thread. Set by the live session's runner.
    public var onDidBecomeKey: (() -> Void)?

    /// A "Displays" increase the host refused, said in this window in the
    /// host's own plain words rather than only logged -- docs/ux-spec.md:
    /// "There is no error whose remedy is a command, a file, or another
    /// app." Not the session-lost overlay (`apply(status:)`): the session
    /// itself is fine, only this one request was refused, so it must not
    /// look like the picture is about to disappear.
    public func showDisplayCountRefusal(reason: String) {
        displayCountNotice.show(reason)
    }

    /// A host-screen resolution change the host refused, in the same
    /// transient notice a refused "Displays" increase uses and for the same
    /// reason: the session is fine, one request was not, and it must not
    /// look like the picture is about to disappear.
    public func showHostScreenModeRefusal(_ line: String) {
        displayCountNotice.show(line)
    }

    /// A clipboard that was not shared, from either machine, in the same
    /// transient notice and for the same reason as a refused request: the
    /// session is fine, one copy did not go through.
    public func showClipboardRefusal(_ line: String) {
        displayCountNotice.show(line)
    }

    /// Chooses this window's own stream scale, or hands the decision back to
    /// the viewer's own geometry with `.automatic`, and persists the choice
    /// with the saved host so it survives relaunch. Goes through
    /// `ClientViewportController`, the one place the choice is applied and
    /// reported to the host -- never applied here.
    public func selectStreamScale(_ preference: StreamScalePreference) {
        let viewport = viewport
        let store = savedHostStore
        let key = savedHostPublicKey
        Task {
            await viewport.setStreamScalePreference(preference)
            guard let store, let key else { return }
            store.setStreamScalePreference(hostPublicKey: key, to: preference)
        }
    }

    /// Whether this window's canvas has hidden the local cursor and switched
    /// to captured relative motion -- see `CanvasSurfaceView.togglePointerCapture()`.
    public var isPointerCaptured: Bool {
        surfaceView.isPointerCaptured
    }

    /// This window's own presenter's real, GPU-completion-measured
    /// present-to-screen latency -- see `MetalFramePresenter.completionLatency`.
    public var presentCompletionLatency: LatencySamples {
        presenter.completionLatency
    }

    /// How far past its capture time this window is holding each frame to keep
    /// the motion even -- see `PresentationPacer`. Read once per telemetry
    /// tick, for the panel to show as latency this machine added on purpose.
    public var presentationHoldNanoseconds: Int64 {
        presenter.holdNanoseconds
    }

    /// Which decoder this window's own decompression session actually
    /// selected. Read once per telemetry tick, so the panel can say whether
    /// this machine is decoding in hardware instead of only logging it.
    public var decoderHardwareAcceleration: DecoderHardwareAccelerationStatus? {
        decoder?.hardwareAcceleration
    }

    /// Shows one session state over the canvas. Nothing is decided here: the
    /// phase, the words, the status tone and the buttons all arrive already
    /// chosen.
    public func apply(status: ViewerSessionStatus) {
        // Session teardown: a session that goes down while the pointer is
        // captured must not leave the physical mouse disconnected with no
        // canvas left to release it from. Idempotent, so a status repeated
        // while already down costs nothing.
        if status.isOverlayVisible {
            surfaceView.endPointerCaptureIfNeeded()
        }
        surfaceView.sessionOverlayVisibilityChanged(status.isOverlayVisible)
        statusOverlay.apply(status)
        // The strip sends input, so it exists only while there is a live
        // session to send it to.
        shortcutStrip.phaseChanged(status.phase)
        // The HUD's own first line is the session state, and this is the only
        // place the window learns it.
        sessionHUD.apply(session: status)
        // Keyboard focus follows what is actually usable: the buttons while
        // the session is not live, the canvas the moment it is again. Read
        // from the status rather than from the overlay alone, so a live
        // session puts the keyboard back on the canvas whatever the panel
        // happens to be holding.
        window.makeFirstResponder(
            status.isOverlayVisible ? (statusOverlay.preferredFocus ?? surfaceView) : surfaceView
        )
    }

    /// Where the overlay's buttons go. Set by the session, which owns the one
    /// quit latch and the one dialling loop — a button here starts neither of
    /// them a second time.
    public var onSessionAction: ((ViewerSessionAction) -> Void)? {
        get { statusOverlay.onAction }
        set { statusOverlay.onAction = newValue }
    }

    /// A decoder holds the previous session's parameter sets; a new session
    /// starts from its own recovery keyframe.
    ///
    /// The queue is stopped before the decoder is reset, so nothing new is
    /// handed to a session about to be invalidated. A decode already running
    /// holds the decoder's own lock, which is what `reset()` then waits on.
    public func stopDecoding() {
        presenter.onFramePresented = nil
        presenter.discardPendingFrames()
        videoSink.attach(nil)
        decodeQueue?.stop()
        decodeQueue = nil
        coalescer?.stop()
        coalescer = nil
        decoder?.reset()
        decoder = nil
        videoSink.receipts.reset()
    }

    /// Orders the window off screen. Used only when the viewer is leaving for
    /// good, not on an ordinary per-session disconnect — a reconnect reuses
    /// this same window, so closing it there would flash it away and back.
    public func close() {
        surfaceView.forceRestoreCursor()
        window.orderOut(nil)
    }
}

/// Turns the close button into leaving the session.
///
/// Deliberately refuses the close itself: the viewer's quit path ends the
/// session, releases the host's canvas and orders these windows away, and a
/// window torn down before that runs would take the surface out from under it.
@MainActor
private final class CanvasWindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onCloseRequested: () -> Void

    init(onCloseRequested: @escaping () -> Void) {
        self.onCloseRequested = onCloseRequested
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequested()
        return false
    }
}

/// Draws one `ViewerSessionStatus` over the canvas: a scrim that marks the
/// frozen picture underneath as stale, and a panel saying what happened and
/// what happens next.
///
/// Deliberately dumb. It holds no session state, decides no wording, and reads
/// no clock -- `ViewerSessionStateMachine` owns all of that and is verified
/// without a window. Colours and metrics come from `ViewerDesign`, never from
/// an AppKit semantic colour, and nothing here casts a shadow.
@MainActor
final class ViewerSessionStatusOverlay: NSView {
    private let panel = NSView()
    private let toneDot = NSView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    /// Collapsed to nothing when a state offers no buttons, so a panel with
    /// only words keeps its own padding.
    private var buttonRowTop: NSLayoutConstraint!
    var onAction: ((ViewerSessionAction) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = ViewerDesign.chromeBg2.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = ViewerDesign.chromeBorder2.cgColor
        panel.layer?.cornerRadius = ViewerDesign.Radius.base
        addSubview(panel)

        toneDot.translatesAutoresizingMaskIntoConstraints = false
        toneDot.wantsLayer = true
        toneDot.layer?.cornerRadius = ViewerDesign.Radius.tight
        panel.addSubview(toneDot)

        eyebrow.translatesAutoresizingMaskIntoConstraints = false
        eyebrow.font = ViewerDesign.font(mono: true, size: 12, weight: .medium)
        eyebrow.textColor = ViewerDesign.muted2.nsColor
        panel.addSubview(eyebrow)

        headline.translatesAutoresizingMaskIntoConstraints = false
        headline.font = ViewerDesign.font(mono: false, size: 16, weight: .medium)
        headline.textColor = ViewerDesign.ink.nsColor
        // Unbounded: a machine name can run past what two lines hold, and the
        // panel has no fixed height, so wrapping onto a third line costs
        // nothing -- an ellipsis would cut off the one word, the machine's own
        // name, that this sentence exists to show.
        headline.maximumNumberOfLines = 0
        headline.lineBreakMode = .byWordWrapping
        headline.preferredMaxLayoutWidth = StatusPanelLayout.sessionPanelWidth - ViewerDesign.Space.lg * 2
        panel.addSubview(headline)

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = ViewerDesign.font(mono: false, size: 12)
        detail.textColor = ViewerDesign.muted.nsColor
        // Unbounded, the same reasoning as `headline` above: this line is a
        // host's own refusal reason, and the panel has no fixed height, so
        // wrapping further costs nothing -- a line cap here would silently
        // clip the one sentence this panel exists to show in full.
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = StatusPanelLayout.sessionPanelWidth - ViewerDesign.Space.lg * 2
        panel.addSubview(detail)

        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = ViewerDesign.Space.xs
        panel.addSubview(buttonRow)

        let inset = ViewerDesign.Space.lg
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // One width for every state (`StatusPanelLayout.sessionPanelWidth`),
            // so the panel does not jump as the session changes state under
            // the person reading it.
            panel.widthAnchor.constraint(equalToConstant: StatusPanelLayout.sessionPanelWidth),

            toneDot.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            toneDot.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset + 2),
            toneDot.widthAnchor.constraint(equalToConstant: ViewerDesign.Space.xs),
            toneDot.heightAnchor.constraint(equalToConstant: ViewerDesign.Space.xs),

            eyebrow.leadingAnchor.constraint(equalTo: toneDot.trailingAnchor, constant: ViewerDesign.Space.xs),
            eyebrow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -inset),
            eyebrow.centerYAnchor.constraint(equalTo: toneDot.centerYAnchor),

            headline.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            headline.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            headline.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: ViewerDesign.Space.sm),

            detail.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            detail.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: ViewerDesign.Space.xs),

            buttonRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -inset),
            buttonRow.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -inset)
        ])
        buttonRowTop = buttonRow.topAnchor.constraint(equalTo: detail.bottomAnchor)
        buttonRowTop.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(_ status: ViewerSessionStatus) {
        isHidden = !status.isOverlayVisible
        if status.indicatorPulses {
            ViewerPulse.apply(to: toneDot.layer)
        } else {
            ViewerPulse.remove(from: toneDot.layer)
        }
        // Emptied for every status, including the ones this panel does not
        // show: buttons left behind by the last visible state are still
        // buttons `preferredFocus` would hand the keyboard to, and a panel
        // nobody can see must never hold the keys the canvas needs.
        for view in buttonRow.arrangedSubviews {
            buttonRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard status.isOverlayVisible else { return }
        // Opaque before a first frame exists, a scrim once there is a picture
        // underneath to mark as stale.
        layer?.backgroundColor = status.dimsCanvas
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.66).cgColor
            : ViewerDesign.chromeBg.cgColor
        toneDot.layer?.backgroundColor = ViewerDesign.color(for: status.tone).cgColor
        eyebrow.attributedStringValue = NSAttributedString(
            string: status.eyebrow,
            attributes: [
                .font: ViewerDesign.font(mono: true, size: 12, weight: .medium),
                .foregroundColor: ViewerDesign.muted2.nsColor,
                .kern: ViewerDesign.kern(ViewerDesign.Tracking.widest, size: 12)
            ]
        )
        headline.stringValue = status.headline
        detail.stringValue = status.detail

        for button in status.buttons {
            buttonRow.addArrangedSubview(ViewerActionButton(button) { [weak self] action in
                self?.onAction?(action)
            })
        }
        buttonRowTop.constant = status.buttons.isEmpty ? 0 : ViewerDesign.Space.md
    }

    /// What the keyboard should land on while this state is up: see
    /// `ViewerFocusPolicy`.
    var preferredFocus: NSView? {
        let buttons = buttonRow.arrangedSubviews.compactMap { $0 as? ViewerActionButton }
        let index = ViewerFocusPolicy.chosenIndex(
            among: buttons.map { (action: $0.sessionAction, isPrimary: $0.isPrimaryAction) }
        )
        return index.map { buttons[$0] }
    }
}

/// One button in the status panel. Flat, sharp-cornered, and focus-visible
/// without AppKit's focus ring, which draws in the system's accent rather than
/// this palette's.
@MainActor
final class ViewerActionButton: NSButton {
    let isPrimaryAction: Bool
    let sessionAction: ViewerSessionAction
    private let onAction: (ViewerSessionAction) -> Void
    /// Matches `PairedMachinesView`'s Remove button on the host side, so a compact
    /// action's title never hugs its own border the way a bare `>= 96`
    /// minimum width does once a title -- like "Connect again" -- outgrows it.
    /// Shared with `StatusPanelLayout`, which measures the same title the
    /// same way to size the panel before any button exists to compress.
    static let horizontalInset = ViewerDesign.Space.sm
    static let minimumWidth: CGFloat = 96
    static let titleFont = ViewerDesign.font(mono: false, size: 13, weight: .medium)

    init(_ model: ViewerSessionButton, onAction: @escaping (ViewerSessionAction) -> Void) {
        isPrimaryAction = model.isPrimary
        sessionAction = model.action
        self.onAction = onAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = ViewerDesign.Radius.base
        title = model.title
        attributedTitle = NSAttributedString(
            string: model.title,
            attributes: [
                .font: Self.titleFont,
                .foregroundColor: (model.isPrimary ? ViewerDesign.chromeBg : ViewerDesign.ink).nsColor
            ]
        )
        // Return activates the primary action. A hidden view is skipped by
        // AppKit's key-equivalent pass, so a live session's Return still
        // reaches the remote canvas.
        if model.isPrimary {
            keyEquivalent = "\r"
        }
        target = self
        action = #selector(fire)
        // Required, not the default: the panel is sized to fit this button's
        // own intrinsic width (`StatusPanelLayout`), and a button that could
        // still compress under that guarantee would silently reopen the
        // overflow this exists to prevent.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth)
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The `>= 96` width floor above only pads a short title like "Pair"; a
    /// longer one, like "Connect again", outgrows it with no horizontal
    /// margin at all. This adds that margin regardless of title length.
    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(attributedTitle.size().width)
        return NSSize(width: titleWidth + Self.horizontalInset * 2, height: 28)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        refreshAppearance(isFocused: accepted)
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        refreshAppearance(isFocused: !resigned)
        return resigned
    }

    @objc private func fire() {
        onAction(sessionAction)
    }

    private func refreshAppearance(isFocused: Bool = false) {
        layer?.backgroundColor = (isPrimaryAction ? ViewerDesign.accent : ViewerDesign.bg4).cgColor
        layer?.borderWidth = isFocused ? 1 : 0
        // The accent is the focus colour, except on the button that is already
        // filled with it.
        layer?.borderColor = (isPrimaryAction ? ViewerDesign.ink : ViewerDesign.accent).cgColor
    }
}
#endif
