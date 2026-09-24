#if canImport(CEGL) && canImport(CAVCodec)
import CAVCodec
import CEGL
import CVASurfaceExport
import CWayland
import Foundation
import SensoriumCore

extension EGLFramePresenter: CanvasFramePresenting {}

public enum EGLFramePresenterError: Error, Equatable {
    case displayUnavailable(UInt32)
    case configUnavailable(UInt32)
    case contextUnavailable(UInt32)
    case surfaceUnavailable(UInt32)
    case shaderCompilationFailed(String)
    case unsupportedPixelFormat(Int32)
}

/// What a thread had bound to EGL at one moment: a context, the two surfaces
/// it was reading and drawing through, and the display all three belong to.
///
/// EGL currency is a property of the thread, not of the object holding the
/// context, and every GL call goes to whichever context is current when it is
/// made. This viewer shares its thread with a widget toolkit that binds a
/// context of its own, so neither side may assume the binding it made is still
/// the binding in force: a draw made against someone else's binding is
/// silently dropped, and the window stays black while every counter says
/// frames were drawn.
private struct EGLBinding {
    let display: EGLDisplay?
    let draw: EGLSurface?
    let read: EGLSurface?
    let context: EGLContext?

    static func current() -> EGLBinding {
        EGLBinding(
            display: eglGetCurrentDisplay(),
            draw: eglGetCurrentSurface(EGLint(EGL_DRAW)),
            read: eglGetCurrentSurface(EGLint(EGL_READ)),
            context: eglGetCurrentContext()
        )
    }

    /// Binds this again. With nothing to put back, the caller's own display is
    /// what the release is asked of, since a release still names a display.
    func restore(unbindingOn fallbackDisplay: EGLDisplay) {
        guard let context, context != sensorium_egl_no_context(), let display,
              display != sensorium_egl_no_display() else {
            eglMakeCurrent(
                fallbackDisplay,
                sensorium_egl_no_surface(),
                sensorium_egl_no_surface(),
                sensorium_egl_no_context()
            )
            return
        }
        eglMakeCurrent(display, draw, read, context)
    }
}

/// Draws one surface's decoded frames onto its Wayland surface through EGL and
/// OpenGL ES, on the compositor's own frame callbacks and at the pace
/// `PresentationPacer` decides.
///
/// The two shapes a decoded frame arrives in are both drawn as one textured
/// quad. A frame the GPU decoded stays on the GPU: its VA-API surface is
/// exported as dma-buf descriptors and imported as two `EGLImage`s, one per
/// plane, with no copy anywhere. A frame decoded in software is uploaded plane
/// by plane. Either way the colour conversion happens in the fragment shader,
/// generated from `NV12ColorConversion`, and the letterbox is the clear colour
/// rather than a picture drawn underneath.
@MainActor
public final class EGLFramePresenter {
    // Read from `deinit`, which is not isolated to this actor: they are
    // handles the GPU driver owns, and tearing them down is the last thing
    // anything does with them.
    nonisolated(unsafe) private let display: EGLDisplay
    nonisolated(unsafe) private let context: EGLContext
    nonisolated(unsafe) private let surface: EGLSurface
    private let drops: ViewerFrameDropCounter?
    private var pacer = PresentationPacer()
    /// One program per colour conversion, of which a session uses one. Built
    /// on first use because the matrix is compiled into the shader.
    private var programs: [NV12ColorConversion: Program] = [:]
    private var textures: [GLuint] = []
    private var latestFrame: AVFrameBox?
    private var latestTiming: FrameTiming?
    private var dueAtNanoseconds: Int64?
    private var hasUndrawnFrame = false
    private var hasReportedRenderFailure = false
    /// What the drawable is currently sized to, so `glViewport` is set from
    /// the size the window last resized its EGL window to.
    private var drawablePixelWidth = 0
    private var drawablePixelHeight = 0
    /// A band across the top of the drawable the picture may not use, in the
    /// same pixels the drawable is measured in: what a pinned shortcut strip
    /// has claimed. Zero whenever no strip is pinned open.
    public var videoTopInsetPixels = 0

    /// Called with each frame this presenter really drew and the moment it
    /// swapped. A frame superseded while it waited never reaches this.
    public var onFramePresented: ((FrameTiming, Int64) -> Void)?

    /// How many frames this presenter really put on screen.
    public private(set) var presentedFrameCount = 0

    /// Whether something else on this thread held the GL context at the moment
    /// this presenter went to draw its first frame -- see `EGLBinding`. `nil`
    /// until that first draw. Read by the run's optional presentation trace,
    /// which is the only thing that reports it.
    public private(set) var foundForeignContextAtFirstDraw: Bool?

    /// Called once, with what the first real draw found: which client API
    /// this thread had bound, whether this presenter's own context was in
    /// force once it had asked for it, which driver answered, what the pixel
    /// at the middle of the picture came back as, and what EGL made of the
    /// swap. A window showing nothing and a window showing a black picture
    /// are the same window from outside, and this is what tells them apart.
    /// Set only by a run that asked for a trace; nothing is read back
    /// otherwise, because a read-back stalls the pipeline it measures.
    public var onFirstDrawDiagnostics: ((String) -> Void)?
    private var hasReportedFirstDrawDiagnostics = false
    /// Every completion sample added together, so a run can report the mean
    /// alongside the percentiles `LatencySamples` keeps.
    private var completionTotalNanoseconds: Int64 = 0

    /// The mean of those samples, or `nil` before there are any.
    public var meanCompletionLatencyNanoseconds: Int64? {
        guard completionLatency.count > 0 else { return nil }
        return completionTotalNanoseconds / Int64(completionLatency.count)
    }

    /// How long a frame takes from the moment it was due on screen to the
    /// compositor reporting it on the screen. Measured from the due time
    /// rather than from `present(_:)`, so the hold this viewer adds on purpose
    /// is reported as the hold and never as the GPU being slow.
    public private(set) var completionLatency = LatencySamples()

    /// Whether the completion figure above is a real presentation time from
    /// the compositor, or the moment `eglSwapBuffers` returned. The window
    /// sets this to `false` once `wp_presentation` has agreed to report on a
    /// clock this machine can compare against; until then, and on a
    /// compositor that offers no such report at all, the swap's return is the
    /// only completion signal there is, and it is earlier than the real one.
    public var measuresCompletionAtSwap = true

    public init(
        waylandDisplay: OpaquePointer,
        eglWindow: OpaquePointer,
        pixelWidth: Int,
        pixelHeight: Int,
        drops: ViewerFrameDropCounter? = nil
    ) throws {
        self.drops = drops
        guard let display = sensorium_egl_display_for_native(UnsafeMutableRawPointer(waylandDisplay)),
              display != sensorium_egl_no_display() else {
            throw EGLFramePresenterError.displayUnavailable(eglGetError().magnitude)
        }
        var major: EGLint = 0
        var minor: EGLint = 0
        guard eglInitialize(display, &major, &minor) == EGL_TRUE else {
            throw EGLFramePresenterError.displayUnavailable(eglGetError().magnitude)
        }
        guard eglBindAPI(EGLenum(EGL_OPENGL_ES_API)) == EGL_TRUE else {
            throw EGLFramePresenterError.displayUnavailable(eglGetError().magnitude)
        }
        self.display = display

        let configAttributes: [EGLint] = [
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 0,
            EGL_NONE
        ]
        var config: EGLConfig?
        var configCount: EGLint = 0
        guard eglChooseConfig(display, configAttributes, &config, 1, &configCount) == EGL_TRUE,
              configCount > 0, let config else {
            throw EGLFramePresenterError.configUnavailable(eglGetError().magnitude)
        }

        let contextAttributes: [EGLint] = [EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE]
        guard let context = eglCreateContext(display, config, sensorium_egl_no_context(), contextAttributes),
              context != sensorium_egl_no_context() else {
            throw EGLFramePresenterError.contextUnavailable(eglGetError().magnitude)
        }
        self.context = context

        guard let surface = sensorium_egl_create_window_surface(
            display,
            config,
            UnsafeMutableRawPointer(eglWindow)
        ), surface != sensorium_egl_no_surface() else {
            throw EGLFramePresenterError.surfaceUnavailable(eglGetError().magnitude)
        }
        self.surface = surface

        // Put back whatever this thread had bound before, once the objects
        // below are built. This process runs a widget toolkit on the same
        // thread, and a toolkit that still believes its own context is
        // current would otherwise draw into this window's surface.
        let previousBinding = EGLBinding.current()
        defer { previousBinding.restore(unbindingOn: display) }
        guard eglMakeCurrent(display, surface, surface, context) == EGL_TRUE else {
            throw EGLFramePresenterError.contextUnavailable(eglGetError().magnitude)
        }
        // Never block inside the swap: which refresh a frame belongs on is the
        // pacer's decision, taken on the compositor's own frame callback, and
        // a swap that waited for the next refresh would stall the one thread
        // this viewer runs everything on.
        eglSwapInterval(display, 0)

        textures = [GLuint](repeating: 0, count: 3)
        textures.withUnsafeMutableBufferPointer { glGenTextures(3, $0.baseAddress) }
        for texture in textures {
            glBindTexture(GLenum(GL_TEXTURE_2D), texture)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        }
        resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    // Read and written from `deinit`, which is not isolated to this actor;
    // see the comment on `display` above.
    nonisolated(unsafe) private var hasTornDown = false

    /// Tears down every EGL object this presenter owns, in the reverse of the
    /// order they were built, and only once: a second call is a no-op. A
    /// caller that owns the native window these objects were built against
    /// must call this before destroying it, because `deinit` runs whenever
    /// the last reference goes away, which is not guaranteed to be before
    /// that window is gone.
    public nonisolated func tearDown() {
        guard !hasTornDown else { return }
        hasTornDown = true
        // Only this presenter's own binding is given up: releasing whatever
        // else happens to be current would take the context away from
        // whichever part of this process is drawing with it.
        if eglGetCurrentContext() == context {
            eglMakeCurrent(
                display,
                sensorium_egl_no_surface(),
                sensorium_egl_no_surface(),
                sensorium_egl_no_context()
            )
        }
        eglDestroySurface(display, surface)
        eglDestroyContext(display, context)
        eglTerminate(display)
    }

    deinit {
        tearDown()
    }

    public func resize(pixelWidth: Int, pixelHeight: Int) {
        drawablePixelWidth = max(pixelWidth, 1)
        drawablePixelHeight = max(pixelHeight, 1)
    }

    /// How far past its capture time each frame is currently being held, for
    /// the session panel to show.
    public var holdNanoseconds: Int64 {
        pacer.holdNanoseconds
    }

    /// Takes one decoded frame and returns. Nothing is drawn here: the frame
    /// waits until the frame callback its due time falls on.
    public func present(_ frame: DecodedFrame) {
        let superseded = pacer.admit(frame, nowNanoseconds: MonotonicClock.nowNanoseconds())
        drops?.recordDroppedBeforePresent(superseded)
    }

    /// Gives up every frame still waiting and forgets what this session taught
    /// the pacer about the link. The picture already on screen stays.
    public func discardPendingFrames() {
        pacer.reset()
    }

    /// Draws whichever frame is due, if any, and swaps. Returns the moment
    /// that frame was due on screen when something really was drawn, which is
    /// what a later presentation report is measured from.
    ///
    /// Called on every frame callback, and drawing nothing is a normal
    /// outcome: the picture already on screen is then still the right one.
    @discardableResult
    public func drawIfDue(nowNanoseconds: Int64) -> Int64? {
        guard !hasTornDown else { return nil }
        if let due = pacer.frameToPresent(nowNanoseconds: nowNanoseconds) {
            drops?.recordDroppedBeforePresent(due.supersededCount)
            latestFrame = due.frame.payload as? AVFrameBox
            latestTiming = due.frame.timing
            dueAtNanoseconds = due.dueAtNanoseconds
            hasUndrawnFrame = latestFrame != nil
        }
        guard hasUndrawnFrame, let frame = latestFrame else {
            return nil
        }
        if foundForeignContextAtFirstDraw == nil {
            foundForeignContextAtFirstDraw = eglGetCurrentContext() != context
        }
        // Queried only when a trace will actually use it: `eglQueryAPI` is
        // itself a call against thread-global EGL state, and asking it on
        // every callback would be a needless extra query on the hot path.
        let shouldReportFirstDraw = onFirstDrawDiagnostics != nil && !hasReportedFirstDrawDiagnostics
        let apiBeforeBinding: EGLenum = shouldReportFirstDraw ? eglQueryAPI() : EGLenum(EGL_NONE)
        let drew = withCurrentContext { () -> Bool in
            let release: (() -> Void)?
            do {
                release = try draw(frame)
            } catch {
                reportRenderFailure(error)
                // Given up rather than kept: a frame the GPU refused once it
                // will refuse on every callback after it, and holding on to it
                // would keep the frames behind it off the screen as well.
                drops?.recordDroppedBeforePresent(1)
                latestFrame = nil
                latestTiming = nil
                hasUndrawnFrame = false
                return false
            }
            let diagnostics = shouldReportFirstDraw
                ? firstDrawReport(apiBeforeBinding: apiBeforeBinding, frame: frame)
                : nil
            eglSwapBuffers(display, surface)
            if let diagnostics {
                hasReportedFirstDrawDiagnostics = true
                onFirstDrawDiagnostics?(diagnostics + " swap-error=\(String(eglGetError(), radix: 16))")
            }
            // The exported surface's dma-buf fds and EGLImages must outlive
            // the draw call -- the GPU reads them lazily -- but not the swap:
            // once `eglSwapBuffers` has returned, the rendered frame has been
            // taken, and it is safe to let the decoder reuse or free what
            // backed it.
            release?()
            return true
        }
        guard let drew, drew else { return nil }
        hasUndrawnFrame = false
        presentedFrameCount += 1
        let swappedAt = MonotonicClock.nowNanoseconds()
        if measuresCompletionAtSwap, let dueAtNanoseconds {
            record(completion: swappedAt - dueAtNanoseconds)
        }
        if let latestTiming {
            onFramePresented?(latestTiming, swappedAt)
        }
        return dueAtNanoseconds
    }

    /// One real presentation time from the compositor, for the frame that was
    /// due at `dueAtNanoseconds`. Used instead of the swap's return once the
    /// window has confirmed the compositor reports on this machine's own
    /// monotonic clock.
    public func recordPresentationCompleted(dueAtNanoseconds: Int64, presentedAtNanoseconds: Int64) {
        record(completion: presentedAtNanoseconds - dueAtNanoseconds)
    }

    private func record(completion nanoseconds: Int64) {
        completionLatency.record(nanoseconds: nanoseconds)
        completionTotalNanoseconds += nanoseconds
    }

    /// What the picture looked like to this process at the moment it was
    /// drawn, read back from the drawable before the swap takes it.
    ///
    /// The colour is read at the middle of the video rect, which is inside
    /// the picture whenever there is one at all, and never in the letterbox.
    private func firstDrawReport(apiBeforeBinding: EGLenum, frame: AVFrameBox) -> String {
        let videoRect = CanvasPresentationLayout.videoRect(
            sourceWidth: Double(frame.width),
            sourceHeight: Double(frame.height),
            viewportWidth: Double(drawablePixelWidth),
            viewportHeight: Double(drawablePixelHeight),
            topInset: Double(videoTopInsetPixels)
        )
        var pixels = [UInt8](repeating: 0, count: 16)
        // `glReadPixels` counts rows from the bottom of the drawable, while
        // the video rect counts from the top.
        let centreX = GLint(videoRect.x + videoRect.width / 2)
        let centreY = GLint(Double(drawablePixelHeight) - (videoRect.y + videoRect.height / 2))
        pixels.withUnsafeMutableBytes { buffer in
            glReadPixels(
                centreX, centreY, 2, 2,
                GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE),
                buffer.baseAddress
            )
        }
        let renderer = glGetString(GLenum(GL_RENDERER)).map { String(cString: $0) } ?? "unknown"
        let source = Self.sourceRange(of: frame)
        let colour = pixels.prefix(4).map { String($0) }.joined(separator: ",")
        return "first draw; egl-api-before=\(String(apiBeforeBinding, radix: 16)) "
            + "bind-error=\(String(lastBindErrorCode, radix: 16)) "
            + "context-held-elsewhere=\(foundForeignContextAtFirstDraw == true ? "yes" : "no") "
            + "own-context-bound=\(eglGetCurrentContext() == context ? "yes" : "no") "
            + "own-display-bound=\(eglGetCurrentDisplay() == display ? "yes" : "no") "
            + "renderer=\(renderer) frame=\(frame.width)x\(frame.height) "
            + "video-rect=\(Int(videoRect.width))x\(Int(videoRect.height))"
            + "+\(Int(videoRect.x))+\(Int(videoRect.y)) "
            + "centre-pixel=\(colour) \(source)"
    }

    /// What a coarse grid over one decoded frame finds in each of its planes,
    /// which says whether the picture that arrived is itself black: luma at
    /// its limited-range floor with chroma sitting at the neutral 128 is a
    /// black picture, and no amount of drawing will make it anything else.
    /// Only a frame decoded in software can be read here; a frame still on
    /// the GPU answers `on-gpu`.
    private static func sourceRange(of box: AVFrameBox) -> String {
        if box.pixelFormat == AV_PIX_FMT_VAAPI {
            return "source=on-gpu"
        }
        guard let frame = box.frame else {
            return "source=no-frame"
        }
        let luma = range(
            plane: frame.pointee.data.0,
            rowBytes: Int(frame.pointee.linesize.0),
            width: box.width,
            height: box.height,
            bytesPerSample: 1
        )
        let chroma: String
        switch box.pixelFormat {
        case AV_PIX_FMT_NV12:
            // One interleaved plane, so both channels are read at a stride of
            // two bytes, starting at each of them in turn.
            let blue = range(
                plane: frame.pointee.data.1,
                rowBytes: Int(frame.pointee.linesize.1),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerSample: 2
            )
            let red = range(
                plane: frame.pointee.data.1.map { $0 + 1 },
                rowBytes: Int(frame.pointee.linesize.1),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerSample: 2
            )
            chroma = "\(blue) \(red)"
        case AV_PIX_FMT_YUV420P:
            let blue = range(
                plane: frame.pointee.data.1,
                rowBytes: Int(frame.pointee.linesize.1),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerSample: 1
            )
            let red = range(
                plane: frame.pointee.data.2,
                rowBytes: Int(frame.pointee.linesize.2),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerSample: 1
            )
            chroma = "\(blue) \(red)"
        default:
            chroma = "unreadable unreadable"
        }
        return "source-luma=\(luma) source-chroma=\(chroma)"
    }

    /// The lowest and highest value a grid of at most 16 by 16 samples finds
    /// in one plane, as `lowest-highest`.
    private static func range(
        plane: UnsafeMutablePointer<UInt8>?,
        rowBytes: Int,
        width: Int,
        height: Int,
        bytesPerSample: Int
    ) -> String {
        guard let plane, rowBytes > 0, width > 0, height > 0 else { return "unreadable" }
        var lowest = 255
        var highest = 0
        for row in stride(from: 0, to: height, by: max(height / 16, 1)) {
            for column in stride(from: 0, to: width, by: max(width / 16, 1)) {
                let value = Int(plane[row * rowBytes + column * bytesPerSample])
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        return "\(lowest)-\(highest)"
    }

    /// Clears the whole drawable and swaps, with no picture at all. The first
    /// thing a window does once it has been configured, so the compositor has
    /// a buffer to show rather than nothing.
    public func clear() {
        withCurrentContext {
            glViewport(0, 0, GLsizei(drawablePixelWidth), GLsizei(drawablePixelHeight))
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            eglSwapBuffers(display, surface)
        }
    }

    /// EGL's error immediately after this presenter last tried to bind its
    /// own context, read separately from the swap's own error so a first-draw
    /// report can never confuse the two. `EGL_SUCCESS` when the context was
    /// already bound and no bind was attempted.
    private var lastBindErrorCode: EGLint = EGLint(EGL_SUCCESS)

    /// Runs `body` with this presenter's own context and surface bound, and
    /// puts back whatever this thread had bound before. Returns `nil`,
    /// without running `body`, when the bind itself failed: drawing against a
    /// binding that was never actually made would be worse than skipping the
    /// frame. Every GL call and every swap this presenter makes goes through
    /// here -- see `EGLBinding` for why neither half of the restore can be
    /// left out.
    private func withCurrentContext<T>(_ body: () throws -> T) rethrows -> T? {
        let previous = EGLBinding.current()
        let isAlreadyBound = previous.context == context && previous.draw == surface
        if !isAlreadyBound {
            let bound = eglMakeCurrent(display, surface, surface, context)
            lastBindErrorCode = eglGetError()
            guard bound == EGL_TRUE else { return nil }
        } else {
            lastBindErrorCode = EGLint(EGL_SUCCESS)
        }
        defer {
            if !isAlreadyBound {
                previous.restore(unbindingOn: display)
            }
        }
        return try body()
    }

    /// Draws one frame and hands back what has to run once the swap that
    /// takes it has returned -- `nil` when nothing was bound because the
    /// letterbox left no video rect to draw into. A throw after the planes
    /// were bound still releases them, so a shader or program failure never
    /// leaks the exported surface behind the frame.
    private func draw(_ frame: AVFrameBox) throws -> (() -> Void)? {
        let videoRect = CanvasPresentationLayout.videoRect(
            sourceWidth: Double(frame.width),
            sourceHeight: Double(frame.height),
            viewportWidth: Double(drawablePixelWidth),
            viewportHeight: Double(drawablePixelHeight),
            topInset: Double(videoTopInsetPixels)
        )
        glViewport(0, 0, GLsizei(drawablePixelWidth), GLsizei(drawablePixelHeight))
        // The bars beside or above the picture, drawn by clearing rather than
        // by compositing the frame over a black picture.
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        guard videoRect.width > 0, videoRect.height > 0 else {
            return nil
        }

        let source = try bindPlanes(of: frame)
        do {
            let program = try program(for: source.conversion, layout: source.layout)
            glUseProgram(program.identifier)
            glUniform2f(
                program.scale,
                GLfloat(2 * videoRect.width / Double(drawablePixelWidth)),
                GLfloat(-2 * videoRect.height / Double(drawablePixelHeight))
            )
            glUniform2f(
                program.offset,
                GLfloat(2 * videoRect.x / Double(drawablePixelWidth) - 1),
                GLfloat(1 - 2 * videoRect.y / Double(drawablePixelHeight))
            )
            for (index, sampler) in program.samplers.enumerated() where index < source.layout.planeCount {
                glUniform1i(sampler, GLint(index))
            }
            glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        } catch {
            source.release()
            throw error
        }
        return source.release
    }

    /// What one frame's planes look like once they are on the GPU: how many
    /// there are, which conversion they need, and whatever has to be let go of
    /// after the draw.
    private struct BoundPlanes {
        let layout: PlaneLayout
        let conversion: NV12ColorConversion
        let release: () -> Void
    }

    private enum PlaneLayout: Hashable {
        /// Luma and interleaved chroma.
        case biplanar
        /// Luma and the two chroma channels in planes of their own.
        case triplanar

        var planeCount: Int {
            switch self {
            case .biplanar: return 2
            case .triplanar: return 3
            }
        }
    }

    private func bindPlanes(of box: AVFrameBox) throws -> BoundPlanes {
        guard let frame = box.frame else {
            throw EGLFramePresenterError.unsupportedPixelFormat(box.pixelFormat.rawValue)
        }
        let conversion = NV12ColorConversion.matching(
            colorspace: Self.signalledColorspace(of: frame),
            isFullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG
        )
        if box.pixelFormat == AV_PIX_FMT_VAAPI {
            return try bindExportedSurface(of: box, conversion: conversion)
        }
        switch box.pixelFormat {
        case AV_PIX_FMT_NV12:
            uploadPlane(
                index: 0,
                data: frame.pointee.data.0,
                stride: Int(frame.pointee.linesize.0),
                width: box.width,
                height: box.height,
                bytesPerPixel: 1
            )
            uploadPlane(
                index: 1,
                data: frame.pointee.data.1,
                stride: Int(frame.pointee.linesize.1),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerPixel: 2
            )
            return BoundPlanes(layout: .biplanar, conversion: conversion, release: {})
        case AV_PIX_FMT_YUV420P:
            uploadPlane(
                index: 0,
                data: frame.pointee.data.0,
                stride: Int(frame.pointee.linesize.0),
                width: box.width,
                height: box.height,
                bytesPerPixel: 1
            )
            uploadPlane(
                index: 1,
                data: frame.pointee.data.1,
                stride: Int(frame.pointee.linesize.1),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerPixel: 1
            )
            uploadPlane(
                index: 2,
                data: frame.pointee.data.2,
                stride: Int(frame.pointee.linesize.2),
                width: (box.width + 1) / 2,
                height: (box.height + 1) / 2,
                bytesPerPixel: 1
            )
            return BoundPlanes(layout: .triplanar, conversion: conversion, release: {})
        default:
            throw EGLFramePresenterError.unsupportedPixelFormat(box.pixelFormat.rawValue)
        }
    }

    /// The zero-copy path: the decoder's own surface, handed to the GPU as
    /// dma-buf descriptors rather than read back and uploaded.
    private func bindExportedSurface(
        of box: AVFrameBox,
        conversion: NV12ColorConversion
    ) throws -> BoundPlanes {
        guard let vaDisplay = box.vaDisplay, let vaSurface = box.vaSurfaceID else {
            throw EGLFramePresenterError.unsupportedPixelFormat(box.pixelFormat.rawValue)
        }
        var exported = SensoriumExportedSurface()
        let status = sensorium_export_va_surface(vaDisplay, vaSurface, &exported)
        guard status == 0 else {
            throw EGLFramePresenterError.unsupportedPixelFormat(status)
        }
        var images: [EGLImageKHR] = []
        let layers = withUnsafeBytes(of: exported.layers) { raw in
            Array(raw.bindMemory(to: SensoriumExportedSurfaceLayer.self).prefix(Int(exported.layer_count)))
        }
        for (index, layer) in layers.enumerated() {
            let attributes: [EGLint] = [
                EGL_WIDTH, EGLint(layer.width),
                EGL_HEIGHT, EGLint(layer.height),
                EGL_LINUX_DRM_FOURCC_EXT, EGLint(bitPattern: layer.drm_format),
                EGL_DMA_BUF_PLANE0_FD_EXT, EGLint(layer.fd),
                EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGLint(layer.offset),
                EGL_DMA_BUF_PLANE0_PITCH_EXT, EGLint(layer.pitch),
                EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGLint(bitPattern: UInt32(layer.modifier & 0xFFFF_FFFF)),
                EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGLint(bitPattern: UInt32(layer.modifier >> 32)),
                EGL_NONE
            ]
            guard let image = attributes.withUnsafeBufferPointer({
                sensorium_egl_create_dma_buf_image(display, $0.baseAddress)
            }), image != sensorium_egl_no_image() else {
                for image in images {
                    sensorium_egl_destroy_image(display, image)
                }
                sensorium_close_exported_surface(&exported)
                throw EGLFramePresenterError.unsupportedPixelFormat(Int32(bitPattern: eglGetError().magnitude))
            }
            images.append(image)
            glActiveTexture(GLenum(GL_TEXTURE0 + Int32(index)))
            glBindTexture(GLenum(GL_TEXTURE_2D), textures[index])
            sensorium_gl_bind_egl_image_to_texture(image)
        }
        let eglDisplay = display
        let closing = exported
        return BoundPlanes(layout: .biplanar, conversion: conversion) {
            // The images and their descriptors outlive the swap: the caller
            // releases them only after `eglSwapBuffers` has returned and
            // taken the rendered frame, and the textures stop naming
            // these images at the next frame's binds.
            for image in images {
                sensorium_egl_destroy_image(eglDisplay, image)
            }
            var mutable = closing
            sensorium_close_exported_surface(&mutable)
        }
    }

    /// Uploads one plane, reading it at the stride libavcodec allocated rather
    /// than at the picture's own width: the two are rarely the same, and a
    /// plane read at the wrong stride comes out sheared.
    private func uploadPlane(
        index: Int,
        data: UnsafeMutablePointer<UInt8>?,
        stride: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) {
        guard let data, width > 0, height > 0, stride > 0 else { return }
        glActiveTexture(GLenum(GL_TEXTURE0 + Int32(index)))
        glBindTexture(GLenum(GL_TEXTURE_2D), textures[index])
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH), GLint(stride / bytesPerPixel))
        let internalFormat: Int32 = bytesPerPixel == 1 ? GL_R8 : GL_RG8
        let format: Int32 = bytesPerPixel == 1 ? GL_RED : GL_RG
        glTexImage2D(
            GLenum(GL_TEXTURE_2D),
            0,
            internalFormat,
            GLsizei(width),
            GLsizei(height),
            0,
            GLenum(format),
            GLenum(GL_UNSIGNED_BYTE),
            data
        )
        glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH), 0)
    }

    private static func signalledColorspace(
        of frame: UnsafeMutablePointer<AVFrame>
    ) -> NV12ColorConversion.SignalledColorspace {
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709:
            return .bt709
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M:
            return .bt601
        default:
            return .unspecified
        }
    }

    private func reportRenderFailure(_ error: Error) {
        guard !hasReportedRenderFailure else { return }
        hasReportedRenderFailure = true
        print("Sensorium: a decoded frame could not be drawn -- \(error)")
    }

    // MARK: - Shaders

    private struct Program {
        let identifier: GLuint
        let scale: GLint
        let offset: GLint
        let samplers: [GLint]
    }

    private func program(for conversion: NV12ColorConversion, layout: PlaneLayout) throws -> Program {
        if let existing = programs[conversion], existing.samplers.count == layout.planeCount {
            return existing
        }
        let program = try Self.makeProgram(conversion: conversion, layout: layout)
        if let existing = programs[conversion] {
            glDeleteProgram(existing.identifier)
        }
        programs[conversion] = program
        return program
    }

    private static func makeProgram(conversion: NV12ColorConversion, layout: PlaneLayout) throws -> Program {
        let vertex = try compile(source: vertexShaderSource, type: GLenum(GL_VERTEX_SHADER))
        let fragment = try compile(
            source: fragmentShaderSource(conversion: conversion, layout: layout),
            type: GLenum(GL_FRAGMENT_SHADER)
        )
        let program = glCreateProgram()
        glAttachShader(program, vertex)
        glAttachShader(program, fragment)
        glLinkProgram(program)
        glDeleteShader(vertex)
        glDeleteShader(fragment)
        var linked: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
        guard linked == GL_TRUE else {
            throw EGLFramePresenterError.shaderCompilationFailed(programLog(program))
        }
        let samplerNames = layout == .biplanar
            ? ["luma", "chroma"]
            : ["luma", "blueChroma", "redChroma"]
        return Program(
            identifier: program,
            scale: glGetUniformLocation(program, "placementScale"),
            offset: glGetUniformLocation(program, "placementOffset"),
            samplers: samplerNames.map { glGetUniformLocation(program, $0) }
        )
    }

    private static func compile(source: String, type: GLenum) throws -> GLuint {
        let shader = glCreateShader(type)
        try source.withCString { text in
            var pointer: UnsafePointer<GLchar>? = text
            glShaderSource(shader, 1, &pointer, nil)
        }
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
        guard compiled == GL_TRUE else {
            throw EGLFramePresenterError.shaderCompilationFailed(shaderLog(shader))
        }
        return shader
    }

    private static func shaderLog(_ shader: GLuint) -> String {
        var length: GLint = 0
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 0 else { return "" }
        var buffer = [GLchar](repeating: 0, count: Int(length))
        glGetShaderInfoLog(shader, GLsizei(length), nil, &buffer)
        return String(cString: buffer)
    }

    private static func programLog(_ program: GLuint) -> String {
        var length: GLint = 0
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 0 else { return "" }
        var buffer = [GLchar](repeating: 0, count: Int(length))
        glGetProgramInfoLog(program, GLsizei(length), nil, &buffer)
        return String(cString: buffer)
    }

    /// No vertex buffer is ever allocated: the quad's corner is derived from
    /// the vertex index and mapped into the destination by the placement the
    /// letterbox geometry produced.
    private static let vertexShaderSource = """
    #version 300 es
    uniform vec2 placementScale;
    uniform vec2 placementOffset;
    out vec2 textureCoordinate;
    void main() {
        vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
        gl_Position = vec4(corner * placementScale + placementOffset, 0.0, 1.0);
        textureCoordinate = corner;
    }
    """

    /// Generated from `NV12ColorConversion`, so the matrix a screen shows and
    /// the matrix the verification runner checks are the same numbers.
    private static func fragmentShaderSource(
        conversion: NV12ColorConversion,
        layout: PlaneLayout
    ) -> String {
        let samplers: String
        let encoded: String
        switch layout {
        case .biplanar:
            samplers = """
            uniform sampler2D luma;
            uniform sampler2D chroma;
            """
            encoded = """
            vec3(texture(luma, textureCoordinate).r, texture(chroma, textureCoordinate).rg)
            """
        case .triplanar:
            samplers = """
            uniform sampler2D luma;
            uniform sampler2D blueChroma;
            uniform sampler2D redChroma;
            """
            encoded = """
            vec3(texture(luma, textureCoordinate).r,
                 texture(blueChroma, textureCoordinate).r,
                 texture(redChroma, textureCoordinate).r)
            """
        }
        return """
        #version 300 es
        precision highp float;
        \(samplers)
        in vec2 textureCoordinate;
        out vec4 fragmentColor;
        void main() {
            vec3 encoded = \(encoded);
            vec3 linearRGB = \(conversion.glslMatrixLiteral) * (encoded - \(conversion.glslOffsetLiteral));
            fragmentColor = vec4(clamp(linearRGB, 0.0, 1.0), 1.0);
        }
        """
    }
}
#endif
