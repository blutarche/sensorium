#if canImport(CWayland) && canImport(CCairo)
import CCairo
import CWayland
import CWaylandProtocols
import Foundation

/// One open menu of the session window's painted menu bar: an `xdg_popup`,
/// so it can reach past the window's own edges the way a menu does, drawn
/// with cairo into shared memory.
///
/// It takes no grab. The keyboard stays with the session window, which sends
/// keys to the open menu itself, and the window closes its menus on a press
/// anywhere else, on losing the keyboard, or when the compositor says the
/// popup is done.
@MainActor
final class WaylandMenuPopup {
    let surface: OpaquePointer
    /// This popup's own `xdg_surface`, which a submenu opened from it is
    /// positioned against.
    let xdgSurface: OpaquePointer
    let width: Double
    let height: Double

    var onDone: (() -> Void)?

    private let popup: OpaquePointer
    private let shm: OpaquePointer
    private let viewport: OpaquePointer?
    private let scale: Double
    private let draw: (OpaquePointer, ViewerChromeRect) -> Void
    private var buffers: [WaylandShmBuffer] = []
    private var isConfigured = false
    private var needsRedraw = false

    /// `anchor` is the rect in `parent`'s window geometry the popup opens
    /// from: below it for a menu from the bar, beside it for a submenu.
    init?(
        compositor: OpaquePointer,
        wmBase: OpaquePointer,
        parent: OpaquePointer,
        anchor: ViewerChromeRect,
        isSubmenu: Bool,
        width: Double,
        height: Double,
        scale: Double,
        shm: OpaquePointer,
        viewporter: OpaquePointer?,
        draw: @escaping (OpaquePointer, ViewerChromeRect) -> Void
    ) {
        guard let surface = wl_compositor_create_surface(compositor) else { return nil }
        guard let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface) else {
            wl_surface_destroy(surface)
            return nil
        }
        guard let positioner = xdg_wm_base_create_positioner(wmBase) else {
            xdg_surface_destroy(xdgSurface)
            wl_surface_destroy(surface)
            return nil
        }
        xdg_positioner_set_size(positioner, Int32(width.rounded(.up)), Int32(height.rounded(.up)))
        xdg_positioner_set_anchor_rect(
            positioner,
            Int32(anchor.x.rounded()),
            Int32(anchor.y.rounded()),
            max(1, Int32(anchor.width.rounded())),
            max(1, Int32(anchor.height.rounded()))
        )
        if isSubmenu {
            xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_TOP_RIGHT.rawValue)
            xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT.rawValue)
            xdg_positioner_set_offset(positioner, 0, -Int32(ViewerChromeMetrics.MenuBar.popupPaddingY))
            xdg_positioner_set_constraint_adjustment(
                positioner,
                XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X.rawValue | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y.rawValue
            )
        } else {
            xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_LEFT.rawValue)
            xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT.rawValue)
            xdg_positioner_set_constraint_adjustment(
                positioner,
                XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X.rawValue | XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y.rawValue
            )
        }
        guard let popup = xdg_surface_get_popup(xdgSurface, parent, positioner) else {
            xdg_positioner_destroy(positioner)
            xdg_surface_destroy(xdgSurface)
            wl_surface_destroy(surface)
            return nil
        }
        xdg_positioner_destroy(positioner)
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.popup = popup
        self.shm = shm
        self.width = width
        self.height = height
        self.scale = max(scale, 0.01)
        self.draw = draw
        viewport = viewporter.flatMap { wp_viewporter_get_viewport($0, surface) }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        xdg_surface_add_listener(xdgSurface, menuPopupSurfaceListener, opaqueSelf)
        xdg_popup_add_listener(popup, menuPopupListener, opaqueSelf)
        // The first commit carries no buffer; the compositor answers it with
        // the configure that lets the popup draw.
        wl_surface_commit(surface)
    }

    func redraw() {
        guard isConfigured else { return }
        let pixelWidth = WaylandOverlayLayout.pixelSize(logical: width, scale: scale)
        let pixelHeight = WaylandOverlayLayout.pixelSize(logical: height, scale: scale)
        guard let target = freeBuffer(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            needsRedraw = true
            return
        }
        needsRedraw = false
        target.clear()
        guard let context = cairo_create(target.cairoSurface) else { return }
        cairo_scale(context, scale, scale)
        draw(context, ViewerChromeRect(x: 0, y: 0, width: width, height: height))
        cairo_destroy(context)
        cairo_surface_flush(target.cairoSurface)
        if let viewport {
            wp_viewport_set_destination(viewport, Int32(width.rounded(.up)), Int32(height.rounded(.up)))
        }
        wl_surface_attach(surface, target.buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, Int32(pixelWidth), Int32(pixelHeight))
        wl_surface_commit(surface)
        target.markAttached()
    }

    func redrawIfOwed() {
        guard needsRedraw else { return }
        redraw()
    }

    /// A submenu's popup has to go before the popup it opened from, which
    /// the window's close order already guarantees.
    func tearDown() {
        for buffer in buffers {
            buffer.tearDown()
        }
        buffers = []
        if let viewport {
            wp_viewport_destroy(viewport)
        }
        xdg_popup_destroy(popup)
        xdg_surface_destroy(xdgSurface)
        wl_surface_destroy(surface)
    }

    fileprivate func handleConfigure(serial: UInt32) {
        xdg_surface_ack_configure(xdgSurface, serial)
        isConfigured = true
        redraw()
    }

    fileprivate func handleDone() {
        onDone?()
    }

    private func freeBuffer(pixelWidth: Int, pixelHeight: Int) -> WaylandShmBuffer? {
        if let free = buffers.first(where: { !$0.isHeldByCompositor }) {
            return free
        }
        guard buffers.count < 2,
              let fresh = WaylandShmBuffer(shm: shm, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        buffers.append(fresh)
        return fresh
    }
}

private func popupFrom(_ data: UnsafeMutableRawPointer?) -> WaylandMenuPopup? {
    guard let data else { return nil }
    return Unmanaged<WaylandMenuPopup>.fromOpaque(data).takeUnretainedValue()
}

nonisolated(unsafe) private let menuPopupSurfaceListener: UnsafeMutablePointer<xdg_surface_listener> = {
    let pointer = UnsafeMutablePointer<xdg_surface_listener>.allocate(capacity: 1)
    pointer.initialize(to: xdg_surface_listener(
        configure: { data, _, serial in
            guard let popup = popupFrom(data) else { return }
            MainActor.assumeIsolated { popup.handleConfigure(serial: serial) }
        }
    ))
    return pointer
}()

nonisolated(unsafe) private let menuPopupListener: UnsafeMutablePointer<xdg_popup_listener> = {
    let pointer = UnsafeMutablePointer<xdg_popup_listener>.allocate(capacity: 1)
    pointer.initialize(to: xdg_popup_listener(
        configure: { _, _, _, _, _, _ in },
        popup_done: { data, _ in
            guard let popup = popupFrom(data) else { return }
            MainActor.assumeIsolated { popup.handleDone() }
        },
        repositioned: { _, _, _ in }
    ))
    return pointer
}()
#endif
