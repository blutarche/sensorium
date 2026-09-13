import CoreGraphics

/// A single observation of whether a freshly created session canvas is usable
/// yet. Kept free of AppKit/CoreGraphics calls so the waiting policy below can
/// be driven by a fake in tests that must never open a window or touch a real
/// display.
public struct CanvasDisplayReadinessSample: Equatable, Sendable {
    public let bounds: CGRect
    public let isRegisteredInScreens: Bool

    public init(bounds: CGRect, isRegisteredInScreens: Bool) {
        self.bounds = bounds
        self.isRegisteredInScreens = isRegisteredInScreens
    }
}

/// One `awaitReady` bring-up: the last sample, how many probe attempts
/// reached it, and whether that sample was ready. `isReady` is carried
/// rather than derived from `attempts`, because a bring-up can exhaust
/// `maxAttempts` unready or become ready on the last allowed attempt.
public struct CanvasDisplayReadinessResult: Equatable, Sendable {
    public let sample: CanvasDisplayReadinessSample
    public let attempts: Int
    public let isReady: Bool

    public init(sample: CanvasDisplayReadinessSample, attempts: Int, isReady: Bool) {
        self.sample = sample
        self.attempts = attempts
        self.isReady = isReady
    }
}

/// Polls an injectable probe until a freshly created virtual display reports
/// its expected size and has registered with AppKit, instead of assuming both
/// are already true the instant the display is created.
///
/// `CGVirtualDisplay` registration with WindowServer is asynchronous:
/// `CGDisplayBounds` can already report the real size before `NSScreen.screens`
/// catches up. Treating the display as ready before both agree — and then
/// releasing it because AppKit had not caught up yet — destroys the display
/// while its registration is still in flight, which is what corrupts the
/// adapter for every later connection.
public enum CanvasDisplayReadiness {
    /// Calls `probe` up to `maxAttempts` times, calling `pump` between
    /// attempts so a real run loop can turn and let the pending
    /// CoreGraphics/AppKit display-reconfiguration notifications this
    /// readiness depends on actually be delivered. Returns the last sample
    /// observed whether or not it became ready, so the caller can report the
    /// precise, accurate cause of a timeout instead of masking it, alongside
    /// how many attempts that took.
    public static func awaitReady(
        expectedWidth: Int,
        expectedHeight: Int,
        maxAttempts: Int,
        probe: () -> CanvasDisplayReadinessSample,
        pump: () -> Void
    ) -> CanvasDisplayReadinessResult {
        precondition(maxAttempts > 0)
        var sample = probe()
        var attempt = 1
        while attempt < maxAttempts,
              !isReady(sample, expectedWidth: expectedWidth, expectedHeight: expectedHeight) {
            pump()
            sample = probe()
            attempt += 1
        }
        return CanvasDisplayReadinessResult(
            sample: sample,
            attempts: attempt,
            isReady: isReady(sample, expectedWidth: expectedWidth, expectedHeight: expectedHeight)
        )
    }

    private static func isReady(
        _ sample: CanvasDisplayReadinessSample,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> Bool {
        Int(sample.bounds.width) == expectedWidth
            && Int(sample.bounds.height) == expectedHeight
            && sample.isRegisteredInScreens
    }
}
