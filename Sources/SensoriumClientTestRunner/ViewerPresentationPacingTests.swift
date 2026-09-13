import CoreVideo
import Foundation
import SensoriumClient
import SensoriumCore

/// Identifies a frame by its host capture time, the one field that travels
/// through the pacer unchanged.
private func makePacedFrame(capturedAtNanoseconds: Int64) -> DecodedFrame {
    DecodedFrame(
        pixelBuffer: makeTestPixelBuffer(),
        timing: FrameTiming(
            hostCapturedAtNanoseconds: capturedAtNanoseconds,
            receivedAtNanoseconds: capturedAtNanoseconds,
            decodedAtNanoseconds: capturedAtNanoseconds
        )
    )
}

private func capturedAt(_ presentation: PresentationPacer.Presentation?) -> Int64? {
    presentation?.frame.timing?.hostCapturedAtNanoseconds
}

/// Feeds a pacer one steady stream so it knows the stream's frame interval and
/// how little its arrivals vary, and returns it warmed up. Every frame is taken
/// back out, so nothing is left waiting.
private func warmedPacer(
    interval: Int64,
    transit: Int64,
    start: Int64,
    frames: Int
) -> PresentationPacer {
    var pacer = PresentationPacer()
    for index in 0..<frames {
        let captured = start + Int64(index) * interval
        let arrived = captured + transit
        pacer.admit(makePacedFrame(capturedAtNanoseconds: captured), nowNanoseconds: arrived)
        _ = pacer.frameToPresent(nowNanoseconds: arrived + PresentationPacer.maximumHoldNanoseconds)
    }
    return pacer
}

@MainActor
func testViewerPresentationPacingTests() {
    let interval = PresentationPacer.defaultFrameIntervalNanoseconds
    let transit: Int64 = 20_000_000
    let start: Int64 = 1_000_000_000
    let warmUpFrames = 30

    var pacer = warmedPacer(interval: interval, transit: transit, start: start, frames: warmUpFrames)
    expect(
        pacer.holdNanoseconds == interval,
        "a stream whose frames all arrive alike is held one frame interval, got \(pacer.holdNanoseconds)"
    )

    // Two frames the host captured a frame apart, arriving off the network
    // together. Held apart by the gap between their capture times, they are
    // drawn on two consecutive refreshes instead of one of them being thrown
    // away because both landed inside the same one.
    let firstCapture = start + Int64(warmUpFrames) * interval
    let secondCapture = firstCapture + interval
    let burstArrival = secondCapture + transit
    pacer.admit(makePacedFrame(capturedAtNanoseconds: firstCapture), nowNanoseconds: burstArrival)
    pacer.admit(makePacedFrame(capturedAtNanoseconds: secondCapture), nowNanoseconds: burstArrival)

    let firstRefresh = pacer.frameToPresent(nowNanoseconds: burstArrival)
    expect(
        capturedAt(firstRefresh) == firstCapture && firstRefresh?.supersededCount == 0,
        "the older of two frames that arrived together is the one drawn first, got \(String(describing: capturedAt(firstRefresh)))"
    )
    expect(
        pacer.frameToPresent(nowNanoseconds: burstArrival) == nil,
        "the newer one is not yet due, so the same refresh does not take it too"
    )
    let secondRefresh = pacer.frameToPresent(nowNanoseconds: burstArrival + interval)
    expect(
        capturedAt(secondRefresh) == secondCapture && secondRefresh?.supersededCount == 0,
        "it is drawn on the next refresh instead, got \(String(describing: capturedAt(secondRefresh)))"
    )

    // A frame that arrived long after its capture time says so is drawn at
    // once. Waiting on a clock this far out would freeze the picture.
    let lateArrival = burstArrival + 2 * interval
    let lateCapture = lateArrival - transit - 300_000_000
    pacer.admit(makePacedFrame(capturedAtNanoseconds: lateCapture), nowNanoseconds: lateArrival)
    expect(
        capturedAt(pacer.frameToPresent(nowNanoseconds: lateArrival)) == lateCapture,
        "a frame 300 milliseconds behind the stream is drawn on the next refresh, not held further"
    )

    // Arrivals that vary are held longer, so the gaps between them are
    // absorbed rather than shown as judder.
    var jittery = PresentationPacer()
    for index in 0..<60 {
        let captured = start + Int64(index) * interval
        let arrived = captured + transit + (index % 5 == 0 ? 25_000_000 : 0)
        jittery.admit(makePacedFrame(capturedAtNanoseconds: captured), nowNanoseconds: arrived)
        _ = jittery.frameToPresent(nowNanoseconds: arrived + PresentationPacer.maximumHoldNanoseconds)
    }
    expect(
        jittery.holdNanoseconds > interval,
        "a stream that arrives unevenly is held longer than one that does not, got \(jittery.holdNanoseconds)"
    )
    expect(
        jittery.holdNanoseconds <= PresentationPacer.maximumHoldNanoseconds,
        "and never past the ceiling, got \(jittery.holdNanoseconds)"
    )

    var wild = PresentationPacer()
    for index in 0..<60 {
        let captured = start + Int64(index) * interval
        let arrived = captured + transit + (index % 5 == 0 ? 400_000_000 : 0)
        wild.admit(makePacedFrame(capturedAtNanoseconds: captured), nowNanoseconds: arrived)
        _ = wild.frameToPresent(nowNanoseconds: arrived + PresentationPacer.maximumHoldNanoseconds)
    }
    expect(
        wild.holdNanoseconds == PresentationPacer.maximumHoldNanoseconds,
        "a link that stalls for hundreds of milliseconds is held at the ceiling, not for as long as it stalled,"
            + " got \(wild.holdNanoseconds)"
    )

    // A frame with no timing cannot be placed on the host's clock, so it is
    // drawn at the next refresh exactly as it was before there was a pacer at
    // all.
    var untimed = PresentationPacer()
    untimed.admit(DecodedFrame(pixelBuffer: makeTestPixelBuffer()), nowNanoseconds: start)
    expect(
        untimed.frameToPresent(nowNanoseconds: start) != nil,
        "a frame the viewer could not tie to a capture time waits for nothing"
    )
    expect(
        untimed.holdNanoseconds == 0,
        "and nothing it carries is folded into the hold, got \(untimed.holdNanoseconds)"
    )

    // Frames waiting are pixel buffers held in memory, so the queue is bounded
    // the same way every other viewer queue is.
    var flooded = PresentationPacer()
    var superseded = 0
    for index in 0...(PresentationPacer.maximumPending + 4) {
        let captured = start + Int64(index) * interval
        superseded += flooded.admit(
            makePacedFrame(capturedAtNanoseconds: captured),
            nowNanoseconds: captured + transit
        )
    }
    expect(
        superseded == 5,
        "a viewer whose screen is not drawing gives up the oldest frames rather than holding them all, got \(superseded)"
    )

    // A link that varies wildly pins the hold at its ceiling, where the hold
    // can no longer absorb anything. One unusually quick packet then makes the
    // window's smallest delay smaller, which must not pull a later-captured
    // frame in front of one already waiting: the frames waiting are exactly
    // the ones a person is about to see, and reordering them shows the past
    // after the present.
    var pinned = PresentationPacer()
    var captured = start
    for index in 0..<40 {
        let arrived = captured + (index.isMultiple(of: 2) ? 20_000_000 : 300_000_000)
        pinned.admit(makePacedFrame(capturedAtNanoseconds: captured), nowNanoseconds: arrived)
        _ = pinned.frameToPresent(nowNanoseconds: arrived + PresentationPacer.maximumHoldNanoseconds)
        captured += interval
    }
    expect(
        pinned.holdNanoseconds == PresentationPacer.maximumHoldNanoseconds,
        "a link this uneven is held at the ceiling, got \(pinned.holdNanoseconds)"
    )

    // Three frames queued together, the last of them arriving unusually fast.
    let queued = [captured, captured + interval, captured + 2 * interval]
    pinned.admit(makePacedFrame(capturedAtNanoseconds: queued[0]), nowNanoseconds: queued[0] + 20_000_000)
    pinned.admit(makePacedFrame(capturedAtNanoseconds: queued[1]), nowNanoseconds: queued[1] + 20_000_000)
    pinned.admit(makePacedFrame(capturedAtNanoseconds: queued[2]), nowNanoseconds: queued[2] + 3_000_000)

    var shown: [Int64] = []
    var supersededWhileQueued = 0
    var tick = queued[2] + 3_000_000
    let stopAt = tick + 2_000_000_000
    while shown.count < queued.count, tick < stopAt {
        if let presentation = pinned.frameToPresent(nowNanoseconds: tick) {
            shown.append(presentation.frame.timing?.hostCapturedAtNanoseconds ?? -1)
            supersededWhileQueued += presentation.supersededCount
        }
        tick += 1_000_000
    }
    expect(
        shown == queued,
        "every queued frame is shown, in the order the host captured them, got \(shown) of \(queued)"
    )
    expect(
        supersededWhileQueued == 0,
        "and none of them is given up for a frame captured after it, got \(supersededWhileQueued)"
    )

    print("viewer presentation pacing tests passed")
}
