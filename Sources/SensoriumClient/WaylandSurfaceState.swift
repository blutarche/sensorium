import Foundation

/// What a Wayland toplevel knows about itself, kept apart from the Wayland
/// objects that report it.
///
/// A compositor tells a surface how big to be, what fraction of a pixel a
/// logical unit is worth, how often the screen it is on refreshes, and when
/// the person closed it. Every one of those is a plain value, and the window
/// makes the same decisions from them whether they arrived from a real
/// compositor or from a test. Each mutating call answers whether it actually
/// changed anything, which is also what keeps the window's logging to one line
/// per real change rather than one per event.
public struct WaylandSurfaceState: Equatable, Sendable {
    /// The size a surface asks for before a compositor has said anything.
    public static let defaultLogicalWidth = 1280
    public static let defaultLogicalHeight = 800
    /// Used until an output reports a mode of its own.
    public static let defaultRefreshIntervalNanoseconds = PresentationPacer.defaultFrameIntervalNanoseconds

    /// The surface's size in the compositor's own logical units.
    public private(set) var logicalWidth: Int
    public private(set) var logicalHeight: Int
    /// How many real pixels one logical unit is worth. Sent in 120ths by
    /// `wp_fractional_scale_v1`, so 1.5 arrives as 180.
    public private(set) var scale: Double = 1
    public private(set) var refreshIntervalNanoseconds = WaylandSurfaceState.defaultRefreshIntervalNanoseconds
    public private(set) var isClosed = false

    /// What the surface last heard, so a repeat of it is not taken as a
    /// change. `nil` until an output has reported a mode.
    private var reportedMilliHertz: Int?
    private var scaleNumerator120 = 120

    public init(
        defaultLogicalWidth: Int = WaylandSurfaceState.defaultLogicalWidth,
        defaultLogicalHeight: Int = WaylandSurfaceState.defaultLogicalHeight
    ) {
        logicalWidth = max(defaultLogicalWidth, 1)
        logicalHeight = max(defaultLogicalHeight, 1)
    }

    /// The buffer size in real pixels, which is also what the viewer reports
    /// to the host as its drawable size. Rounded halfway away from zero, the
    /// rounding the fractional-scale protocol specifies for a toplevel, and
    /// clamped to `Int32.max` because a caller hands this to APIs that take a
    /// 32-bit size.
    public var drawablePixelWidth: Int {
        clampedToInt32Max((Double(logicalWidth) * scale).rounded(.toNearestOrAwayFromZero))
    }

    public var drawablePixelHeight: Int {
        clampedToInt32Max((Double(logicalHeight) * scale).rounded(.toNearestOrAwayFromZero))
    }

    private func clampedToInt32Max(_ value: Double) -> Int {
        guard value < Double(Int32.max) else { return Int(Int32.max) }
        return max(Int(value), 1)
    }

    /// One `xdg_toplevel.configure`. A zero dimension is the compositor
    /// leaving that dimension to the client, so the size already in force
    /// stands.
    @discardableResult
    public mutating func configure(logicalWidth newWidth: Int, logicalHeight newHeight: Int) -> Bool {
        let width = newWidth > 0 ? newWidth : logicalWidth
        let height = newHeight > 0 ? newHeight : logicalHeight
        guard width != logicalWidth || height != logicalHeight else { return false }
        logicalWidth = width
        logicalHeight = height
        return true
    }

    /// The largest scale a compositor's report is trusted at. Nothing real
    /// scales a display this far; a report past it is treated as bogus rather
    /// than adopted, so the derived drawable size below never has to fend off
    /// numbers the display protocols themselves would never produce.
    private static let maximumScaleNumerator120 = 16 * 120

    /// One `wp_fractional_scale_v1.preferred_scale`, in 120ths.
    @discardableResult
    public mutating func setFractionalScale(numerator120: Int) -> Bool {
        guard numerator120 > 0,
              numerator120 <= Self.maximumScaleNumerator120,
              numerator120 != scaleNumerator120 else { return false }
        scaleNumerator120 = numerator120
        scale = Double(numerator120) / 120
        return true
    }

    /// One `wl_output.mode` refresh figure, in millihertz. An output that
    /// reports none leaves the interval already in force standing.
    @discardableResult
    public mutating func setOutputRefresh(milliHertz: Int) -> Bool {
        guard milliHertz > 0, milliHertz != reportedMilliHertz else { return false }
        reportedMilliHertz = milliHertz
        refreshIntervalNanoseconds = Int64((1_000_000_000_000.0 / Double(milliHertz)).rounded())
        return true
    }

    @discardableResult
    public mutating func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        return true
    }
}
