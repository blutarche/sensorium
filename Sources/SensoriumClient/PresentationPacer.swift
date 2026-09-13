import Foundation
import SensoriumCore

/// When each decoded frame belongs on screen.
///
/// Frames leave the host at an even rate and arrive at an uneven one: a
/// network delivers them in small groups, so two frames often land inside one
/// display refresh and the next refresh has none. Drawing each frame the
/// moment it is decoded turns that unevenness into visible judder, because one
/// of the two is thrown away and the following refresh repeats a picture.
///
/// So each frame is given a due time instead. The host stamped it with the
/// moment it was captured, and those stamps are as even as the capture itself
/// was, so holding every frame by the same amount past its own stamp restores
/// the spacing the host sent. The screen is then drawn on its own refresh, and
/// each refresh takes the newest frame whose due time has passed.
///
/// The hold is the cost of that steadiness, so it is kept as small as the link
/// allows. It is measured, not chosen: the pacer watches how much later some
/// frames arrive than the earliest-arriving ones, and holds by a high
/// percentile of that spread plus one frame interval, which is enough for all
/// but the latest arrivals to be waiting before their due time comes. It never
/// falls below one frame interval, which is the least that can separate two
/// frames on screen, and never rises above `maximumHoldNanoseconds`, because
/// past that a person feels the delay more than they see the judder.
///
/// The two clocks never have to agree. The host's capture stamps and this
/// machine's arrival times are read on different clocks, so every delay this
/// type measures carries the offset between them; subtracting the smallest
/// delay in the window removes it, whatever it is. A frame that arrives later
/// than the whole window's spread is therefore already past due and is drawn
/// at the next refresh rather than held.
///
/// Pure and nonisolated: what to draw when is decided here, and the drawing
/// itself, the display link and the GPU stay in `MetalFramePresenter`.
public struct PresentationPacer: Sendable {
    /// One frame and the moment it belongs on screen.
    public struct Presentation: Sendable {
        public let frame: DecodedFrame
        public let dueAtNanoseconds: Int64
        /// Frames older than this one that were still waiting and are now
        /// given up, because this one is a whole newer picture.
        public let supersededCount: Int
    }

    /// One frame waiting its turn. The capture time is kept alongside the due
    /// time because the next frame's due time is placed relative to both.
    private struct Waiting {
        let frame: DecodedFrame
        let dueAtNanoseconds: Int64
        let capturedAtNanoseconds: Int64?
    }

    /// The longest a frame is ever held. Everything above this is felt as
    /// delay rather than seen as smoothness.
    public static let maximumHoldNanoseconds: Int64 = 50_000_000
    /// Used until the stream's own capture stamps say otherwise.
    public static let defaultFrameIntervalNanoseconds: Int64 = 16_666_667
    /// Frames waiting here are decoded pixel buffers, so the queue is bounded
    /// like every other one on the viewer. Reached only when the screen is not
    /// drawing at all, since a hold of at most 50 milliseconds cannot fill it.
    public static let maximumPending = 8

    /// How far past its capture stamp each frame is currently being held.
    /// Shown on the session panel, because it is latency this machine added
    /// on purpose and a person reading the panel should be able to see it.
    public private(set) var holdNanoseconds: Int64 = 0

    /// Two seconds of a 60fps stream: long enough to have seen the link's
    /// spread, short enough to follow a link that changes.
    private static let windowCapacity = 120
    /// A gap longer than this is a stream that stopped and started, not a
    /// frame interval.
    private static let maximumCaptureGapNanoseconds: Int64 = 200_000_000
    private static let minimumFrameIntervalNanoseconds: Int64 = 1_000_000

    private var arrivalDelays: [Int64] = []
    private var captureIntervals: [Int64] = []
    private var lastCapturedAtNanoseconds: Int64?
    /// The delay of the earliest-arriving frames, which is what every other
    /// delay is measured against. Held rather than recomputed outright: see
    /// `updateBaseline(with:interval:)`.
    private var baselineNanoseconds: Int64?
    private var pending: [Waiting] = []

    public init() {}

    public var pendingCount: Int { pending.count }

    /// Takes one decoded frame and reports how many waiting frames that cost.
    /// Zero unless the screen has stopped drawing altogether.
    ///
    /// A frame with no timing is due at once: without a capture stamp there is
    /// nothing to pace it against, and a viewer that has not yet tied its
    /// frames to the host's clock still has to show them.
    @discardableResult
    public mutating func admit(_ frame: DecodedFrame, nowNanoseconds: Int64) -> Int {
        guard let timing = frame.timing else {
            return append(frame, dueAtNanoseconds: nowNanoseconds)
        }
        let capturedAt = timing.hostCapturedAtNanoseconds
        recordCaptureInterval(capturedAt: capturedAt)
        append(&arrivalDelays, nowNanoseconds - capturedAt)
        let interval = frameIntervalNanoseconds
        let baseline = updateBaseline(with: arrivalDelays.min() ?? 0, interval: interval)
        let spread = (percentile(arrivalDelays, 0.9) ?? baseline) - baseline
        // `spread` is never negative, so this is already at least one frame
        // interval.
        holdNanoseconds = min(spread + interval, Self.maximumHoldNanoseconds)
        return append(
            frame,
            capturedAtNanoseconds: capturedAt,
            dueAtNanoseconds: capturedAt + baseline + holdNanoseconds
        )
    }

    /// The newest frame that is due, and how many older ones it supersedes.
    /// `nil` when nothing waiting is due yet, which is the screen's cue to
    /// leave the picture it is already showing alone.
    public mutating func frameToPresent(nowNanoseconds: Int64) -> Presentation? {
        // Due times rise with position, so the last one that has passed is
        // both the newest frame due and the last waiting frame worth keeping.
        guard let index = pending.lastIndex(where: { $0.dueAtNanoseconds <= nowNanoseconds }) else {
            return nil
        }
        let due = pending[index]
        pending.removeFirst(index + 1)
        return Presentation(
            frame: due.frame,
            dueAtNanoseconds: due.dueAtNanoseconds,
            supersededCount: index
        )
    }

    /// Gives up everything waiting and forgets what it learned about the link.
    /// A session that ended and one that reconnected are different streams,
    /// and the frames of the one are not evidence about the other.
    public mutating func reset() {
        pending.removeAll()
        arrivalDelays.removeAll()
        captureIntervals.removeAll()
        lastCapturedAtNanoseconds = nil
        baselineNanoseconds = nil
        holdNanoseconds = 0
    }

    /// The baseline follows the window's smallest delay upwards at once, since
    /// a link that slowed down has to be waited for. Downwards it follows by
    /// one frame interval at a time.
    ///
    /// One packet that happened to cross quickly is not evidence the link got
    /// faster, and taking it as evidence would shorten every later frame's
    /// wait in one step. Frames already waiting were placed against the old
    /// baseline, so a step like that pulls a later frame in front of one a
    /// person is about to see. Easing it in instead keeps the order, and a
    /// link that really did get faster is followed within a few frames.
    private mutating func updateBaseline(with windowMinimum: Int64, interval: Int64) -> Int64 {
        guard let current = baselineNanoseconds else {
            baselineNanoseconds = windowMinimum
            return windowMinimum
        }
        let updated = windowMinimum > current
            ? windowMinimum
            : max(windowMinimum, current - interval)
        baselineNanoseconds = updated
        return updated
    }

    private mutating func recordCaptureInterval(capturedAt: Int64) {
        defer { lastCapturedAtNanoseconds = max(lastCapturedAtNanoseconds ?? capturedAt, capturedAt) }
        guard let last = lastCapturedAtNanoseconds, capturedAt > last else { return }
        let gap = capturedAt - last
        guard gap <= Self.maximumCaptureGapNanoseconds else { return }
        append(&captureIntervals, gap)
    }

    /// The stream's own frame interval, from the gaps between capture stamps.
    private var frameIntervalNanoseconds: Int64 {
        let measured = percentile(captureIntervals, 0.5) ?? Self.defaultFrameIntervalNanoseconds
        return min(max(measured, Self.minimumFrameIntervalNanoseconds), Self.maximumHoldNanoseconds)
    }

    /// Places one frame in the queue, never earlier than the frame in front of
    /// it and never closer to it than the host's own capture times were.
    ///
    /// Monotone by construction rather than by hoping the arithmetic above
    /// comes out ordered: the hold sits at a clamp for as long as a link is
    /// bad, and at a clamp it can no longer absorb a change in the baseline.
    /// A queue ordered by due time is also what lets `frameToPresent` treat
    /// position and due time as the same ordering.
    private mutating func append(
        _ frame: DecodedFrame,
        capturedAtNanoseconds: Int64? = nil,
        dueAtNanoseconds: Int64
    ) -> Int {
        var dueAt = dueAtNanoseconds
        if let last = pending.last {
            let separation: Int64
            if let capturedAtNanoseconds, let lastCapturedAt = last.capturedAtNanoseconds {
                separation = max(0, capturedAtNanoseconds - lastCapturedAt)
            } else {
                separation = 0
            }
            dueAt = max(dueAt, last.dueAtNanoseconds + separation)
        }
        pending.append(
            Waiting(
                frame: frame,
                dueAtNanoseconds: dueAt,
                capturedAtNanoseconds: capturedAtNanoseconds
            )
        )
        guard pending.count > Self.maximumPending else { return 0 }
        let superseded = pending.count - Self.maximumPending
        pending.removeFirst(superseded)
        return superseded
    }

    private func append(_ samples: inout [Int64], _ sample: Int64) {
        samples.append(sample)
        if samples.count > Self.windowCapacity {
            samples.removeFirst(samples.count - Self.windowCapacity)
        }
    }

    /// Nearest rank, the same convention `LatencySamples` reports.
    private func percentile(_ samples: [Int64], _ percentile: Double) -> Int64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
