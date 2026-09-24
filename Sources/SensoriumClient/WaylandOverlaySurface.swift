#if canImport(CWayland) && canImport(CCairo)
import CCairo
import CWayland
import CWaylandProtocols
import Foundation

/// One piece of chrome drawn over the session picture: a Wayland subsurface
/// of the window's own surface, backed by shared memory and drawn with cairo.
///
/// A subsurface is the compositor's own answer to "put this on top of that":
/// it is positioned in the parent's logical coordinates, composited above the
/// parent, and -- once desynchronised -- committed on its own clock. That is
/// what keeps a status change from waiting for a video frame and a video
/// frame from waiting for text.
///
/// The buffer is drawn in real pixels at the surface's fractional scale and
/// mapped back onto the parent's logical size by a `wp_viewport`, exactly the
/// way the picture underneath already is. Two buffers, used alternately: a
/// buffer the compositor is still reading is never drawn into again.
@MainActor
final class WaylandOverlaySurface {
    /// The compositor's own handle for this overlay, which is what a pointer
    /// event names when the pointer is over it.
    let surface: OpaquePointer

    /// Where this overlay sits in the parent's logical units, or `nil` while
    /// it has never been placed.
    private(set) var rect: ViewerChromeRect?
    private(set) var isVisible = false

    private let subsurface: OpaquePointer
    private let shm: OpaquePointer
    private let viewport: OpaquePointer?
    private var buffers: [WaylandShmBuffer] = []
    /// Buffers of a size this overlay has outgrown, kept only until the
    /// compositor says it has finished reading them.
    private var retired: [WaylandShmBuffer] = []
    private var scale: Double = 1
    /// Set when a redraw could not run because both buffers were still with
    /// the compositor, so the next release is followed by the drawing that
    /// was skipped.
    private var needsRedraw = false
    /// What this overlay draws, given a cairo context already scaled so the
    /// closure works in logical units.
    private var draw: ((OpaquePointer, ViewerChromeRect) -> Void)?

    init?(
        compositor: OpaquePointer,
        subcompositor: OpaquePointer,
        parent: OpaquePointer,
        shm: OpaquePointer,
        viewporter: OpaquePointer?
    ) {
        guard let surface = wl_compositor_create_surface(compositor) else { return nil }
        guard let subsurface = wl_subcompositor_get_subsurface(subcompositor, surface, parent) else {
            wl_surface_destroy(surface)
            return nil
        }
        self.surface = surface
        self.subsurface = subsurface
        self.shm = shm
        viewport = viewporter.flatMap { wp_viewporter_get_viewport($0, surface) }
        // Desynchronised from the parent: chrome and picture are two
        // different clocks, and neither should be able to stall the other.
        wl_subsurface_set_desync(subsurface)
        // Nothing is on screen until something is drawn: an overlay with no
        // buffer attached occupies nothing and takes no input.
        wl_surface_attach(surface, nil, 0, 0)
        wl_surface_commit(surface)
    }

    /// What this overlay draws. The context handed to the closure is already
    /// scaled, so the closure works in the same logical units the rect is in,
    /// with its own origin at the overlay's top-left corner.
    func setDrawing(_ draw: @escaping (OpaquePointer, ViewerChromeRect) -> Void) {
        self.draw = draw
    }

    /// Holds the parent's own commits back while it is being resized, so a
    /// resize moves the picture and the chrome on it in one atomic step
    /// rather than showing chrome at the old place over a picture at the new
    /// one.
    func setSynchronisedWithParent(_ isSynchronised: Bool) {
        if isSynchronised {
            wl_subsurface_set_sync(subsurface)
        } else {
            wl_subsurface_set_desync(subsurface)
        }
    }

    /// Takes the overlay off screen without destroying it. A subsurface with
    /// no buffer is not composited and receives no pointer events, which is
    /// exactly what a hidden overlay should be.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        needsRedraw = false
        wl_surface_attach(surface, nil, 0, 0)
        wl_surface_commit(surface)
    }

    /// Puts the overlay at `rect`, in the parent's logical units, and draws
    /// it at `scale` real pixels per logical unit.
    func show(at rect: ViewerChromeRect, scale: Double) {
        self.rect = rect
        self.scale = max(scale, 0.01)
        isVisible = true
        wl_subsurface_set_position(subsurface, Int32(rect.x.rounded()), Int32(rect.y.rounded()))
        redraw()
    }

    /// Whether a point in the parent's logical units is inside this overlay
    /// while it is on screen.
    func containsInParent(x: Double, y: Double) -> Bool {
        guard isVisible, let rect else { return false }
        return rect.contains(x: x, y: y)
    }

    func redraw() {
        guard isVisible, let rect, let draw else { return }
        let pixelWidth = WaylandOverlayLayout.pixelSize(logical: rect.width, scale: scale)
        let pixelHeight = WaylandOverlayLayout.pixelSize(logical: rect.height, scale: scale)
        guard let target = buffer(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            // Both buffers are still the compositor's. The drawing is owed,
            // not lost: the next release runs it.
            needsRedraw = true
            return
        }
        needsRedraw = false
        target.clear()
        guard let context = cairo_create(target.cairoSurface) else { return }
        cairo_scale(context, scale, scale)
        draw(context, ViewerChromeRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cairo_destroy(context)
        cairo_surface_flush(target.cairoSurface)

        if let viewport {
            wp_viewport_set_destination(viewport, Int32(rect.width.rounded()), Int32(rect.height.rounded()))
        }
        wl_surface_attach(surface, target.buffer, 0, 0)
        wl_surface_damage_buffer(surface, 0, 0, Int32(pixelWidth), Int32(pixelHeight))
        wl_surface_commit(surface)
        target.markAttached()
    }

    /// Runs a redraw that was skipped for want of a free buffer. Called once
    /// per compositor round, from the window's own frame callback.
    func redrawIfOwed() {
        guard needsRedraw else { return }
        redraw()
    }

    func tearDown() {
        for buffer in buffers + retired {
            buffer.tearDown()
        }
        buffers = []
        retired = []
        if let viewport {
            wp_viewport_destroy(viewport)
        }
        wl_subsurface_destroy(subsurface)
        wl_surface_destroy(surface)
    }

    /// A buffer of exactly this size that the compositor is not reading.
    ///
    /// An overlay changes size whenever the text in it does, so a buffer of
    /// the previous size is retired rather than reused. Retired is not the
    /// same as freed: the compositor may still be reading one, and its own
    /// release event is delivered to the buffer object, so it is held until
    /// that arrives.
    private func buffer(pixelWidth: Int, pixelHeight: Int) -> WaylandShmBuffer? {
        retired.removeAll { candidate in
            guard !candidate.isHeldByCompositor else { return false }
            candidate.tearDown()
            return true
        }
        let stale = buffers.filter { $0.pixelWidth != pixelWidth || $0.pixelHeight != pixelHeight }
        if !stale.isEmpty {
            buffers.removeAll { $0.pixelWidth != pixelWidth || $0.pixelHeight != pixelHeight }
            for buffer in stale {
                if buffer.isHeldByCompositor {
                    retired.append(buffer)
                } else {
                    buffer.tearDown()
                }
            }
        }
        if let free = buffers.first(where: { !$0.isHeldByCompositor }) {
            return free
        }
        guard buffers.count < 2 else { return nil }
        guard let fresh = WaylandShmBuffer(shm: shm, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        buffers.append(fresh)
        return fresh
    }
}
#endif
