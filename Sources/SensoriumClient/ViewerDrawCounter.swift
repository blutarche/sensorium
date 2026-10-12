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

    public init() {}

    public var counts: ViewerDrawCounts {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// One draw callback, whether or not a frame was waiting.
    public func recordDraw() {
        lock.lock()
        current.draws += 1
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
}
