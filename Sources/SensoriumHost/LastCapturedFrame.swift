import CoreMedia

/// The frame a capture pipeline last delivered, held across the capture queue
/// and the main actor. One frame, replaced by each new one and given up as
/// soon as it has been used, so nothing outlives the capture session that
/// vended it.
///
/// It is a frame from ScreenCaptureKit's own pool, so holding it holds one of
/// that pool's surfaces for as long as the screen stays still. One is the
/// whole cost, and it buys the only copy of the picture the viewer is
/// currently looking at: capture is change-driven, so once a screen goes
/// still, nothing will deliver that picture again.
public final class LastCapturedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleBuffer: CMSampleBuffer?

    public init() {}

    public func record(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleBuffer = sampleBuffer
    }

    /// Hands the held frame over and stops holding it. Taken rather than read
    /// because the caller submits it to the encoder, which holds it for as
    /// long as it needs it: keeping a second reference here past that point
    /// would hold a capture-pool surface for a picture already on its way out.
    public func take() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let taken = sampleBuffer
        sampleBuffer = nil
        return taken
    }

    public var isHoldingFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sampleBuffer != nil
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        sampleBuffer = nil
    }
}
