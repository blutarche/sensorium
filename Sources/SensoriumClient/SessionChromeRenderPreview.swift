#if canImport(CCairo)
import CCairo
import Foundation

/// Paints any overlay `SessionChromePainter` knows, or a whole window's worth
/// of them, onto a plain cairo image surface and writes it as a PNG -- with no
/// Wayland connection at all.
///
/// `SessionChromePainter`'s own functions already draw into whatever cairo
/// context they are handed, at whatever origin that context's own transform
/// puts it at -- the same contract `WaylandOverlaySurface.redraw()` relies on.
/// This calls those functions against a surface this process allocated for
/// itself, so the paint code a render check verifies is exactly the paint
/// code a real compositor sees.
@MainActor
public enum SessionChromeRenderPreview {
    /// One overlay `SessionChromePainter` draws, with the words and state it
    /// needs already decided -- nothing here invents copy.
    public enum Overlay {
        case statusPanel(ViewerSessionStatus)
        case notice(String)
        case diagnostics(blocks: [SessionHUDBlock])
        case stripHandle
        case strip(visibility: ShortcutStripVisibility, hostName: String, isPinned: Bool)
    }

    /// Renders one overlay at its own measured size and writes it as a PNG.
    /// `false` when cairo could not produce or save the surface.
    @discardableResult
    public static func renderOverlay(_ overlay: Overlay, scale: Double, to url: URL) -> Bool {
        let size = measuredSize(of: overlay)
        return renderToPNG(logicalWidth: size.width, logicalHeight: size.height, scale: scale, to: url) { context in
            draw(overlay, in: context, bounds: ViewerChromeRect(x: 0, y: 0, width: size.width, height: size.height))
        }
    }

    /// Renders a black window of `windowWidth` x `windowHeight` logical units
    /// with every overlay `state` says is on screen, each placed exactly the
    /// way `WaylandSessionWindow.relayoutChrome()` places it on a real
    /// compositor: `WaylandOverlayLayout` decides the rect, `SessionChromePainter`
    /// draws into it. `hostName` is what the strip's own confirmation names.
    @discardableResult
    public static func renderComposite(
        state: SessionChromeState,
        hostName: String,
        windowWidth: Double,
        windowHeight: Double,
        scale: Double,
        to url: URL
    ) -> Bool {
        // The band a pinned, open strip claims across the top, exactly as
        // `WaylandSessionWindow.relayoutChrome()` computes it -- the notice
        // and diagnostics panel move down by the same amount here.
        let topInset = WaylandOverlayLayout.topInset(
            isPinned: state.strip.isPinned,
            isStripOpen: state.isStripVisible,
            stripHeight: SessionChromePainter.stripHeight
        )
        return renderToPNG(logicalWidth: windowWidth, logicalHeight: windowHeight, scale: scale, to: url) { context in
            CairoChromeText.setSource(context, ViewerColor(hex: 0x000000))
            cairo_rectangle(context, 0, 0, windowWidth, windowHeight)
            cairo_fill(context)

            if let status = state.status, state.isStatusPanelVisible {
                let measured = SessionChromePainter.statusPanelSize(status: status)
                let rect = WaylandOverlayLayout.statusPanel(
                    windowWidth: windowWidth,
                    windowHeight: windowHeight,
                    contentWidth: measured.width,
                    contentHeight: measured.height
                )
                drawAt(rect, in: context) { bounds in
                    SessionChromePainter.drawStatusPanel(status: status, in: context, bounds: bounds)
                }
            }
            if state.isHandleVisible {
                let rect = WaylandOverlayLayout.stripHandle(
                    windowWidth: windowWidth,
                    contentWidth: SessionChromePainter.handleWidth,
                    contentHeight: SessionChromePainter.handleHeight
                )
                drawAt(rect, in: context) { bounds in
                    SessionChromePainter.drawHandle(in: context, bounds: bounds)
                }
            }
            if state.isStripVisible {
                let visibility = state.strip.visibility
                let isPinned = state.strip.isPinned
                let measured = SessionChromePainter.stripSize(visibility: visibility, hostName: hostName)
                let rect = WaylandOverlayLayout.shortcutStrip(
                    windowWidth: windowWidth,
                    contentWidth: measured.width,
                    contentHeight: measured.height
                )
                drawAt(rect, in: context) { bounds in
                    SessionChromePainter.drawStrip(
                        visibility: visibility, hostName: hostName, isPinned: isPinned, in: context, bounds: bounds
                    )
                }
            }
            if let line = state.notice {
                let measured = SessionChromePainter.noticeSize(line: line)
                let rect = WaylandOverlayLayout.transientNotice(
                    windowWidth: windowWidth,
                    contentWidth: measured.width,
                    contentHeight: measured.height,
                    topInset: topInset
                )
                drawAt(rect, in: context) { bounds in
                    SessionChromePainter.drawNotice(line: line, in: context, bounds: bounds)
                }
            }
            // Placed exactly where `WaylandSessionWindow.relayoutChrome()`
            // places the real diagnostics panel: top right, below the same
            // pinned-strip band the notice moved down by.
            if state.isDiagnosticsVisible {
                let blocks = state.diagnosticsBlocks
                let measured = SessionChromePainter.diagnosticsSize(blocks: blocks)
                let rect = WaylandOverlayLayout.diagnosticsHUD(
                    windowWidth: windowWidth,
                    contentWidth: measured.width,
                    contentHeight: measured.height,
                    topInset: topInset
                )
                drawAt(rect, in: context) { bounds in
                    SessionChromePainter.drawDiagnostics(blocks: blocks, in: context, bounds: bounds)
                }
            }
        }
    }

    // MARK: - Measuring and drawing one overlay

    private static func measuredSize(of overlay: Overlay) -> (width: Double, height: Double) {
        switch overlay {
        case let .statusPanel(status):
            SessionChromePainter.statusPanelSize(status: status)
        case let .notice(line):
            SessionChromePainter.noticeSize(line: line)
        case let .diagnostics(blocks):
            SessionChromePainter.diagnosticsSize(blocks: blocks)
        case .stripHandle:
            (SessionChromePainter.handleWidth, SessionChromePainter.handleHeight)
        case let .strip(visibility, hostName, _):
            SessionChromePainter.stripSize(visibility: visibility, hostName: hostName)
        }
    }

    private static func draw(_ overlay: Overlay, in context: OpaquePointer, bounds: ViewerChromeRect) {
        switch overlay {
        case let .statusPanel(status):
            SessionChromePainter.drawStatusPanel(status: status, in: context, bounds: bounds)
        case let .notice(line):
            SessionChromePainter.drawNotice(line: line, in: context, bounds: bounds)
        case let .diagnostics(blocks):
            SessionChromePainter.drawDiagnostics(blocks: blocks, in: context, bounds: bounds)
        case .stripHandle:
            SessionChromePainter.drawHandle(in: context, bounds: bounds)
        case let .strip(visibility, hostName, isPinned):
            SessionChromePainter.drawStrip(
                visibility: visibility, hostName: hostName, isPinned: isPinned, in: context, bounds: bounds
            )
        }
    }

    /// Translates to `rect`'s own origin so the body draws in the same local,
    /// top-left-relative coordinates every overlay's own paint code already
    /// assumes -- what a real subsurface's own position does for it.
    private static func drawAt(_ rect: ViewerChromeRect, in context: OpaquePointer, _ body: (ViewerChromeRect) -> Void) {
        cairo_save(context)
        cairo_translate(context, rect.x, rect.y)
        body(ViewerChromeRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cairo_restore(context)
    }

    // MARK: - Cairo plumbing

    /// One offscreen ARGB32 surface, drawn into at `scale` real pixels per
    /// logical unit exactly as `WaylandOverlaySurface.redraw()` scales its own
    /// context, then flushed and saved. No `WaylandShmBuffer` or compositor
    /// involved: `cairo_image_surface_create` is itself already "a cairo
    /// surface of a given pixel size," which is all `draw` ever needs.
    private static func renderToPNG(
        logicalWidth: Double,
        logicalHeight: Double,
        scale: Double,
        to url: URL,
        draw: (OpaquePointer) -> Void
    ) -> Bool {
        let pixelWidth = WaylandOverlayLayout.pixelSize(logical: logicalWidth, scale: scale)
        let pixelHeight = WaylandOverlayLayout.pixelSize(logical: logicalHeight, scale: scale)
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(pixelWidth), Int32(pixelHeight)),
              cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else {
            return false
        }
        defer { cairo_surface_destroy(surface) }
        guard let context = cairo_create(surface) else { return false }
        defer { cairo_destroy(context) }
        cairo_scale(context, scale, scale)
        draw(context)
        cairo_surface_flush(surface)
        return cairo_surface_write_to_png(surface, url.path) == CAIRO_STATUS_SUCCESS
    }
}
#endif
