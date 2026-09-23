#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import Foundation

/// What a run started with `--trace` says about the picture while it is
/// running: one line the first time a frame really reaches the screen, and one
/// line every five seconds after that.
///
/// A window showing nothing looks exactly like a window that was sent nothing,
/// and telling those apart is the first thing anyone diagnosing a session has
/// to do. These are the presenter's own counts and the window's own geometry,
/// reported while the session is live rather than in a summary after it ended.
@MainActor
final class WaylandSessionTrace {
    private static let interval = Duration.seconds(5)

    private weak var window: WaylandSessionWindow?
    private var hasNamedDecoder = false

    init(window: WaylandSessionWindow) {
        self.window = window
        window.onFirstDrawDiagnostics = { Self.say($0) }
        window.onFirstPresentedFrame = { [weak window] in
            guard let window else { return }
            let heldElsewhere = window.foundForeignGLContextAtFirstDraw == true
            Self.say(
                "first frame presented; \(Self.geometry(of: window)) "
                    + "gl-context-held-elsewhere=\(heldElsewhere ? "yes" : "no")"
            )
        }
    }

    /// Reports until the window it reports on closes or is dropped. The task
    /// below holds this object for exactly that long, so nothing else has to.
    func start() {
        Task { @MainActor in
            while true {
                do {
                    try await Task.sleep(for: Self.interval)
                } catch {
                    return
                }
                guard let window, !window.isClosed else { return }
                tick(window)
            }
        }
    }

    private func tick(_ window: WaylandSessionWindow) {
        if !hasNamedDecoder, let status = window.decoderHardwareAcceleration {
            hasNamedDecoder = true
            // Already a whole line, prefix included, and the same wording the
            // decoder itself uses the first time it decodes.
            Self.say(status.logLine, isPrefixed: true)
        }
        Self.say(
            "presented=\(window.presentedFrameCount) dropped=\(window.droppedFrameCount) "
                + Self.geometry(of: window)
        )
    }

    private static func geometry(of window: WaylandSessionWindow) -> String {
        let size = window.drawablePixelSize
        return "drawable=\(size.width)x\(size.height) scale=\(String(format: "%.2f", window.surfaceScale))"
    }

    /// Standard error, so a trace never lands in the middle of what the viewer
    /// tells the person running it.
    private static func say(_ line: String, isPrefixed: Bool = false) {
        FileHandle.standardError.write(Data(((isPrefixed ? "" : "Sensorium: ") + line + "\n").utf8))
    }
}
#endif
