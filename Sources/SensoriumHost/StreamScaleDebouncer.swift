import SensoriumCore

/// Trailing debounce over the stream scale a viewer asks for.
///
/// Dragging a window edge emits a continuous stream of drawable sizes, and
/// each distinct scale would otherwise rebuild the whole capture and encode
/// path — a visible stall per intermediate size. Only a value that has
/// stayed put for its settle time is worth rebuilding for.
///
/// Applying is deliberately a separate step from settling: a reconfiguration
/// that failed must not leave this believing the new scale is live, or the
/// stream would be reported at a resolution it is not actually running.
public struct StreamScaleDebouncer: Sendable {
    public static let defaultSettleSeconds: Double = 0.35
    /// How long a viewer's drawable must hold still before the stream follows
    /// it, when the change is upward or more than one
    /// `StreamScalePolicy.quantum` down.
    public static let drawableSettleSeconds: Double = 0.25
    /// How long a drawable that shrank by at most one quantum must hold
    /// before the stream follows it. Long enough that a strip of controls
    /// shown for a moment does not rebuild the encoder each time it appears
    /// and goes, short enough that a window left slightly smaller still ends
    /// up streamed at its exact size.
    public static let drawableSmallShrinkSettleSeconds: Double = 2.0

    public let settleSeconds: Double
    public private(set) var appliedScale: Double
    private var pendingScale: Double?
    private var pendingSinceSeconds: Double = 0
    private var pendingSettleSeconds: Double = 0

    public init(
        appliedScale: Double = StreamScalePolicy.defaultScale,
        settleSeconds: Double = defaultSettleSeconds
    ) {
        self.appliedScale = appliedScale
        self.settleSeconds = settleSeconds
    }

    /// - Parameter settleSeconds: how long this request must stand before
    ///   it is taken; `nil` is this debouncer's own `settleSeconds`.
    public mutating func request(scale: Double, atSeconds: Double, settleSeconds: Double? = nil) {
        guard scale != appliedScale else {
            pendingScale = nil
            return
        }
        pendingSettleSeconds = settleSeconds ?? self.settleSeconds
        guard pendingScale != scale else {
            // Repeating the value already pending must not push its deadline
            // out forever; only an actual change restarts the window.
            return
        }
        pendingScale = scale
        pendingSinceSeconds = atSeconds
    }

    /// The scale to reconfigure to, once and only once it has settled.
    /// Call `markApplied` after the reconfiguration actually succeeds.
    public mutating func takeSettledScale(atSeconds: Double) -> Double? {
        guard let pendingScale, atSeconds - pendingSinceSeconds >= pendingSettleSeconds else {
            return nil
        }
        self.pendingScale = nil
        return pendingScale
    }

    public mutating func markApplied(_ scale: Double) {
        appliedScale = scale
    }
}
