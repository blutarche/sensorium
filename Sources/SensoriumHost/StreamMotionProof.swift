import Foundation

/// Judges what a viewer saw of a host screen while it scrolled and then stood
/// still: frames at the motion size while the scroll ran, the full size again
/// soon after it stopped, and the full size from then on.
public struct StreamMotionProof: Equatable, Sendable {
    public struct FrameSize: Equatable, Sendable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        var pixels: Int { width * height }
        var text: String { "\(width)x\(height)" }
    }

    /// One decoded frame, `milliseconds` after the first scroll event.
    public struct Frame: Equatable, Sendable {
        public let milliseconds: Int
        public let size: FrameSize

        public init(milliseconds: Int, size: FrameSize) {
            self.milliseconds = milliseconds
            self.size = size
        }
    }

    public enum Verdict: String, Equatable, Sendable {
        case pass
        case fail
        case skippedNoMotionSize = "skipped-no-motion-size"
    }

    /// How long after the last scroll event the full size has to be back. The
    /// host settles 0.5 s after the last broad change; the rest is the time
    /// the last scroll took to show on screen, the key frame, and the network.
    public static let settleLimitMilliseconds = 1000

    public let fullSize: FrameSize
    public let scrollSize: FrameSize
    public let settledAfterMilliseconds: Int?
    public let stillStaysFull: Bool
    public let verdict: Verdict

    /// `frames` are in arrival order; `lastScrollMilliseconds` is on the same
    /// clock as theirs. `expectedMotionSize` comes from the settled encoder's
    /// `motionConfiguration`; nil means that configuration has no motion size.
    public static func judge(
        fullSize: FrameSize,
        expectedMotionSize: FrameSize?,
        frames: [Frame],
        lastScrollMilliseconds: Int
    ) -> StreamMotionProof {
        let scrollSize = frames
            .filter { $0.milliseconds >= 0 && $0.milliseconds <= lastScrollMilliseconds }
            .map(\.size)
            .min { $0.pixels < $1.pixels }
            .map { $0.pixels < fullSize.pixels ? $0 : fullSize } ?? fullSize
        // A full-size frame before the last scroll event is a gap between two
        // flicks, not the picture settling.
        let settledIndex = frames.firstIndex {
            $0.milliseconds > lastScrollMilliseconds && $0.size == fullSize
        }
        let settledAfter = settledIndex.map { frames[$0].milliseconds - lastScrollMilliseconds }
        // Millisecond rounding can give consecutive arrivals the same time.
        let stillStaysFull = settledIndex.map { index in
            frames.dropFirst(index + 1).allSatisfy { $0.size == fullSize }
        } ?? false

        let verdict: Verdict
        if expectedMotionSize == nil {
            verdict = .skippedNoMotionSize
        } else if scrollSize == expectedMotionSize,
                  let settledAfter, settledAfter <= Self.settleLimitMilliseconds,
                  stillStaysFull {
            verdict = .pass
        } else {
            verdict = .fail
        }
        return StreamMotionProof(
            fullSize: fullSize,
            scrollSize: scrollSize,
            settledAfterMilliseconds: settledAfter,
            stillStaysFull: stillStaysFull,
            verdict: verdict
        )
    }

    /// The lines a probe prints, in the order a smoke script reads them.
    public var lines: [String] {
        [
            "motion_full_size=\(fullSize.text)",
            "motion_scroll_size=\(scrollSize.text)",
            "motion_settled_after_ms=\(settledAfterMilliseconds.map(String.init) ?? "none")",
            "motion_still_stays_full=\(stillStaysFull ? "yes" : "no")",
            "motion_check=\(verdict.rawValue)"
        ]
    }
}
