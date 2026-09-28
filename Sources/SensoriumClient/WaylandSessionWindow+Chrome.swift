#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec) && canImport(CCairo) && canImport(CGtk4)
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
    /// Whether the painted menu bar is up, which full screen decides.
    var menuBar = SessionMenuBarVisibility()
    var menuNavigator = SessionMenuNavigator()
    /// One popup per open menu, the bar's menu first and each submenu after
    /// it, with the navigator path each was opened for.
    var menuPopups: [WaylandMenuPopup] = []
    var menuPopupPaths: [[Int?]] = []
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

    public func updateScreenMenu(displays: [HostScreenListEntry], selectedToken: Data?, canvasAvailable: Bool) {
        chrome.state.controls.hostScreens = displays
        chrome.state.controls.selectedScreenToken = selectedToken
        chrome.state.controls.canvasAvailable = canvasAvailable
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

    public func showClipboardRefusal(_ line: String) {
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

    /// View > Session Diagnostics.
    func toggleDiagnostics() {
        chrome.state.toggleDiagnosticsRequested()
        relayoutChrome()
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
        for popup in chrome.menuPopups {
            popup.redrawIfOwed()
        }
    }

    func tearDownChrome() {
        closeMenuPopups(from: 0)
        for overlay in chrome.overlays.values {
            overlay.tearDown()
        }
        chrome.overlays = [:]
    }

    /// Places every overlay the current state asks for and hides the rest.
    /// One pass, so an overlay can never be left drawn at a size the window
    /// no longer has.
    func relayoutChrome() {
        guard !chrome.overlays.isEmpty else { return }
        let size = logicalSize
        let scale = surfaceScale
        let state = chrome.state
        // The menu bar's height, outside full screen, and below it what a
        // pinned strip has taken. The picture gives both up rather than
        // being drawn under them, and the other chrome starts below them.
        let barTop = chrome.menuBar.contentTop
        let topInset = barTop + WaylandOverlayLayout.topInset(
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

        if state.isScrimVisible {
            let rect = WaylandOverlayLayout.canvasScrim(windowWidth: size.width, windowHeight: size.height, top: barTop)
            place(.canvasScrim, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawScrim(in: context, bounds: bounds, opaque: state.isScrimOpaque)
            }
        } else {
            chrome.overlays[.canvasScrim]?.hide()
        }

        if let status = state.status, state.isStatusPanelVisible {
            let measured = SessionChromePainter.statusPanelSize(status: status)
            let rect = WaylandOverlayLayout.statusPanel(
                windowWidth: size.width,
                windowHeight: size.height - barTop,
                contentWidth: measured.width,
                contentHeight: measured.height
            ).offset(y: barTop)
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
            let isFlagged = state.telemetry?.isAttentionWorthy ?? false
            place(.diagnostics, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawDiagnostics(blocks: blocks, in: context, bounds: bounds, isFlagged: isFlagged)
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
                contentHeight: measured.height
            ).offset(y: barTop)
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
            ).offset(y: barTop)
            place(.stripHandle, at: rect, scale: scale) { context, bounds in
                SessionChromePainter.drawHandle(in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.stripHandle]?.hide()
        }

        if chrome.menuBar.isVisible {
            let titles = sessionMenus.map(\.title)
            let openIndex = chrome.menuNavigator.openMenu
            place(.menuBar, at: WaylandOverlayLayout.menuBar(windowWidth: size.width), scale: scale) { context, bounds in
                SessionChromePainter.drawMenuBar(titles: titles, openIndex: openIndex, in: context, bounds: bounds)
            }
        } else {
            chrome.overlays[.menuBar]?.hide()
        }
    }

    // MARK: - Menu bar

    /// The menus as the painted bar shows them now.
    var sessionMenus: [ViewerMenu] {
        LinuxViewerMenu.bar(menuBarState)
    }

    /// Opens the bar's menu titled `title`, its first choosable row
    /// highlighted, as a click on the title followed by Down would.
    public func openMenu(titled title: String) {
        guard let index = sessionMenus.firstIndex(where: { $0.title == title }) else { return }
        if chrome.menuBar.isFullscreen {
            chrome.menuBar.pointerOnPicture(y: 0, isMenuOpen: false)
        }
        chrome.menuNavigator.open(index, in: sessionMenus, highlightFirst: true)
        menuOpened()
    }

    /// One key while a menu is open. Every key comes here then, and the ones
    /// that are not a menu key do nothing.
    public func menuKey(_ key: SessionMenuKey) {
        let command = chrome.menuNavigator.key(key, in: sessionMenus)
        syncMenuPopups()
        if let command { performMenuCommand(command) }
    }

    var isMenuOpen: Bool { chrome.menuNavigator.isOpen }

    func closeMenus() {
        guard chrome.menuNavigator.isOpen || !chrome.menuPopups.isEmpty else { return }
        chrome.menuNavigator.close()
        syncMenuPopups()
    }

    /// Full screen hides the bar and takes its height back for the picture.
    func menuBarFullscreenChanged(_ isFullscreen: Bool) {
        guard chrome.menuBar.isFullscreen != isFullscreen else { return }
        chrome.menuNavigator.close()
        chrome.menuBar.setFullscreen(isFullscreen)
        syncMenuPopups()
    }

    /// Keys held into an open menu are not the far machine's any more.
    private func menuOpened() {
        route(.focusLost)
        syncMenuPopups()
    }

    /// Makes the open popups match the navigator: keeps each one whose menu
    /// is still the one open at its depth and redraws it, closes the rest,
    /// and opens what is newly open.
    func syncMenuPopups() {
        let menus = sessionMenus
        let navigator = chrome.menuNavigator
        var depth = 0
        if let openMenu = navigator.openMenu {
            while depth < navigator.highlights.count, let menu = navigator.menu(atDepth: depth, in: menus) {
                let path = [openMenu] + Array(navigator.highlights.prefix(depth))
                if depth < chrome.menuPopupPaths.count, chrome.menuPopupPaths[depth] == path {
                    chrome.menuPopups[depth].redraw()
                } else {
                    closeMenuPopups(from: depth)
                    guard let popup = makeMenuPopup(depth: depth, menu: menu, openMenu: openMenu) else { break }
                    chrome.menuPopups.append(popup)
                    chrome.menuPopupPaths.append(path)
                }
                depth += 1
            }
        }
        closeMenuPopups(from: depth)
        if !navigator.isOpen {
            chrome.menuBar.menuClosed(isPointerOnBar: overlayKind(for: pointerSurface) == .menuBar)
        }
        relayoutChrome()
        wl_display_flush(display)
    }

    /// A submenu has to go before the popup it opened from, so the deepest
    /// goes first.
    private func closeMenuPopups(from depth: Int) {
        while chrome.menuPopups.count > depth {
            chrome.menuPopups.removeLast().tearDown()
            chrome.menuPopupPaths.removeLast()
        }
    }

    private func makeMenuPopup(depth: Int, menu: ViewerMenu, openMenu: Int) -> WaylandMenuPopup? {
        guard let compositor, let xdgWmBase, let shm, let xdgSurface else { return nil }
        let layout = SessionChromePainter.menuPopupLayout(menu)
        let parent: OpaquePointer
        let anchor: ViewerChromeRect
        if depth == 0 {
            let items = SessionChromePainter.menuBarItems(titles: sessionMenus.map(\.title))
            guard items.indices.contains(openMenu) else { return nil }
            parent = xdgSurface
            anchor = ViewerChromeRect(
                x: items[openMenu].x, y: 0, width: items[openMenu].width, height: SessionChromePainter.menuBarHeight
            )
        } else {
            guard let row = chrome.menuNavigator.highlights[depth - 1],
                  let parentMenu = chrome.menuNavigator.menu(atDepth: depth - 1, in: sessionMenus) else { return nil }
            let parentPopup = chrome.menuPopups[depth - 1]
            parent = parentPopup.xdgSurface
            let rect = SessionChromePainter.menuPopupLayout(parentMenu).rect(ofRow: row)
            anchor = ViewerChromeRect(x: 0, y: rect.y, width: parentPopup.width, height: rect.height)
        }
        let popup = WaylandMenuPopup(
            compositor: compositor,
            wmBase: xdgWmBase,
            parent: parent,
            anchor: anchor,
            isSubmenu: depth > 0,
            width: layout.width,
            height: layout.height,
            scale: surfaceScale,
            shm: shm,
            viewporter: viewporter
        ) { [weak self] context, bounds in
            guard let self, let menu = self.chrome.menuNavigator.menu(atDepth: depth, in: self.sessionMenus) else { return }
            let highlights = self.chrome.menuNavigator.highlights
            let highlighted = depth < highlights.count ? highlights[depth] : nil
            SessionChromePainter.drawMenuPopup(menu, highlighted: highlighted, in: context, bounds: bounds)
        }
        popup?.onDone = { [weak self] in self?.closeMenus() }
        return popup
    }

    private func menuPopupDepth(for surface: OpaquePointer?) -> Int? {
        guard let surface else { return nil }
        return chrome.menuPopups.firstIndex { $0.surface == surface }
    }

    /// The pointer over an open popup highlights the row under it; a move
    /// along the bar while a menu is open opens the one under it instead.
    private func menuPointerMoved(surface: OpaquePointer?, x: Double, y: Double) -> Bool {
        if let depth = menuPopupDepth(for: surface) {
            guard let menu = chrome.menuNavigator.menu(atDepth: depth, in: sessionMenus) else { return true }
            let row = SessionChromePainter.menuPopupLayout(menu).row(atY: y)
            let before = chrome.menuNavigator
            chrome.menuNavigator.hover(depth: depth, row: row, in: sessionMenus)
            if chrome.menuNavigator != before { syncMenuPopups() }
            return true
        }
        guard overlayKind(for: surface) == .menuBar else { return false }
        if chrome.menuNavigator.isOpen,
           let index = SessionMenuBarLayout.item(atX: x, in: SessionChromePainter.menuBarItems(titles: sessionMenus.map(\.title))),
           index != chrome.menuNavigator.openMenu {
            chrome.menuNavigator.open(index, in: sessionMenus, highlightFirst: false)
            syncMenuPopups()
        }
        return true
    }

    /// Whether this press was the menus': on the bar, in a popup, or anywhere
    /// at all while a menu is open, where it only closes the menus.
    private func menuPressed(surface: OpaquePointer?, button: CanvasPointerButton) -> Bool {
        if let depth = menuPopupDepth(for: surface) {
            guard button == .left,
                  let menu = chrome.menuNavigator.menu(atDepth: depth, in: sessionMenus),
                  let row = SessionChromePainter.menuPopupLayout(menu).row(atY: chrome.overlayPointerY) else { return true }
            let command = chrome.menuNavigator.click(depth: depth, row: row, in: sessionMenus)
            syncMenuPopups()
            if let command { performMenuCommand(command) }
            return true
        }
        if overlayKind(for: surface) == .menuBar {
            guard button == .left else { return true }
            let items = SessionChromePainter.menuBarItems(titles: sessionMenus.map(\.title))
            let index = SessionMenuBarLayout.item(atX: chrome.overlayPointerX, in: items)
            if let index, index != chrome.menuNavigator.openMenu {
                chrome.menuNavigator.open(index, in: sessionMenus, highlightFirst: false)
                menuOpened()
            } else {
                closeMenus()
            }
            return true
        }
        guard chrome.menuNavigator.isOpen else { return false }
        closeMenus()
        return true
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
        overlayKind(for: surface) != nil || menuPopupDepth(for: surface) != nil || chrome.menuNavigator.isOpen
    }

    /// True when this enter belonged to an overlay, in which case the session
    /// hears nothing about it.
    func chromePointerEntered(surface: OpaquePointer?, x: Double, y: Double) -> Bool {
        if menuPopupDepth(for: surface) != nil {
            chrome.overlayPointerX = x
            chrome.overlayPointerY = y
            return menuPointerMoved(surface: surface, x: x, y: y)
        }
        guard let kind = overlayKind(for: surface) else {
            menuBarPointerOnPicture(y: y)
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
        guard overlayKind(for: surface) != nil || menuPopupDepth(for: surface) != nil else {
            menuBarPointerOnPicture(y: y)
            return false
        }
        chrome.overlayPointerX = x
        chrome.overlayPointerY = y
        _ = menuPointerMoved(surface: surface, x: x, y: y)
        return true
    }

    /// In full screen the top edge brings the bar up, and moving off it puts
    /// it away again.
    private func menuBarPointerOnPicture(y: Double) {
        guard chrome.menuBar.isFullscreen, capture?.isCapturing != true else { return }
        let before = chrome.menuBar
        chrome.menuBar.pointerOnPicture(y: y, isMenuOpen: chrome.menuNavigator.isOpen)
        if chrome.menuBar != before { relayoutChrome() }
    }

    /// A press the policy already decided is the chrome's. Which control it
    /// landed on is decided by the same layout that drew them.
    func chromePressed(surface: OpaquePointer?, button: CanvasPointerButton) {
        guard !menuPressed(surface: surface, button: button) else { return }
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
            pressNotice()
        case .diagnostics, .canvasScrim, .menuBar:
            break
        }
    }

    /// Dismisses only when the press lands on the ✕ itself -- the same rule
    /// a real `NSButton` gives the banner's dismiss control on macOS, rather
    /// than the whole banner acting as one big dismiss target.
    private func pressNotice() {
        guard let rect = chrome.overlays[.notice]?.rect else { return }
        let local = ViewerChromeRect(x: 0, y: 0, width: rect.width, height: rect.height)
        let dismissRect = SessionChromePainter.noticeDismissRect(in: local)
        guard dismissRect.contains(x: chrome.overlayPointerX, y: chrome.overlayPointerY) else { return }
        chrome.state.dismissNotice()
        relayoutChrome()
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
            originY: 0,
            width: rect.width
        )
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
        case .statusPanel, .notice, .diagnostics, .canvasScrim, .menuBar:
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

    func applySessionControl(_ activation: SessionControlsActivation) {
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

    /// A menu open while its choices change shows the new ones.
    private func refreshSessionControls() {
        guard chrome.menuNavigator.isOpen else { return }
        syncMenuPopups()
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
