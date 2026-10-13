import Foundation
import SensoriumCore

/// Why a draw callback that had a decoded frame waiting ended without showing
/// it. Only the reasons the presenter's own early returns can tell apart.
public enum ViewerDrawNotShownReason: Sendable {
    case noDrawable
    case noCommandBuffer
    case emptyDestination
    case renderFailure
}

/// Cumulative draw counts for one window.
public struct ViewerDrawCounts: Equatable, Sendable {
    public var draws = 0
    public var noDrawable = 0
    public var noCommandBuffer = 0
    public var emptyDestination = 0
    public var renderFailure = 0

    public init(
        draws: Int = 0,
        noDrawable: Int = 0,
        noCommandBuffer: Int = 0,
        emptyDestination: Int = 0,
        renderFailure: Int = 0
    ) {
        self.draws = draws
        self.noDrawable = noDrawable
        self.noCommandBuffer = noCommandBuffer
        self.emptyDestination = emptyDestination
        self.renderFailure = renderFailure
    }

    /// Draws that had a frame waiting and showed none, for any reason.
    public var notShown: Int {
        noDrawable + noCommandBuffer + emptyDestination + renderFailure
    }
}

/// What a window's draw timing and main-thread heartbeat measured since the
/// last report, each field absent when the window held nothing to measure it
/// from.
public struct ViewerDrawWindow: Equatable, Sendable {
    public var longestDrawGapMilliseconds: Double?
    public var longestMainThreadStallMilliseconds: Double?
    public var hiddenFraction: Double?
    public var preferredFramesPerSecond: Int?

    public init(
        longestDrawGapMilliseconds: Double? = nil,
        longestMainThreadStallMilliseconds: Double? = nil,
        hiddenFraction: Double? = nil,
        preferredFramesPerSecond: Int? = nil
    ) {
        self.longestDrawGapMilliseconds = longestDrawGapMilliseconds
        self.longestMainThreadStallMilliseconds = longestMainThreadStallMilliseconds
        self.hiddenFraction = hiddenFraction
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }
}

/// Draw gaps and main-thread heartbeat accounting for one report window, fed
/// timestamps so it is verifiable without a timer or a screen.
///
/// The two measure different things: a long draw gap with a quiet heartbeat
/// means the main thread was alive and the display never asked for a picture;
/// a long gap with a late heartbeat means the main thread itself stalled.
public struct ViewerDrawTiming: Sendable {
    /// The heartbeat's nominal period; a tick later than this by some amount
    /// is a stall of that amount.
    public static let heartbeatIntervalNanoseconds: Int64 = 50_000_000

    private var lastDrawAt: Int64?
    private var longestDrawGap: Int64?
    private var lastHeartbeatAt: Int64?
    private var longestStall: Int64?
    private var heartbeats = 0
    private var hiddenHeartbeats = 0

    public init() {}

    /// Kept across `take()`, so a gap that spans two windows is counted in
    /// the window it ends in.
    public mutating func recordDraw(atNanoseconds now: Int64) {
        if let lastDrawAt {
            longestDrawGap = max(longestDrawGap ?? 0, now - lastDrawAt)
        }
        lastDrawAt = now
    }

    public mutating func recordHeartbeat(atNanoseconds now: Int64, hidden: Bool) {
        if let lastHeartbeatAt {
            let stall = max(0, now - lastHeartbeatAt - Self.heartbeatIntervalNanoseconds)
            longestStall = max(longestStall ?? 0, stall)
        }
        lastHeartbeatAt = now
        heartbeats += 1
        if hidden {
            hiddenHeartbeats += 1
        }
    }

    /// Forgets the previous tick, for a heartbeat that was stopped: the time
    /// it was off is not a stall.
    public mutating func restartHeartbeat() {
        lastHeartbeatAt = nil
    }

    /// Reads the window and starts the next one.
    public mutating func take() -> ViewerDrawWindow {
        let window = ViewerDrawWindow(
            longestDrawGapMilliseconds: longestDrawGap.map { Double($0) / 1_000_000 },
            longestMainThreadStallMilliseconds: longestStall.map { Double($0) / 1_000_000 },
            hiddenFraction: heartbeats > 0 ? Double(hiddenHeartbeats) / Double(heartbeats) : nil
        )
        longestDrawGap = nil
        longestStall = nil
        heartbeats = 0
        hiddenHeartbeats = 0
        return window
    }
}

/// How often the screen asked this viewer to draw, and how often a draw that
/// had a frame to show could not.
///
/// A viewer that decodes frames and presents none is silent about why: the
/// display may never have asked for a picture, or asked and been refused a
/// drawable. Counting each draw callback and each refusal by reason is what
/// tells the two apart. A draw with nothing waiting is normal and is only a
/// draw; a frame refused on several draws in a row is counted on each, since
/// each is a callback that showed nothing.
///
/// Not an actor, for the same reason as `ViewerFrameDropCounter`: the
/// presenter writes it on the main actor and the telemetry tick reads it from
/// elsewhere, and neither can suspend.
public final class ViewerDrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ViewerDrawCounts()
    private var timing = ViewerDrawTiming()

    public init() {}

    public var counts: ViewerDrawCounts {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// One draw callback, whether or not a frame was waiting.
    public func recordDraw(atNanoseconds now: Int64 = MonotonicClock.nowNanoseconds()) {
        lock.lock()
        current.draws += 1
        timing.recordDraw(atNanoseconds: now)
        lock.unlock()
    }

    /// A draw callback with a frame waiting that ended without showing it.
    public func recordNotShown(_ reason: ViewerDrawNotShownReason) {
        lock.lock()
        switch reason {
        case .noDrawable: current.noDrawable += 1
        case .noCommandBuffer: current.noCommandBuffer += 1
        case .emptyDestination: current.emptyDestination += 1
        case .renderFailure: current.renderFailure += 1
        }
        lock.unlock()
    }

    /// One tick of the main-thread heartbeat.
    public func recordHeartbeat(hidden: Bool, atNanoseconds now: Int64 = MonotonicClock.nowNanoseconds()) {
        lock.lock()
        timing.recordHeartbeat(atNanoseconds: now, hidden: hidden)
        lock.unlock()
    }

    public func restartHeartbeat() {
        lock.lock()
        timing.restartHeartbeat()
        lock.unlock()
    }

    /// Reads the timing window and starts the next one.
    public func takeTimingWindow() -> ViewerDrawWindow {
        lock.lock()
        defer { lock.unlock() }
        return timing.take()
    }
}
