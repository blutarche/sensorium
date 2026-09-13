import Foundation

/// Which part of the pipeline is failing to keep up, decided from this tick's
/// evidence and the few ticks before it.
///
/// The class does not choose which lever is given up -- the ladder does that,
/// in the same order for every class. It chooses which thresholds are applied
/// and which evidence is trusted, and it is what the viewer is told when it
/// asks why the picture is not what it asked for.
///
/// Every rule below the encoder's own median asks for the same evidence
/// several ticks running. A single tick's counters are dominated by whatever
/// the pipeline was doing when it started, and a class decided from one of
/// them costs fidelity the surface never needed to give up.
public enum StreamFidelityPressure: String, Equatable, Sendable, CaseIterable {
    case none
    case encoder
    case link
    case viewer

    public var isPressured: Bool { self != .none }

    /// A tick that captured no more than this many frames is a still screen,
    /// not a struggling one.
    public static let stillCapturedDeltaLimit = 1

    /// The share of one frame period a median encode may take before the
    /// encoder counts as behind. Short of the full period, because an encoder
    /// already at its budget has no room for the frame that costs more than
    /// the median -- but only just short: a hardware encoder whose floor sits
    /// a few milliseconds under the frame period is a marginal frame rate,
    /// and one step down is the whole of the right answer to it.
    public static let encodeBudgetFraction = 0.9
    /// The share of the target frame period a median encode has to fit
    /// inside before a frame rate given up to the encoder is taken back.
    /// Below `encodeBudgetFraction` deliberately: a faster frame rate is
    /// worth climbing back into only with room to spare, or the surface
    /// arrives on the edge of a rate it just failed at and fails again.
    public static let encodeRecoveryFraction = 0.8
    /// The share of captured frames the admission path may drop before the
    /// encoder counts as behind.
    public static let admissionDropFraction = 0.05
    /// How many ticks running the admission path has to lose more than its
    /// share for the encoder to be named.
    public static let admissionDropTicks = 2
    /// What a stream has to be asking of the link before anything the link
    /// does is evidence about it. A stream well under this is small enough
    /// that any link carries it, so whatever went wrong, giving up fidelity
    /// is not the answer to it.
    ///
    /// Read against what the encoder produced, not against what the transport
    /// managed to send: the ask is what the encoder puts in front of the link,
    /// and a link so slow that most of it is discarded before the wire is
    /// exactly the case this floor must not exclude.
    public static let linkMinimumProducedBitsPerSecond = 2_000_000.0
    /// How many of the last `linkDropWindowTicks` ticks have to have lost
    /// frames at the transport hand-off for the link to be named.
    public static let linkDropTicks = 2
    public static let linkDropWindowTicks = 3
    /// How many ticks running a ratio has to hold before it is a trend rather
    /// than a hiccup. Every ratio here is an average over one second of a
    /// pipeline that is allowed the occasional bad one.
    public static let sustainedRatioTicks = 3
    /// The share of one frame period a viewer's decode may take.
    public static let decodeBudgetFraction = 0.8
    /// The share of what was actually put on the wire that must arrive, and
    /// the share of what the viewer decoded that it must actually put on
    /// screen.
    public static let deliveredFraction = 0.7
    /// The frame rate a viewer has to be decoding before the share of it that
    /// reaches the screen means anything. A viewer decoding a handful of
    /// frames a second is looking at a quiet screen, not missing frames.
    public static let viewerMinimumDecodedFramesPerSecond = 10.0

    /// The few ticks of memory the multi-tick rules need, held by whoever
    /// calls `classify` so the classifier itself stays a function of its
    /// arguments. One instance per surface, folded forward one tick at a
    /// time.
    public struct History: Equatable, Sendable {
        fileprivate var admissionOverShareTicks = 0
        /// Whether each of the last `linkDropWindowTicks` ticks lost frames
        /// at the transport hand-off, oldest first.
        fileprivate var sendQueueDroppedTicks: [Bool] = []
        fileprivate var receivedShortfallTicks = 0
        fileprivate var decodeOverBudgetTicks = 0
        fileprivate var presentedShortfallTicks = 0

        public init() {}

        /// Forgets every streak. Called where the ticks on either side cannot
        /// be compared at all: a still screen produces no evidence, and a
        /// pipeline that has just been built produces only its own warm-up.
        public mutating func forget() {
            self = History()
        }

        fileprivate mutating func record(
            _ observation: StreamFidelityObservation,
            framePeriodNanoseconds: Double
        ) {
            let droppedBeforeEncode =
                observation.encoderInputDroppedDelta + observation.globalAdmissionDroppedDelta
            admissionOverShareTicks = Double(droppedBeforeEncode)
                > StreamFidelityPressure.admissionDropFraction * Double(observation.capturedDelta)
                ? admissionOverShareTicks + 1
                : 0

            sendQueueDroppedTicks.append(observation.sendQueueDroppedDelta > 0)
            if sendQueueDroppedTicks.count > StreamFidelityPressure.linkDropWindowTicks {
                sendQueueDroppedTicks.removeFirst()
            }

            // Missing viewer telemetry breaks every streak it feeds rather
            // than extending it: silence is not evidence that a viewer is
            // behind, and it is not evidence that it has caught up either.
            let viewer = observation.viewer
            receivedShortfallTicks = StreamFidelityPressure.isReceivingLessThanSent(
                viewer,
                sentBitsPerSecond: observation.sentBitsPerSecond
            ) ? receivedShortfallTicks + 1 : 0
            decodeOverBudgetTicks = StreamFidelityPressure.isDecodingOverBudget(
                viewer,
                framePeriodNanoseconds: framePeriodNanoseconds
            ) ? decodeOverBudgetTicks + 1 : 0
            presentedShortfallTicks = StreamFidelityPressure.isPresentingLessThanDecoded(viewer)
                ? presentedShortfallTicks + 1
                : 0
        }

        fileprivate var hasSustainedSendQueueDrops: Bool {
            sendQueueDroppedTicks.filter { $0 }.count >= StreamFidelityPressure.linkDropTicks
        }
    }

    /// The one class to act on this tick. Several kinds of evidence can be
    /// present at once -- a host that cannot encode also sends late -- and the
    /// earliest stage wins, because fixing it is what makes the later ones
    /// measurable at all.
    public static func classify(
        _ observation: StreamFidelityObservation,
        appliedFramesPerSecond: Int,
        history: inout History
    ) -> StreamFidelityPressure {
        // Stillness is decided before anything else, and every rule below it
        // is a ratio over frames that were actually captured. A screen nobody
        // is changing produces almost no frames, so the last few before it
        // went quiet would otherwise decide the whole session's fidelity.
        guard observation.capturedDelta > stillCapturedDeltaLimit else {
            history.forget()
            return .none
        }
        let framePeriod = Double(
            EncodeSustainabilityPolicy.frameBudgetNanoseconds(framesPerSecond: appliedFramesPerSecond)
        )
        history.record(observation, framePeriodNanoseconds: framePeriod)

        if let encodeP50Nanoseconds = observation.encodeP50Nanoseconds,
           EncodeSustainabilityPolicy.hasEnoughSamples(observation.encodeSampleCount),
           Double(encodeP50Nanoseconds) > encodeBudgetFraction * encoderBudgetPeriodNanoseconds(
               observation, nominalFramePeriodNanoseconds: framePeriod
           ) {
            return .encoder
        }
        if history.admissionOverShareTicks >= admissionDropTicks {
            return .encoder
        }
        if isLinkPressured(observation, history: history) {
            return .link
        }
        if history.decodeOverBudgetTicks >= sustainedRatioTicks
            || history.presentedShortfallTicks >= sustainedRatioTicks {
            return .viewer
        }
        return .none
    }

    /// The pressure the viewer's own report shows, evaluated on its own so a
    /// recovery decision can ask for unpressured viewer evidence directly
    /// rather than inferring it from a tick that may never have looked.
    ///
    /// One tick, deliberately: giving ground up asks for the same evidence
    /// several ticks running, while taking it back asks for a single fresh
    /// report with nothing wrong in it, and holds the picture where it is
    /// until one arrives.
    public static func viewerEvidencePressure(
        _ viewer: StreamFidelityViewerObservation,
        producedBitsPerSecond: Double?,
        sentBitsPerSecond: Double?,
        appliedFramesPerSecond: Int
    ) -> StreamFidelityPressure {
        let framePeriod = Double(
            EncodeSustainabilityPolicy.frameBudgetNanoseconds(framesPerSecond: appliedFramesPerSecond)
        )
        if hasLinkWorthBlaming(producedBitsPerSecond: producedBitsPerSecond),
           isReceivingLessThanSent(viewer, sentBitsPerSecond: sentBitsPerSecond) {
            return .link
        }
        if isDecodingOverBudget(viewer, framePeriodNanoseconds: framePeriod)
            || isPresentingLessThanDecoded(viewer) {
            return .viewer
        }
        return .none
    }

    /// The period a median encode is judged against: the longer of the
    /// applied frame rate's own nominal period and this tick's observed
    /// capture period, `tickDurationNanoseconds` divided by `capturedDelta`.
    /// A screen producing far fewer frames than that rate is idle for most
    /// of each tick, so the nominal period alone would blame the encoder for
    /// having little to do. `nil` `tickDurationNanoseconds` -- a caller with
    /// no tick boundary to report -- falls back to the nominal period alone.
    public static func encoderBudgetPeriodNanoseconds(
        _ observation: StreamFidelityObservation,
        nominalFramePeriodNanoseconds: Double
    ) -> Double {
        guard let tickDurationNanoseconds = observation.tickDurationNanoseconds,
              observation.capturedDelta > 0 else {
            return nominalFramePeriodNanoseconds
        }
        let observedCapturePeriod = Double(tickDurationNanoseconds) / Double(observation.capturedDelta)
        return Swift.max(nominalFramePeriodNanoseconds, observedCapturePeriod)
    }

    private static func isLinkPressured(
        _ observation: StreamFidelityObservation,
        history: History
    ) -> Bool {
        guard hasLinkWorthBlaming(producedBitsPerSecond: observation.producedBitsPerSecond) else {
            return false
        }
        return history.hasSustainedSendQueueDrops
            || history.receivedShortfallTicks >= sustainedRatioTicks
    }

    private static func hasLinkWorthBlaming(producedBitsPerSecond: Double?) -> Bool {
        guard let producedBitsPerSecond else {
            return false
        }
        return producedBitsPerSecond >= linkMinimumProducedBitsPerSecond
    }

    /// Against what the transport actually put on the wire, never against what
    /// the encoder produced. A link the encoder outruns has its excess frames
    /// discarded at the send queue, and charging the viewer for bits that were
    /// thrown away on this machine makes every tick after the first drop read
    /// as a starved link -- which is the one reading that can never be climbed
    /// out of, since climbing back past what the link took asks for exactly
    /// this measurement to come back clean.
    ///
    /// No send figure means no ratio. Unmeasured is not the same as starved.
    private static func isReceivingLessThanSent(
        _ viewer: StreamFidelityViewerObservation?,
        sentBitsPerSecond: Double?
    ) -> Bool {
        guard let receivedBitsPerSecond = viewer?.receivedBitsPerSecond,
              let sentBitsPerSecond,
              sentBitsPerSecond > 0 else {
            return false
        }
        return receivedBitsPerSecond < deliveredFraction * sentBitsPerSecond
    }

    private static func isDecodingOverBudget(
        _ viewer: StreamFidelityViewerObservation?,
        framePeriodNanoseconds: Double
    ) -> Bool {
        guard let decodeP95Nanoseconds = viewer?.decodeP95Nanoseconds else {
            return false
        }
        return Double(decodeP95Nanoseconds) > decodeBudgetFraction * framePeriodNanoseconds
    }

    /// Against the viewer's own decoded count, never against the frame rate
    /// the host asked for: a viewer presenting everything that reached it is
    /// not the stage that is behind.
    private static func isPresentingLessThanDecoded(_ viewer: StreamFidelityViewerObservation?) -> Bool {
        guard let presentedFramesPerSecond = viewer?.presentedFramesPerSecond,
              let decodedFramesPerSecond = viewer?.decodedFramesPerSecond,
              decodedFramesPerSecond >= viewerMinimumDecodedFramesPerSecond else {
            return false
        }
        return presentedFramesPerSecond < deliveredFraction * decodedFramesPerSecond
    }
}
