#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import CEGL
import CGLib
import CWayland
import CWaylandGlue
import CWaylandProtocols
import Foundation
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

public enum WaylandSessionWindowError: Error, Equatable {
    /// No compositor answered. Either there is no graphical session on this
    /// machine, or this process was started outside it.
    case displayUnavailable
    /// The compositor advertises none of the interfaces a session window is
    /// made of. Carries the name of the first one that was missing.
    case interfaceUnavailable(String)
    case surfaceUnavailable
}

/// A session's own window where Wayland is the display server: one xdg
/// toplevel carrying an EGL surface, driven by the compositor's frame
/// callbacks.
///
/// This is the Linux counterpart of `ClientCanvasWindowController`, and the
/// decode path behind it is the same portable one: a `VideoDecodePipeline`
/// feeding a `DecodedFrameCoalescer` feeding `ClientViewportController`, which
/// hands each frame to `EGLFramePresenter`. Only the platform pieces differ.
///
/// Everything here runs on the event loop's own thread -- see `GLibMainLoop`,
/// which is what makes the main actor and that thread the same thread. The
/// listeners the compositor calls are plain C callbacks arriving on it, and
/// each one re-enters this actor rather than hopping onto it.
///
/// Input arrives here as the compositor's own facts -- evdev key codes, axis
/// values, surface-local positions -- and is translated before it is routed:
/// `WaylandKeyboardState` and `WaylandScrollFrameAccumulator` own that
/// translation, `WaylandPointerCaptureController` owns captured-pointer mode,
/// and `CanvasSurfaceEventRouter` owns everything after it, exactly as it
/// does for the macOS surface.
@MainActor
public final class WaylandSessionWindow:
    @MainActor SessionCanvasWindow,
    WaylandPointerLocking,
    WaylandShortcutInhibiting,
    ShortcutForwardingTarget,
    @unchecked Sendable {
    public let surfaceID: UInt32
    /// This window's video entry point, reachable without the main actor so a
    /// frame off the socket never waits for whatever the window is doing.
    public nonisolated let videoSink = SurfaceVideoSink()

    private let display: OpaquePointer
    private var registry: OpaquePointer?
    /// Read by `WaylandSessionWindow+Chrome.swift`, which builds this
    /// window's overlays out of them: an extension can store nothing, so the
    /// handles the chrome needs are held here with the rest.
    private(set) var compositor: OpaquePointer?
    private(set) var subcompositor: OpaquePointer?
    private(set) var shm: OpaquePointer?
    /// This desktop's default cursor image, loaded once through
    /// `wl_shm`/`wayland-cursor` -- see `loadCursorTheme()`. Nil for a
    /// compositor that never advertised `wl_shm`, or a theme that failed to
    /// load, in which case this window never touches the cursor at all.
    private var cursorTheme: OpaquePointer?
    private var cursorSurface: OpaquePointer?
    private var cursorHotspotX: Int32 = 0
    private var cursorHotspotY: Int32 = 0
    private var xdgWmBase: OpaquePointer?
    private(set) var surface: OpaquePointer?
    private var xdgSurface: OpaquePointer?
    private var xdgToplevel: OpaquePointer?
    private var decorationManager: OpaquePointer?
    private var decoration: OpaquePointer?
    private(set) var viewporter: OpaquePointer?
    private var surfaceViewport: OpaquePointer?
    private var fractionalScaleManager: OpaquePointer?
    private var fractionalScale: OpaquePointer?
    private var presentation: OpaquePointer?
    private var seat: OpaquePointer?
    private var dataDeviceManager: OpaquePointer?
    private var dataDeviceGlue: WaylandDataDeviceGlue?
    /// This window's clipboard, built once `wl_seat` and
    /// `wl_data_device_manager` are both bound -- see `bringUp()`. `nil` on a
    /// compositor that never advertises `wl_data_device_manager`: everything
    /// else about the session still works, just with no clipboard sharing.
    public private(set) var pasteboard: WaylandPasteboard?
    private var keyboard: OpaquePointer?
    private var pointer: OpaquePointer?
    private var relativePointerManager: OpaquePointer?
    private var pointerConstraints: OpaquePointer?
    private var shortcutsInhibitManager: OpaquePointer?
    /// Live only while the pointer is captured.
    private var lockedPointer: OpaquePointer?
    private var relativePointer: OpaquePointer?
    /// Live only while the compositor has been asked to leave its own chords
    /// alone -- see `WaylandShortcutInterceptor`.
    private var shortcutsInhibitor: OpaquePointer?
    private var dmabuf: OpaquePointer?
    private var eglWindow: OpaquePointer?
    private var outputRefreshMilliHertz: [OpaquePointer: Int] = [:]
    /// Which output this surface is on, so a machine with two screens of
    /// different rates paces against the one the window is actually on.
    private var currentOutput: OpaquePointer?
    /// A presentation report names the frame it is about only by the feedback
    /// object it arrives on, so the due time waits here until it does.
    private var feedbackDueTimes: [OpaquePointer: Int64] = [:]
    /// `feedbackDueTimes`'s keys, oldest first, so a compositor that stops
    /// answering `wp_presentation_feedback` at all cannot grow this without
    /// bound: the oldest pending feedback is destroyed once the cap is hit.
    private var feedbackOrder: [OpaquePointer] = []
    private static let maxPendingFeedbacks = 32

    private var state = WaylandSurfaceState()
    private var presenter: EGLFramePresenter?
    /// Built after the presenter, which needs a surface the compositor has
    /// already configured, and therefore cannot exist when this object's
    /// stored properties are first set.
    private var viewport: ClientViewportController!
    /// Built with the viewport, and told that this surface counts from its
    /// top-left corner rather than an AppKit view's bottom-left one.
    private var router: CanvasSurfaceEventRouter!
    private var capture: WaylandPointerCaptureController!
    private var keyboardState: WaylandKeyboardState?
    private var scroll = WaylandScrollFrameAccumulator()
    private var keyRepeat = KeyRepeatSchedule()
    nonisolated(unsafe) private var repeatTimerID: guint = 0
    nonisolated(unsafe) private var lockConfirmationTimerID: guint = 0
    /// The pointer's last surface-local position in logical units, which is
    /// where a button press and a scroll are reported to have happened.
    private var pointerX: Double = 0
    private var pointerY: Double = 0
    /// The serial of the last `wl_pointer.enter`, which is what a cursor
    /// change has to be attributed to.
    private var pointerEnterSerial: UInt32 = 0
    /// Which of this window's surfaces the pointer is on -- the main one, or
    /// one of the chrome's subsurfaces. `nil` while it is on none of them.
    private var pointerSurface: OpaquePointer?
    /// The newest input event serial this window has seen since it last lost
    /// keyboard focus, or `nil` while it has none -- what `WaylandPasteboard`
    /// needs `set_selection` to carry, since a stale one is ignored.
    private var latestInputSerial: UInt32?
    private var hasKeyboardFocus = false
    private var isFullscreen = false
    private let drops = ViewerFrameDropCounter()
    private let makeDecoder: VideoDecoderFactory
    private let initialStreamScalePreference: StreamScalePreference
    private let pointerSink: any CanvasInputSending
    private var decoder: (any VideoDecoding)?
    private var decodeQueue: VideoDecodeQueue?
    private var coalescer: DecodedFrameCoalescer?
    private var title: String
    private var hasConfigured = false
    private var boundGlobals: [String] = []
    nonisolated(unsafe) private var waylandSourceID: guint = 0

    /// Fires when the compositor's own close control was used, or when the
    /// connection to it went away. The viewer ends the session from here; the
    /// window is not torn down under a session that is still live.
    public var onClosed: (() -> Void)?

    /// Fires whenever captured-pointer mode is entered or left, by whichever
    /// of the three ways it can be: the viewer asked, the escape gesture, or
    /// the compositor ended the lock.
    public var onPointerCaptureChanged: ((Bool) -> Void)?

    /// The escape gesture's landing, for a caller that has somewhere to put
    /// the person: the window has already given the pointer and the keyboard
    /// back by the time this runs.
    public var onReleaseToLocalMachine: (() -> Void)?

    /// Runs every time this window gains keyboard focus, synchronously on
    /// the event loop's thread. Set by the live session's runner.
    public var onDidBecomeKey: (() -> Void)?

    /// Set when captured-pointer mode is to start at the first left click
    /// inside the window rather than only on request. That first click is
    /// the gesture, so it is not also sent to the far machine.
    public var capturesPointerAtFirstClick = false

    /// Answers whether a reserved chord was claimed for the host before
    /// ordinary routing. Held weakly: the interceptor is owned by the
    /// `SystemShortcutForwarder` that drives it, and it holds this window.
    public weak var shortcutInterceptor: WaylandShortcutInterceptor?

    /// The chrome around the picture -- the closures the viewer's controller
    /// sets, and what each of them was last told. Held here because an
    /// extension cannot store anything; everything that reads or writes it is
    /// in `WaylandSessionWindow+Chrome.swift`.
    var chrome = WaylandSessionChrome()

    /// Brings the window up: the surface is configured, decorated, sized and
    /// cleared before this returns, so the first frame has somewhere to go.
    ///
    /// The sink is where this window's pointer and keyboard geometry reports
    /// go. A session is the one that matters; the smoke check on a machine
    /// with no host to dial passes one that reports nowhere.
    public init(
        title: String,
        pointerSink: any CanvasInputSending,
        surfaceID: UInt32 = 0,
        initialStreamScalePreference: StreamScalePreference = .automatic,
        makeDecoder: @escaping VideoDecoderFactory
    ) throws {
        self.title = title
        self.pointerSink = pointerSink
        self.surfaceID = surfaceID
        self.makeDecoder = makeDecoder
        self.initialStreamScalePreference = initialStreamScalePreference
        guard let display = wl_display_connect(nil) else {
            throw WaylandSessionWindowError.displayUnavailable
        }
        self.display = display
        try bringUp()
    }

    /// The window a live session opens: everything this one reports goes to
    /// that session, scoped to this window's own surface.
    public convenience init(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32 = 0,
        initialStreamScalePreference: StreamScalePreference = .automatic,
        makeDecoder: @escaping VideoDecoderFactory
    ) throws {
        try self.init(
            title: title,
            pointerSink: surfaceID == 0 ? session : SurfaceScopedInputSink(session: session, surfaceID: surfaceID),
            surfaceID: surfaceID,
            initialStreamScalePreference: initialStreamScalePreference,
            makeDecoder: makeDecoder
        )
    }

    // MARK: - Bring-up

    private func bringUp() throws {
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        registry = wl_display_get_registry(display)
        wl_registry_add_listener(registry, registryListener, opaqueSelf)
        // Twice: the first round brings the advertisements in, the second lets
        // the listeners added during the first round settle.
        wl_display_roundtrip(display)
        wl_display_roundtrip(display)

        guard let compositor else { throw WaylandSessionWindowError.interfaceUnavailable("wl_compositor") }
        guard let xdgWmBase else { throw WaylandSessionWindowError.interfaceUnavailable("xdg_wm_base") }
        guard let seat else { throw WaylandSessionWindowError.interfaceUnavailable("wl_seat") }
        // Optional, unlike every other interface bound above: a compositor
        // with no clipboard support still gets a working session, just with
        // `pasteboard` left `nil`.
        if let dataDeviceManager {
            let dataDeviceGlue = WaylandDataDeviceGlue(dataDeviceManager: dataDeviceManager, seat: seat, display: display)
            self.dataDeviceGlue = dataDeviceGlue
            pasteboard = WaylandPasteboard(io: dataDeviceGlue) { [weak self] in self?.latestInputSerial }
        } else {
            print("Sensorium: this compositor has no wl_data_device_manager, so no clipboard sharing is available")
        }
        guard let surface = wl_compositor_create_surface(compositor) else {
            throw WaylandSessionWindowError.surfaceUnavailable
        }
        self.surface = surface
        wl_surface_add_listener(surface, surfaceListener, opaqueSelf)

        guard let xdgSurface = xdg_wm_base_get_xdg_surface(xdgWmBase, surface) else {
            throw WaylandSessionWindowError.surfaceUnavailable
        }
        self.xdgSurface = xdgSurface
        xdg_surface_add_listener(xdgSurface, xdgSurfaceListener, opaqueSelf)

        guard let toplevel = xdg_surface_get_toplevel(xdgSurface) else {
            throw WaylandSessionWindowError.surfaceUnavailable
        }
        xdgToplevel = toplevel
        xdg_toplevel_add_listener(toplevel, xdgToplevelListener, opaqueSelf)
        xdg_toplevel_set_app_id(toplevel, Self.applicationIdentifier)
        xdg_toplevel_set_title(toplevel, title)

        // The window's frame is the desktop's own, so it looks and behaves
        // like every other window on this machine. A compositor that draws
        // none leaves the surface undecorated, which is its decision to make.
        if let decorationManager {
            decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorationManager, toplevel)
            zxdg_toplevel_decoration_v1_set_mode(
                decoration,
                UInt32(ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE.rawValue)
            )
        }
        // Together these are what lets the picture be drawn in real pixels on
        // a scaled desktop: the compositor names the fraction it wants, and
        // the viewport maps a buffer of that many pixels back onto the
        // surface's own logical size.
        if let fractionalScaleManager {
            fractionalScale = wp_fractional_scale_manager_v1_get_fractional_scale(fractionalScaleManager, surface)
            wp_fractional_scale_v1_add_listener(fractionalScale, fractionalScaleListener, opaqueSelf)
        }
        if let viewporter {
            surfaceViewport = wp_viewporter_get_viewport(viewporter, surface)
        }
        if let presentation {
            wp_presentation_add_listener(presentation, presentationListener, opaqueSelf)
        }
        loadCursorTheme()

        wl_surface_commit(surface)
        while !hasConfigured {
            guard wl_display_dispatch(display) >= 0 else {
                throw WaylandSessionWindowError.displayUnavailable
            }
        }

        guard let eglWindow = wl_egl_window_create(
            surface,
            Int32(state.drawablePixelWidth),
            Int32(state.drawablePixelHeight)
        ) else {
            throw WaylandSessionWindowError.surfaceUnavailable
        }
        self.eglWindow = eglWindow
        let presenter = try EGLFramePresenter(
            waylandDisplay: display,
            eglWindow: eglWindow,
            pixelWidth: state.drawablePixelWidth,
            pixelHeight: state.drawablePixelHeight,
            drops: drops
        )
        self.presenter = presenter
        viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(SavedHost.remoteCanvasPreset.logicalWidth),
                logicalHeight: Double(SavedHost.remoteCanvasPreset.logicalHeight)
            ),
            pointerSink: pointerSink,
            framePresenter: presenter,
            initialStreamScalePreference: initialStreamScalePreference
        )
        // A Wayland surface counts from its top-left corner, which is the
        // corner the canvas counts from too, so nothing here is flipped.
        router = CanvasSurfaceEventRouter(viewport: viewport, sourceOrigin: .topLeft)
        capture = WaylandPointerCaptureController(locking: self) { [weak self] event in
            guard let self else { return }
            if case let .pointerCaptureChanged(isCaptured) = event {
                onPointerCaptureChanged?(isCaptured)
            }
            route(event)
        }
        applySurfaceGeometry()
        // The request first, then the clear: a frame callback is only
        // registered by the next commit on that surface, and the swap inside
        // `clear()` is that commit. Requesting it afterwards would leave the
        // request sitting on a surface nothing commits again, and no callback
        // would ever arrive to draw the first frame.
        requestFrameCallback()
        presenter.clear()
        wl_display_flush(display)
        attachToEventLoop()
        print("Sensorium: \(boundGlobalsDescription)")
    }

    /// Hands the Wayland connection to the event loop this viewer runs on, so
    /// the compositor's events arrive alongside everything else rather than
    /// through a read loop of their own.
    private func attachToEventLoop() {
        waylandSourceID = g_unix_fd_add(
            wl_display_get_fd(display),
            G_IO_IN,
            { _, condition, data in
                guard let data else { return 0 }
                let window = Unmanaged<WaylandSessionWindow>.fromOpaque(data).takeUnretainedValue()
                return MainActor.assumeIsolated { window.readCompositorEvents(condition: condition) }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func readCompositorEvents(condition: GIOCondition) -> gboolean {
        guard condition.rawValue & (G_IO_ERR.rawValue | G_IO_HUP.rawValue) == 0 else {
            reportClosed()
            return 0
        }
        guard wl_display_dispatch(display) >= 0 else {
            reportClosed()
            return 0
        }
        wl_display_flush(display)
        return 1
    }

    // MARK: - SessionCanvasWindow

    /// Wires this window's decode path: the same portable pieces the macOS
    /// window uses, in the same order, with this platform's own decoder.
    public func startDecoding(
        latency: SessionLatencyMonitor? = nil,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? = nil
    ) throws {
        let viewport = viewport!
        let surfaceID = surfaceID
        presenter?.onFramePresented = { [weak self] timing, presentedAtNanoseconds in
            if let self, let first = self.onFirstPresentedFrame {
                self.onFirstPresentedFrame = nil
                first()
            }
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

    public nonisolated func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        try videoSink.receive(packet, receivedAtNanoseconds: receivedAtNanoseconds)
    }

    public func stopDecoding() {
        presenter?.onFramePresented = nil
        presenter?.discardPendingFrames()
        videoSink.attach(nil)
        decodeQueue?.stop()
        decodeQueue = nil
        coalescer?.stop()
        coalescer = nil
        decoder?.reset()
        decoder = nil
        videoSink.receipts.reset()
    }

    public func canvasObserver() -> ClientViewportController {
        viewport
    }

    /// The diagnostics panel's own readings. Arrives on every receive tick,
    /// and is drawn only while the panel is open.
    public func updateSessionHUD(_ snapshot: SessionHUDSnapshot) {
        applyDiagnostics(snapshot)
    }

    public var decoderHardwareAcceleration: DecoderHardwareAccelerationStatus? {
        decoder?.hardwareAcceleration
    }

    public var isPointerCaptured: Bool { capture?.isCapturing ?? false }

    public var presentCompletionLatency: LatencySamples {
        presenter?.completionLatency ?? LatencySamples()
    }

    public var presentationHoldNanoseconds: Int64 {
        presenter?.holdNanoseconds ?? 0
    }

    /// What this window really put on screen, and the mean of its own
    /// completion samples, for a run that reports what it did at the end.
    public var presentedFrameCount: Int { presenter?.presentedFrameCount ?? 0 }

    /// Gives the picture back exactly the top edge a pinned shortcut strip's
    /// own band is not claiming right now, in drawable pixels -- what
    /// `ClientCanvasWindowController` does to its video view on macOS.
    func setVideoTopInset(pixels: Int) {
        presenter?.videoTopInsetPixels = pixels
    }

    /// Tells the session how big the picture is now, which is the window
    /// minus whatever band a pinned strip has taken. The mapper turns a
    /// pointer position into a place on the far machine against exactly this
    /// area, so the two have to be reported from the same rule.
    func reportVideoBounds() {
        guard router != nil else { return }
        let area = videoArea
        route(.boundsChanged(width: area.width, height: area.height))
        // And the same area in the pixels the host streams at: a band the
        // picture cannot use is a band nobody should be encoding.
        route(.drawableSizeChanged(
            pixelWidth: Double(state.drawablePixelWidth),
            pixelHeight: WaylandOverlayLayout.videoDrawablePixelHeight(
                drawablePixelHeight: Double(state.drawablePixelHeight),
                topInset: chrome.videoTopInset,
                scale: state.scale
            )
        ))
    }

    /// The compositor's own scale for this surface, which is what turns its
    /// logical size into the pixels the presenter draws.
    var surfaceScale: Double { state.scale }

    /// The window's size in the logical units a pointer position and a
    /// subsurface's placement are both counted in.
    var logicalSize: (width: Double, height: Double) {
        (Double(state.logicalWidth), Double(state.logicalHeight))
    }

    /// Whether another part of this process held the GL context when this
    /// window drew its first frame -- `nil` until it has drawn one. Reported
    /// by `WaylandSessionTrace` and by nothing else.
    var foundForeignGLContextAtFirstDraw: Bool? { presenter?.foundForeignContextAtFirstDraw }

    /// What the first real draw found -- see
    /// `EGLFramePresenter.onFirstDrawDiagnostics`. Set by a run that asked
    /// for a trace, and by nothing else.
    public var onFirstDrawDiagnostics: ((String) -> Void)? {
        get { presenter?.onFirstDrawDiagnostics }
        set { presenter?.onFirstDrawDiagnostics = newValue }
    }

    /// Fired once, when a frame first really reaches the screen, and then
    /// dropped. Set by `WaylandSessionTrace` and by nothing else.
    var onFirstPresentedFrame: (() -> Void)?
    public var meanPresentLatencyNanoseconds: Int64? { presenter?.meanCompletionLatencyNanoseconds }

    public var droppedFrameCount: Int { drops.total }
    public var droppedBeforeDecodeCount: Int { drops.droppedBeforeDecode }
    public var droppedBeforePresentCount: Int { drops.droppedBeforePresent }

    // MARK: - Window

    /// Called once the host's own name is known, replacing whatever
    /// address-derived title the window opened with.
    public func updateTitle(_ title: String) {
        self.title = title
        guard let xdgToplevel else { return }
        xdg_toplevel_set_title(xdgToplevel, title)
        wl_display_flush(display)
    }

    /// What this window bound and at which version, for the run's own log.
    public var boundGlobalsDescription: String {
        boundGlobals.isEmpty
            ? "no Wayland globals bound"
            : "Wayland globals bound: " + boundGlobals.joined(separator: ", ")
    }

    /// The buffer's size in real pixels, which is what the host is told this
    /// viewer needs.
    public var drawablePixelSize: (width: Int, height: Int) {
        (state.drawablePixelWidth, state.drawablePixelHeight)
    }

    /// The refresh interval this window is pacing against, as the output it
    /// is on or the compositor's own presentation reports named it.
    public var refreshIntervalNanoseconds: Int64 { state.refreshIntervalNanoseconds }

    public var isClosed: Bool { state.isClosed }

    /// Takes the window off the screen. Used when the viewer is leaving, after
    /// the session it was showing has already ended.
    public func close() {
        // Before anything else, and unconditionally: a window that went away
        // mid-capture must not leave a lock the compositor is still holding.
        capture?.reset()
        cancelKeyRepeat()
        // Before the surface they are subsurfaces of goes away.
        tearDownChrome()
        destroyShortcutInhibitor()
        pasteboard?.clear()
        dataDeviceGlue?.tearDown()
        dataDeviceGlue = nil
        // The seat's devices are given back rather than dropped: a pointer or
        // keyboard this window still holds would keep delivering events into
        // a surface that is about to stop existing.
        if let pointer {
            wl_pointer_release(pointer)
            self.pointer = nil
        }
        if let keyboard {
            wl_keyboard_release(keyboard)
            self.keyboard = nil
        }
        keyboardState = nil
        if waylandSourceID != 0 {
            g_source_remove(waylandSourceID)
            waylandSourceID = 0
        }
        // Torn down explicitly, and before the native window it drew into is
        // destroyed: `viewport` was built with this presenter and has no way
        // to let go of it, so `deinit` running only once that reference is
        // gone as well is not soon enough.
        presenter?.tearDown()
        presenter = nil
        if let eglWindow {
            wl_egl_window_destroy(eglWindow)
            self.eglWindow = nil
        }
        if let xdgToplevel {
            xdg_toplevel_destroy(xdgToplevel)
            self.xdgToplevel = nil
        }
        if let xdgSurface {
            xdg_surface_destroy(xdgSurface)
            self.xdgSurface = nil
        }
        if let cursorSurface {
            wl_surface_destroy(cursorSurface)
            self.cursorSurface = nil
        }
        if let cursorTheme {
            wl_cursor_theme_destroy(cursorTheme)
            self.cursorTheme = nil
        }
        if let surface {
            wl_surface_destroy(surface)
            self.surface = nil
        }
        wl_display_flush(display)
    }

    /// `close()` is the supported teardown path; this only disarms the GLib
    /// sources a window dropped without it would otherwise leave dispatching.
    deinit {
        if waylandSourceID != 0 { g_source_remove(waylandSourceID) }
        if repeatTimerID != 0 { g_source_remove(repeatTimerID) }
        if lockConfirmationTimerID != 0 { g_source_remove(lockConfirmationTimerID) }
    }

    // MARK: - Compositor events

    fileprivate func bindGlobal(name: UInt32, interface: String, version: UInt32) {
        func bind(_ wanted: UInt32) -> OpaquePointer? {
            let negotiated = min(version, wanted)
            guard let bound = interface.withCString({
                sensorium_wayland_bind(registry, name, $0, negotiated)
            }) else {
                return nil
            }
            boundGlobals.append("\(interface) v\(negotiated)")
            return OpaquePointer(bound)
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        switch interface {
        case "wl_compositor":
            compositor = bind(4)
        case "wl_shm":
            shm = bind(1)
        case "wl_subcompositor":
            subcompositor = bind(1)
        case "xdg_wm_base":
            xdgWmBase = bind(6)
            xdg_wm_base_add_listener(xdgWmBase, xdgWmBaseListener, opaqueSelf)
        case "zxdg_decoration_manager_v1":
            decorationManager = bind(1)
        case "wp_viewporter":
            viewporter = bind(1)
        case "wp_fractional_scale_manager_v1":
            fractionalScaleManager = bind(1)
        case "wp_presentation":
            presentation = bind(1)
        case "zwp_relative_pointer_manager_v1":
            relativePointerManager = bind(1)
        case "zwp_pointer_constraints_v1":
            pointerConstraints = bind(1)
        case "zwp_keyboard_shortcuts_inhibit_manager_v1":
            shortcutsInhibitManager = bind(1)
        case "zwp_linux_dmabuf_v1":
            dmabuf = bind(4)
        case "wl_data_device_manager":
            dataDeviceManager = bind(4)
        case "wl_seat":
            // Version 8 for the pointer it hands out: that is where
            // `axis_value120` arrives, which is the only report that says how
            // far a high-resolution wheel really turned.
            seat = bind(8)
            wl_seat_add_listener(seat, seatListener, opaqueSelf)
        case "wl_output":
            guard let output = bind(2) else { return }
            outputRefreshMilliHertz[output] = 0
            wl_output_add_listener(output, outputListener, opaqueSelf)
        default:
            return
        }
    }

    fileprivate func handleToplevelConfigure(width: Int32, height: Int32, isFullscreen: Bool) {
        self.isFullscreen = isFullscreen
        guard state.configure(logicalWidth: Int(width), logicalHeight: Int(height)) else { return }
        applySurfaceGeometry()
    }

    fileprivate func handleSurfaceConfigure(serial: UInt32) {
        xdg_surface_ack_configure(xdgSurface, serial)
        hasConfigured = true
    }

    fileprivate func handlePreferredScale(numerator120: UInt32) {
        guard state.setFractionalScale(numerator120: Int(numerator120)) else { return }
        applySurfaceGeometry()
    }

    fileprivate func handleOutputMode(output: OpaquePointer, isCurrent: Bool, refreshMilliHertz: Int32) {
        guard isCurrent else { return }
        outputRefreshMilliHertz[output] = Int(refreshMilliHertz)
        guard currentOutput == nil || output == currentOutput else { return }
        _ = state.setOutputRefresh(milliHertz: Int(refreshMilliHertz))
    }

    fileprivate func handleSurfaceEnter(output: OpaquePointer?) {
        currentOutput = output
        guard let output, let refresh = outputRefreshMilliHertz[output] else { return }
        _ = state.setOutputRefresh(milliHertz: refresh)
    }

    fileprivate func handlePresentationClock(_ clockID: UInt32) {
        // A report on any other clock cannot be compared against the times
        // this viewer stamps its own frames with, so it is not used at all and
        // the swap's own return stays the completion signal.
        guard clockID == UInt32(CLOCK_MONOTONIC) else { return }
        presenter?.measuresCompletionAtSwap = false
    }

    fileprivate func handlePresented(
        feedback: OpaquePointer,
        secondsHigh: UInt32,
        secondsLow: UInt32,
        nanoseconds: UInt32,
        refreshNanoseconds: UInt32
    ) {
        defer {
            feedbackDueTimes[feedback] = nil
            feedbackOrder.removeAll { $0 == feedback }
            wp_presentation_feedback_destroy(feedback)
        }
        if refreshNanoseconds > 0 {
            _ = state.setOutputRefresh(
                milliHertz: Int((1_000_000_000_000.0 / Double(refreshNanoseconds)).rounded())
            )
        }
        guard let dueAt = feedbackDueTimes[feedback], let presenter else { return }
        let seconds = Int64(UInt64(secondsHigh) << 32 | UInt64(secondsLow))
        presenter.recordPresentationCompleted(
            dueAtNanoseconds: dueAt,
            presentedAtNanoseconds: seconds * 1_000_000_000 + Int64(nanoseconds)
        )
    }

    fileprivate func handleFeedbackDiscarded(feedback: OpaquePointer) {
        feedbackDueTimes[feedback] = nil
        feedbackOrder.removeAll { $0 == feedback }
        wp_presentation_feedback_destroy(feedback)
    }

    /// One frame callback: draw whatever is due, then ask for the next one.
    ///
    /// The next callback is always requested, whether or not anything was
    /// drawn. A compositor sends one callback per request, so a callback that
    /// asked for nothing further would be the last this window ever saw and
    /// the picture would stop at whatever happened to be on screen.
    fileprivate func handleFrameCallback(_ callback: OpaquePointer) {
        wl_callback_destroy(callback)
        requestFrameCallback()
        // Once per compositor round: a strip that was due to close, a notice
        // whose time is up, and any overlay drawing that had to wait for a
        // buffer the compositor was still reading.
        serviceChrome()
        guard let presenter, let surface else { return }
        var feedback: OpaquePointer?
        if let presentation, !presenter.measuresCompletionAtSwap {
            feedback = wp_presentation_feedback(presentation, surface)
            wp_presentation_feedback_add_listener(
                feedback,
                presentationFeedbackListener,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        let dueAt = presenter.drawIfDue(nowNanoseconds: MonotonicClock.nowNanoseconds())
        if dueAt != nil {
            // The swap that carried it committed the parent surface, so the
            // overlays held to it have arrived and can go back to their own
            // clock.
            releaseOverlaysAfterPicture()
        }
        if let feedback {
            if let dueAt {
                feedbackDueTimes[feedback] = dueAt
                feedbackOrder.append(feedback)
                if feedbackOrder.count > Self.maxPendingFeedbacks {
                    let oldest = feedbackOrder.removeFirst()
                    feedbackDueTimes[oldest] = nil
                    wp_presentation_feedback_destroy(oldest)
                }
            } else {
                wp_presentation_feedback_destroy(feedback)
            }
        }
        if dueAt == nil {
            // Nothing was due, so nothing was swapped, and the frame request
            // above still has to be committed for the compositor to answer it.
            wl_surface_commit(surface)
        }
    }

    fileprivate func reportClosed() {
        guard state.close() else { return }
        onClosed?()
    }

    fileprivate func registerSeatDevices(seat: OpaquePointer, capabilities: UInt32) {
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        if capabilities & UInt32(WL_SEAT_CAPABILITY_KEYBOARD.rawValue) != 0, keyboard == nil {
            keyboard = wl_seat_get_keyboard(seat)
            wl_keyboard_add_listener(keyboard, keyboardListener, opaqueSelf)
        }
        if capabilities & UInt32(WL_SEAT_CAPABILITY_POINTER.rawValue) != 0, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            wl_pointer_add_listener(pointer, pointerListener, opaqueSelf)
        }
    }

    // MARK: - Keyboard

    fileprivate func handleKeymap(format: UInt32, descriptor: Int32, size: UInt32) {
        guard format == UInt32(WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.rawValue) else {
            // Not a keymap this viewer can read, and the descriptor is this
            // client's own to close either way.
            Glibc.close(descriptor)
            reportKeymapFallback()
            return
        }
        // The descriptor is closed by the keyboard state, whether or not the
        // keymap compiled.
        guard let compositorKeymap = WaylandKeyboardState(keymapFileDescriptor: descriptor, size: Int(size)) else {
            reportKeymapFallback()
            return
        }
        replaceKeyboardState(with: compositorKeymap)
    }

    /// Swaps in a freshly compiled keymap, keeping the outgoing one's held
    /// modifiers from being dropped silently: a state already live when a
    /// second `wl_keyboard.keymap` arrives is told its focus left before it
    /// is replaced, so its own tracker and the host agree that nothing is
    /// held, the same way an ordinary `wl_keyboard.leave` would.
    private func replaceKeyboardState(with fresh: WaylandKeyboardState) {
        if let previous = keyboardState {
            previous.focusLeft()
            route(.focusLost)
        }
        keyboardState = fresh
    }

    /// A keymap that would not compile leaves this machine's own default in
    /// its place: a keyboard that types nothing at all would be worse, and
    /// the wire carries physical positions, which every layout shares.
    private func reportKeymapFallback() {
        guard keyboardState == nil else { return }
        keyboardState = WaylandKeyboardState()
        print("Sensorium: this compositor's keymap could not be read; the system default keymap is in use")
    }

    fileprivate func handleKeyboardEnter() {
        hasKeyboardFocus = true
        // Keys already held when the keyboard arrived are deliberately not
        // replayed: the person did not press them into this window.
        shortcutInterceptor?.keyboardDidEnter()
        // `noteInputSerial` has already set `latestInputSerial` to this same
        // enter's serial, which is what a write held while unfocused is
        // flushed with.
        if let serial = latestInputSerial {
            pasteboard?.keyboardDidEnter(serial: serial)
        }
        // After the held write above is flushed, so a poll this triggers
        // reads the selection as it now stands.
        onDidBecomeKey?()
    }

    fileprivate func handleKeyboardLeave() {
        hasKeyboardFocus = false
        latestInputSerial = nil
        cancelKeyRepeat()
        keyRepeat.focusLost()
        keyboardState?.focusLeft()
        capture?.endIfNeeded()
        route(.focusLost)
    }

    /// The newest input event serial, remembered for `WaylandPasteboard`'s
    /// `set_selection` -- see `latestInputSerial`'s own doc comment. Fed only
    /// from the keyboard's own `enter` and `key` events: a pointer button's
    /// serial belongs to a different input stream and a compositor may
    /// reject `set_selection` called with it, so it is never passed here.
    /// Called directly from the listener closures below rather than threaded
    /// through the handler functions' own parameters, so this stays the one
    /// change those functions need.
    fileprivate func noteInputSerial(_ serial: UInt32) {
        latestInputSerial = serial
    }

    fileprivate func handleKeyboardModifiers(depressed: UInt32, latched: UInt32, locked: UInt32, group: UInt32) {
        keyboardState?.reconcileModifiers(depressed: depressed, latched: latched, locked: locked, group: group)
    }

    fileprivate func handleRepeatInfo(rate: Int32, delayMilliseconds: Int32) {
        keyRepeat.setRepeatInfo(rate: Int(rate), delayMilliseconds: Int(delayMilliseconds))
    }

    fileprivate func handleKey(evdev: UInt32, isDown: Bool) {
        if isDown {
            if let delay = keyRepeat.keyDown(evdev: evdev, isModifier: EvdevKeycodeTable.isModifierKey(evdev: evdev)) {
                armKeyRepeat(afterMilliseconds: delay)
            }
        } else if keyRepeat.keyUp(evdev: evdev) {
            cancelKeyRepeat()
        }
        apply(WaylandKeyPath.destination(evdev: evdev, isDown: isDown, keyboard: keyboardState))
    }

    /// One key, acted on where `WaylandKeyPath` said it goes. The window's
    /// own half of that decision and nothing more: the order the questions
    /// were asked in lives there, so it is answerable without a compositor.
    private func apply(_ destination: WaylandKeyDestination) {
        switch destination {
        case let .shortcutStrip(isDown):
            if isDown { toggleShortcutStrip() }
        case let .sessionControls(isDown):
            if isDown { openSessionControls() }
        case let .reservedChord(chord, event, isDown):
            // A chord that means one thing is not a chord to hold down.
            cancelKeyRepeat()
            keyRepeat.focusLost()
            if shortcutInterceptor?.claim(chord: chord, isDown: isDown) == true { return }
            if chord == SystemShortcutCatalog.escapeGesture {
                if isDown { releaseToLocalMachine() }
                return
            }
            route(event)
        case let .canvas(event):
            route(event)
        case .dropped:
            break
        }
    }

    /// Wayland leaves key repeat to the client, so the repeats a held key
    /// produces are this timer's, at the rate and delay the compositor asked
    /// for.
    private func armKeyRepeat(afterMilliseconds delay: Int) {
        cancelKeyRepeat()
        guard delay > 0 else { return }
        repeatTimerID = g_timeout_add(
            guint(delay),
            { data in
                guard let data else { return 0 }
                let window = Unmanaged<WaylandSessionWindow>.fromOpaque(data).takeUnretainedValue()
                return MainActor.assumeIsolated { window.fireKeyRepeat() }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func cancelKeyRepeat() {
        guard repeatTimerID != 0 else { return }
        g_source_remove(repeatTimerID)
        repeatTimerID = 0
    }

    /// Always removes the source that fired and arms the next one, because
    /// the first interval is the compositor's delay and every one after it is
    /// its rate.
    private func fireKeyRepeat() -> gboolean {
        repeatTimerID = 0
        guard let due = keyRepeat.fire() else { return 0 }
        let destination = WaylandKeyPath.destination(evdev: due.key, isDown: true, keyboard: keyboardState)
        // A key with nowhere to go stops repeating rather than repeating
        // into nothing.
        guard destination != .dropped else { return 0 }
        apply(destination)
        armKeyRepeat(afterMilliseconds: due.nextDelayMilliseconds)
        return 0
    }

    // MARK: - Pointer

    /// A cursor image belongs to the client the pointer is over, and is set
    /// against the serial of the event that brought it here. Captured-pointer
    /// mode hides it; otherwise this window's own loaded theme is shown, or
    /// nothing at all where no theme could be loaded.
    fileprivate func handlePointerEnter(serial: UInt32, surface: OpaquePointer?, x: Double, y: Double) {
        pointerEnterSerial = serial
        // Which surface the pointer is over decides where its events go: this
        // window's chrome is made of subsurfaces of its own, and the
        // compositor names whichever one the pointer is really on.
        pointerSurface = surface
        guard !chromePointerEntered(surface: surface, x: x, y: y) else {
            showCursor()
            return
        }
        pointerX = x
        pointerY = y - chrome.videoTopInset
        if capture?.isCapturing == true {
            hideCursor()
        } else {
            showCursor()
        }
    }

    /// Nothing is reported to the session: a pointer that left while the lock
    /// holds it has not really gone anywhere, and one that left without a
    /// lock is the same as a cursor leaving an AppKit view, which reports
    /// nothing either. The chrome still has to hear it, or a strip opened by
    /// a hover would never close.
    fileprivate func handlePointerLeave(surface: OpaquePointer?) {
        chromePointerLeft(surface: surface)
        if surface == pointerSurface {
            pointerSurface = nil
        }
    }

    fileprivate func handlePointerMotion(x: Double, y: Double) {
        guard !chromePointerMoved(surface: pointerSurface, x: x, y: y) else { return }
        // A pinned strip moved the picture down the window, and the far
        // machine is told where the pointer is on the picture.
        pointerX = x
        pointerY = y - chrome.videoTopInset
        // While the pointer is locked it is not really where the compositor
        // last saw it, and relative motion is what the session is being sent.
        guard capture?.isCapturing != true else { return }
        route(.pointerMoved(x: pointerX, y: pointerY))
    }

    fileprivate func handleRelativeMotion(deltaX: Double, deltaY: Double) {
        guard capture?.isCapturing == true else { return }
        route(.pointerMovedRelative(deltaX: deltaX, deltaY: deltaY))
    }

    fileprivate func handlePointerButton(code: UInt32, isDown: Bool) {
        guard let button = WaylandPointerButtonMap.button(forEvdev: code) else { return }
        // A press aimed at this window's own chrome is not the far machine's,
        // and neither is the release that ends it -- `CanvasChromeClickPolicy`
        // decides both halves, so a drag that ends over the strip still lets
        // go of the button on the machine being worked on.
        let isOverChrome = chromeContainsPointer(surface: pointerSurface)
        if isDown {
            let forwards = chrome.clicks.shouldForwardPress(button, isOverChrome: isOverChrome)
            if !forwards {
                chromePressed(surface: pointerSurface, button: button)
                return
            }
        } else if !chrome.clicks.shouldForwardRelease(button) {
            return
        }
        if capturesPointerAtFirstClick, button == .left, isDown, capture?.isCapturing == false {
            capturesPointerAtFirstClick = false
            togglePointerCapture()
            return
        }
        route(.pointerButton(button: button, isDown: isDown, x: pointerX, y: pointerY))
    }

    fileprivate func handleAxis(_ axis: WaylandScrollAxis, value: Double) {
        scroll.axis(axis, value: value)
    }

    fileprivate func handleAxisValue120(_ axis: WaylandScrollAxis, value120: Int32) {
        scroll.axisValue120(axis, value120: value120)
    }

    fileprivate func handleAxisSource(_ source: WaylandScrollAxisSource) {
        scroll.axisSource(source)
    }

    fileprivate func handleAxisStop(_ axis: WaylandScrollAxis) {
        scroll.axisStop(axis)
    }

    fileprivate func handlePointerFrame() {
        guard let event = scroll.frame(x: pointerX, y: pointerY) else { return }
        route(event)
    }

    // MARK: - Captured pointer

    /// Enters or leaves captured-pointer mode. The one way in and the one way
    /// out, so the compositor's lock and this window's bookkeeping can never
    /// disagree -- see `WaylandPointerCaptureController`.
    public func togglePointerCapture() {
        capture?.toggle()
    }

    public func endPointerCaptureIfNeeded() {
        capture?.endIfNeeded()
    }

    public func lockPointer() {
        guard let pointerConstraints, let surface, let pointer else { return }
        lockedPointer = zwp_pointer_constraints_v1_lock_pointer(
            pointerConstraints,
            surface,
            pointer,
            // No region: the whole surface, which is the only thing a locked
            // pointer can be locked to here.
            nil,
            UInt32(ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT.rawValue)
        )
        zwp_locked_pointer_v1_add_listener(
            lockedPointer,
            lockedPointerListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let relativePointerManager {
            relativePointer = zwp_relative_pointer_manager_v1_get_relative_pointer(relativePointerManager, pointer)
            zwp_relative_pointer_v1_add_listener(
                relativePointer,
                relativePointerListener,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        hideCursor()
        wl_display_flush(display)
        armLockConfirmation()
    }

    public func unlockPointer() {
        cancelLockConfirmation()
        if let lockedPointer {
            zwp_locked_pointer_v1_destroy(lockedPointer)
            self.lockedPointer = nil
        }
        if let relativePointer {
            zwp_relative_pointer_v1_destroy(relativePointer)
            self.relativePointer = nil
        }
        // Wayland has no request that asks for the cursor back on its own:
        // the client that has the pointer sets whatever image it wants shown
        // over it, which is why the theme this window loaded is set again
        // here rather than left to the compositor.
        showCursor()
        wl_display_flush(display)
    }

    private func hideCursor() {
        guard let pointer else { return }
        wl_pointer_set_cursor(pointer, pointerEnterSerial, nil, 0, 0)
    }

    /// Restores this window's own cursor image, for every path that leaves
    /// captured-pointer mode -- the escape gesture, the compositor ending the
    /// lock, and the confirmation timeout -- as well as an ordinary
    /// `wl_pointer.enter` while not captured. Nothing is set where no theme
    /// could be loaded, which leaves whatever the compositor already drew.
    private func showCursor() {
        guard let pointer, let cursorSurface else { return }
        wl_pointer_set_cursor(pointer, pointerEnterSerial, cursorSurface, cursorHotspotX, cursorHotspotY)
    }

    /// Loads this desktop's default pointer image once `wl_shm` is bound, so
    /// there is something for `showCursor()` to set. A theme, a cursor
    /// inside it, or the surface to hold its image can each fail to become
    /// available; any of those leaves the cursor untouched rather than
    /// hidden, which is why every step here is a `guard` that logs once and
    /// returns rather than throwing.
    private func loadCursorTheme() {
        guard let shm, let compositor else { return }
        let environment = ProcessInfo.processInfo.environment
        // Read here rather than left to `wl_cursor_theme_load` itself: the
        // installed header documents neither variable, so this window does
        // not assume the library consults them.
        let size = environment["XCURSOR_SIZE"].flatMap(Int32.init) ?? 24
        let themeName = environment["XCURSOR_THEME"]
        // Loaded at this fixed size rather than scaled by the output's own
        // factor: matching a HiDPI output would also mean calling
        // `wl_surface_set_buffer_scale` on the cursor surface and dividing
        // its hotspot by that same factor, which this window does not do --
        // the pointer stays a correctly shaped arrow either way, just not
        // scaled to the output's density.
        let theme = themeName.map { name in
            name.withCString { wl_cursor_theme_load($0, size, shm) }
        } ?? wl_cursor_theme_load(nil, size, shm)
        guard let theme else {
            print("Sensorium: this desktop's cursor theme could not be loaded, so the pointer image is left to the compositor")
            return
        }
        guard let cursor = wl_cursor_theme_get_cursor(theme, "default")
            ?? wl_cursor_theme_get_cursor(theme, "left_ptr"),
            cursor.pointee.image_count > 0,
            let image = cursor.pointee.images[0],
            let buffer = wl_cursor_image_get_buffer(image) else {
            wl_cursor_theme_destroy(theme)
            print("Sensorium: this desktop's cursor theme has neither a \"default\" nor a \"left_ptr\" cursor, so the pointer image is left to the compositor")
            return
        }
        guard let surface = wl_compositor_create_surface(compositor) else {
            wl_cursor_theme_destroy(theme)
            return
        }
        wl_surface_attach(surface, buffer, 0, 0)
        wl_surface_damage(surface, 0, 0, Int32(image.pointee.width), Int32(image.pointee.height))
        wl_surface_commit(surface)
        cursorTheme = theme
        cursorSurface = surface
        cursorHotspotX = Int32(image.pointee.hotspot_x)
        cursorHotspotY = Int32(image.pointee.hotspot_y)
    }

    fileprivate func handlePointerLocked() {
        capture?.compositorConfirmedLock()
    }

    fileprivate func handlePointerUnlocked() {
        capture?.compositorEndedLock()
    }

    private func armLockConfirmation() {
        cancelLockConfirmation()
        lockConfirmationTimerID = g_timeout_add(
            guint(WaylandPointerCaptureController.lockConfirmationSeconds * 1000),
            { data in
                guard let data else { return 0 }
                let window = Unmanaged<WaylandSessionWindow>.fromOpaque(data).takeUnretainedValue()
                return MainActor.assumeIsolated { window.reportLockRefusedIfUnconfirmed() }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func cancelLockConfirmation() {
        guard lockConfirmationTimerID != 0 else { return }
        g_source_remove(lockConfirmationTimerID)
        lockConfirmationTimerID = 0
    }

    private func reportLockRefusedIfUnconfirmed() -> gboolean {
        lockConfirmationTimerID = 0
        guard capture?.lockConfirmationDeadlinePassed() == true else { return 0 }
        print("Sensorium: this compositor did not lock the pointer, so captured-pointer mode is not available")
        return 0
    }

    // MARK: - Shortcut forwarding

    public var viewerWindowState: ViewerWindowState {
        ViewerWindowState(surfaceID: surfaceID, hasKeyFocus: hasKeyboardFocus, isFullscreen: isFullscreen)
    }

    public func forwardShortcut(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags) {
        route(.key(keyCode: keyCode, isDown: isDown, modifiers: modifiers))
    }

    /// The escape gesture's landing. There is no hiding an application on
    /// Wayland -- a client cannot take the desktop's focus away from itself
    /// -- so the window is minimised instead, which is the nearest thing the
    /// desktop offers.
    public func releaseToLocalMachine() {
        capture?.endIfNeeded()
        route(.focusLost)
        if let xdgToplevel {
            xdg_toplevel_set_minimized(xdgToplevel)
            wl_display_flush(display)
        }
        onReleaseToLocalMachine?()
    }

    public func requestShortcutInhibitor() -> Bool {
        guard let shortcutsInhibitManager, let surface, let seat, shortcutsInhibitor == nil else { return false }
        guard let inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(
            shortcutsInhibitManager,
            surface,
            seat
        ) else {
            return false
        }
        shortcutsInhibitor = inhibitor
        zwp_keyboard_shortcuts_inhibitor_v1_add_listener(
            inhibitor,
            shortcutsInhibitorListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        wl_display_flush(display)
        return true
    }

    public func destroyShortcutInhibitor() {
        guard let shortcutsInhibitor else { return }
        zwp_keyboard_shortcuts_inhibitor_v1_destroy(shortcutsInhibitor)
        self.shortcutsInhibitor = nil
        wl_display_flush(display)
    }

    fileprivate func handleShortcutsInhibitorActive() {
        shortcutInterceptor?.inhibitorBecameActive()
    }

    fileprivate func handleShortcutsInhibitorInactive() {
        shortcutInterceptor?.inhibitorBecameInactive()
    }

    private func requestFrameCallback() {
        guard let surface, let callback = wl_surface_frame(surface) else { return }
        wl_callback_add_listener(callback, frameListener, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Re-sizes everything that has to follow the surface: the buffer EGL
    /// draws into, the viewport that maps it back onto the surface's logical
    /// size, and the host, which streams at the resolution this viewer says it
    /// needs.
    private func applySurfaceGeometry() {
        if let eglWindow {
            wl_egl_window_resize(
                eglWindow,
                Int32(state.drawablePixelWidth),
                Int32(state.drawablePixelHeight),
                0,
                0
            )
        }
        presenter?.resize(pixelWidth: state.drawablePixelWidth, pixelHeight: state.drawablePixelHeight)
        if let surfaceViewport {
            wp_viewport_set_destination(surfaceViewport, Int32(state.logicalWidth), Int32(state.logicalHeight))
        }
        // Every overlay commits with the picture from here until the picture
        // has been drawn at the new size, so no frame shows one without the
        // other.
        holdOverlaysForResize()
        // The chrome is laid out against the window's logical size and drawn
        // at its scale, so both have to be re-read whenever either changes.
        relayoutChrome()
        guard router != nil else { return }
        // Two different sizes, and the difference matters: the pointer is
        // reported in the surface's logical units, while what is worth
        // streaming is decided by its real pixels.
        reportVideoBounds()
    }

    /// Everything this window reports to the session goes through here, so
    /// there is one place where a surface event becomes canvas input.
    func route(_ event: CanvasSurfaceEvent) {
        guard let router else { return }
        Task { await router.route(event) }
    }

    /// The identifier a desktop matches this window to its own launcher entry
    /// by.
    private static let applicationIdentifier = "com.sensorium.viewer"
}

// MARK: - Listeners
//
// Each listener is one C struct of function pointers, made once and shared by
// every window: which window an event is for travels in the user data pointer,
// never in the listener itself. They live on the heap because a proxy keeps
// the address it was given for as long as it lives. Every event the negotiated
// version of an object can send has a handler, because libwayland calls
// whatever is in the slot without checking it first.

/// Core-protocol listeners start from the zeroed `init()` and set only the
/// events their object's bound version can deliver. libwayland aborts on an
/// event whose handler is NULL, but a compositor never sends an event newer
/// than the bound version, so leaving the rest unset is safe. It also keeps
/// these listeners compiling as system libwayland headers add events, such as
/// `wl_pointer.warp` in 1.26, and against older headers that lack the newer
/// ones. Raising a bound version in `bindGlobal` means setting the events it
/// adds. The extension-protocol listeners use generated headers checked into
/// this repository, so a memberwise init there only changes when those are
/// regenerated.
private func heapListener<Listener>(_ value: Listener) -> UnsafeMutablePointer<Listener> {
    let pointer = UnsafeMutablePointer<Listener>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}

/// One Wayland proxy on its way from a C callback into the actor that owns
/// it. Both sides are the event loop's own thread; this is how that is said to
/// a compiler that cannot see it.
private struct ProxyPointer: @unchecked Sendable {
    let pointer: OpaquePointer
}

private func windowFrom(_ data: UnsafeMutableRawPointer?) -> WaylandSessionWindow? {
    guard let data else { return nil }
    return Unmanaged<WaylandSessionWindow>.fromOpaque(data).takeUnretainedValue()
}

nonisolated(unsafe) private let registryListener: UnsafeMutablePointer<wl_registry_listener> = {
    var listener = wl_registry_listener()
    listener.global = { data, _, name, interface, version in
        guard let window = windowFrom(data), let interface else { return }
        let interfaceName = String(cString: interface)
        MainActor.assumeIsolated {
            window.bindGlobal(name: name, interface: interfaceName, version: version)
        }
    }
    listener.global_remove = { _, _, _ in }
    return heapListener(listener)
}()

nonisolated(unsafe) private let xdgWmBaseListener = heapListener(xdg_wm_base_listener(
    ping: { _, base, serial in
        xdg_wm_base_pong(base, serial)
    }
))

nonisolated(unsafe) private let xdgSurfaceListener = heapListener(xdg_surface_listener(
    configure: { data, _, serial in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handleSurfaceConfigure(serial: serial) }
    }
))

/// Whether a `xdg_toplevel.configure` state array says this window is
/// fullscreen. The array is a run of 32-bit state values, and a state the
/// compositor does not name is one this window is not in.
private func statesContainFullscreen(_ states: UnsafeMutablePointer<wl_array>?) -> Bool {
    guard let states, let data = states.pointee.data else { return false }
    let count = states.pointee.size / MemoryLayout<UInt32>.size
    let values = data.assumingMemoryBound(to: UInt32.self)
    for index in 0..<count where values[index] == UInt32(XDG_TOPLEVEL_STATE_FULLSCREEN.rawValue) {
        return true
    }
    return false
}

nonisolated(unsafe) private let xdgToplevelListener = heapListener(xdg_toplevel_listener(
    configure: { data, _, width, height, states in
        guard let window = windowFrom(data) else { return }
        let isFullscreen = statesContainFullscreen(states)
        MainActor.assumeIsolated {
            window.handleToplevelConfigure(width: width, height: height, isFullscreen: isFullscreen)
        }
    },
    close: { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.reportClosed() }
    },
    configure_bounds: { _, _, _, _ in },
    wm_capabilities: { _, _, _ in }
))

nonisolated(unsafe) private let surfaceListener: UnsafeMutablePointer<wl_surface_listener> = {
    var listener = wl_surface_listener()
    listener.enter = { data, _, output in
        guard let window = windowFrom(data) else { return }
        let entered = output.map { ProxyPointer(pointer: $0) }
        MainActor.assumeIsolated { window.handleSurfaceEnter(output: entered?.pointer) }
    }
    listener.leave = { _, _, _ in }
    return heapListener(listener)
}()

nonisolated(unsafe) private let outputListener: UnsafeMutablePointer<wl_output_listener> = {
    var listener = wl_output_listener()
    listener.geometry = { _, _, _, _, _, _, _, _, _, _ in }
    listener.mode = { data, output, flags, _, _, refresh in
        guard let window = windowFrom(data), let output else { return }
        let source = ProxyPointer(pointer: output)
        let isCurrent = flags & UInt32(WL_OUTPUT_MODE_CURRENT.rawValue) != 0
        MainActor.assumeIsolated {
            window.handleOutputMode(output: source.pointer, isCurrent: isCurrent, refreshMilliHertz: refresh)
        }
    }
    listener.done = { _, _ in }
    listener.scale = { _, _, _ in }
    return heapListener(listener)
}()

nonisolated(unsafe) private let fractionalScaleListener = heapListener(wp_fractional_scale_v1_listener(
    preferred_scale: { data, _, scale in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handlePreferredScale(numerator120: scale) }
    }
))

nonisolated(unsafe) private let presentationListener = heapListener(wp_presentation_listener(
    clock_id: { data, _, clockID in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handlePresentationClock(clockID) }
    }
))

nonisolated(unsafe) private let presentationFeedbackListener = heapListener(wp_presentation_feedback_listener(
    sync_output: { _, _, _ in },
    presented: { data, feedback, secondsHigh, secondsLow, nanoseconds, refresh, _, _, _ in
        guard let window = windowFrom(data), let feedback else { return }
        let source = ProxyPointer(pointer: feedback)
        MainActor.assumeIsolated {
            window.handlePresented(
                feedback: source.pointer,
                secondsHigh: secondsHigh,
                secondsLow: secondsLow,
                nanoseconds: nanoseconds,
                refreshNanoseconds: refresh
            )
        }
    },
    discarded: { data, feedback in
        guard let window = windowFrom(data), let feedback else { return }
        let source = ProxyPointer(pointer: feedback)
        MainActor.assumeIsolated { window.handleFeedbackDiscarded(feedback: source.pointer) }
    }
))

nonisolated(unsafe) private let frameListener: UnsafeMutablePointer<wl_callback_listener> = {
    var listener = wl_callback_listener()
    listener.done = { data, callback, _ in
        guard let window = windowFrom(data), let callback else { return }
        let source = ProxyPointer(pointer: callback)
        MainActor.assumeIsolated { window.handleFrameCallback(source.pointer) }
    }
    return heapListener(listener)
}()

nonisolated(unsafe) private let seatListener: UnsafeMutablePointer<wl_seat_listener> = {
    var listener = wl_seat_listener()
    listener.capabilities = { data, seat, capabilities in
        guard let window = windowFrom(data), let seat else { return }
        let source = ProxyPointer(pointer: seat)
        MainActor.assumeIsolated { window.registerSeatDevices(seat: source.pointer, capabilities: capabilities) }
    }
    listener.name = { _, _, _ in }
    return heapListener(listener)
}()

nonisolated(unsafe) private let keyboardListener: UnsafeMutablePointer<wl_keyboard_listener> = {
    var listener = wl_keyboard_listener()
    listener.keymap = { data, _, format, fd, size in
        guard let window = windowFrom(data) else {
            // Unowned by any window, and still this client's descriptor to
            // close: leaving it open would leak one per keyboard.
            close(fd)
            return
        }
        MainActor.assumeIsolated { window.handleKeymap(format: format, descriptor: fd, size: size) }
    }
    listener.enter = { data, _, serial, _, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated {
            window.noteInputSerial(serial)
            window.handleKeyboardEnter()
        }
    }
    listener.leave = { data, _, _, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handleKeyboardLeave() }
    }
    listener.key = { data, _, serial, _, key, keyState in
        guard let window = windowFrom(data) else { return }
        let isDown = keyState == UInt32(WL_KEYBOARD_KEY_STATE_PRESSED.rawValue)
        MainActor.assumeIsolated {
            window.noteInputSerial(serial)
            window.handleKey(evdev: key, isDown: isDown)
        }
    }
    listener.modifiers = { data, _, _, depressed, latched, locked, group in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated {
            window.handleKeyboardModifiers(depressed: depressed, latched: latched, locked: locked, group: group)
        }
    }
    listener.repeat_info = { data, _, rate, delay in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handleRepeatInfo(rate: rate, delayMilliseconds: delay) }
    }
    return heapListener(listener)
}()

/// Which of a pointer's axes an axis event names, or nil for one this viewer
/// does not carry.
private func scrollAxis(_ axis: UInt32) -> WaylandScrollAxis? {
    switch axis {
    case UInt32(WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue): .vertical
    case UInt32(WL_POINTER_AXIS_HORIZONTAL_SCROLL.rawValue): .horizontal
    default: nil
    }
}

private func scrollAxisSource(_ source: UInt32) -> WaylandScrollAxisSource? {
    switch source {
    case UInt32(WL_POINTER_AXIS_SOURCE_WHEEL.rawValue): .wheel
    case UInt32(WL_POINTER_AXIS_SOURCE_FINGER.rawValue): .finger
    case UInt32(WL_POINTER_AXIS_SOURCE_CONTINUOUS.rawValue): .continuous
    case UInt32(WL_POINTER_AXIS_SOURCE_WHEEL_TILT.rawValue): .wheelTilt
    default: nil
    }
}

nonisolated(unsafe) private let pointerListener: UnsafeMutablePointer<wl_pointer_listener> = {
    var listener = wl_pointer_listener()
    listener.enter = { data, _, serial, surface, x, y in
        guard let window = windowFrom(data) else { return }
        let entered = surface.map { ProxyPointer(pointer: $0) }
        MainActor.assumeIsolated {
            window.handlePointerEnter(
                serial: serial,
                surface: entered?.pointer,
                x: wl_fixed_to_double(x),
                y: wl_fixed_to_double(y)
            )
        }
    }
    listener.leave = { data, _, _, surface in
        guard let window = windowFrom(data) else { return }
        let left = surface.map { ProxyPointer(pointer: $0) }
        MainActor.assumeIsolated { window.handlePointerLeave(surface: left?.pointer) }
    }
    listener.motion = { data, _, _, x, y in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated {
            window.handlePointerMotion(x: wl_fixed_to_double(x), y: wl_fixed_to_double(y))
        }
    }
    listener.button = { data, _, _, _, button, buttonState in
        guard let window = windowFrom(data) else { return }
        let isDown = buttonState == UInt32(WL_POINTER_BUTTON_STATE_PRESSED.rawValue)
        // A pointer button carries its own serial, but `set_selection`
        // requires one from the keyboard's own input stream -- see
        // `noteInputSerial`'s doc comment -- so this one is not fed to it.
        MainActor.assumeIsolated {
            window.handlePointerButton(code: button, isDown: isDown)
        }
    }
    listener.axis = { data, _, _, axis, value in
        guard let window = windowFrom(data), let scrolled = scrollAxis(axis) else { return }
        MainActor.assumeIsolated { window.handleAxis(scrolled, value: wl_fixed_to_double(value)) }
    }
    listener.frame = { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handlePointerFrame() }
    }
    listener.axis_source = { data, _, source in
        guard let window = windowFrom(data), let axisSource = scrollAxisSource(source) else { return }
        MainActor.assumeIsolated { window.handleAxisSource(axisSource) }
    }
    listener.axis_stop = { data, _, _, axis in
        guard let window = windowFrom(data), let scrolled = scrollAxis(axis) else { return }
        MainActor.assumeIsolated { window.handleAxisStop(scrolled) }
    }
    // Superseded by `axis_value120`, which the pointer this window binds
    // always sends instead.
    listener.axis_discrete = { _, _, _, _ in }
    listener.axis_value120 = { data, _, axis, value120 in
        guard let window = windowFrom(data), let scrolled = scrollAxis(axis) else { return }
        MainActor.assumeIsolated { window.handleAxisValue120(scrolled, value120: value120) }
    }
    return heapListener(listener)
}()

nonisolated(unsafe) private let relativePointerListener = heapListener(zwp_relative_pointer_v1_listener(
    relative_motion: { data, _, _, _, _, _, unacceleratedX, unacceleratedY in
        guard let window = windowFrom(data) else { return }
        // Unaccelerated: the far machine applies its own pointer
        // acceleration, and applying this machine's first would apply it
        // twice.
        MainActor.assumeIsolated {
            window.handleRelativeMotion(
                deltaX: wl_fixed_to_double(unacceleratedX),
                deltaY: wl_fixed_to_double(unacceleratedY)
            )
        }
    }
))

nonisolated(unsafe) private let lockedPointerListener = heapListener(zwp_locked_pointer_v1_listener(
    locked: { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handlePointerLocked() }
    },
    unlocked: { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handlePointerUnlocked() }
    }
))

nonisolated(unsafe) private let shortcutsInhibitorListener = heapListener(zwp_keyboard_shortcuts_inhibitor_v1_listener(
    active: { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handleShortcutsInhibitorActive() }
    },
    inactive: { data, _ in
        guard let window = windowFrom(data) else { return }
        MainActor.assumeIsolated { window.handleShortcutsInhibitorInactive() }
    }
))
#endif
