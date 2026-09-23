#if canImport(CWayland) && canImport(CCairo)
import CCairo
import CWayland
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// One shared-memory buffer the compositor reads a drawn overlay out of.
///
/// Wayland has no drawing of its own: a client that wants text on screen
/// hands the compositor a block of memory both sides can see and says what
/// shape the pixels in it are. This is that block -- an anonymous file in the
/// runtime directory, mapped into this process, wrapped in a `wl_shm_pool`
/// and handed out as one `wl_buffer` of premultiplied ARGB, which is the one
/// format cairo and `wl_shm` already agree on.
///
/// A buffer the compositor is still reading must not be drawn into again, so
/// each one tracks whether it has been handed over and not yet given back.
@MainActor
final class WaylandShmBuffer {
    let buffer: OpaquePointer
    let pixelWidth: Int
    let pixelHeight: Int
    let stride: Int
    /// The cairo surface that draws into this buffer's own memory. No copy
    /// happens: cairo writes the pixels the compositor will read.
    let cairoSurface: OpaquePointer

    /// True from the commit that attached this buffer until the compositor
    /// says it is finished with it.
    private(set) var isHeldByCompositor = false

    private let pool: OpaquePointer
    private let memory: UnsafeMutableRawPointer
    private let byteCount: Int

    init?(shm: OpaquePointer, pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let stride = Int(cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, Int32(pixelWidth)))
        guard stride > 0 else { return nil }
        let byteCount = stride * pixelHeight
        guard let descriptor = Self.makeAnonymousFile(byteCount: byteCount) else { return nil }
        defer { close(descriptor) }

        guard let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        guard let pool = wl_shm_create_pool(shm, descriptor, Int32(byteCount)) else {
            munmap(mapped, byteCount)
            return nil
        }
        guard let buffer = wl_shm_pool_create_buffer(
            pool,
            0,
            Int32(pixelWidth),
            Int32(pixelHeight),
            Int32(stride),
            UInt32(WL_SHM_FORMAT_ARGB8888.rawValue)
        ) else {
            wl_shm_pool_destroy(pool)
            munmap(mapped, byteCount)
            return nil
        }
        guard let cairoSurface = cairo_image_surface_create_for_data(
            mapped.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32,
            Int32(pixelWidth),
            Int32(pixelHeight),
            Int32(stride)
        ) else {
            wl_buffer_destroy(buffer)
            wl_shm_pool_destroy(pool)
            munmap(mapped, byteCount)
            return nil
        }

        self.buffer = buffer
        self.pool = pool
        self.memory = mapped
        self.byteCount = byteCount
        self.stride = stride
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cairoSurface = cairoSurface
        wl_buffer_add_listener(buffer, bufferListener, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Marks this buffer as the compositor's until it says otherwise. Called
    /// by whoever committed the surface it was attached to.
    func markAttached() {
        isHeldByCompositor = true
    }

    fileprivate func markReleased() {
        isHeldByCompositor = false
    }

    /// Everything a fresh drawing starts from: fully transparent, so an
    /// overlay that shrank does not leave the previous drawing's edges behind.
    func clear() {
        memset(memory, 0, byteCount)
        cairo_surface_mark_dirty(cairoSurface)
    }

    func tearDown() {
        cairo_surface_destroy(cairoSurface)
        wl_buffer_destroy(buffer)
        wl_shm_pool_destroy(pool)
        munmap(memory, byteCount)
    }

    /// An unlinked file in this session's own runtime directory, sized and
    /// ready to map. Unlinked immediately: the descriptor is the only handle
    /// either side needs, and nothing should be able to open it by name.
    private static func makeAnonymousFile(byteCount: Int) -> Int32? {
        let directory = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        var template = Array("\(directory)/sensorium-overlay-XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            let opened = mkstemp(base)
            if opened >= 0 {
                unlink(base)
            }
            return opened
        }
        guard descriptor >= 0 else { return nil }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}

nonisolated(unsafe) private let bufferListener: UnsafeMutablePointer<wl_buffer_listener> = {
    let pointer = UnsafeMutablePointer<wl_buffer_listener>.allocate(capacity: 1)
    pointer.initialize(to: wl_buffer_listener(release: { data, _ in
        guard let data else { return }
        let held = Unmanaged<WaylandShmBuffer>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated { held.markReleased() }
    }))
    return pointer
}()
#endif
