import Foundation
import SensoriumHost

private typealias Size = StreamMotionProof.FrameSize
private typealias Frame = StreamMotionProof.Frame

private let full = Size(width: 3024, height: 1964)
private let motion = Size(width: 1786, height: 1160)

/// Frames every `step` ms in `range`, all at `size`.
private func frames(_ range: ClosedRange<Int>, every step: Int = 100, at size: Size) -> [Frame] {
    stride(from: range.lowerBound, through: range.upperBound, by: step).map { Frame(milliseconds: $0, size: size) }
}

func runStreamMotionProofTests() {
    expectAScrollThatShrinksAndSettlesPasses()
    expectEachMotionFailureIsReportedOnItsOwn()
    expectFrameArrivalOrderAndDimensionsAreChecked()
    expectOnlyTheConfiguredMotionSizeProvesMotion()
    expectAStreamWithNoMotionSizeIsSkipped()
    expectTheLinesAreWhatTheSmokeReads()
}

private func expectAScrollThatShrinksAndSettlesPasses() {
    let recorded = frames(0...1500, at: motion) + frames(1600...2100, at: motion)
        + [Frame(milliseconds: 2150, size: full)] + frames(2250...4500, every: 250, at: full)
    let proof = StreamMotionProof.judge(fullSize: full, expectedMotionSize: motion, frames: recorded, lastScrollMilliseconds: 1500)
    expect(proof.verdict == .pass, "motion size while scrolling, full size soon after, full size ever after passes, got \(proof)")
    expect(proof.scrollSize == motion, "the smallest size seen during the scroll is the motion size, got \(proof.scrollSize)")
    expect(proof.settledAfterMilliseconds == 650, "settling is timed from the last scroll event to the first full-size frame, got \(String(describing: proof.settledAfterMilliseconds))")
    expect(proof.stillStaysFull, "no smaller frame after settling")
}

private func expectEachMotionFailureIsReportedOnItsOwn() {
    let neverShrank = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(neverShrank.verdict == .fail, "a scroll that never produced a smaller frame fails")
    expect(neverShrank.scrollSize == full, "and its smallest size is the full size, got \(neverShrank.scrollSize)")

    let neverSettled = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...4500, at: motion),
        lastScrollMilliseconds: 1500
    )
    expect(neverSettled.verdict == .fail, "a picture that stays at the motion size fails")
    expect(neverSettled.settledAfterMilliseconds == nil, "it never settled")
    expect(!neverSettled.stillStaysFull, "a picture that never reached full size did not stay there")

    let slow = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...2600, at: motion) + frames(2700...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(slow.settledAfterMilliseconds == 1200, "settled at 2700 after a scroll that ended at 1500, got \(String(describing: slow.settledAfterMilliseconds))")
    expect(slow.verdict == .fail, "settling later than the limit fails")

    let atTheLimit = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...2400, at: motion) + frames(2500...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(atTheLimit.settledAfterMilliseconds == StreamMotionProof.settleLimitMilliseconds, "settled exactly at the limit")
    expect(atTheLimit.verdict == .pass, "settling at the limit is on time")

    let softenedAgain = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...2100, at: motion) + frames(2200...3000, at: full)
            + [Frame(milliseconds: 3100, size: motion)] + frames(3200...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(softenedAgain.verdict == .fail, "a smaller frame after settling fails")
    expect(!softenedAgain.stillStaysFull, "and says the picture did not stay full size")
    expect(softenedAgain.settledAfterMilliseconds == 700, "while still reporting when it first settled, got \(String(describing: softenedAgain.settledAfterMilliseconds))")

    let fullFrameBeforeTheScrollEnded = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...1000, at: motion) + [Frame(milliseconds: 1200, size: full)]
            + frames(1300...2800, at: motion) + frames(2900...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(
        fullFrameBeforeTheScrollEnded.settledAfterMilliseconds == 1400,
        "a full-size frame in the middle of the scroll is not settling, got \(String(describing: fullFrameBeforeTheScrollEnded.settledAfterMilliseconds))"
    )
}

private func expectAStreamWithNoMotionSizeIsSkipped() {
    let small = Size(width: 1920, height: 1080)
    let proof = StreamMotionProof.judge(fullSize: small, expectedMotionSize: nil, frames: frames(0...4500, at: small), lastScrollMilliseconds: 1500)
    expect(proof.verdict == .skippedNoMotionSize, "a stream under the motion threshold has no motion size to prove, got \(proof.verdict)")

    let justUnder = Size(width: 2879, height: 1080)
    expect(
        StreamMotionProof.judge(fullSize: justUnder, expectedMotionSize: nil, frames: [], lastScrollMilliseconds: 1500).verdict == .skippedNoMotionSize,
        "just under 1.5 times the motion budget has none"
    )
    let atTheThreshold = Size(width: 2880, height: 1080)
    expect(
        StreamMotionProof.judge(fullSize: atTheThreshold, expectedMotionSize: Size(width: 2352, height: 882), frames: [], lastScrollMilliseconds: 1500).verdict == .fail,
        "at 1.5 times the budget a motion size exists, and no frames means it was not shown"
    )
}

private func expectTheLinesAreWhatTheSmokeReads() {
    let recorded = frames(0...2100, at: motion) + frames(2200...4500, at: full)
    let lines = StreamMotionProof.judge(fullSize: full, expectedMotionSize: motion, frames: recorded, lastScrollMilliseconds: 1500).lines
    expect(
        lines == [
            "motion_full_size=3024x1964",
            "motion_scroll_size=1786x1160",
            "motion_settled_after_ms=700",
            "motion_still_stays_full=yes",
            "motion_check=pass"
        ],
        "the probe prints these lines, got \(lines)"
    )
    let skipped = StreamMotionProof.judge(fullSize: Size(width: 1920, height: 1080), expectedMotionSize: nil, frames: [], lastScrollMilliseconds: 1500).lines
    expect(skipped.last == "motion_check=skipped-no-motion-size", "a skipped check says so, got \(skipped)")
    expect(
        StreamMotionProof.judge(fullSize: full, expectedMotionSize: motion, frames: [], lastScrollMilliseconds: 1500).lines.contains("motion_settled_after_ms=none"),
        "a picture that never settled prints none"
    )
}

private func expectFrameArrivalOrderAndDimensionsAreChecked() {
    let sameMillisecondRegression = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...1500, at: motion) + [
            Frame(milliseconds: 2000, size: full),
            Frame(milliseconds: 2000, size: motion)
        ],
        lastScrollMilliseconds: 1500
    )
    expect(sameMillisecondRegression.verdict == .fail, "a smaller frame after settling fails even when arrivals round to the same millisecond")
    expect(!sameMillisecondRegression.stillStaysFull, "arrival order determines whether the picture stayed full size")

    let changedShape = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...1500, at: motion) + [
            Frame(milliseconds: 2000, size: full),
            Frame(milliseconds: 2100, size: Size(width: full.height, height: full.width))
        ],
        lastScrollMilliseconds: 1500
    )
    expect(changedShape.verdict == .fail, "equal pixel count with different dimensions did not stay at the full size")

    let preScrollShrink = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: [Frame(milliseconds: -1, size: motion)] + frames(0...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(preScrollShrink.verdict == .fail, "a smaller frame before scrolling is not proof of motion resolution")
}

private func expectOnlyTheConfiguredMotionSizeProvesMotion() {
    let fidelitySize = Size(width: 2268, height: 1472)
    let unrelatedDownscale = StreamMotionProof.judge(
        fullSize: full, expectedMotionSize: motion,
        frames: frames(0...2100, at: fidelitySize) + frames(2200...4500, at: full),
        lastScrollMilliseconds: 1500
    )
    expect(unrelatedDownscale.verdict == .fail, "a fidelity downscale is not the configured motion resolution")

    let configuration = VideoEncoderConfiguration.fullHiDPI
    guard let moving = configuration.motionConfiguration else {
        expect(false, "the HiDPI configuration has a motion encoder")
        return
    }
    let configuredFull = Size(width: configuration.encodeWidth, height: configuration.encodeHeight)
    let configuredMotion = Size(width: moving.encodeWidth, height: moving.encodeHeight)
    let exactMotion = StreamMotionProof.judge(
        fullSize: configuredFull, expectedMotionSize: configuredMotion,
        frames: frames(0...2100, at: configuredMotion) + frames(2200...4500, at: configuredFull),
        lastScrollMilliseconds: 1500
    )
    expect(exactMotion.verdict == .pass, "the production motion dimensions followed by full-size recovery pass")
}
