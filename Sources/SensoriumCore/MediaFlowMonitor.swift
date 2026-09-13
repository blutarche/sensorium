import Foundation

/// Observed media flow over one interval. "Capture started" is not evidence that
/// frames are moving; this is.
public struct MediaFlowReport: Equatable, Sendable {
    public let frames: Int
    public let bytes: Int
    public let seconds: Double
    /// Frames the transport had to drop inside this interval alone. A
    /// cumulative session total answers "has anything ever gone wrong",
    /// which every interval after the first one keeps answering yes to; what
    /// a reader of a periodic line needs is whether anything is going wrong
    /// now.
    public let droppedFrames: Int

    public var framesPerSecond: Double {
        seconds > 0 ? Double(frames) / seconds : 0
    }

    public var megabitsPerSecond: Double {
        seconds > 0 ? (Double(bytes) * 8 / 1_000_000) / seconds : 0
    }
}

/// Counts frames and reports at most once per interval, plus a one-shot report
/// when a stream that was running goes quiet.
///
/// Takes its timestamps from the caller so the behaviour is testable without
/// sleeping.
public struct MediaFlowMonitor: Equatable, Sendable {
    private let reportInterval: Double
    private let silenceThreshold: Double
    private var frames = 0
    private var bytes = 0
    /// The caller's cumulative drop count as it stood when this interval
    /// opened. Kept rather than asking the caller for a delta: the counter
    /// the transport exposes is a running total, and one place subtracting
    /// is one place to get it wrong.
    private var droppedAtIntervalStart: Int?
    private var intervalStartedAt: Double?
    private var lastFrameAt: Double?
    private var reportedSilence = false

    /// How often a running stream reports, when nobody says otherwise.
    public static let defaultReportInterval: Double = 5

    public init(reportInterval: Double = MediaFlowMonitor.defaultReportInterval, silenceThreshold: Double = 2) {
        self.reportInterval = reportInterval
        self.silenceThreshold = silenceThreshold
    }

    /// `droppedFramesTotal` is the transport's running count of frames it
    /// could not carry, for the same stream this interval's frames belong to.
    public mutating func record(
        packetBytes: Int,
        droppedFramesTotal: Int,
        atSeconds now: Double
    ) -> MediaFlowReport? {
        if intervalStartedAt == nil {
            intervalStartedAt = now
        }
        if droppedAtIntervalStart == nil {
            droppedAtIntervalStart = droppedFramesTotal
        }
        frames += 1
        bytes += packetBytes
        lastFrameAt = now
        reportedSilence = false

        guard let start = intervalStartedAt, now - start >= reportInterval else {
            return nil
        }
        let report = MediaFlowReport(
            frames: frames,
            bytes: bytes,
            seconds: now - start,
            // Never below zero: two streams can share one monitor, so two
            // readings of one running total can arrive in the other order,
            // and a total that reads lower than the one this interval opened
            // with is not evidence that frames came back.
            droppedFrames: max(0, droppedFramesTotal - (droppedAtIntervalStart ?? droppedFramesTotal))
        )
        frames = 0
        bytes = 0
        // The next interval opens at the highest total seen, not the last one
        // read: the running count only ever grows, so a lower reading is two
        // streams' readings arriving out of order, and opening from it would
        // charge the next interval for drops this one already reported.
        droppedAtIntervalStart = max(droppedFramesTotal, droppedAtIntervalStart ?? droppedFramesTotal)
        intervalStartedAt = now
        return report
    }

    /// Returns the silence duration once, when a stream that had been delivering
    /// frames stops.
    public mutating func checkForSilence(atSeconds now: Double) -> Double? {
        guard let last = lastFrameAt, !reportedSilence else {
            return nil
        }
        let quiet = now - last
        guard quiet >= silenceThreshold else {
            return nil
        }
        reportedSilence = true
        return quiet
    }
}
