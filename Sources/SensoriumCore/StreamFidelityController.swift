import Foundation

/// What the controller decided about one surface this tick. The controller
/// changes no picture itself; it returns the one change worth making, and the
/// caller that owns the encoder applies it.
public enum StreamFidelityDecision: Equatable, Sendable {
    case hold
    case stepDown(to: StreamFidelityLevel, reason: StreamFidelityPressure)
    case stepUp(to: StreamFidelityLevel)
    /// Quality alone returns to full while the screen is still, without
    /// moving either lever.
    case liftQuality(to: StreamFidelityLevel)
    /// The picture a still screen is left holding was encoded as a delta on a
    /// moving one, at whatever the fidelity in force at the time allowed. Sent
    /// again as a whole frame with a budget worth reading, at most once while
    /// the screen stays still, and not while an earlier refresh that was slow
    /// to send is holding refreshes off. Nothing moves.
    case refreshStill

    /// A sharper picture is only visible once a whole frame is coded at the
    /// new quality, so the lift asks for one.
    public var requestsKeyFrame: Bool {
        if case .liftQuality = self {
            return true
        }
        return false
    }
}

/// Decides what one surface streams, one tick of evidence at a time.
///
/// Pure and clock-injected: it reads no clock, touches no encoder, and holds
/// no reference to the session it describes, so the whole policy is testable
/// as arithmetic. One instance per surface.
///
/// It gives ground up in the order `StreamFidelityLadder` describes: the
/// frame rate a step at a time down to 30 fps, then resolution, then quality
/// and the last of the frame rate. Ground comes back in the reverse order.
///
/// Resolution is named rather than stepped towards. Encode cost is per
/// pixel, so the median encode measured at the applied scale predicts the
/// cost of every other scale, and the controller picks the largest scale
/// that leaves the encoder room to hold the frame rate in force. A screen
/// nobody is changing costs nothing to encode and so returns to the size the
/// viewer asked for.
public struct StreamFidelityController: Sendable {
    /// Pressured ticks before ground is given up. One: the cost model names
    /// the resolution that fits from a single tick's measurement, and the
    /// two seconds between changes is what keeps a hiccup from costing a
    /// second one.
    public static let pressuredTicksBeforeStepDown = 1
    /// Consecutive unpressured ticks before ground is taken back. Longer than
    /// the step down, because giving the picture up late is a stutter and
    /// taking it back early is another one.
    public static let unpressuredTicksBeforeStepUp = 2
    /// Ticks after a session start or a pipeline rebuild during which nothing
    /// is decided at all. The counters of those first seconds are the
    /// encoder's opening key frame, the transport's first send, and every
    /// buffer filling for the first time, none of it the cost of what is
    /// about to be streamed steadily.
    public static let warmUpTicks = 3
    /// How long a lever just taken back is watched, so a probe that was too
    /// optimistic is answered in one tick rather than two.
    public static let probationSeconds: Double = 5
    /// How long after taking a lever back a step down below it still counts
    /// as that lever failing.
    ///
    /// Much longer than `probationSeconds`, because the evidence that a lever
    /// is unaffordable can only arrive well after the probe: the stages below
    /// the encoder are named only from several ticks running. A window that
    /// ends before all of that has had time to happen records no failure at
    /// all, and a position that is never recorded as failed is climbed into
    /// again every few seconds for as long as the session lasts.
    public static let leverProbeSeconds: Double = 15
    /// How long a lever position is held off after a probe into it failed.
    public static let initialCeilingSeconds: Double = 60
    /// The longest a lever position is ever held off. A hold-off that
    /// outlives the conditions that caused it is a permanent cap the viewer
    /// never asked for.
    public static let maximumCeilingSeconds: Double = 300
    /// The floor on how often the picture may visibly change.
    public static let minimumSecondsBetweenChanges: Double = 2
    /// Consecutive still ticks before quality returns to full.
    public static let stillTicksBeforeQualityLift = 2
    /// The share of a second the encoder may be predicted to spend at a scale
    /// for that scale to be worth streaming. Room to spare, because the
    /// median is not the slowest frame and a scale change rebuilds the
    /// pipeline.
    public static let climbUtilisation = 0.8
    /// The share of what the viewer says it is receiving that a stream may go
    /// on asking of the link. The rest is room for the bits a link carries
    /// unevenly from one second to the next.
    public static let linkBudgetFraction = 0.8
    /// How much a link budget grows on a tick with nothing wrong in it. A
    /// budget is a reading of one bad moment, and a link that has stopped
    /// refusing bits has to be offered more of them to find out what it can
    /// carry now.
    public static let linkBudgetGrowthRate = 1.1
    /// A still-screen refresh that took longer than this to send held the
    /// link up for everything behind it, the next keystroke's frame included.
    public static let slowStillRefreshSendSeconds = 0.1
    /// How long the next still-screen refresh is held off after one was slow
    /// to send.
    public static let initialStillRefreshHoldOffSeconds: Double = 30
    /// The longest a still-screen refresh is ever held off, however many slow
    /// ones came before it.
    public static let maximumStillRefreshHoldOffSeconds: Double = 240

    /// Where the two cheap levers stand: live settings on the encoder already
    /// running, where a change of scale rebuilds it.
    private struct LeverPosition: Hashable {
        var frameRateIndex: Int
        var qualityIndex: Int

        static let full = LeverPosition(
            frameRateIndex: StreamFidelityLadder.fullFrameRateIndex,
            qualityIndex: StreamFidelityLadder.fullQualityIndex
        )

        /// Whether this position has given up anything the ladder spends after
        /// resolution: quality, or a frame rate below
        /// `StreamFidelityLadder.gentleFrameRateFloorIndex`. Only ever true
        /// once the scale is at its floor.
        var isPastResolution: Bool {
            frameRateIndex > StreamFidelityLadder.gentleFrameRateFloorIndex
                || qualityIndex > StreamFidelityLadder.fullQualityIndex
        }
    }

    /// How long a lever position is held off, and until when. The length
    /// outlives the expiry so a position that fails again is held off for
    /// twice as long as last time rather than starting over.
    private struct LeverCeiling {
        var seconds: Double
        var expiresAtSeconds: Double
    }

    public private(set) var requestedScale: Double
    /// How many `StreamScalePolicy.quantum` steps below `requestedScale` this
    /// surface is streaming.
    public private(set) var scaleStepsBelowRequested = 0
    public private(set) var frameRateIndex = StreamFidelityLadder.fullFrameRateIndex
    public private(set) var qualityIndex = StreamFidelityLadder.fullQualityIndex
    /// Whether the still-screen overlay is in force. It ends with the next
    /// step down, not with the next movement: a screen that starts moving
    /// again has not shown that it cannot afford the sharper picture.
    public private(set) var isQualityLifted = false

    private var pressuredTicks = 0
    private var unpressuredTicks = 0
    private var stillTicks = 0
    /// Consecutive ticks that captured nothing at all. Stricter than
    /// `stillTicks`, which lets a single changed frame through: a blinking
    /// caret changes the screen on nearly every tick, and each change after a
    /// refresh forces a whole-screen key frame that replaces the refreshed
    /// picture, so only a screen with nothing changing keeps one.
    private var quietTicks = 0
    private var warmUpTicksRemaining = StreamFidelityController.warmUpTicks
    private var history = StreamFidelityPressure.History()
    private var lastChangeSeconds: Double?
    private var probationUntilSeconds: Double?
    /// The lever position most recently taken back, and when, until something
    /// steps off it. What decides whether the next step down is this probe
    /// failing.
    private var lastLeverStepUp: (position: LeverPosition, atSeconds: Double)?
    /// The scale this surface was streaming before the change now waiting on
    /// a rebuild. A rebuild that could not be applied leaves the stream where
    /// it was, and the controller has to go back to it rather than describe a
    /// resolution the viewer is not being sent.
    private var scaleStepsBeforeLastChange: Int?
    /// Whether the picture this still screen is holding has already been sent
    /// again properly. Cleared the moment anything moves, so every still
    /// picture gets at most one refresh and no still screen gets a second. A
    /// refresh held off is not one sent: a picture still on screen when the
    /// hold-off ends is refreshed then.
    private var hasRefreshedStill = false
    /// How long still-screen refreshes are held off after the last one was
    /// slow to send, and until when.
    private var stillRefreshHoldOff: LeverCeiling?
    private var ceilings: [LeverPosition: LeverCeiling] = [:]
    /// How long each resolution a rebuild refused is left alone for, keyed by
    /// how many steps below the ask it is. A pipeline that could not be built
    /// at a resolution is usually a piece of hardware saying no, and without
    /// this the cost model names that same resolution again on every
    /// pressured tick for as long as the session lasts.
    private var scaleCeilings: [Int: LeverCeiling] = [:]
    /// Which stage last took resolution, and which stage took each lever
    /// position. What the viewer is told, and what decides whose evidence is
    /// allowed to hand any of it back. The resolution's reason is kept rather
    /// than cleared when the scale returns to the ask, because a rebuild that
    /// then refuses puts the surface back where that stage left it, and the
    /// viewer has to be told the same thing it was told before.
    private var scaleReason: StreamFidelityPressure?
    private var leverReason: [LeverPosition: StreamFidelityPressure] = [:]
    /// What the link showed it could carry when it was last short of bits,
    /// and what every resolution's predicted bits are measured against.
    /// `nil` while nothing has been short, which constrains nothing: a link
    /// nobody has measured is not a link anything is known about.
    private var linkBudgetBitsPerSecond: Double?

    public init(requestedScale: Double = StreamScalePolicy.defaultScale) {
        self.requestedScale = requestedScale
    }

    public var currentLevel: StreamFidelityLevel {
        StreamFidelityLevel(
            framesPerSecond: StreamFidelityLadder.frameRate(at: frameRateIndex),
            qualityScale: isQualityLifted ? 1.0 : StreamFidelityLadder.qualityScale(at: qualityIndex),
            scaleStepsBelowRequested: scaleStepsBelowRequested
        )
    }

    /// Which stage is holding this surface below what the viewer asked for,
    /// for the viewer to be told why: the one that took the last thing given
    /// up, which is also the first thing to come back. `nil` when nothing is
    /// being held back.
    public var limitReason: StreamFidelityPressure? {
        let position = currentLeverPosition
        if position.isPastResolution {
            return leverReason[position]
        }
        if scaleStepsBelowRequested > 0 {
            return scaleReason
        }
        return position == LeverPosition.full ? nil : leverReason[position]
    }

    /// The viewer asked for a different scale. The number of steps this
    /// surface is below the ask is kept, clamped into the range the new ask
    /// has room for.
    public mutating func setRequestedScale(_ scale: Double) {
        // Every scale change re-states the ask, unchanged, on the way through,
        // so anything cleared here unconditionally would be cleared by the
        // controller's own decisions as well as by a viewer's.
        guard scale != requestedScale else {
            return
        }
        requestedScale = scale
        scaleStepsBelowRequested = Swift.min(
            scaleStepsBelowRequested,
            StreamFidelityLadder.scaleStepCount(requestedScale: scale)
        )
        // A step means something different under a different ask, so the one
        // remembered from before it is not a scale to return to any more, and
        // a refusal measured against the old ask says nothing about this one.
        scaleStepsBeforeLastChange = nil
        scaleCeilings.removeAll()
    }

    /// The rebuild the last resolution change asked for could not be applied,
    /// and the stream is still at the scale it was. Puts the scale back, so
    /// what this controller reports is what the viewer is actually being
    /// sent, and leaves that resolution alone for a while, for longer every
    /// time it fails again.
    public mutating func streamScaleDidNotApply(atSeconds: Double) {
        guard let scaleStepsBeforeLastChange else {
            return
        }
        scaleCeilings[scaleStepsBelowRequested] = Self.ceiling(
            after: scaleCeilings[scaleStepsBelowRequested], atSeconds: atSeconds
        )
        scaleStepsBelowRequested = scaleStepsBeforeLastChange
        self.scaleStepsBeforeLastChange = nil
    }

    /// A change this controller asked for could not be applied, and the
    /// caller has put this controller back where it was. The picture never
    /// moved, but the attempt did happen, so the next one waits out the floor
    /// between visible changes rather than running again on the next tick.
    public mutating func changeDidNotApply(atSeconds: Double) {
        lastChangeSeconds = atSeconds
    }

    /// Forgets every hold-off, on the levers and on the resolutions alike.
    /// Called when a surface stops, so a new session is not capped by what an
    /// old one measured.
    public mutating func clearCeilings() {
        ceilings.removeAll()
        scaleCeilings.removeAll()
    }

    /// Starts the warm-up again, for a caller that has just rebuilt the
    /// pipeline this controller is deciding about. What a fresh pipeline
    /// reports first is what building it cost, and fidelity given up for that
    /// is fidelity given up for nothing.
    public mutating func beginWarmUp() {
        warmUpTicksRemaining = Self.warmUpTicks
        // A pipeline that came up is a change that applied; there is nothing
        // left to put back.
        scaleStepsBeforeLastChange = nil
        // The picture this pipeline is now holding is not the one that was
        // refreshed: a rebuild re-encodes from whatever capture delivers next,
        // so a still screen is owed a refresh again.
        hasRefreshedStill = false
        forgetEvidence()
    }

    /// A still-screen refresh finished sending, or failed to, `sendSeconds`
    /// after it was handed to the transport. A slow one holds the next
    /// refresh off: `initialStillRefreshHoldOffSeconds` the first time, twice
    /// as long for each slow one after it, never past
    /// `maximumStillRefreshHoldOffSeconds`. A fast one ends the hold-off.
    ///
    /// Returns how long the hold-off that this refresh started or renewed
    /// lasts, or `nil` when it was fast enough to hold nothing off.
    public mutating func stillRefreshFinishedSending(inSeconds sendSeconds: Double, atSeconds: Double) -> Double? {
        guard sendSeconds > Self.slowStillRefreshSendSeconds else {
            stillRefreshHoldOff = nil
            return nil
        }
        let seconds = Swift.min(
            Self.maximumStillRefreshHoldOffSeconds,
            stillRefreshHoldOff.map { $0.seconds * 2 } ?? Self.initialStillRefreshHoldOffSeconds
        )
        stillRefreshHoldOff = LeverCeiling(seconds: seconds, expiresAtSeconds: atSeconds + seconds)
        return seconds
    }

    public mutating func observe(
        _ observation: StreamFidelityObservation,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        guard warmUpTicksRemaining == 0 else {
            // Read and discarded: the counters of a warm-up tick are only
            // there to be the reading the first real tick takes its deltas
            // against.
            warmUpTicksRemaining -= 1
            forgetEvidence()
            return .hold
        }
        let pressure = StreamFidelityPressure.classify(
            observation,
            appliedFramesPerSecond: currentLevel.framesPerSecond,
            history: &history
        )
        let isStillTick = observation.capturedDelta <= StreamFidelityPressure.stillCapturedDeltaLimit
        stillTicks = isStillTick ? stillTicks + 1 : 0
        quietTicks = observation.capturedDelta == 0 ? quietTicks + 1 : 0
        if !isStillTick {
            hasRefreshedStill = false
        }

        guard pressure.isPressured else {
            pressuredTicks = 0
            unpressuredTicks += 1
            openLinkBudget()
            return recover(observation, atSeconds: atSeconds)
        }
        unpressuredTicks = 0
        pressuredTicks += 1
        if pressure == .link {
            measureLinkBudget(observation)
        }
        return giveUpGround(observation, reason: pressure, atSeconds: atSeconds)
    }

    private mutating func giveUpGround(
        _ observation: StreamFidelityObservation,
        reason: StreamFidelityPressure,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        if let probationUntilSeconds, atSeconds < probationUntilSeconds {
            // Ground taken back a moment ago is already in trouble. Hand it
            // straight back, without the anti-thrash delay: this is undoing
            // this controller's own change, not making a new one. The
            // hold-off that failure earns is recorded by the step down
            // itself, which is also what answers a probe that fails later
            // than this window can see.
            self.probationUntilSeconds = nil
            return stepDown(observation, reason: reason, atSeconds: atSeconds)
        }
        guard pressuredTicks >= Self.pressuredTicksBeforeStepDown,
              canChangePicture(atSeconds: atSeconds) else {
            return .hold
        }
        return stepDown(observation, reason: reason, atSeconds: atSeconds)
    }

    /// One move down the ladder, whichever stage is behind: the frame rate a
    /// step at a time down to `StreamFidelityLadder.gentleFrameRateFloorIndex`,
    /// then the resolution, then `leverPositionBelow`.
    private mutating func stepDown(
        _ observation: StreamFidelityObservation,
        reason: StreamFidelityPressure,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        let position = currentLeverPosition
        if position.frameRateIndex < StreamFidelityLadder.gentleFrameRateFloorIndex {
            let slowed = LeverPosition(
                frameRateIndex: position.frameRateIndex + 1,
                qualityIndex: position.qualityIndex
            )
            return stepLevers(from: position, to: slowed, reason: reason, atSeconds: atSeconds)
        }
        let floor = StreamFidelityLadder.scaleStepCount(requestedScale: requestedScale)
        if scaleStepsBelowRequested < floor {
            scaleStepsBeforeLastChange = scaleStepsBelowRequested
            scaleStepsBelowRequested = scaleStepsForDownMove(
                observation, reason: reason, floor: floor, atSeconds: atSeconds
            )
            scaleReason = reason
            return finishStepDown(reason: reason, atSeconds: atSeconds)
        }
        guard let target = leverPositionBelow(position) else {
            return .hold
        }
        return stepLevers(from: position, to: target, reason: reason, atSeconds: atSeconds)
    }

    /// Moves the levers down from `position` to `target`. Stepping off the
    /// position most recently taken back, inside `leverProbeSeconds`, is that
    /// probe failing, and holds the position off.
    private mutating func stepLevers(
        from position: LeverPosition,
        to target: LeverPosition,
        reason: StreamFidelityPressure,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        if let lastLeverStepUp,
           lastLeverStepUp.position == position,
           atSeconds - lastLeverStepUp.atSeconds <= Self.leverProbeSeconds {
            holdOff(position, atSeconds: atSeconds)
        }
        lastLeverStepUp = nil
        frameRateIndex = target.frameRateIndex
        qualityIndex = target.qualityIndex
        leverReason[target] = reason
        return finishStepDown(reason: reason, atSeconds: atSeconds)
    }

    private mutating func finishStepDown(
        reason: StreamFidelityPressure,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        isQualityLifted = false
        pressuredTicks = 0
        stillTicks = 0
        quietTicks = 0
        probationUntilSeconds = nil
        lastChangeSeconds = atSeconds
        return .stepDown(to: currentLevel, reason: reason)
    }

    /// Where a pressured surface's resolution goes. The encoder's measured
    /// cost and the link's measured budget each name the scale they can
    /// afford directly, at the frame rate already given up to reach this
    /// point, so a stream that cannot carry what it is sending lands on one
    /// that can in a single change rather than several seconds and several
    /// rebuilds later. A viewer behind on its own frames is short of neither,
    /// and one step smaller is what answers it.
    private func scaleStepsForDownMove(
        _ observation: StreamFidelityObservation,
        reason: StreamFidelityPressure,
        floor: Int,
        atSeconds: Double
    ) -> Int {
        let oneStep = Swift.min(scaleStepsBelowRequested + 1, floor)
        guard reason == .encoder || reason == .link,
              let affordable = affordableScaleSteps(
                  observation,
                  framesPerSecond: currentLevel.framesPerSecond,
                  utilisationLimit: Self.climbUtilisation,
                  atSeconds: atSeconds
              ) else {
            return oneStep
        }
        return Swift.min(Swift.max(oneStep, affordable), floor)
    }

    private mutating func recover(
        _ observation: StreamFidelityObservation,
        atSeconds: Double
    ) -> StreamFidelityDecision {
        if let probationUntilSeconds, atSeconds >= probationUntilSeconds {
            self.probationUntilSeconds = nil
        }
        let isStill = stillTicks >= Self.stillTicksBeforeQualityLift
        if isStill,
           !isQualityLifted,
           currentLevel.qualityScale < 1.0,
           canChangePicture(atSeconds: atSeconds) {
            isQualityLifted = true
            lastChangeSeconds = atSeconds
            return .liftQuality(to: currentLevel)
        }
        let canClimb = unpressuredTicks >= Self.unpressuredTicksBeforeStepUp
            && canChangePicture(atSeconds: atSeconds)
        // The reverse of the order ground was given up in: what was spent
        // after the resolution comes back before it, and the resolution
        // before the frame rate above 30 fps.
        let position = currentLeverPosition
        if canClimb, position.isPastResolution {
            if let decision = raiseLever(observation, isStill: isStill, atSeconds: atSeconds) {
                return decision
            }
        } else if canClimb, let decision = raiseScale(observation, atSeconds: atSeconds) {
            return decision
        }
        if quietTicks >= Self.stillTicksBeforeQualityLift, !hasRefreshedStill,
           !Self.isHeldOff(stillRefreshHoldOff, atSeconds: atSeconds),
           canChangePicture(atSeconds: atSeconds) {
            // After the quality lift and the resolution: a lift changes what
            // the picture is worth and a resolution change replaces it
            // outright, so refreshing the one the viewer ends up keeping is
            // the only refresh worth sending. The frame rate above 30 fps
            // waits its turn because it leaves the picture itself alone.
            hasRefreshedStill = true
            lastChangeSeconds = atSeconds
            return .refreshStill
        }
        if canClimb, !position.isPastResolution, scaleStepsBelowRequested == 0,
           let decision = raiseLever(observation, isStill: isStill, atSeconds: atSeconds) {
            return decision
        }
        return .hold
    }

    /// Predicted at the frame rate in force, because that is the rate the
    /// larger picture will be streamed at: the frame rate above it comes back
    /// only once the resolution has, and only if the encoder can afford it
    /// at the size it is then streaming.
    private mutating func raiseScale(
        _ observation: StreamFidelityObservation,
        atSeconds: Double
    ) -> StreamFidelityDecision? {
        guard scaleStepsBelowRequested > 0,
              canRaise(past: scaleReason, observation: observation),
              let affordable = affordableScaleSteps(
                  observation,
                  framesPerSecond: currentLevel.framesPerSecond,
                  utilisationLimit: Self.climbUtilisation,
                  atSeconds: atSeconds
              ),
              affordable < scaleStepsBelowRequested else {
            return nil
        }
        scaleStepsBeforeLastChange = scaleStepsBelowRequested
        scaleStepsBelowRequested = affordable
        unpressuredTicks = 0
        lastChangeSeconds = atSeconds
        probationUntilSeconds = atSeconds + Self.probationSeconds
        return .stepUp(to: currentLevel)
    }

    private mutating func raiseLever(
        _ observation: StreamFidelityObservation,
        isStill: Bool,
        atSeconds: Double
    ) -> StreamFidelityDecision? {
        let position = currentLeverPosition
        guard let target = leverPositionAbove(position),
              !isHeldOff(target, atSeconds: atSeconds),
              canRaiseLever(from: position, to: target, isStill: isStill, observation: observation) else {
            return nil
        }
        leverReason[position] = nil
        frameRateIndex = target.frameRateIndex
        qualityIndex = target.qualityIndex
        unpressuredTicks = 0
        lastChangeSeconds = atSeconds
        probationUntilSeconds = atSeconds + Self.probationSeconds
        lastLeverStepUp = (position: target, atSeconds: atSeconds)
        return .stepUp(to: currentLevel)
    }

    private var currentLeverPosition: LeverPosition {
        LeverPosition(frameRateIndex: frameRateIndex, qualityIndex: qualityIndex)
    }

    /// Where the levers go once the frame rate is at
    /// `StreamFidelityLadder.gentleFrameRateFloorIndex` and the resolution at
    /// its floor: quality first, because the slowest frame rate is worse to
    /// look at than any softening, then the last of the frame rate. `nil`
    /// when both levers are exhausted.
    private func leverPositionBelow(_ position: LeverPosition) -> LeverPosition? {
        if position.qualityIndex < StreamFidelityLadder.softestQualityIndex {
            return LeverPosition(
                frameRateIndex: position.frameRateIndex,
                qualityIndex: position.qualityIndex + 1
            )
        }
        guard position.frameRateIndex < StreamFidelityLadder.slowestFrameRateIndex else {
            return nil
        }
        return LeverPosition(
            frameRateIndex: position.frameRateIndex + 1,
            qualityIndex: position.qualityIndex
        )
    }

    /// The reverse of the order the levers are spent in: the frame rate below
    /// `StreamFidelityLadder.gentleFrameRateFloorIndex`, then the quality,
    /// then the frame rate above it, which `recover` asks for only once the
    /// resolution is back at the scale the viewer asked for.
    private func leverPositionAbove(_ position: LeverPosition) -> LeverPosition? {
        if position.frameRateIndex > StreamFidelityLadder.gentleFrameRateFloorIndex {
            return LeverPosition(
                frameRateIndex: position.frameRateIndex - 1,
                qualityIndex: position.qualityIndex
            )
        }
        if position.qualityIndex > StreamFidelityLadder.fullQualityIndex {
            return LeverPosition(
                frameRateIndex: position.frameRateIndex,
                qualityIndex: position.qualityIndex - 1
            )
        }
        guard position.frameRateIndex > StreamFidelityLadder.fullFrameRateIndex else {
            return nil
        }
        return LeverPosition(
            frameRateIndex: position.frameRateIndex - 1,
            qualityIndex: position.qualityIndex
        )
    }

    private func canRaiseLever(
        from position: LeverPosition,
        to target: LeverPosition,
        isStill: Bool,
        observation: StreamFidelityObservation
    ) -> Bool {
        switch leverReason[position] ?? .none {
        case .encoder:
            // A still screen hands the frame rate back without the median
            // encode a moving one has to show. There is nothing to measure,
            // an encoder with no frames to encode is not the stage that
            // cannot keep up, and asking for a measurement a still screen
            // cannot produce is what would leave a quiet session capped for
            // as long as it stays quiet. Nothing here rebuilds a pipeline:
            // both levers are live settings on the encoder already running.
            if isStill {
                return true
            }
            return canAffordEncode(
                atFramesPerSecond: StreamFidelityLadder.frameRate(at: target.frameRateIndex),
                observation: observation
            )
        case .link, .viewer:
            return canRaise(past: leverReason[position], observation: observation)
        case .none:
            return true
        }
    }

    /// Whether the evidence in this tick is enough to climb past what the
    /// named stage took, which that stage decides, because each leaves a
    /// different kind of silence behind.
    ///
    /// Ground given up to the link or the viewer can only be taken back on
    /// the viewer's own evidence. The host looking healthy proves nothing
    /// about either, and telemetry that has stopped arriving proves less:
    /// silence must never read as recovery. The encoder is the one stage this
    /// controller measures directly, and the cost model is what answers it.
    private func canRaise(
        past reason: StreamFidelityPressure?,
        observation: StreamFidelityObservation
    ) -> Bool {
        switch reason {
        case .some(.link), .some(.viewer):
            guard let viewer = observation.viewer else {
                return false
            }
            return !StreamFidelityPressure.viewerEvidencePressure(
                viewer,
                producedBitsPerSecond: observation.producedBitsPerSecond,
                sentBitsPerSecond: observation.sentBitsPerSecond,
                appliedFramesPerSecond: currentLevel.framesPerSecond
            ).isPressured
        case .some(.encoder), .some(.none), nil:
            return true
        }
    }

    /// The largest scale worth streaming, as a number of quantum steps below
    /// `requestedScale`.
    ///
    /// Encode cost is per pixel, so a scale is predicted to cost the measured
    /// median times the square of its ratio to the scale that median was
    /// measured at. What that costs per second is the prediction times the
    /// rate frames actually arrive at, which is the lower of the screen's own
    /// observed capture rate and `framesPerSecond`, the frame rate in force:
    /// a screen producing 10 frames a second costs ten encodes, whatever the
    /// frame rate says, and a frame rate already given up leaves each frame
    /// a longer share of the second.
    ///
    /// A scale has to fit the link as well as the encoder: what it would cost
    /// in bits per second is predicted the same way, from what this tick
    /// produced, and measured against what the link last showed it carries.
    ///
    /// A resolution a rebuild refused is skipped for as long as its hold-off
    /// lasts, and the next one down is chosen instead.
    ///
    /// `nil` when nothing has been measured. Unmeasured is not affordable.
    private func affordableScaleSteps(
        _ observation: StreamFidelityObservation,
        framesPerSecond: Int,
        utilisationLimit: Double,
        atSeconds: Double
    ) -> Int? {
        let rate = Swift.min(observedCaptureRate(observation), Double(framesPerSecond))
        let floor = StreamFidelityLadder.scaleStepCount(requestedScale: requestedScale)
        let worthTrying = (0...floor).filter {
            !Self.isHeldOff(scaleCeilings[$0], atSeconds: atSeconds)
        }
        // A resolution every rebuild refused is still better than none at
        // all, so a surface with nothing left open falls back to the floor.
        let smallestWorthTrying = worthTrying.last ?? floor
        guard rate > 0 else {
            // A screen producing nothing costs nothing to encode at any size
            // and asks nothing of the link either, whatever either of them
            // last measured on a moving one.
            return worthTrying.first ?? floor
        }
        guard let encodeP50Nanoseconds = observation.encodeP50Nanoseconds,
              EncodeSustainabilityPolicy.hasEnoughSamples(observation.encodeSampleCount) else {
            return nil
        }
        let measuredScale = currentLevel.streamScale(requestedScale: requestedScale)
        guard measuredScale > 0 else {
            return nil
        }
        let measuredSeconds = Double(encodeP50Nanoseconds) / 1_000_000_000
        for steps in worthTrying {
            let scale = StreamFidelityLevel(
                framesPerSecond: framesPerSecond,
                qualityScale: 1.0,
                scaleStepsBelowRequested: steps
            ).streamScale(requestedScale: requestedScale)
            let ratio = scale / measuredScale
            if measuredSeconds * ratio * ratio * rate <= utilisationLimit,
               fitsLinkBudget(observation, scale: scale, measuredScale: measuredScale) {
                return steps
            }
        }
        return smallestWorthTrying
    }

    /// Whether a scale's predicted bits fit what the link has shown it can
    /// carry. Bits go with pixels and with the quality multiplier, so this
    /// tick's own measured bits predict every other scale the way the median
    /// encode predicts every other cost. How often a frame is produced is in
    /// both figures equally, this tick's rate being the only rate either of
    /// them is about, so it cancels rather than appearing here.
    ///
    /// An unknown budget and unmeasured bits both fit: nothing has asked for
    /// a smaller picture, and a stream this controller cannot read is not one
    /// it may charge for the link.
    private func fitsLinkBudget(
        _ observation: StreamFidelityObservation,
        scale: Double,
        measuredScale: Double
    ) -> Bool {
        guard let linkBudgetBitsPerSecond,
              let producedBitsPerSecond = observation.producedBitsPerSecond,
              measuredScale > 0 else {
            return true
        }
        let measuredQuality = currentLevel.qualityScale
        guard measuredQuality > 0 else {
            return true
        }
        let ratio = scale / measuredScale
        let predicted = producedBitsPerSecond * ratio * ratio / measuredQuality
        return predicted <= linkBudgetBitsPerSecond
    }

    /// What the link carried while it was refusing bits, less the room a
    /// budget leaves. Taken from the viewer's own reading, because what
    /// arrived is the only honest measure of what the link will carry. A
    /// link named from frames the send queue refused, with no viewer report
    /// behind it, measures nothing and constrains nothing.
    private mutating func measureLinkBudget(_ observation: StreamFidelityObservation) {
        guard let receivedBitsPerSecond = observation.viewer?.receivedBitsPerSecond,
              receivedBitsPerSecond > 0 else {
            return
        }
        linkBudgetBitsPerSecond = receivedBitsPerSecond * Self.linkBudgetFraction
    }

    /// Opens the budget up on a tick with nothing wrong in it, so a link that
    /// has recovered is offered the resolution back a step at a time instead
    /// of being held at what its worst second measured. A surface already
    /// streaming what the viewer asked for has nothing left to climb to, and
    /// its budget is forgotten rather than grown without bound.
    private mutating func openLinkBudget() {
        guard scaleStepsBelowRequested > 0 else {
            linkBudgetBitsPerSecond = nil
            return
        }
        guard let linkBudgetBitsPerSecond else {
            return
        }
        self.linkBudgetBitsPerSecond = linkBudgetBitsPerSecond * Self.linkBudgetGrowthRate
    }

    /// How many frames the screen actually produced per second this tick. A
    /// still screen produced nothing for the encoder to do, so it predicts
    /// zero and every scale is affordable, which is why a screen nobody is
    /// changing goes back to the size the viewer asked for.
    private func observedCaptureRate(_ observation: StreamFidelityObservation) -> Double {
        guard observation.capturedDelta > StreamFidelityPressure.stillCapturedDeltaLimit else {
            return 0
        }
        guard let tickDurationNanoseconds = observation.tickDurationNanoseconds,
              tickDurationNanoseconds > 0 else {
            // No tick boundary to divide by. Assume the screen is producing
            // everything the applied frame rate asks for, which is the most
            // it can cost.
            return Double(currentLevel.framesPerSecond)
        }
        return Double(observation.capturedDelta) * 1_000_000_000 / Double(tickDurationNanoseconds)
    }

    /// Whether the median encode of this tick fits the frame period being
    /// climbed into, with the margin
    /// `StreamFidelityPressure.encodeRecoveryFraction` asks for.
    ///
    /// Measured against the target's period rather than the current one,
    /// which is longer and which the encoder is already meeting by
    /// definition. Without the margin a surface climbs back into a frame rate
    /// it fails at, fails, and climbs again. No median, or too few samples
    /// behind one, holds it where it is: unmeasured is not the same as
    /// affordable.
    ///
    /// A quiet screen's own capture period still counts, as it does in
    /// `StreamFidelityPressure.encoderBudgetPeriodNanoseconds`, but scaled to
    /// the target first. Capture never delivers more frames than the frame
    /// rate in force, so a busy screen held to 45 fps captures 45 a second,
    /// and read as it stands that period would judge the climb against the
    /// rate already being met. Scaled in proportion, a screen filling every
    /// frame it is allowed is judged against the target's own period, and a
    /// quiet one is still judged against the long gaps between its frames.
    private func canAffordEncode(
        atFramesPerSecond framesPerSecond: Int,
        observation: StreamFidelityObservation
    ) -> Bool {
        guard let encodeP50Nanoseconds = observation.encodeP50Nanoseconds,
              EncodeSustainabilityPolicy.hasEnoughSamples(observation.encodeSampleCount) else {
            return false
        }
        var budgetPeriod = Double(
            EncodeSustainabilityPolicy.frameBudgetNanoseconds(framesPerSecond: framesPerSecond)
        )
        if let tickDurationNanoseconds = observation.tickDurationNanoseconds, observation.capturedDelta > 0 {
            let observedCapturePeriod = Double(tickDurationNanoseconds) / Double(observation.capturedDelta)
            let projectedCapturePeriod = observedCapturePeriod
                * Double(currentLevel.framesPerSecond) / Double(Swift.max(1, framesPerSecond))
            budgetPeriod = Swift.max(budgetPeriod, projectedCapturePeriod)
        }
        return Double(encodeP50Nanoseconds)
            < StreamFidelityPressure.encodeRecoveryFraction * budgetPeriod
    }

    /// Drops every streak and every run of ticks, so nothing measured before
    /// this point can combine with anything measured after it.
    private mutating func forgetEvidence() {
        history.forget()
        pressuredTicks = 0
        unpressuredTicks = 0
        stillTicks = 0
        quietTicks = 0
    }

    /// Holds `position` off for twice as long as the last time it failed, or
    /// for `initialCeilingSeconds` if this is the first time.
    private mutating func holdOff(_ position: LeverPosition, atSeconds: Double) {
        ceilings[position] = Self.ceiling(after: ceilings[position], atSeconds: atSeconds)
    }

    private func isHeldOff(_ position: LeverPosition, atSeconds: Double) -> Bool {
        Self.isHeldOff(ceilings[position], atSeconds: atSeconds)
    }

    /// The hold-off that follows `existing`: twice as long as it was, or
    /// `initialCeilingSeconds` where there was none, never past
    /// `maximumCeilingSeconds`.
    private static func ceiling(after existing: LeverCeiling?, atSeconds: Double) -> LeverCeiling {
        let heldOffFor = Swift.min(
            maximumCeilingSeconds,
            existing.map { $0.seconds * 2 } ?? initialCeilingSeconds
        )
        return LeverCeiling(seconds: heldOffFor, expiresAtSeconds: atSeconds + heldOffFor)
    }

    private static func isHeldOff(_ ceiling: LeverCeiling?, atSeconds: Double) -> Bool {
        guard let ceiling else {
            return false
        }
        return atSeconds < ceiling.expiresAtSeconds
    }

    private func canChangePicture(atSeconds: Double) -> Bool {
        guard let lastChangeSeconds else {
            return true
        }
        return atSeconds - lastChangeSeconds >= Self.minimumSecondsBetweenChanges
    }
}
