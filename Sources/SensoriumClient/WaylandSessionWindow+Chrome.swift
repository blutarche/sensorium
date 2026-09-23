#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec) && canImport(CCairo)
import CWayland
import Foundation
import SensoriumCore

/// Everything a Linux session window holds on behalf of the chrome around the
/// picture: the closures the viewer's controller sets, the state every
/// overlay is drawn from, and the subsurfaces they are drawn on.
///
/// One value rather than a dozen stored properties, so the window itself
/// keeps a single line of this and the whole surface lives in the file that
/// implements it.
struct WaylandSessionChrome {
    var onCloseRequested: (() -> Void)?
    var onSessionAction: ((ViewerSessionAction) -> Void)?
    var onSelectDisplayCount: ((Int) -> Void)?
    var onSelectRealScreen: ((Data?) -> Void)?
    var onSelectHostScreenMode: ((String) -> Void)?
    var onSelectClipboardSharing: ((Bool) -> Void)?
    var onSelectStartTarget: ((StartTarget) -> Void)?

    /// What the chrome is showing, decided by the portable model and drawn
    /// from here.
    var state = SessionChromeState()
    /// Which presses belong to the chrome and which to the far machine.
    var clicks = CanvasChromeClickPolicy()
    /// Where the pointer is inside whichever overlay it is on, in that
    /// overlay's own logical units -- which is what the compositor reports
    /// for a subsurface, and what a hit test needs.
    var overlayPointerX: Double = 0
    var overlayPointerY: Double = 0
    var overlays: [WaylandOverlayKind: WaylandOverlaySurface] = [:]
    /// The session controls are an ordinary desktop window rather than an
    /// overlay: it takes typing, and a subsurface cannot hold the keyboard
    /// focus a toplevel already has.
    var controlsWindow: GtkSessionControlsWindow?
    /// The band a pinned strip has taken off the top of the window, in the
    /// logical units a pointer position is reported in. The picture and
    /// every pointer position are measured against what is left.
    var videoTopInset: Double = 0
    /// Whether the overlays are committing with the picture across a resize.
    var syncGate = WaylandOverlaySyncGate()
    /// The host this session is working on, as every strip tooltip and every
    /// confirmation names it.
    var hostName = ""
    var hasShown = false
}

/// The Linux session window's half of `SessionWindowChrome`.
///
/// Every word already arrived decided, from `ViewerSessionStateMachine`,
/// `ScreenMenuPlan`, `DisplayCountMenuPlan` or `SessionHUDPanel`;
/// `SessionChromeState` decides which of them is on screen;
/// `SessionChromePainter` puts the ink down. This file is the wiring between
/// the three.
extension WaylandSessionWindow: SessionWindowChrome {
    public var onCloseRequested: (() -> Void)? {
        get { chrome.onCloseRequested }
        set { chrome.onCloseRequested = newValue }
    }

    public var onSessionAction: ((ViewerSessionAction) -> Void)? {
        get { chrome.onSessionAction }
        set { chrome.onSessionAction = newValue }
    }

    public var onSelectDisplayCount: ((Int) -> Void)? {
        get { chrome.onSelectDisplayCount }
        set { chrome.onSelectDisplayCount = newValue }
    }

    public var onSelectRealScreen: ((Data?) -> Void)? {
        get { chrome.onSelectRealScreen }
        set { chrome.onSelectRealScreen = newValue }
    }

    public var onSelectHostScreenMode: ((String) -> Void)? {
        get { chrome.onSelectHostScreenMode }
        set { chrome.onSelectHostScreenMode = newValue }
    }

    public var onSelectClipboardSharing: ((Bool) -> Void)? {
        get { chrome.onSelectClipboardSharing }
        set { chrome.onSelectClipboardSharing = newValue }
    }

    public var onSelectStartTarget: ((StartTarget) -> Void)? {
        get { chrome.onSelectStartTarget }
        set { chrome.onSelectStartTarget = newValue }
    }

    /// Points this window at a freshly connected session, reusing the surface
    /// the person is already looking at rather than opening a new one. The
    /// router, the mapper and the decode pipeline all belong to the window and
    /// survive; only where this window's input goes changes.
    public func attach(session: ClientSessionController) async {
        await canvasObserver().replacePointerSink(
            surfaceID == 0 ? session : SurfaceScopedInputSink(session: session, surfaceID: surfaceID)
        )
    }

    /// A Wayland surface is on screen from the moment the compositor
    /// configures it, so there is nothing to raise here. What a fresh session
    /// does need is this window's real size, which it has been told nothing
    /// about yet.
    public func show() async {
        let size = drawablePixelSize
        _ = await canvasObserver().setDrawableSize(
            pixelWidth: Double(size.width), pixelHeight: Double(size.height)
        )
        guard !chrome.hasShown else { return }
        chrome.hasShown = true
        buildOverlaysIfNeeded()
        relayoutChrome()
    }

    /// Wayland gives a client no say in where its window is placed, so a
    /// second canvas cannot be offset from the first.
    public func cascadeIfUnplaced(from other: any SessionWindowChrome) {}

    public func apply(status: ViewerSessionStatus) {
        chrome.state.apply(status: status, now: chromeNow())
        relayoutChrome()
    }

    public func updateDisplayCount(_ count: Int) {
        chrome.state.controls.displayCount = count
        refreshSessionControls()
    }

    public func updateIsHostScreenSession(_ isHostScreenSession: Bool) {
        chrome.state.controls.isHostScreenSession = isHostScreenSession
        refreshSessionControls()
    }

    public func updateScreenMenu(displays: [HostScreenListEntry], selectedToken: Data?) {
        chrome.state.controls.hostScreens = displays
        chrome.state.controls.selectedScreenToken = selectedToken
        refreshSessionControls()
    }

    public func updateHostScreenModes(_ modes: [HostScreenModeEntry], currentModeID: String?) {
        chrome.state.controls.hostScreenModes = modes
        chrome.state.controls.currentHostScreenModeID = currentModeID
        refreshSessionControls()
    }

    public func updateStartTargetPreference(_ preference: StartTarget) {
        chrome.state.controls.startTargetPreference = preference
        refreshSessionControls()
    }

    public func updateClipboardSharingEnabled(_ enabled: Bool) {
        chrome.state.controls.clipboardSharingEnabled = enabled
        refreshSessionControls()
    }

    public func showDisplayCountRefusal(reason: String) {
        showTransientNotice(reason)
    }

    public func showHostScreenModeRefusal(_ line: String) {
        showTransientNotice(line)
    }

    // MARK: - Chrome the window itself drives

    /// The host this session is working on, as the strip's own confirmations
    /// name it. Set by the factory, which is the only place that knows it.
    func setChromeHostName(_ name: String) {
        chrome.hostName = name
    }

    /// The viewer's own chord for the strip, and the click on the handle that
    /// does the same thing.
    func toggleShortcutStrip() {
        chrome.state.toggleStripRequested(now: chromeNow())
        relayoutChrome()
    }

    /// The viewer's own chord for the session controls. On macOS these are
    /// menu bar menus; here they are a window of their own.
    func openSessionControls() {
        guard let window = chrome.controlsWindow ?? makeSessionControlsWindow() else { return }
        chrome.controlsWindow = window
        window.present(model: chrome.state.controls)
    }

    func applyDiagnostics(_ snapshot: SessionHUDSnapshot) {
        chrome.state.apply(telemetry: snapshot)
        guard chrome.state.isDiagnosticsVisible else { return }
        relayoutChrome()
    }

    /// Once per compositor round: whatever the clock owes the chrome, and any
    /// drawing that had to wait for a buffer.
    func serviceChrome() {
        let before = chrome.state
        chrome.state.tick(now: chromeNow())
        if chrome.state != before {
            relayoutChrome()
        }
        for overlay in chrome.overlays.values {
            overlay.redrawIfOwed()
        }
    }

    func tearDownChrome() {
        for overlay in chrome.overlays.values {
            overlay.tearDown()
        }
        chrome.overlays = [:]
        chrome.controlsWindow?.close()
        chrome.controlsWindow = nil
    }

    /// Places every overlay the current state asks for and hides the rest.
    /// One pass, so an overlay can never be left drawn at a size the window
    /// no longer has.
    func relayoutChrome() {
        guard !chrome.overlays.isEmpty else { return }
        let size = logicalSize
        let scale = surfaceScale
        let state = chrome.state
        // What a pinned strip has taken from the top of the window. The
        // picture gives it up rather than being drawn under it, and the
        // diagnostics panel starts below it.
        let topInset = WaylandOverlayLayout.topInset(
            isPinned: state.strip.isPinned,
            isStripOpen: state.isStripVisible,
            stripHeight: SessionChromePainter.stripHeight
        )
        if topInset != chrome.videoTopInset {
            chrome.videoTopInset = topInset
            setVideoTopInset(
                pixels: topInset > 0 ? WaylandOverlayLayout.pixelSize(logical: topInset, scale: scale) : 0
            )
            // The picture just changed size and place, so what the session
            // was told about the area a pointer is measured against is no
            // longer true.
            reportVideoBounds()
        }

        if let status = state.status, state.isStatusPanelVisible {
            let measured = SessionChromePainter.statusPanelSize(status: status)
            let rect = WaylandOverlayLayout.statusPanel(
                windowWidth: size.width,
                windowHeight: size.height,
                contentWidth: measured.width,
                contentHeight: measured.height
            )
            place(.statusPanel, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawStatusPanel(status: status, in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.statusPanel]?.hide()
        }

        if let line = state.notice {
            let measured = SessionChromePainter.noticeSize(line: line)
            let rect = WaylandOverlayLayout.transientNotice(
                windowWidth: size.width,
                contentWidth: measured.width,
                contentHeight: measured.height,
                topInset: topInset
            )
            place(.notice, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawNotice(line: line, in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.notice]?.hide()
        }

        if state.isDiagnosticsVisible {
            let blocks = state.diagnosticsBlocks
            let measured = SessionChromePainter.diagnosticsSize(blocks: blocks)
            let rect = WaylandOverlayLayout.diagnosticsHUD(
                windowWidth: size.width,
                contentWidth: measured.width,
                contentHeight: measured.height,
                topInset: topInset
            )
            place(.diagnostics, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawDiagnostics(blocks: blocks, in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.diagnostics]?.hide()
        }

        if state.isStripVisible {
            let hostName = chrome.hostName
            let visibility = state.strip.visibility
            let isPinned = state.strip.isPinned
            let measured = SessionChromePainter.stripSize(visibility: visibility, hostName: hostName)
            let rect = WaylandOverlayLayout.shortcutStrip(
                windowWidth: size.width,
                contentWidth: measured.width,
                contentHeight: measured.height
            )
            place(.shortcutStrip, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawStrip(
                    visibility: visibility,
                    hostName: hostName,
                    isPinned: isPinned,
                    in: context,
                    bounds: bounds
                )
            }
        } else {
            chrome.overlays[.shortcutStrip]?.hide()
        }

        if state.isHandleVisible {
            let rect = WaylandOverlayLayout.stripHandle(
                windowWidth: size.width,
                contentWidth: SessionChromePainter.handleWidth,
                contentHeight: SessionChromePainter.handleHeight
            )
            place(.stripHandle, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawHandle(in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.stripHandle]?.hide()
        }
    }

    // MARK: - Resize

    /// Where the picture sits inside the window right now, which is the
    /// whole window until a strip is pinned open.
    var videoArea: ViewerChromeRect {
        let size = logicalSize
        return WaylandOverlayLayout.videoArea(
            windowWidth: size.width,
            windowHeight: size.height,
            topInset: chrome.videoTopInset
        )
    }

    /// Holds every overlay to the parent's next commit, so a resize reaches
    /// the screen as one update rather than as a picture at the new size
    /// with the chrome still at the old one.
    func holdOverlaysForResize() {
        guard chrome.syncGate.surfaceResized() else { return }
        for overlay in chrome.overlays.values {
            overlay.setSynchronisedWithParent(true)
        }
    }

    /// Lets them go again, once the picture behind them has been drawn at
    /// the new size and the swap that carried it has committed the parent.
    func releaseOverlaysAfterPicture() {
        guard chrome.syncGate.pictureDrawn() else { return }
        for overlay in chrome.overlays.values {
            overlay.setSynchronisedWithParent(false)
        }
    }

    // MARK: - Pointer

    /// Whether the pointer is on one of this window's overlays rather than on
    /// the picture. What `CanvasChromeClickPolicy` is asked.
    func chromeContainsPointer(surface: OpaquePointer?) -> Bool {
        overlayKind(for: surface) != nil
    }

    /// True when this enter belonged to an overlay, in which case the session
    /// hears nothing about it.
    func chromePointerEntered(surface: OpaquePointer?, x: Double, y: Double) -> Bool {
        guard let kind = overlayKind(for: surface) else {
            // Back on the picture: whatever the strip believed about the
            // pointer being on it is no longer true.
            chrome.state.pointerOverStrip(false, now: chromeNow())
            chrome.state.pointerOverHandle(false, now: chromeNow())
            relayoutChrome()
            return false
        }
        chrome.overlayPointerX = x
        chrome.overlayPointerY = y
        setStripHover(kind, isOver: true)
        return true
    }

    func chromePointerLeft(surface: OpaquePointer?) {
        guard let kind = overlayKind(for: surface) else { return }
        setStripHover(kind, isOver: false)
    }

    /// True when this motion belonged to an overlay. Motion inside an overlay
    /// is not the far machine's pointer moving.
    func chromePointerMoved(surface: OpaquePointer?, x: Double, y: Double) -> Bool {
        guard overlayKind(for: surface) != nil else { return false }
        chrome.overlayPointerX = x
        chrome.overlayPointerY = y
        return true
    }

    /// A press the policy already decided is the chrome's. Which control it
    /// landed on is decided by the same layout that drew them.
    func chromePressed(surface: OpaquePointer?, button: CanvasPointerButton) {
        guard button == .left, let kind = overlayKind(for: surface) else { return }
        switch kind {
        case .stripHandle:
            chrome.state.handleClicked()
            relayoutChrome()
        case .statusPanel:
            pressStatusPanel()
        case .shortcutStrip:
            pressShortcutStrip()
        case .notice:
            chrome.state.dismissNotice()
            relayoutChrome()
        case .diagnostics:
            break
        }
    }

    private func pressStatusPanel() {
        guard let status = chrome.state.status,
              let rect = chrome.overlays[.statusPanel]?.rect else { return }
        let local = ViewerChromeRect(x: 0, y: 0, width: rect.width, height: rect.height)
        let layouts = SessionChromePainter.statusButtonLayouts(status: status, panel: local)
        guard let action = ViewerStatusPanelHitTest.action(
            atX: chrome.overlayPointerX, y: chrome.overlayPointerY, in: layouts
        ) else {
            return
        }
        chrome.onSessionAction?(action)
    }

    private func pressShortcutStrip() {
        guard let rect = chrome.overlays[.shortcutStrip]?.rect else { return }
        let entries = SessionChromePainter.stripLayout(
            visibility: chrome.state.strip.visibility,
            hostName: chrome.hostName,
            originX: 0,
            originY: 0
        )
        _ = rect
        guard let entry = entries.first(where: {
            $0.rect.contains(x: chrome.overlayPointerX, y: chrome.overlayPointerY)
        }) else {
            return
        }
        switch entry.hit {
        case let .action(action):
            if case let .send(sent)? = chrome.state.pressStrip(action) {
                sendShortcut(sent)
            }
        case .confirm:
            if let confirmed = chrome.state.confirmPendingStripAction() {
                sendShortcut(confirmed)
            }
        case .cancel:
            chrome.state.cancelPendingStripAction()
        case .pin:
            chrome.state.togglePinRequested(now: chromeNow())
        }
        relayoutChrome()
    }

    private func sendShortcut(_ action: ShortcutStripAction) {
        for event in action.events() {
            guard case let .key(keyCode, isDown, modifiers) = event else { continue }
            forwardShortcut(keyCode: keyCode, isDown: isDown, modifiers: modifiers)
        }
    }

    private func setStripHover(_ kind: WaylandOverlayKind, isOver: Bool) {
        let now = chromeNow()
        switch kind {
        case .stripHandle:
            chrome.state.pointerOverHandle(isOver, now: now)
        case .shortcutStrip:
            chrome.state.pointerOverStrip(isOver, now: now)
        case .statusPanel, .notice, .diagnostics:
            return
        }
        relayoutChrome()
    }

    private func overlayKind(for surface: OpaquePointer?) -> WaylandOverlayKind? {
        WaylandOverlayPointerTargets(
            targets: chrome.overlays.map {
                .init(kind: $0.key, surface: $0.value.surface, isVisible: $0.value.isVisible)
            }
        ).kind(for: surface)
    }

    // MARK: - Windows that take typing

    private func showTransientNotice(_ line: String) {
        chrome.state.showNotice(line, now: chromeNow())
        relayoutChrome()
    }

    private func makeSessionControlsWindow() -> GtkSessionControlsWindow? {
        GtkSessionControlsWindow { [weak self] activation in
            self?.applySessionControl(activation)
        }
    }

    private func applySessionControl(_ activation: SessionControlsActivation) {
        switch activation {
        case let .selectRealScreen(token):
            chrome.onSelectRealScreen?(token)
        case let .selectHostScreenMode(modeID):
            chrome.onSelectHostScreenMode?(modeID)
        case let .selectStartTarget(target):
            chrome.onSelectStartTarget?(target)
        case let .selectDisplayCount(count):
            chrome.onSelectDisplayCount?(count)
        case let .setStreamScale(scale):
            let preference: StreamScalePreference = scale.map { .fixed($0) } ?? .automatic
            chrome.state.controls.streamScalePreference = preference
            let viewport = canvasObserver()
            Task { await viewport.setStreamScalePreference(preference) }
            refreshSessionControls()
        case let .setClipboardSharing(enabled):
            chrome.onSelectClipboardSharing?(enabled)
        }
    }

    private func refreshSessionControls() {
        chrome.controlsWindow?.update(model: chrome.state.controls)
    }

    private func buildOverlaysIfNeeded() {
        guard chrome.overlays.isEmpty,
              let compositor,
              let subcompositor,
              let shm,
              let surface else {
            if subcompositor == nil {
                print("Sensorium: this compositor has no wl_subcompositor, so the session window draws no chrome over the picture")
            }
            return
        }
        for kind in WaylandOverlayKind.allCases {
            guard let overlay = WaylandOverlaySurface(
                compositor: compositor,
                subcompositor: subcompositor,
                parent: surface,
                shm: shm,
                viewporter: viewporter
            ) else {
                continue
            }
            chrome.overlays[kind] = overlay
        }
    }

    private func place(
        _ kind: WaylandOverlayKind,
        at rect: ViewerChromeRect,
        scale: Double,
        draw: @escaping (OpaquePointer, ViewerChromeRect) -> Void
    ) {
        guard let overlay = chrome.overlays[kind] else { return }
        overlay.setDrawing(draw)
        overlay.show(at: rect, scale: scale)
    }

    /// The clock the strip's hide delay and the notice's own life are judged
    /// against. The same monotonic source the presenter paces on, in seconds.
    func chromeNow() -> TimeInterval {
        Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    }
}
#endif
