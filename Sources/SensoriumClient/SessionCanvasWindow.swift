/// What `ClientSessionRunner` needs of a session's own canvas window beyond
/// `CanvasSurfaceWindow`: the portable entry point its media takes off the
/// wire, and starting or observing the decode session behind it. Both
/// `ClientCanvasWindowController` (macOS) and its Linux counterpart conform,
/// which is what lets the runner itself hold no AppKit dependency at all.
public protocol SessionCanvasWindow: CanvasSurfaceWindow {
    var videoSink: SurfaceVideoSink { get }
    func startDecoding(
        latency: SessionLatencyMonitor?,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)?
    ) throws
    func canvasObserver() -> ClientViewportController
}
