import Foundation
import SensoriumCore

/// Frames 60 a second apart, each covering the whole screen.
private func changeRun(
    _ detector: inout StreamMotionDetector,
    count: Int,
    from start: Double,
    interval: Double = 1.0 / 60,
    changedFraction: Double? = 1.0
) -> [StreamMotionDetector.Mode] {
    (0..<count).map { index in
        detector.screenChanged(atSeconds: start + Double(index) * interval, changedFraction: changedFraction)
    }
}

func testStreamMotionNeedsAContinuousRunOfBroadChanges() {
    var detector = StreamMotionDetector()
    expect(detector.mode == .settled, "a stream starts settled, at the size the viewer asked for")
    let modes = changeRun(&detector, count: StreamMotionDetector.continuousChangeCount, from: 10)
    expect(
        modes.dropLast().allSatisfy { $0 == .settled },
        "the changes before the run is long enough are still encoded settled, got \(modes)"
    )
    expect(modes.last == .moving, "the change that completes the run is the first one encoded moving, got \(modes)")

    var spaced = StreamMotionDetector()
    let spacedModes = changeRun(
        &spaced,
        count: 10,
        from: 10,
        interval: StreamMotionDetector.continuousChangeGapSeconds + 0.01
    )
    expect(
        spacedModes.allSatisfy { $0 == .settled },
        "changes further apart than the gap are separate changes, not motion: typing never softens the picture, got \(spacedModes)"
    )

    var small = StreamMotionDetector()
    let smallModes = changeRun(
        &small,
        count: 120,
        from: 10,
        changedFraction: StreamMotionDetector.broadChangeFraction / 2
    )
    expect(
        smallModes.allSatisfy { $0 == .settled },
        "a small part of the screen changing every frame, a spinner or a caret, never softens the whole picture, got \(smallModes.last!)"
    )

    var unknown = StreamMotionDetector()
    let unknownModes = changeRun(&unknown, count: StreamMotionDetector.continuousChangeCount, from: 10, changedFraction: nil)
    expect(
        unknownModes.last == .moving,
        "a change whose extent capture did not report counts as the whole screen, got \(unknownModes)"
    )
}

func testStreamMotionStartsAtOnceAfterViewerScrollOrDrag() {
    var detector = StreamMotionDetector()
    detector.viewerInteracted(atSeconds: 20)
    expect(detector.mode == .settled, "input alone changes nothing on screen, so it changes nothing about the picture")
    let mode = detector.screenChanged(
        atSeconds: 20 + StreamMotionDetector.interactionWindowSeconds - 0.01,
        changedFraction: 0.5
    )
    expect(
        mode == .moving,
        "the first broad change after a viewer scroll or drag is already encoded moving, so the first frame of a scroll is the cheap one"
    )

    var late = StreamMotionDetector()
    late.viewerInteracted(atSeconds: 20)
    let lateMode = late.screenChanged(
        atSeconds: 20 + StreamMotionDetector.interactionWindowSeconds + 0.01,
        changedFraction: 0.5
    )
    expect(lateMode == .settled, "a change long after the input is not that input's answer")

    var small = StreamMotionDetector()
    small.viewerInteracted(atSeconds: 20)
    let smallMode = small.screenChanged(
        atSeconds: 20.01,
        changedFraction: StreamMotionDetector.broadChangeFraction / 2
    )
    expect(smallMode == .settled, "a drag that changes only a little of the screen, a text selection, keeps the picture sharp")
}

func testStreamMotionSettlesOnlyAfterTheScreenStaysStill() {
    var detector = StreamMotionDetector()
    expect(detector.settleDeadlineSeconds == nil, "a settled stream has nothing to settle")
    _ = changeRun(&detector, count: 30, from: 30)
    let lastChange = 30 + Double(29) * (1.0 / 60)
    expect(detector.mode == .moving, "a long run of broad changes is motion")
    expect(
        detector.settleDeadlineSeconds == lastChange + StreamMotionDetector.settleSeconds,
        "the picture is due back to full size one settle delay after the last broad change, got \(String(describing: detector.settleDeadlineSeconds))"
    )
    expect(
        !detector.settleIfDue(atSeconds: lastChange + StreamMotionDetector.settleSeconds - 0.001),
        "not a moment before"
    )
    expect(detector.mode == .moving, "and it stays moving until then")

    // Small changes while moving keep the moving encoder in use but do not
    // keep the picture soft: a spinner left running when a scroll ends must
    // not hold the whole screen at the moving size.
    _ = detector.screenChanged(atSeconds: lastChange + 0.2, changedFraction: StreamMotionDetector.broadChangeFraction / 2)
    expect(
        detector.settleDeadlineSeconds == lastChange + StreamMotionDetector.settleSeconds,
        "a small change does not push the settle back"
    )
    expect(
        detector.settleIfDue(atSeconds: lastChange + StreamMotionDetector.settleSeconds),
        "the screen staying still for the settle delay settles the stream"
    )
    expect(detector.mode == .settled, "and the next frame is encoded at full size")
    expect(detector.settleDeadlineSeconds == nil, "a settled stream has no deadline")
    expect(!detector.settleIfDue(atSeconds: lastChange + 10), "and settling twice is not two settles")

    var extended = StreamMotionDetector()
    _ = changeRun(&extended, count: 10, from: 40)
    _ = extended.screenChanged(atSeconds: 40.4, changedFraction: 1)
    expect(
        extended.settleDeadlineSeconds == 40.4 + StreamMotionDetector.settleSeconds,
        "a broad change while moving pushes the settle back to a full delay after it"
    )
}

func testStreamMotionDoesNotFlapOnShortBursts() {
    var detector = StreamMotionDetector()
    for burst in 0..<10 {
        let modes = changeRun(&detector, count: StreamMotionDetector.continuousChangeCount - 1, from: 50 + Double(burst))
        expect(
            modes.allSatisfy { $0 == .settled },
            "a burst shorter than the run, a menu opening or a page loading, never changes size, burst \(burst) got \(modes)"
        )
    }

    var settledAgain = StreamMotionDetector()
    _ = changeRun(&settledAgain, count: 10, from: 60)
    let lastChange = 60 + Double(9) * (1.0 / 60)
    expect(settledAgain.settleIfDue(atSeconds: lastChange + StreamMotionDetector.settleSeconds), "the scroll settles")
    let afterSettle = settledAgain.screenChanged(
        atSeconds: lastChange + StreamMotionDetector.settleSeconds + 0.01,
        changedFraction: 1
    )
    expect(
        afterSettle == .settled,
        "the run that started the last motion does not carry over a settle: a single change after it stays at full size"
    )
}

func testStreamMotionInputIsAScrollOrAPointerMovedWithAButtonHeld() {
    var input = StreamMotionInput()
    expect(
        input.isMotion(.scrolled(deltaX: 0, deltaY: -4, x: 10, y: 10, phase: nil, momentumPhase: nil)),
        "a scroll is motion the viewer asked for"
    )
    expect(!input.isMotion(.pointerMoved(x: 20, y: 20)), "hovering moves nothing on screen but the pointer")
    expect(
        !input.isMotion(.pointerMovedRelative(deltaX: 3, deltaY: 0)),
        "nor does a captured pointer with no button down"
    )
    expect(!input.isMotion(.key(keyCode: 0, isDown: true, modifiers: [])), "typing is never motion")
    expect(
        !input.isMotion(.pointerButton(button: .left, isDown: true, x: 20, y: 20)),
        "a press on its own is a click until the pointer moves"
    )
    expect(input.isMotion(.pointerMoved(x: 30, y: 20)), "moving with a button held is a drag")
    expect(input.isMotion(.pointerMovedRelative(deltaX: 3, deltaY: 0)), "with a captured pointer too")
    expect(
        !input.isMotion(.pointerButton(button: .left, isDown: false, x: 30, y: 20)),
        "the release ends the drag"
    )
    expect(!input.isMotion(.pointerMoved(x: 40, y: 20)), "and moving after it is hovering again")

    _ = input.isMotion(.pointerButton(button: .left, isDown: true, x: 20, y: 20))
    _ = input.isMotion(.pointerButton(button: .right, isDown: true, x: 20, y: 20))
    _ = input.isMotion(.pointerButton(button: .left, isDown: false, x: 20, y: 20))
    expect(input.isMotion(.pointerMoved(x: 50, y: 20)), "a drag lasts while any button is still held")
    _ = input.isMotion(.releaseAllInput)
    expect(!input.isMotion(.pointerMoved(x: 60, y: 20)), "releasing every input releases the held buttons too")
}
