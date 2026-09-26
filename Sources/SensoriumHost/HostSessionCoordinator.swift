import Foundation
import SensoriumCore

/// Capture and encode of the session-owned canvas, behind a seam so the decision
/// of *when* to stream is verifiable without ScreenCaptureKit or a permission.
@MainActor
public protocol CanvasMediaStreaming: AnyObject {
    /// `onPacket` answers whether the frame was taken by whatever is behind
    /// it. A stream frame ignores that; a still-screen refresh does not, and
    /// `refreshStillPicture` reports a refused frame rather than counting it
    /// as a picture that went out.
    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws
    func stop() async
    /// The fraction of the canvas's native resolution currently streamed.
    var currentStreamScale: Double { get }
    /// Rebuilds capture and encode at a new fraction of the canvas's native
    /// resolution, keeping the same packet stream so the viewer's frame
    /// sequencing and keyframe recovery survive the change.
    ///
    /// Throws `CanvasMediaReconfigurationError.recoveredToPreviousScale` when
    /// the new resolution failed but the previous working stream was restored;
    /// any other error means there is no working stream left.
    func reconfigure(streamScale: Double) async throws
    /// Changes the capture and encode frame rate on the running stream. No
    /// rebuild: unlike a resolution change, this costs the viewer no gap in
    /// the picture, which is why it is the first fidelity lever to reach for.
    func apply(framesPerSecond: Int) async throws
    /// Changes how many bits the current resolution is allowed, on the
    /// running stream and with no rebuild.
    func apply(qualityScale: Double) async throws
    /// Makes the next frame a key frame. A fidelity change is worth one: the
    /// viewer sees the new picture at once rather than deltas built on the old
    /// one until the key-frame interval next comes around.
    func requestKeyFrame() async
    /// Sends the frame this surface last captured again, as a whole frame
    /// sharp enough to read, without waiting for the screen to change.
    ///
    /// Capture is change-driven, so the last thing a screen that has gone
    /// still sent is a delta encoded while it was moving, at whatever the
    /// fidelity in force then allowed -- and nothing will replace it until
    /// something moves again. This is what replaces it. The fidelity in force
    /// is not changed by it: that frame is encoded on a session of its own.
    ///
    /// Answers how large the frame that went out is, or `nil` when there was
    /// nothing to send, which is a surface that has not captured a frame yet
    /// rather than a failure.
    func refreshStillPicture() async throws -> Int?
    /// The frame rate currently applied, which is what a viewer is told, not
    /// whatever was asked for.
    var currentFramesPerSecond: Int { get async }
    /// The fraction of this resolution's full bitrate currently applied.
    var currentQualityScale: Double { get async }
    /// This surface's ground-truth capture and encode counters, so a caller
    /// deciding whether to change fidelity reads what actually happened
    /// instead of inferring it. Cumulative for the life of the stream; a
    /// caller wanting a rate takes the difference between two readings.
    ///
    /// All zero from a media with no recorder behind it. That means nothing
    /// was measured, not that nothing was dropped.
    var frameCounts: HostFrameCounts { get async }
    /// Told when this capture stops on its own -- `SCStreamDelegate`'s own
    /// stream-stopped signal, never a stop this caller asked for through
    /// `stop()`. `nil` clears whatever handler was set. Default no-op below,
    /// so a conformer with no such signal to report keeps conforming
    /// unchanged.
    func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?)
}

public extension CanvasMediaStreaming {
    func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {}
}

public enum CanvasMediaReconfigurationError: Error, Equatable {
    /// The requested scale could not be brought up, and the stream is running
    /// at the scale named here instead. The session survives.
    case recoveredToPreviousScale(Double)
}

/// Where encoded frames go once produced. Deliberately not main-actor isolated:
/// encoded frames arrive from the encoder's own queue at 60 fps and must not
/// queue behind main-thread work to be sent.
public protocol CanvasVideoSending: AnyObject, Sendable {
    /// `surface` is carried all the way to the wire: it decides both which of
    /// the per-surface send queues the frame waits in and which surfaceID the
    /// frame is tagged with. `priority` is the seam a later focus signal would
    /// use; see `SurfaceVideoSendQueues`.
    ///
    /// `false` when this frame was not taken: the link could not keep up and
    /// the queue discarded it, or this sink has no way to tag the surface it
    /// belongs to. A stream frame has nothing to do about either, which is why
    /// the result is discardable -- but a still-screen refresh is a single
    /// frame whose sending is reported to a person, and that report must not
    /// describe a picture the transport refused.
    ///
    /// `true` means the transport accepted the frame, not that its bytes have
    /// reached the wire: the write itself completes later.
    @discardableResult
    func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool
    /// Frames the transport discarded because the link could not keep up.
    /// A sink with no queue of its own reports none.
    var droppedVideoFrameCount: Int { get }
    /// The same count for one surface alone. The total above is what an
    /// operator reads; this is what a per-surface fidelity decision needs,
    /// since one canvas's link trouble is not evidence about the other's.
    func droppedVideoFrameCount(for surface: CanvasSurfaceID) -> Int
    /// Bytes this sink actually wrote for `surface`, cumulative for the life
    /// of the connection. Distinct from the bytes handed to `send`, which
    /// include every frame the queue then discarded: what a viewer reports
    /// receiving is only comparable with what really went onto the wire.
    ///
    /// `nil` from a sink that does not count sends, which leaves a fidelity
    /// decision with no ratio rather than one built on bytes that may never
    /// have left this machine.
    func sentVideoByteCount(for surface: CanvasSurfaceID) -> Int?
}

public extension CanvasVideoSending {
    var droppedVideoFrameCount: Int { 0 }

    func droppedVideoFrameCount(for surface: CanvasSurfaceID) -> Int { 0 }

    func sentVideoByteCount(for surface: CanvasSurfaceID) -> Int? { nil }
}

/// The three steps share one catch, so each names itself; a workspace that
/// would not place is not a capture failure.
private enum CanvasBringUpStage {
    case workspacePlacement
    case canvasReadyWrite
    case captureStart

    /// The cause goes through `HostOperatorLog`, never straight into the
    /// string: interpolating the error is what put Swift case names in front
    /// of the person standing at this machine.
    func failureEvent(displayID: UInt32, error: any Error) -> String {
        let cause = HostOperatorLog.describe(error)
        switch self {
        case .workspacePlacement:
            return "Could not open the workspace on session canvas \(displayID). \(cause)"
        case .canvasReadyWrite:
            return "Could not tell the other machine that session canvas \(displayID) is ready. \(cause)"
        case .captureStart:
            return "Could not start capturing session canvas \(displayID). \(cause)"
        }
    }
}

/// Host-screen bring-up has no workspace step, so it names its own stages,
/// keeping the failure cause attributable to the step that actually
/// failed.
private enum HostScreenBringUpStage {
    case readyWrite
    case captureStart
    case modeListWrite

    func failureEvent(error: any Error) -> String {
        let cause = HostOperatorLog.describe(error)
        switch self {
        case .readyWrite:
            return "Could not tell the other machine that host-screen capture is ready. \(cause)"
        case .captureStart:
            return "Could not start host-screen capture. \(cause)"
        case .modeListWrite:
            return "Could not tell the other machine which display modes this screen offers. \(cause)"
        }
    }
}

/// A `hostScreenReady` reached the coordinator with no way to bring capture
/// up. Unreachable in a correctly wired process, since the controller only
/// answers `hostScreenReady` after admission resolved a display, so both
/// cases fail the way any bring-up failure does rather than leaving a
/// viewer a ready session that never gets video.
public enum HostScreenBringUpError: Error, Equatable {
    /// No `hostScreenMediaFactory` was ever given to this coordinator.
    case noMediaFactoryConfigured
    /// The controller admitted a request but reports no resolved display.
    case displayIDUnavailable
}

/// Ties the control protocol to the media pipelines: streaming begins only after
/// a canvas exists, targets only that canvas, and stops when the session ends.
///
/// Everything a canvas owns — its display session, its media pipeline, its
/// workspace window, its stream scale — is keyed by `CanvasSurfaceID`, so a
/// second canvas is a second set of state rather than a second claim on the
/// first canvas's. The connection itself is not: one transport, one video
/// sink, one session-ended signal.
@MainActor
public final class HostSessionCoordinator {
    private let controller: HostSessionController
    private let media: CanvasSurfaceSlots<any CanvasMediaStreaming>
    private let videoSink: any CanvasVideoSending
    /// Shared with every media pipeline this session runs, so the focus
    /// report the controller accepts reaches the encode gate as well as the
    /// send path.
    private let focus: CanvasFocusTracker
    private let workspaces: CanvasSurfaceSlots<any CanvasWorkspacePresenting>
    /// Operational diagnostics. A headless host that fails silently is
    /// indistinguishable from one that is working.
    private let onEvent: (@Sendable (String) -> Void)?
    /// Fires exactly once per session that actually started streaming, at the
    /// point capture stops — the natural place for a caller to write a
    /// latency trace before the recorder that fed it goes out of scope. Once
    /// per *session*, not per surface: both canvases share one connection and
    /// one latency recorder.
    private let onSessionEnded: (@Sendable () -> Void)?
    /// Fires when the session has no working video left and cannot get one
    /// back. The caller must drop the connection: a viewer left holding a
    /// frozen picture on a live socket has no way to tell that the stream
    /// died, and would never redial.
    private let onStreamUnrecoverable: (@Sendable (String) -> Void)?
    private var isStreaming = CanvasSurfaceSlots { _ in false }
    /// Host-screen mode has no `CanvasSurfaceID` of its own, so its
    /// bring-up, teardown, and streaming flag are their own,
    /// unkeyed state rather than a third `CanvasSurfaceSlots` entry.
    /// Constructed once per session by `hostScreenMediaFactory`, the moment
    /// a `hostScreenReady` response names the real geometry to size it
    /// from -- never built speculatively, since most sessions never use
    /// this mode at all.
    private var hostScreenMedia: (any CanvasMediaStreaming)?
    private var isHostScreenStreaming = false
    /// Set once, by this session's first capture, and read by every capture
    /// a display-mode change later rebuilds -- never reset in between, so
    /// `flow`'s shared `MediaFlowMonitor` (which tracks its own interval
    /// start against seconds measured from this) keeps reporting on the
    /// same clock a rebuilt capture restarts against seconds near zero
    /// would otherwise silence for a long time.
    private var hostScreenStreamStartedAt: Date?
    /// The base dimensions this session's host-screen encoder measures a
    /// stream scale against -- the target display's own logical size, which
    /// is what `VideoEncoderConfiguration.scaled(toStreamScale:)` multiplies.
    /// The session canvas's compiled-in size would name a picture a
    /// host-screen session is not encoding.
    private var hostScreenEncodeBase: (width: Int, height: Int)?
    /// `nil` until a caller wires host-screen mode in: no default that
    /// pretends the capability exists. Takes the already-sized configuration
    /// (`HostScreenEncoderSizing.resolve(for:)`, computed by this
    /// coordinator) rather than raw geometry, so this factory only ever
    /// has to construct a media object, never decide how big to make it.
    private let hostScreenMediaFactory: ((VideoEncoderConfiguration) -> any CanvasMediaStreaming)?
    /// Reads whether this machine's screen is locked, so the viewer is told whether
    /// to offer the unlock prompt and so an unlock is confirmed after it types.
    private let lockStateReader: any ScreenLockStateReading
    /// The lock state this session last told the viewer, from bring-up, an
    /// unlock attempt, or an earlier `tickHostScreenLockState()` -- what a new
    /// tick compares its own reading against so it reports only a real
    /// change, never a value the viewer has already been told. `nil` until
    /// bring-up seeds it, which never leaves a real reading unreported: the
    /// first tick after bring-up can only find no change against what
    /// bring-up itself just announced.
    private var lastAnnouncedHostScreenLockState: Bool?
    /// Set for the whole span of one `hostScreenUnlockRequest` -- from before
    /// its `await unlock(password:)` to after its own lock-state announcement
    /// -- so `tickHostScreenLockState()` never interleaves inside that await
    /// and races the attempt's own announcement onto the wire first. See the
    /// comment where this is set.
    private var isHostScreenUnlockAttemptInFlight = false
    /// Types the login password into the locked login window over loopback RFB.
    /// Neither the password nor that IO lives in the controller; both are here,
    /// where the `.goodbye` short-circuit already keeps IO out of the
    /// controller's dispatch.
    private let lockScreenUnlocker: any LockScreenUnlocking
    /// Decides, from every lock-state reading this session has fed it,
    /// whether the machine should be relocked when this session ends -- see
    /// the type's own doc comment.
    private var hostScreenRelockTracker = HostScreenRelockTracker()
    /// Posts the Lock Screen shortcut when `hostScreenRelockTracker` says to,
    /// once `tearDownSurfaces` has released this session's own hold on the
    /// displays.
    private let hostScreenRelockPoster: any HostScreenRelocking
    /// This machine's own local-input-idle signal, read to keep a relock
    /// from firing on a machine someone is actually using -- see
    /// `hardwareActivityNearby()`. Expected to already be a
    /// `SelfPostDiscountingLocalActivitySignal`, so a viewer's continuously
    /// forwarded input is never mistaken for a person at the machine.
    /// Deliberately its own instance, separate from this connection's
    /// `HostSessionController`'s presence-gate signal, which must stay raw
    /// -- see that property's own doc comment for why the two must differ.
    /// `nil` where a caller never wired one in, which reads as
    /// `.unavailable`, the same fail-safe reading `HostScreenPresenceRule`
    /// gives an absent sensor.
    private let hostScreenRelockActivitySignal: (any HostLocalActivitySignal)?
    /// Host-screen frames are tagged surface 0 inside the telemetry,
    /// admission-priority and send machinery shared with the canvas path.
    /// Safe because a connection is one shape for its whole life: a
    /// `hostScreenReady` is only produced where no canvas surface 0 can
    /// exist.
    private static let hostScreenTelemetrySurface = CanvasSurfaceID.allCases[0]
    /// How many capture-delivery reports in a row must find a stream
    /// delivering nothing at all before it is treated as dead. Two, not one:
    /// the first report of a session can land before the stream's own first
    /// delivery, and a rebuild costs the viewer its picture.
    private static let silentCaptureReportsBeforeRebuild = 2
    /// Whether this connection's own attempt actually created each surface's
    /// workspace. A rejected canvas request (`CanvasCreationGateError`) never
    /// sets this, so this connection's teardown never asks to stop a workspace
    /// another, still in-flight connection may own. A workspace this
    /// connection did start but a later one has since taken over is refused by
    /// `owner` instead.
    private var didStartWorkspace = CanvasSurfaceSlots { _ in false }
    /// Identifies this connection to the workspaces, which are shared across
    /// connections exactly as the display sessions are. The controller's own
    /// token, not a second one: a surface's canvas display and the workspace
    /// window standing on it are one ownership.
    private var owner: CanvasOwnerToken { controller.canvasOwner }
    /// One flow report for the whole connection, deliberately not per surface:
    /// it is a transport-level diagnostic, and `droppedVideoFrameCount` it
    /// prints alongside is the total across both surfaces' send queues.
    private let flow: FlowBox
    private var streamScale: CanvasSurfaceSlots<StreamScaleDebouncer>
    /// Whether `applyStreamScale` has ever actually run for this surface, so
    /// `streamScale[surface].appliedScale` is a real, deliberate answer
    /// rather than just whatever a fresh pipeline happened to start
    /// streaming at (`StreamScalePolicy.defaultScale`). The very first
    /// viewer-geometry report is exactly as legitimate a correction as any
    /// later one -- often a full step or more away from that arbitrary
    /// default -- so `requireMinimumDelta` in `requestStreamScale` only
    /// applies once there is a real value to measure a delta against.
    private var hasAppliedStreamScale = CanvasSurfaceSlots<Bool> { _ in false }
    /// Where each surface sits on the fidelity ladder, and everything that
    /// decides when it moves. One controller per surface: two canvases share
    /// a machine and a wire, but a resize, a still screen, and a viewer that
    /// cannot decode are all per surface, and a single shared position would
    /// charge one canvas for the other's content.
    ///
    /// The single owner of this surface's stream scale as well as its frame
    /// rate and encoder quality. A scale change reaches the encoder through
    /// `requestStreamScale`'s own ceiling, so there is one debounce, one
    /// reconfigure path, and no second mechanism that could ask for a
    /// different scale in the same breath.
    private var fidelity = CanvasSurfaceSlots<StreamFidelityController> { _ in StreamFidelityController() }
    /// The previous tick's counters, which is what makes a cumulative counter
    /// into the rate a decision can be made from. `nil` before this surface's
    /// first tick and again whenever it stops streaming: a delta taken across
    /// a stopped stream would report a whole idle gap as one bad second.
    private var previousFidelityReading = CanvasSurfaceSlots<FidelityReading?> { _ in nil }
    /// The counters behind the last capture-delivery line, so the next one
    /// reports an interval rather than a session total.
    private var previousCaptureDeliveryReading = CanvasSurfaceSlots<CaptureDeliveryReading?> { _ in nil }
    /// What this surface's counters read when its stream started, so a later
    /// tick can ask whether that stream has ever delivered anything at all.
    /// Read against a baseline rather than against zero: the counters may be
    /// a machine's whole run rather than this session's.
    private var captureDeliveryBaseline = CanvasSurfaceSlots<HostFrameCounts?> { _ in nil }
    /// How many capture-delivery reports in a row have found this surface's
    /// stream delivering nothing whatsoever.
    private var silentCaptureReports = CanvasSurfaceSlots { _ in 0 }
    /// Whether this surface's silent stream has already been rebuilt once.
    /// The second silence is not answered with a second rebuild: a pipeline
    /// that came up twice and delivered nothing twice is not a pipeline
    /// problem.
    private var didRebuildSilentCapture = CanvasSurfaceSlots { _ in false }
    /// Whether this surface's silent stream has already been answered once by
    /// waking this machine's displays. A second silence after that is not a
    /// sleeping display any more, whatever the display list says.
    private var didWakeSleepingDisplaysForSilentCapture = CanvasSurfaceSlots { _ in false }
    /// Which canvas capture a stopped-on-its-own signal belongs to, as
    /// `hostScreenCaptureGeneration` is for a host screen: bumped at every
    /// start and stop, so a signal from a capture already stopped is ignored.
    private var canvasCaptureGeneration = CanvasSurfaceSlots { _ in 0 }
    /// Whether this surface's canvas capture has already been rebuilt once
    /// after stopping on its own. A second stop ends the session.
    private var didRebuildStoppedCanvasCapture = CanvasSurfaceSlots { _ in false }
    /// Whether this session holds the machine's displays awake. Its own, not
    /// the process's: the hold is counted, and this is what makes this
    /// session's share of it exactly one.
    private var isHoldingDisplaysAwake = false
    /// How often each surface says what its capture stream delivered. The same
    /// interval the flow report uses, so the two lines read as one cadence.
    private let captureDeliveryReportSeconds: Double
    /// Encoded bytes per surface, counted where the packets are handed to the
    /// sink. What the viewer reports receiving is only meaningful against
    /// what this host actually produced.
    private let producedBytes = SurfaceByteCounter()
    /// This process's own record of whether it can still capture anything on
    /// this machine. Written here, and read by every canvas request that
    /// follows on any connection.
    private let captureAvailability: HostCaptureAvailability
    /// Where the encode and send percentiles a fidelity tick reads come from.
    /// `nil` in a session with no measurement behind it, which reports no
    /// latency evidence at all rather than a flattering zero.
    private let latencyRecorder: HostMediaLatencyRecorder?
    /// The last scale this surface's own viewer geometry (and user maximum)
    /// actually asked for, before any measured ceiling -- what a fidelity
    /// scale step re-requests, so the ladder always counts its steps down
    /// from what the viewer currently wants rather than from whatever the
    /// clamped scale happened to be.
    private var lastRequestedScale = CanvasSurfaceSlots<Double?> { _ in nil }
    /// This surface's viewer's own choice of stream scale -- `.automatic`
    /// until a `streamScalePreference` message says otherwise. Every scale
    /// decision resolves through `StreamScalePreference.resolve` against
    /// this, so a `.fixed` choice is honoured exactly and only a learned
    /// ceiling can still hold it back.
    private var streamScalePreference = CanvasSurfaceSlots<StreamScalePreference> { _ in .automatic }
    /// What `StreamScaleResolution.clampedFromUserChoice` last reported for
    /// this surface -- the scale a person explicitly asked for, when a
    /// measured fidelity ceiling held the applied scale below it. Read for the
    /// telemetry tick, the same way `scaleCeiling` is.
    private var clampedFromUserChoice = CanvasSurfaceSlots<Double?> { _ in nil }
    /// The last line this surface's scale hold was reported with, so the same
    /// hold is stated once and not on every re-request that runs into it.
    private var lastStreamScaleHold = CanvasSurfaceSlots<String?> { _ in nil }
    /// Restarted on every request, so only the last size of a window drag
    /// survives long enough to rebuild that surface's encoder. Resizing one
    /// viewer window must never rebuild the other surface's encoder.
    private var streamScaleSettleTask = CanvasSurfaceSlots<Task<Void, Never>?> { _ in nil }
    /// Guards the ordered teardown against running more than once:
    /// `HostNetworkSession.stop()`, its own `run()` loop's error-path
    /// teardown, and a viewer `.goodbye` can all reach it for the same
    /// session. Every path that ends a session sets it; readable so that
    /// obligation is verifiable rather than only visible in the effects a
    /// second teardown happens to be idempotent about.
    public private(set) var hasEnded = false
    private var hasSignalledSessionEnd = false
    /// Bumped every time host-screen capture is (re)built or deliberately
    /// stopped. Captured by value the moment a capture's stopped-on-its-own
    /// handler is wired, so a stop signal reaching this coordinator for a
    /// capture it has already moved on from -- one it deliberately stopped,
    /// or one an earlier recovery has already replaced -- is ignored rather
    /// than starting a second recovery for a capture nobody is streaming
    /// any more.
    private var hostScreenCaptureGeneration = 0
    /// The in-flight recovery for a host-screen capture that stopped on its
    /// own, or `nil` when none is running. At most one at a time: a second
    /// stop signal while one is already running names the same dead
    /// capture, not a second failure. Cancelled on teardown; otherwise
    /// cleared only once `isHostScreenCaptureRebuildInFlight` itself is,
    /// at the very end of the `Task` this starts.
    private var hostScreenRecoveryTask: Task<Void, Never>?
    /// True from the moment a host-screen capture recovery starts until
    /// every mode request it parked has been drained -- see
    /// `drainPendingHostScreenModeRequests`. A second `.hostScreenModeRequest`
    /// reaching `handle` anywhere in that window parks instead of racing
    /// whichever rebuild already owns the surface: recovery's own restart,
    /// or a parked request's own replay once recovery hands the surface
    /// back. Without this, `hostScreenRecoveryTask` alone is not enough --
    /// it goes `nil` the instant recovery's own restart finishes, before
    /// the drain that follows even begins, and a request arriving in that
    /// gap would reach `restartHostScreenStreaming` at the same moment the
    /// drain's own replay is still inside it.
    private var isHostScreenCaptureRebuildInFlight = false
    /// A `.hostScreenModeRequest` that arrived while a rebuild owned the
    /// host-screen surface, parked here instead of blocking `handle` on
    /// that rebuild's own outcome -- blocking there would starve this
    /// connection's whole read loop (`HostNetworkSession.run()` awaits
    /// `handle` serially) of goodbye, input, clipboard and keepalive
    /// frames for up to the recovery bound. Drained through
    /// `processMessage`, with the exact `writeResponse` a live request
    /// would have used, once the rebuild in front of it finishes. Latest
    /// wins: a later park overwrites an earlier one outright, since a mode
    /// request the viewer sent again supersedes whichever came before it.
    private var pendingHostScreenModeRequest: (
        message: SensoriumMessage,
        writeResponse: @MainActor @Sendable (SensoriumMessage) async throws -> Void
    )?
    /// How long a host-screen capture that stopped on its own is retried
    /// before this session gives up on its own target display.
    private let hostScreenCaptureRecoveryBoundSeconds: Double
    /// The pace of one retry attempt within that bound.
    private let hostScreenCaptureRecoveryPollSeconds: Double
    /// How one retry's own pause is waited out, injected so a test proves
    /// the bound without spending it.
    private let hostScreenCaptureRecoveryWait: (Double) async -> Void
    /// How often a live host-screen session re-declares user activity, so
    /// the monitor it streams does not idle to sleep out from under the
    /// prevent-sleep hold this session already took -- see
    /// `DisplayWakeController.redeclareUserActivityForLiveSession`.
    private let hostScreenKeepAwakeRedeclareIntervalSeconds: Double
    /// The tick clock reading a live host-screen session last re-declared
    /// activity at. `nil` before the first tick of a live host-screen
    /// session.
    private var hostScreenLastKeepAwakeRedeclareAtSeconds: Double?
    /// Reads elapsed wall-clock time for `hostScreenCaptureRecoveryBoundSeconds`,
    /// injected so a test can prove the bound without spending it. Production
    /// reads the real clock; `wakeAndSettleDisplays` and
    /// `waitForDisplaysToWake` can each spend several real seconds inside one
    /// retry, and the bound must count that time rather than treat every
    /// retry as instant.
    private let hostScreenNowSecondsProvider: () -> Double

    public init(
        controller: HostSessionController,
        media: CanvasSurfaceSlots<any CanvasMediaStreaming>,
        videoSink: any CanvasVideoSending,
        workspaces: CanvasSurfaceSlots<any CanvasWorkspacePresenting> = CanvasSurfaceSlots { _ in NoCanvasWorkspace() },
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        streamScaleSettleSeconds: Double = StreamScaleDebouncer.defaultSettleSeconds,
        flowReportSeconds: Double = MediaFlowMonitor.defaultReportInterval,
        onEvent: (@Sendable (String) -> Void)? = nil,
        onSessionEnded: (@Sendable () -> Void)? = nil,
        onStreamUnrecoverable: (@Sendable (String) -> Void)? = nil,
        hostScreenMediaFactory: ((VideoEncoderConfiguration) -> any CanvasMediaStreaming)? = nil,
        captureAvailability: HostCaptureAvailability = .shared,
        lockStateReader: any ScreenLockStateReading = CGSessionScreenLockState(),
        lockScreenUnlocker: any LockScreenUnlocking = RFBLockScreenUnlocker(),
        hostScreenRelockPoster: any HostScreenRelocking = CoreGraphicsHostScreenRelockPoster(),
        hostScreenRelockActivitySignal: (any HostLocalActivitySignal)? = nil,
        hostScreenCaptureRecoveryBoundSeconds: Double = 30,
        hostScreenCaptureRecoveryPollSeconds: Double = 1,
        hostScreenCaptureRecoveryWait: @escaping (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        hostScreenKeepAwakeRedeclareIntervalSeconds: Double = 5,
        hostScreenNowSecondsProvider: @escaping () -> Double = {
            Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
        }
    ) {
        self.hostScreenCaptureRecoveryBoundSeconds = hostScreenCaptureRecoveryBoundSeconds
        self.hostScreenCaptureRecoveryPollSeconds = hostScreenCaptureRecoveryPollSeconds
        self.hostScreenCaptureRecoveryWait = hostScreenCaptureRecoveryWait
        self.hostScreenKeepAwakeRedeclareIntervalSeconds = hostScreenKeepAwakeRedeclareIntervalSeconds
        self.hostScreenNowSecondsProvider = hostScreenNowSecondsProvider
        self.lockStateReader = lockStateReader
        self.lockScreenUnlocker = lockScreenUnlocker
        self.hostScreenRelockPoster = hostScreenRelockPoster
        self.hostScreenRelockActivitySignal = hostScreenRelockActivitySignal
        self.captureAvailability = captureAvailability
        self.controller = controller
        self.media = media
        self.latencyRecorder = latencyRecorder
        self.videoSink = videoSink
        self.workspaces = workspaces
        self.focus = focus
        self.onEvent = onEvent
        self.onSessionEnded = onSessionEnded
        self.onStreamUnrecoverable = onStreamUnrecoverable
        self.hostScreenMediaFactory = hostScreenMediaFactory
        flow = FlowBox(reportSeconds: flowReportSeconds)
        captureDeliveryReportSeconds = flowReportSeconds
        streamScale = CanvasSurfaceSlots { surface in
            StreamScaleDebouncer(
                appliedScale: media[surface].currentStreamScale,
                settleSeconds: streamScaleSettleSeconds
            )
        }
    }

    /// `writeResponse` writes a `canvasReady` before that surface's capture
    /// starts, so the viewer is told the surface exists before its first
    /// frame arrives; a reply written this way comes back `nil` so no
    /// caller writes it twice. The ordering is the `await` sequencing, not
    /// the isolation.
    public func handle(
        _ message: SensoriumMessage,
        writeResponse: @escaping @MainActor @Sendable (SensoriumMessage) async throws -> Void
    ) async throws -> SensoriumMessage? {
        if case .goodbye = message {
            hasEnded = true
            await tearDownSurfaces()
            defer { focus.setFocusedSurface(controller.focusedSurface) }
            return try controller.handle(message)
        }
        if case let .hostScreenUnlockRequest(password) = message {
            // Short-circuited before the controller dispatch below, the same
            // way `.goodbye` is: the password and the loopback IO stay out of
            // the controller entirely. The reply is written, not returned, so
            // no caller writes it twice. The password is passed straight to the
            // unlocker, which zeroes the credential buffer it builds; it is
            // never logged or written to disk. It still lives for this message's
            // lifetime, which copy-on-write `Data` does not let this code cut
            // short.
            // The lock state is itself a disclosure: an unauthenticated or
            // non-host-screen peer must not learn whether this machine is locked by
            // sending a bogus request. Decided before the attempt so a refused
            // request writes only its `.notAuthorized` result and no lock
            // state, while the attempt itself still flows through `unlock` --
            // the one place every outcome, refused ones included, reaches the
            // operator log line.
            let mayObserveLockState = controller.canObserveHostScreenLockState()
            // Set before the `await` below and cleared only once this
            // attempt's own lock-state announcement (if any) has been
            // written: the change watcher's tick runs on this same actor and
            // can otherwise interleave inside that `await`, read the screen
            // already unlocked, and send its own `hostScreenLockState`
            // ahead of `hostScreenUnlockResult` -- which the viewer would
            // read as the answer to an unlock it never got a result for.
            // `defer` clears it on every exit from here, a throw included.
            isHostScreenUnlockAttemptInFlight = true
            defer { isHostScreenUnlockAttemptInFlight = false }
            let outcome = await unlock(password: password)
            try await writeResponse(.hostScreenUnlockResult(outcome))
            if mayObserveLockState {
                let isLocked = lockStateReader.isScreenLocked()
                hostScreenRelockTracker.observe(isLocked: isLocked, hardwareActivityNearby: hardwareActivityNearby())
                // Recorded so the change watcher's next tick compares against
                // what was just announced here, rather than an older reading,
                // and so does not repeat this same value as a spurious change.
                lastAnnouncedHostScreenLockState = isLocked
                try await writeResponse(.hostScreenLockState(locked: isLocked))
            }
            return nil
        }
        if case .hostScreenModeRequest = message, isHostScreenCaptureRebuildInFlight {
            // A mode change reaching this connection while a rebuild
            // already owns capture on this same display would otherwise
            // race it: the controller would apply the new mode against a
            // display the rebuild in front of it has not yet confirmed is
            // even back, and that rebuild -- unaware anything else touched
            // the capture -- would either collide with it or redo it a
            // moment later. There is no wire reason for "try again once
            // this settles", so the request itself is parked, rather than
            // answered here: blocking this call on that outcome would
            // block this connection's whole read loop behind it
            // (`HostNetworkSession.run()` awaits `handle` serially), so
            // every other frame on the wire -- goodbye, input, clipboard,
            // keepalive -- would go unread for up to the recovery bound.
            // Parked instead, it is handled exactly as it would have been
            // had it arrived a moment later, once nothing is racing --
            // see `drainPendingHostScreenModeRequests`.
            pendingHostScreenModeRequest = (message, writeResponse)
            return nil
        }
        return try await processMessage(message, writeResponse: writeResponse)
    }

    /// `handle`'s own body once nothing is rebuilding the host-screen
    /// capture: dispatches to the controller and, for a mode change,
    /// rebuilds the capture at the new geometry before replying. Also
    /// `drainPendingHostScreenModeRequests`'s own path for a parked
    /// request, once the rebuild in front of it is done -- called
    /// directly, never back through `handle`, whose own park check would
    /// otherwise park it a second time.
    private func processMessage(
        _ message: SensoriumMessage,
        writeResponse: @escaping @MainActor @Sendable (SensoriumMessage) async throws -> Void
    ) async throws -> SensoriumMessage? {
        // Opened before this request wakes anything, and not closed until
        // this whole request's outcome is known -- a session that goes on
        // to hold the displays, or none -- so the gap between the wake
        // below finishing and a hold this same call takes further down
        // never lets the declaration lapse in between. `defer` closes it on
        // every exit from here, a throw included, which is what a capture
        // failure inside the `.canvasReady` or `.hostScreenReady` bring-up
        // further down takes.
        displayWake?.beginRequestScope()
        defer { displayWake?.endRequestScope() }
        await wakeDisplaysForSessionStart(message)
        let response: SensoriumMessage?
        do {
            response = try controller.handle(message)
        } catch let gateError as CanvasCreationGateError {
            // The display session and the workspace share one
            // `CanvasCreationGate`, so `VirtualDisplaySession.start` inside
            // the controller is what refuses a canvas request arriving while
            // another connection's creation is still in flight — this
            // connection never reaches its own workspace. Nothing of its own
            // was touched, so there is nothing to unwind; without this the
            // refusal would reach the viewer with no host-side reason at all.
            onEvent?(Self.canvasCreationRejectedEvent)
            throw gateError
        } catch {
            // Everything else the controller can refuse, including the one
            // that leaves a connection with nothing to show for itself: a
            // canvas macOS would not create under any identity. The caller
            // closes the connection on this, and until it is said here the
            // whole episode reaches the host log as an arrival followed by a
            // departure.
            onEvent?("\(Self.requestDescription(of: message)) failed: \(error)")
            throw error
        }

        if case .hostScreenReady = response {
            // The cap on `wakeDisplaysForSessionStart` covers one request
            // cycle, not this connection's whole life: a session that
            // actually started is the one thing the spec names as ending
            // it, and `goodbye` clears `hostScreenSurface` and
            // `connectionShape` on the controller, so a later request on
            // this same connection can be a genuinely new session -- one
            // this machine's displays are worth waking for again.
            hasWokenForHostScreenSessionStart = false
        }

        if case .hostScreenRequest = message, let content = controller.hostScreenLastPresencePromptContent {
            onEvent?(
                "asking the person at this machine whether \(content.deviceName) may see \(content.displayLabel)"
            )
        }

        if case let .hostScreenRefused(reason) = response {
            onEvent?("host screen refused for \(hostScreenLogName()): \(reason)")
        }

        if case .viewerFocus = message {
            // Read back from the controller rather than from the message: the
            // controller is what validated the surface against the two-canvas
            // cap and what turns "no viewer focus" into no preference.
            focus.setFocusedSurface(controller.focusedSurface)
        }

        if case let .viewerDrawableSize(pixelWidth, pixelHeight, surfaceID, _) = message,
           let surface = CanvasSurfaceID(wireValue: surfaceID),
           let requested = controller.requestedStreamScale(for: surface) {
            // Both read back from the controller rather than off the message:
            // the controller is what validated them against the canvas and
            // the two-surface cap. Recorded here, not inside
            // `requestStreamScale` itself: that function is also called
            // internally with an already-clamped scale, and a later
            // preference change needs the viewer's own last real ask, not
            // whatever the most recent internal call happened to request.
            let previouslyRequested = lastRequestedScale[surface]
            lastRequestedScale[surface] = requested
            if let displayID = controller.hostScreenDisplayID, requested != previouslyRequested {
                onEvent?(
                    "viewer drawable \(Int(pixelWidth))x\(Int(pixelHeight)) px on host-screen display "
                        + "\(displayID): " + String(format: "scale %.2fx", requested)
                )
            }
            requestStreamScale(requested, on: surface, requireMinimumDelta: true)
        }

        if case let .streamScalePreference(_, surfaceID) = message,
           let surface = CanvasSurfaceID(wireValue: surfaceID) {
            // Read back from the controller rather than from the message,
            // the same reasoning as the viewerDrawableSize block above.
            streamScalePreference[surface] = controller.streamScalePreference(for: surface)
            // Applied immediately, not left for the next resize: a person
            // choosing a scale expects it to take effect now, and
            // `requireMinimumDelta`'s default of `false` is exactly the "a
            // deliberate choice is never idle churn" rule `isWorthReconfiguring`
            // exists to distinguish. Harmless before this surface has ever
            // streamed -- `applyStreamScale` no-ops until `isStreaming` is
            // true, and the next real bring-up resolves through the
            // preference already stored above.
            requestStreamScale(lastRequestedScale[surface] ?? streamScale[surface].appliedScale, on: surface)
        }

        // Taking the second display down live has no other message to hang
        // off: `goodbye` always ends the whole connection. The count is
        // read from the message; `isStreaming` is this coordinator's own
        // record of what there is to tear down.
        if case let .displayCount(count) = message, count < 2 {
            let secondSurface = CanvasSurfaceID.allCases[1]
            if isStreaming[secondSurface] {
                await tearDownSurfaceLive(secondSurface)
            }
            // The controller clears its own focus record when the surface
            // it named stops existing; read that back the same way the
            // explicit `viewerFocus` case already does, so a focus report
            // naming a display that is now gone does not keep steering the
            // shared encoder's fair-share priority toward it.
            focus.setFocusedSurface(controller.focusedSurface)
        }

        var didWriteResponse = false
        if let response, case let .canvasReady(displayID, _, _, _, surfaceID, _) = response {
            // The controller has already refused every surfaceID outside the
            // cap, so this cannot fail; treating it as a canvas request
            // failure rather than force-unwrapping keeps that a refusal
            // instead of a crash if the two ever disagree.
            guard let surface = CanvasSurfaceID(wireValue: surfaceID) else {
                throw HostSessionControllerError.invalidCanvasRequest
            }
            // Advanced as each step is entered, so the one catch below names
            // the step that actually failed. All three throw into it, and
            // reporting a workspace that would not place — or a socket that
            // died mid-reply — as a capture failure points whoever reads the
            // log at the wrong subsystem.
            var stage = CanvasBringUpStage.workspacePlacement
            do {
                // Here rather than before the request was judged: a canvas
                // wake names no display and so reaches every one of this
                // machine's, which nothing unauthenticated may do. By this
                // point the request has been authenticated and admitted.
                await displayWake?.wakeDisplays()
                holdDisplaysAwakeForSession()
                try workspaces[surface].start(canvasDisplayID: displayID, owner: owner)
                didStartWorkspace[surface] = true
                onEvent?("workspace started on session canvas \(displayID)")
                // Before capture, not after: video for a surface the viewer
                // has not been told about is a packet it can only hold or
                // drop. The workspace still goes up first — a refused
                // placement must be answered as a failed canvas request, not
                // as a canvas the viewer has already been promised.
                stage = .canvasReadyWrite
                try await writeResponse(response)
                didWriteResponse = true
                stage = .captureStart
                try await startStreaming(on: surface, canvasDisplayID: displayID)
                onEvent?("capture started on session canvas \(displayID)")
            } catch let gateError as CanvasCreationGateError {
                // Production shares one gate, so the refusal above fires
                // first. Kept because the unwind rule is the same: this
                // attempt placed no workspace.
                onEvent?(Self.canvasCreationRejectedEvent)
                throw gateError
            } catch {
                // Never leave a canvas the session cannot actually stream.
                // One canvas that cannot stream ends the whole session: the
                // viewer is told, redials, and gets a working set of canvases
                // back, rather than being left with one black window it has
                // no way to distinguish from a stalled one.
                onEvent?(stage.failureEvent(displayID: displayID, error: error))
                hasEnded = true
                await tearDownSurfaces()
                _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
                throw error
            }
        }

        if let response, case let .hostScreenReady(geometry, _) = response {
            // No workspace step at all -- the only two steps are telling
            // the viewer and starting capture, in that order for the same
            // reason canvas bring-up orders its own two: a viewer told
            // "ready" before capture exists is a black window it cannot
            // tell from a stalled one, but capture started before the
            // viewer has been told would-be video with nowhere admitted
            // to receive it.
            var stage = HostScreenBringUpStage.readyWrite
            do {
                holdDisplaysAwakeForSession()
                try await writeResponse(response)
                didWriteResponse = true
                stage = .captureStart
                try await startHostScreenStreaming(geometry: geometry)
                // Only now has capture actually come up -- admission and the
                // reply above both happen first and can each still be
                // followed by a throw into the catch below, which must be
                // the last word on this request if either one lands.
                onEvent?("host screen started for \(hostScreenLogName())")
                stage = .modeListWrite
                // Unprompted, and last: the viewer needs no round trip to
                // learn what this screen can be set to, and a list written
                // before capture exists would describe a session that may
                // still fail to start.
                if let modeList = controller.hostScreenModeListMessage() {
                    try await writeResponse(modeList)
                }
                // Whether this machine is locked, so the viewer knows to offer the
                // unlock prompt. Last, like the mode list: it describes a
                // session that has now actually started streaming.
                let isLocked = lockStateReader.isScreenLocked()
                hostScreenRelockTracker.observe(isLocked: isLocked, hardwareActivityNearby: hardwareActivityNearby())
                // Seeds the change watcher's baseline, so a first tick against
                // an unchanged lock state reports nothing.
                lastAnnouncedHostScreenLockState = isLocked
                try await writeResponse(.hostScreenLockState(locked: isLocked))
            } catch {
                // Never leave a session the viewer believes is receiving
                // video that never actually starts -- the same "one broken
                // surface ends the whole session" rule canvas bring-up
                // follows. One capture that cannot start ends the session
                // rather than leaving a viewer a ready session with no
                // video.
                onEvent?(stage.failureEvent(error: error))
                hasEnded = true
                await tearDownSurfaces()
                _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
                throw error
            }
        }
        if let response, case let .hostScreenModeApplied(geometry, _) = response {
            // The controller has already set the display to the new mode, so
            // the capture sized for the old one is now streaming a screen
            // that no longer exists at that size. Restarting it is what makes
            // the change real, and it happens before the viewer is told
            // anything -- the same ordering bring-up follows, for the same
            // reason.
            do {
                try await restartHostScreenStreaming(
                    geometry: geometry,
                    note: "mode changed to \(geometry.logicalWidth)x\(geometry.logicalHeight)"
                )
            } catch {
                if hasEnded {
                    // The session ended while the rebuild was in flight. Its
                    // own teardown has already stopped every stream and put
                    // the display back; there is nobody left to tell, and a
                    // recovery started now would build capture for a session
                    // that no longer exists.
                    return nil
                }
                onEvent?("host-screen capture could not restart at the new display mode. \(HostOperatorLog.describe(error))")
                // A mode this host cannot actually stream is not a mode the
                // display is left on. Putting it back is also what gets the
                // session its picture back: capture restarts at the geometry
                // the display is back at, and only a failure to do even that
                // ends the session, since a live session with no video is
                // exactly what the viewer cannot tell from a frozen one.
                if let restoredGeometry = controller.restoreHostScreenMode() {
                    do {
                        try await restartHostScreenStreaming(
                            geometry: restoredGeometry,
                            note: "mode changed to \(restoredGeometry.logicalWidth)x\(restoredGeometry.logicalHeight)"
                        )
                    } catch {
                        onEvent?(HostScreenBringUpStage.captureStart.failureEvent(error: error))
                        hasEnded = true
                        await tearDownSurfaces()
                        _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
                        throw error
                    }
                }
                if hasEnded {
                    return nil
                }
                try await writeResponse(.hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed))
                return nil
            }
            // Checked after every suspension in this branch, not only once:
            // the transport can die inside any of them, and everything below
            // is either a write to a viewer that is gone or -- worse -- a
            // capture built for a session that has already ended.
            if hasEnded {
                return nil
            }
            try await writeResponse(response)
            if hasEnded {
                return nil
            }
            // The list again, so the viewer's own checkmark moves to the
            // mode that is now current without it having to infer one.
            if let modeList = controller.hostScreenModeListMessage() {
                try await writeResponse(modeList)
            }
            didWriteResponse = true
        }
        return didWriteResponse ? nil : response
    }

    /// Rereads this machine's lock state and reports it only if it has moved
    /// since it was last announced to this viewer -- from bring-up, from an
    /// unlock attempt, or from an earlier call here. `nil` when nothing
    /// changed, which is what lets a caller poll this on a timer and write
    /// only what it gets back.
    ///
    /// Re-checks `canObserveHostScreenLockState()` on every call rather than
    /// once when polling starts: the lock state is itself a disclosure (see
    /// `resolveUnlock`), so a tick racing this session's own teardown must
    /// answer `nil`, the same way an unlock request from an unearned
    /// connection learns nothing.
    public func tickHostScreenLockState() -> SensoriumMessage? {
        // An in-flight unlock attempt owns its own announcement; a tick
        // racing it must never write its own first, ahead of the attempt's
        // result.
        guard !isHostScreenUnlockAttemptInFlight else {
            return nil
        }
        guard controller.canObserveHostScreenLockState() else {
            return nil
        }
        let isLocked = lockStateReader.isScreenLocked()
        hostScreenRelockTracker.observe(isLocked: isLocked, hardwareActivityNearby: hardwareActivityNearby())
        guard isLocked != lastAnnouncedHostScreenLockState else {
            return nil
        }
        lastAnnouncedHostScreenLockState = isLocked
        return .hostScreenLockState(locked: isLocked)
    }

    /// Runs one unlock request and leaves the operator one line naming its
    /// outcome. The password never touches the controller and is never logged:
    /// the record carries the outcome token alone, not the password or its
    /// length.
    private func unlock(password: Data) async -> HostScreenUnlockOutcome {
        let outcome = await resolveUnlock(password: password)
        onEvent?("host-screen unlock attempt: \(outcome.wireToken)")
        return outcome
    }

    /// Gates the request, decides whether there is anything to unlock, then
    /// hands the password to the loopback typer. Split from `unlock` so every
    /// outcome, the gated ones included, flows through the one log line there.
    private func resolveUnlock(password: Data) async -> HostScreenUnlockOutcome {
        // A valid, authenticated host-screen session first: everything below,
        // the lock state included, is a disclosure this connection has not
        // earned otherwise.
        guard controller.canObserveHostScreenLockState() else {
            return .notAuthorized
        }
        // An empty submit is not a guess: it never reaches the login window and
        // leaks nothing, so it is refused here without reserving a slot, before
        // the loopback channel is ever opened.
        guard !password.isEmpty else {
            return .wrongPassword
        }
        // Reserve a guess slot atomically before any lock-state probe or
        // attempt. The reservation IS the charge, and it happens on this side
        // of the multi-second `await` below so concurrent connections cannot
        // all pass a stale check and attempt in parallel. Reserving before the
        // lock-state probe also keeps that probe budgeted -- otherwise it would
        // be an unbounded lock-state oracle. `false` means the device is at the
        // cap (or has no budget configured); retrying cannot help, which is
        // told apart from an invalid session so the viewer does not read it as
        // something a reconnect could fix.
        guard let reservation = controller.tryReserveUnlockAttempt() else {
            return .tooManyAttempts
        }
        // Release the slot on any exit that did not consume a real guess,
        // including a throw or cancellation mid-attempt: a connection that dies
        // while the login window is being typed into must not permanently burn
        // a slot. The refund names the key captured at reserve time, so a
        // surface torn down or re-armed during the attempt still releases the
        // right slot. `settled` is set true only for the outcomes that keep the
        // charge.
        var settled = false
        defer {
            if !settled {
                controller.refund(reservation)
            }
        }
        guard lockStateReader.isScreenLocked() else {
            return .notLocked
        }
        let outcome = await lockScreenUnlocker.unlock(password: password)
        switch outcome {
        case .unlocked:
            // The correct password: clear the whole budget, not merely refund
            // this one slot.
            controller.recordUnlockSuccess(reservation)
            settled = true
        case .wrongPassword:
            // The only outcome that keeps its reserved charge: the login window
            // rejected the password before any unlock, which is the one thing
            // that proves a wrong guess reached it. The budget therefore counts
            // exactly confirmed wrong guesses.
            settled = true
        case .failed, .notLocked, .screenSharingUnavailable, .passwordTooLong, .notAuthorized,
             .tooManyAttempts:
            // None of these carries wrong-guess information, so none consumes a
            // guess: the `defer` refunds the reserved slot. `.failed` is
            // reachable only after authenticate already accepted the real
            // password, so it never reflects a wrong guess; a legitimate user
            // who reaches it retries into `.unlocked`, which resets the budget.
            // Listed explicitly, with no `default`, so a new
            // `HostScreenUnlockOutcome` case is a compile error here rather than
            // a silent refund.
            break
        }
        return outcome
    }

    /// Brings host-screen capture back up at a new size: the display's mode
    /// changed underneath it, and a capture stream is sized once, when it
    /// starts. Everything about how one starts stays in
    /// `startHostScreenStreaming`, which this only sequences a stop in front
    /// of.
    private func restartHostScreenStreaming(geometry: SessionSurfaceGeometry, note: String) async throws {
        // Never for a session that has ended. A capture built here after the
        // transport died has no viewer to send to, no badge naming the
        // connected machine, and no open session record -- exactly the
        // unaccountable stream every other path in this type refuses to
        // leave behind.
        guard !hasEnded else {
            return
        }
        // The session did not end and must not look as though it did: the
        // badge naming the connected machine stays up and the session record
        // stays open, because the person at this machine is in exactly the
        // session they were in a moment ago. Only the capture is rebuilt.
        guard isHostScreenStreaming,
              let replaceable = hostScreenMedia as? any HostScreenCaptureReplacing,
              let displayID = controller.hostScreenDisplayID else {
            await stopHostScreenStreaming()
            guard !hasEnded else {
                return
            }
            try await startHostScreenStreaming(geometry: geometry)
            return
        }
        let sizing = hostScreenEncoderSizing(for: geometry)
        // Bumped before the capture being replaced is even asked to stop,
        // the same ordering `stopHostScreenStreaming` already follows for
        // its own path (generation bumped, then `hostScreenMedia?.stop()`
        // awaited): a stop signal that capture reports from here on --
        // whether the deliberate stop below causes it or a genuinely
        // independent one lands at the same moment -- names a capture this
        // coordinator has already moved on from, not the one about to
        // replace it. `beginHostScreenCapture` bumps again once the new
        // capture is actually wired; two bumps in one rebuild cost nothing,
        // since every reader only ever compares this counter for equality.
        hostScreenCaptureGeneration += 1
        await replaceable.replaceCapture(with: sizing.configuration, note: note)
        guard !hasEnded else {
            // The session ended inside the rebuild above, which leaves a
            // capture built and not started. Stopping it is what releases
            // it: the teardown that ran while this was suspended stopped the
            // capture that existed then, not this one.
            await replaceable.stop()
            return
        }
        try await beginHostScreenCapture(media: replaceable, sizing: sizing, displayID: displayID)
    }

    /// How this session wakes this machine's displays and keeps them awake.
    /// The controller's own, not a second one: one session has one hold.
    private var displayWake: DisplayWakeController? {
        controller.displayWake
    }

    /// Set the first time `wakeDisplaysForSessionStart` actually wakes this
    /// machine's displays for a `.hostScreenRequest` on this connection, and
    /// cleared again once a session actually starts -- `handle` resets it
    /// the moment `response` is `.hostScreenReady`, below. A person's own
    /// refusal never needs the same reset: `resolveHostScreenPreAdmission`'s
    /// own sticky state already refuses every later request on this
    /// connection, so no later request would reach the wake gate to ask
    /// this flag anything. A session that ends with `goodbye` and starts
    /// again on the same connection is what this flag exists to let past:
    /// `goodbye` clears the controller's `hostScreenSurface` and
    /// `connectionShape`, so that later request is a genuinely new session.
    private var hasWokenForHostScreenSessionStart = false

    /// Wakes this machine's displays before a request that starts a session
    /// is judged, because macOS draws nothing at all to a sleeping display
    /// and a session canvas is no exception.
    ///
    /// A host-screen request wakes this machine's displays whatever they
    /// report, since display sleep can take a monitor offline without any
    /// display reading asleep, and then waits for the one display its token
    /// names. The display itself is never checked here -- only
    /// `controller.hostScreenRequestPassesPreAdmission`, which stops short
    /// of resolving one -- so a display that went offline since the offer
    /// is still woken rather than mistaken for a reason not to.
    ///
    /// Gated on `hostScreenRequestPassesPreAdmission`, the same method
    /// `handle` itself decides the request with, so a resend the controller
    /// will refuse outright -- an unarmed or disarmed device, a stale or
    /// unminted token, an invalid resume ticket, a sticky refusal, or a
    /// session already live on this connection -- never wakes this
    /// machine's displays either.
    ///
    /// Still capped at one wake per connection until a session actually
    /// starts: `handle` resets it the moment `response` is
    /// `.hostScreenReady`, and never otherwise. A person's own decline or
    /// an unanswered prompt sets a sticky refusal on the controller
    /// instead, which keeps every later request on this connection from
    /// reaching pre-admission at all, so this flag needs no reset for
    /// either. What the cap actually guards against is a request the
    /// presence gate itself refuses without asking anyone -- for want of a
    /// gate, or one already showing for another connection -- which passes
    /// pre-admission on every resend; without this cap an armed device
    /// could keep resetting this machine's idle timer by resending into
    /// that gate, with no badge shown and no session recorded for it.
    private func wakeDisplaysForSessionStart(_ message: SensoriumMessage) async {
        guard let displayWake, case let .hostScreenRequest(token, resumeTicket) = message,
              !hasWokenForHostScreenSessionStart,
              controller.hostScreenRequestPassesPreAdmission(token: token, resumeTicket: resumeTicket) else {
            return
        }
        hasWokenForHostScreenSessionStart = true
        await displayWake.wakeAndSettleDisplays()
        guard let target = controller.hostScreenTargetDisplayID(for: token) else {
            return
        }
        await displayWake.waitForDisplaysToWake(targets: [target])
    }

    /// Takes this session's own hold on the machine's displays, once, however
    /// many surfaces the session goes on to open. Balanced by exactly one
    /// release in `tearDownSurfaces`, so a session ending never drops a hold
    /// another connection's live session is standing on.
    private func holdDisplaysAwakeForSession() {
        guard let displayWake, !isHoldingDisplaysAwake else {
            return
        }
        isHoldingDisplaysAwake = true
        displayWake.holdDisplaysAwake()
    }

    private func releaseDisplaysAwakeForSession() {
        guard let displayWake, isHoldingDisplaysAwake else {
            return
        }
        isHoldingDisplaysAwake = false
        displayWake.releaseDisplaysAwake()
    }

    /// Called when the transport dies without a goodbye.
    ///
    /// Idempotent: `hasEnded` is set synchronously, before the first `await`
    /// below, so a second caller reentering while this one is suspended
    /// inside the teardown sees it already set and returns immediately
    /// rather than running a second, overlapping teardown.
    public func sessionDidEnd(reason: String) async {
        guard !hasEnded else {
            return
        }
        hasEnded = true
        await tearDownSurfaces()
        _ = try? controller.handle(.goodbye(reason: reason))
    }

    /// One fresh reading for `hostScreenRelockTracker`, using the same
    /// `HostScreenPresenceRule.assess` window a session's own admission
    /// check uses. `hostScreenRelockActivitySignal` is expected to already
    /// discount this session's own forwarded input -- see
    /// `SelfPostDiscountingLocalActivitySignal`. Read fresh at every call
    /// rather than cached: it is asked for at each lock-state observation
    /// and once more at the relock decision itself, and each of those
    /// moments needs its own answer.
    private func hardwareActivityNearby() -> Bool {
        HostScreenPresenceRule.assess(
            reading: hostScreenRelockActivitySignal?.currentReading() ?? .unavailable,
            presenceThreshold: HostScreenPresenceRule.recommendedPresenceThreshold
        ) == .mustAsk
    }

    /// Stops every surface's stream, then every surface's workspace window.
    ///
    /// The workspace windows must all be gone before any canvas display is
    /// released, or AppKit may move a surviving window onto a physical
    /// monitor. Display release happens only after this returns, in the
    /// caller's `controller.handle(.goodbye)`.
    private func tearDownSurfaces() async {
        for surface in CanvasSurfaceID.allCases {
            streamScaleSettleTask[surface]?.cancel()
            streamScaleSettleTask[surface] = nil
        }
        hostScreenRecoveryTask?.cancel()
        hostScreenRecoveryTask = nil
        pendingHostScreenModeRequest = nil
        isHostScreenCaptureRebuildInFlight = false
        let stoppedCanvas = await stopStreaming()
        // No display to release here, unlike a canvas -- host screen never
        // owns the display it captures, so there is nothing beyond the
        // media stream itself to tear down. No workspace either,
        // so this has no equivalent of the loop just below.
        let stoppedHostScreen = await stopHostScreenStreaming()
        for surface in CanvasSurfaceID.allCases where didStartWorkspace[surface] {
            // By owner, never unconditionally: a connection whose socket died
            // unnoticed can reach here long after a reconnect took the surface
            // over, and closing that live window would leave the reconnected
            // viewer streaming a bare canvas.
            workspaces[surface].stop(owner: owner)
            didStartWorkspace[surface] = false
        }
        // Every path that ends a session reaches here, the ones that end it
        // on an error and the one that ends it because the host is quitting
        // included, so this machine is never left holding its displays awake
        // for a session that is over.
        releaseDisplaysAwakeForSession()
        // Only a host-screen session ever locks or unlocks a real machine;
        // a session canvas's input is dropped while the machine is locked
        // (see `InputSessionKind`), and it feeds the tracker nothing. Checked after releasing the display hold above, so the
        // relock keystroke is never raced by this session's own display
        // wake assertion.
        if stoppedHostScreen {
            // A last, fresh reading, not only whatever the two-second poll
            // or an unlock attempt last fed the tracker: either could be up
            // to two seconds stale, and a person who unlocked or relocked
            // the machine themselves in that window must still be caught
            // before the decision below is made. One hardware-activity
            // reading, not two: `observe` and `consumeShouldRelock` below
            // must agree on the same moment.
            let activityNearby = hardwareActivityNearby()
            hostScreenRelockTracker.observe(isLocked: lockStateReader.isScreenLocked(), hardwareActivityNearby: activityNearby)
            if hostScreenRelockTracker.consumeShouldRelock(hardwareActivityNearby: activityNearby) {
                hostScreenRelockPoster.relock()
            }
        }
        guard stoppedCanvas || stoppedHostScreen, !hasSignalledSessionEnd else {
            return
        }
        hasSignalledSessionEnd = true
        onSessionEnded?()
    }

    /// What this surface is actually being encoded at right now, and the
    /// highest scale it has been measured to sustain (`nil` until something
    /// has been measured unsustainable). Read for the telemetry tick: the
    /// viewer asks for a scale one way down `viewerDrawableSize` and has no
    /// other way to learn that a backoff moved it.
    public func appliedStreamScale(for surface: CanvasSurfaceID) -> Double {
        streamScale[surface].appliedScale
    }

    /// The highest scale this surface's measured fidelity allows right now,
    /// or `nil` while no resolution has been spent at all -- never a
    /// fabricated limit, and never the viewer's own maximum, which is a
    /// choice rather than a measurement.
    public func sustainableScaleCeiling(for surface: CanvasSurfaceID) -> Double? {
        let level = fidelity[surface].currentLevel
        guard level.scaleStepsBelowRequested > 0 else {
            return nil
        }
        return level.streamScale(requestedScale: fidelity[surface].requestedScale)
    }

    /// The frame rate this surface is being encoded at, which is what the
    /// viewer is told: what the host is aiming for, distinct from what it
    /// managed to produce.
    public func appliedFramesPerSecond(for surface: CanvasSurfaceID) -> Int {
        fidelity[surface].currentLevel.framesPerSecond
    }

    /// The multiplier on this surface's encoder bitrate, `1.0` when nothing
    /// has been given up.
    public func appliedQualityScale(for surface: CanvasSurfaceID) -> Double {
        fidelity[surface].currentLevel.qualityScale
    }

    /// Which stage is holding this surface below what the viewer asked for,
    /// as one of `FidelityLimitReason`'s stable tokens. `nil` when nothing is
    /// being held back.
    public func fidelityLimitReason(for surface: CanvasSurfaceID) -> String? {
        guard let reason = fidelity[surface].limitReason else {
            return nil
        }
        switch reason {
        case .encoder:
            return FidelityLimitReason.encoder
        case .link:
            return FidelityLimitReason.link
        case .viewer:
            return FidelityLimitReason.viewer
        case .none:
            return nil
        }
    }

    /// See `SurfaceTelemetrySample.clampedFromUserChoice`.
    public func clampedStreamScaleFromUserChoice(for surface: CanvasSurfaceID) -> Double? {
        clampedFromUserChoice[surface]
    }

    /// See `SurfaceTelemetrySample.hostRequestedStreamScale`.
    public func hostRequestedStreamScale(for surface: CanvasSurfaceID) -> Double? {
        lastRequestedScale[surface]
    }

    /// Follows the viewer's drawable once it has stopped moving: a window
    /// drag emits a size per frame and each would rebuild capture and
    /// encode. The ask resolves against this surface's own
    /// `StreamScalePreference` and the measured ceiling, with the viewer's
    /// own maximum folded into the geometry scale first. `requireMinimumDelta`,
    /// viewer geometry only, drops a change too small to rebuild for,
    /// checked after clamping so a clamp is still logged.
    private func requestStreamScale(_ scale: Double, on surface: CanvasSurfaceID, requireMinimumDelta: Bool = false) {
        let userMaximum = controller.requestedMaximumStreamScale(for: surface)
        let preference = streamScalePreference[surface]
        // A host-screen surface has a ceiling the session canvas does not:
        // the real display's own pixels and the largest frame this machine's
        // hardware encoder accepts. Applied here rather than only where a
        // drawable size is derived, because a fixed choice reaches the
        // encoder without passing through geometry at all, and a scale past
        // the encoder's limit does not soften the picture -- it fails the
        // rebuild.
        let hostScreenCeiling = isHostScreenSurface(surface)
            ? controller.hostScreenMaximumStreamScale
            : nil
        let geometryScale = [userMaximum, hostScreenCeiling].compactMap { $0 }.reduce(scale, Swift.min)
        // The controller counts its scale steps down from what the viewer
        // is actually asking for, so it is told that ask before its own
        // ceiling is read back below: resolution given up stays measured
        // against whatever the viewer currently wants, rather than against
        // the last number that happened to survive a clamp.
        fidelity[surface].setRequestedScale(Swift.min(
            preference.resolve(geometryScale: geometryScale, sustainabilityCeiling: nil).scale,
            hostScreenCeiling ?? .infinity
        ))
        let ceiling = sustainableScaleCeiling(for: surface)
        let resolution = preference.resolve(geometryScale: geometryScale, sustainabilityCeiling: ceiling)
        // The host-screen ceiling again, after the preference: `resolve`
        // honours a fixed choice exactly and never reads `geometryScale` for
        // it, so the fold above bounds `.automatic` alone.
        let clamped = Swift.min(resolution.scale, hostScreenCeiling ?? .infinity)
        // A fixed choice the host screen itself cut down is reported to the
        // viewer on the same field a measured ceiling uses: both are this
        // host refusing a number a person chose, and the window says so
        // rather than silently showing something else.
        clampedFromUserChoice[surface] = resolution.clampedFromUserChoice
            ?? (clamped < resolution.scale ? resolution.scale : nil)

        if clamped < resolution.scale {
            reportStreamScaleHold(
                String(
                    format: "stream scale %.2fx requested but clamped to %.2fx by the host screen\u{2019}s own "
                        + "pixels and this machine\u{2019}s encoder",
                    Self.scaleAPersonAskedFor(resolution),
                    clamped
                ),
                on: surface
            )
        } else if let requestedByUser = resolution.clampedFromUserChoice {
            // The fidelity controller's ceiling held back an explicit choice.
            // Reported here, for the operator log;
            // `clampedFromUserChoice[surface]` above is what the wire tells
            // the viewer the same fact through.
            reportStreamScaleHold(
                fidelityHoldMessage(requested: requestedByUser, held: clamped, on: surface),
                on: surface
            )
        } else if preference == .automatic, clamped != scale {
            // Loud, not silent: a request the viewer's own geometry justified
            // is being refused, and that is exactly the kind of thing that
            // wastes an afternoon later if it is not in the log. Which of the
            // two ceilings did it matters to whoever reads this: one is the
            // user's own choice and the other is this machine's measured
            // limit. Guarded to `.automatic`: under a `.fixed` choice
            // `clamped` is that choice's own value, not a reduction of
            // `scale` (which `resolve` never even reads), so comparing the
            // two here would log a clamp that never happened.
            let isViewerOwnMaximum = userMaximum.map { $0 <= (ceiling ?? .infinity) } ?? false
            let message = isViewerOwnMaximum
                ? String(
                    format: "stream scale %.2fx requested but clamped to %.2fx by the viewer\u{2019}s own maximum",
                    scale,
                    clamped
                )
                : fidelityHoldMessage(requested: scale, held: clamped, on: surface)
            reportStreamScaleHold(message, on: surface)
        } else {
            // Nothing is holding this surface back any more, so the next hold
            // that does is news again.
            lastStreamScaleHold[surface] = nil
        }
        if requireMinimumDelta, hasAppliedStreamScale[surface],
           !StreamScalePolicy.isWorthReconfiguring(from: streamScale[surface].appliedScale, to: clamped) {
            return
        }
        streamScale[surface].request(scale: clamped, atSeconds: Self.nowSeconds())
        streamScaleSettleTask[surface]?.cancel()
        streamScaleSettleTask[surface] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.streamScale[surface].settleSeconds))
            guard !Task.isCancelled else { return }
            guard let settled = self.streamScale[surface].takeSettledScale(atSeconds: Self.nowSeconds()) else {
                return
            }
            await self.applyStreamScale(settled, on: surface)
        }
    }

    /// A scale the fidelity controller is holding down, named as the decision
    /// it is rather than as a property of the machine: the controller
    /// measured a stage that could not keep up, and the line says which.
    private func fidelityHoldMessage(
        requested: Double,
        held: Double,
        on surface: CanvasSurfaceID
    ) -> String {
        String(
            format: "stream scale %.2fx requested but held to %.2fx by the fidelity controller (%@)",
            requested,
            held,
            Self.limitDescription(fidelity[surface].limitReason)
        )
    }

    /// The scale a person actually asked for, out of a resolution that one
    /// ceiling may already have cut down. `StreamScaleResolution.scale` is what
    /// survived that first ceiling, so a second clamp reported against it names
    /// a number nobody ever chose.
    public nonisolated static func scaleAPersonAskedFor(_ resolution: StreamScaleResolution) -> Double {
        resolution.clampedFromUserChoice ?? resolution.scale
    }

    /// One line per change, not one per request. A viewer re-asks for its
    /// geometry scale every time its window settles, and a hold that has not
    /// moved since the last one is not news -- printed each time, it buries
    /// the lines that are.
    private func reportStreamScaleHold(_ message: String, on surface: CanvasSurfaceID) {
        guard lastStreamScaleHold[surface] != message else {
            return
        }
        lastStreamScaleHold[surface] = message
        onEvent?(message)
    }

    /// Whether `surface` is the one a live host-screen capture streams on.
    /// A connection is one shape for its whole life -- `HostSessionController`
    /// refuses a canvas request once a host-screen one was admitted, and the
    /// other way round -- so a surface is never both at once.
    private func isHostScreenSurface(_ surface: CanvasSurfaceID) -> Bool {
        isHostScreenStreaming && surface == Self.hostScreenTelemetrySurface
    }

    /// The media this surface is actually streaming through, which is the
    /// host-screen capture during a host-screen session and this surface's
    /// canvas pipeline otherwise. Every fidelity, telemetry and rebuild path
    /// reads it here rather than reaching into `media` directly, so a
    /// host-screen session's picture is controlled by the same ladder a
    /// session canvas's is instead of steering a pipeline it never started.
    private func streamingMedia(on surface: CanvasSurfaceID) -> any CanvasMediaStreaming {
        guard isHostScreenSurface(surface), let hostScreenMedia else {
            return media[surface]
        }
        return hostScreenMedia
    }

    /// What a line a person reads calls the thing this surface streams.
    ///
    /// Host-screen frames are tagged with a canvas surface for the telemetry,
    /// admission and send machinery they share with the canvas path, but that
    /// number names nothing the person at this machine can point at: a
    /// host-screen session creates no canvas, so a line calling it "canvas 0"
    /// describes something that does not exist. The display it really
    /// streams does.
    private func surfaceLogName(_ surface: CanvasSurfaceID) -> String {
        guard isHostScreenSurface(surface) else {
            return "canvas \(surface.wireValue)"
        }
        guard let displayID = controller.hostScreenDisplayID else {
            return "the host screen"
        }
        return "host-screen display \(displayID)"
    }

    /// The dimensions a stream scale on this surface is a fraction of.
    private func encodeBaseDimensions(on surface: CanvasSurfaceID) -> (width: Int, height: Int) {
        if isHostScreenSurface(surface), let hostScreenEncodeBase {
            return hostScreenEncodeBase
        }
        let canvas = VirtualCanvasConfiguration.remoteDefault
        return (canvas.logicalWidth, canvas.logicalHeight)
    }

    private func applyStreamScale(_ scale: Double, on surface: CanvasSurfaceID) async {
        guard isStreaming[surface] else {
            return
        }
        // While a rebuild owns the host-screen surface -- recovery's own
        // restart, or a parked request's own replay -- there is no live
        // media to reconfigure, only a capture that rebuild is still
        // building or about to replace, and reconfiguring it ends the
        // session with "stream-reconfiguration-failed", bypassing that
        // rebuild entirely. Left alone here, nothing is lost for recovery's
        // own restart: it rebuilds from the viewer's latest stream-scale
        // preference (see `restartRecoveredHostScreenCapture`), and this
        // settle timer's own request already lives on in
        // `lastRequestedScale`.
        guard !(isHostScreenSurface(surface) && isHostScreenCaptureRebuildInFlight) else {
            return
        }
        await reconfigureStreamScale(scale, on: surface)
    }

    /// The unguarded core of applying a stream scale to whatever this
    /// surface is actually streaming through right now, and recording the
    /// outcome. `applyStreamScale` is the gated entry point every settle
    /// timer calls through; a host-screen recovery reaches this directly,
    /// once its own restart has put a live capture back, because
    /// `isHostScreenCaptureRebuildInFlight` is still held at that point --
    /// recovery's own restart is only the first of what the drain that
    /// follows it may still process -- and would otherwise gate this out
    /// too.
    private func reconfigureStreamScale(_ scale: Double, on surface: CanvasSurfaceID) async {
        // From here on `streamScale[surface].appliedScale` is a real,
        // deliberately-applied value worth comparing a future request
        // against -- not just whatever a fresh pipeline happened to start
        // streaming at. Set before the attempt, not only on success: even a
        // recovered-to-previous outcome below is a real answer to "what is
        // this surface actually streaming right now."
        hasAppliedStreamScale[surface] = true
        do {
            try await streamingMedia(on: surface).reconfigure(streamScale: scale)
            streamScale[surface].markApplied(scale)
            let base = encodeBaseDimensions(on: surface)
            onEvent?(String(
                format: "stream scale now %.2fx: encoding %dx%d",
                scale,
                Int((Double(base.width) * scale).rounded()),
                Int((Double(base.height) * scale).rounded())
            ))
            // A rebuilt encoder's first frames are its opening IDR and its
            // warm-up, and the fidelity tick must not read them as the cost
            // of the resolution it just moved to. The percentiles start over,
            // and so does every counter streak the controller was keeping:
            // the drops of a pipeline being torn down and stood up again say
            // nothing about the one now running.
            latencyRecorder?.resetEncodeCheckpoint(for: surface)
            fidelity[surface].beginWarmUp()
        } catch let CanvasMediaReconfigurationError.recoveredToPreviousScale(previous) {
            // Loud, but not fatal: there is still a working stream, just not
            // the one that was asked for.
            onEvent?(String(
                format: "stream scale %.2fx could not be applied; recovered and still streaming at %.2fx",
                scale,
                previous
            ))
            streamScale[surface].markApplied(previous)
            // The scale first, so what the controller reports is the one the
            // stream is really running at, and the warm-up second: the
            // pipeline was torn down and stood up again either way, and its
            // opening counters are no more the cost of this fidelity than a
            // successful rebuild's are.
            fidelity[surface].streamScaleDidNotApply(atSeconds: Self.nowSeconds())
            fidelity[surface].beginWarmUp()
        } catch {
            // Nothing is streaming on this surface any more. Ending the
            // session is the loud outcome: the viewer redials and gets a
            // working stream back, rather than staring at a picture that
            // stopped updating.
            onEvent?("stream scale \(scale) failed and no working stream could be restored: \(error)")
            hasEnded = true
            await tearDownSurfaces()
            _ = try? controller.handle(.goodbye(reason: "stream-reconfiguration-failed"))
            onStreamUnrecoverable?("stream-reconfiguration-failed")
        }
    }

    /// One tick of adaptive fidelity for every streaming surface, at the
    /// telemetry cadence.
    ///
    /// Driven by the caller rather than by a timer of its own: the host
    /// already runs one loop at `TelemetryPolicy.sendIntervalSeconds`, and a
    /// second timer at the same period would only add a way for the numbers
    /// the viewer is shown and the numbers a decision was made from to
    /// disagree.
    public func tickFidelity() async {
        await tickFidelity(atSeconds: Self.nowSeconds())
    }

    /// The clock-injected form, for a caller that has its own idea of now.
    public func tickFidelity(atSeconds now: Double) async {
        for surface in CanvasSurfaceID.allCases {
            guard isStreaming[surface] else {
                // A stopped stream leaves no evidence behind: a delta taken
                // across the gap would charge the next session for it.
                previousFidelityReading[surface] = nil
                previousCaptureDeliveryReading[surface] = nil
                continue
            }
            if isHostScreenSurface(surface) {
                redeclareHostScreenKeepAwakeIfDue(atSeconds: now)
                guard !isHostScreenCaptureRebuildInFlight else {
                    // A rebuild already owns this surface's capture --
                    // recovery's own restart, or a parked request's own
                    // replay -- torn down and rebuilt, and its counters
                    // describe neither the capture that just died nor the
                    // one that may replace it. Judging either against the
                    // other here would only rebuild or give up on a stream
                    // that is not this tick's to judge.
                    continue
                }
            }
            let reading = FidelityReading(
                counts: await streamingMedia(on: surface).frameCounts,
                sendQueueDropped: videoSink.droppedVideoFrameCount(for: surface),
                producedBytes: producedBytes.total(for: surface),
                sentBytes: videoSink.sentVideoByteCount(for: surface),
                atSeconds: now
            )
            switch reportCaptureDelivery(reading.counts, on: surface, atSeconds: now) {
            case .rebuild:
                await rebuildSilentCapture(on: surface)
            case .giveUp:
                await endSessionForDeadCapture(on: surface)
                return
            case nil:
                break
            }
            defer { previousFidelityReading[surface] = reading }
            guard let previous = previousFidelityReading[surface], now > previous.atSeconds else {
                continue
            }
            let controllerBeforeTick = fidelity[surface]
            let decision = fidelity[surface].observe(
                observation(from: reading, since: previous, on: surface, atSeconds: now),
                atSeconds: now
            )
            await apply(decision, on: surface, revertingTo: controllerBeforeTick, atSeconds: now)
        }
    }

    /// One line per surface per report interval saying what its capture stream
    /// actually delivered, split into the screen changing, the same picture
    /// arriving again, notices carrying no picture at all, and every other
    /// delivery -- so a stream sending only those does not read the same as
    /// one that stopped delivering.
    ///
    /// It is driven by the fidelity tick rather than by the encoded packets,
    /// because a screen nobody is touching produces no packets: every report
    /// downstream of the encoder falls silent in exactly the case this line
    /// exists to describe, and cannot distinguish a stream delivering
    /// unchanged frames at the frame rate from one that has stopped.
    ///
    /// Returns what the silence it found asks for, if anything: a stream that
    /// has delivered nothing whatsoever since it started has not gone quiet,
    /// it has stopped. The workspace window guarantees a first frame and
    /// `FirstFrameGate` forces it to count, so no legitimately still screen
    /// reaches this.
    private func reportCaptureDelivery(
        _ counts: HostFrameCounts,
        on surface: CanvasSurfaceID,
        atSeconds now: Double
    ) -> SilentCaptureResponse? {
        guard let previous = previousCaptureDeliveryReading[surface] else {
            previousCaptureDeliveryReading[surface] = CaptureDeliveryReading(counts: counts, atSeconds: now)
            captureDeliveryBaseline[surface] = counts
            return nil
        }
        let seconds = now - previous.atSeconds
        guard seconds >= captureDeliveryReportSeconds else {
            return nil
        }
        previousCaptureDeliveryReading[surface] = CaptureDeliveryReading(counts: counts, atSeconds: now)
        // What the screen did, which is what a still-screen decision reads:
        // the frames this host asked for are captured frames too, and one of
        // them is the whole difference between a still screen and a moving one.
        let screenChanges = (counts.captured - previous.counts.captured)
            - (counts.hostRequested - previous.counts.hostRequested)
        onEvent?(surfaceLogName(surface) + String(
            format: " capture over %.1fs: %d screen changes, %d unchanged frames, "
                + "%d no-change notices, %d other deliveries",
            seconds,
            screenChanges,
            counts.unchangedFrames - previous.counts.unchangedFrames,
            counts.noChangeNotices - previous.counts.noChangeNotices,
            counts.otherStatusDeliveries - previous.counts.otherStatusDeliveries
        ))
        return noteCaptureSilence(counts, on: surface)
    }

    /// What a stream this surface owns has delivered since it started, in
    /// the four kinds the report above names. Nothing in any of them means
    /// nothing reached this host at all.
    private func hasDeliveredNothing(_ counts: HostFrameCounts, on surface: CanvasSurfaceID) -> Bool {
        guard let baseline = captureDeliveryBaseline[surface] else {
            return false
        }
        return counts.captured - counts.hostRequested == baseline.captured - baseline.hostRequested
            && counts.unchangedFrames == baseline.unchangedFrames
            && counts.noChangeNotices == baseline.noChangeNotices
            && counts.otherStatusDeliveries == baseline.otherStatusDeliveries
    }

    private func noteCaptureSilence(
        _ counts: HostFrameCounts,
        on surface: CanvasSurfaceID
    ) -> SilentCaptureResponse? {
        guard hasDeliveredNothing(counts, on: surface) else {
            silentCaptureReports[surface] = 0
            return nil
        }
        silentCaptureReports[surface] += 1
        guard silentCaptureReports[surface] >= Self.silentCaptureReportsBeforeRebuild else {
            return nil
        }
        silentCaptureReports[surface] = 0
        return didRebuildSilentCapture[surface] ? .giveUp : .rebuild
    }

    /// Stands this surface's pipeline up again, once, at the scale it is
    /// already streaming. The baseline is deliberately left where it is: the
    /// stream delivered nothing to move it, and what the next two reports
    /// have to answer is whether the rebuilt one delivers anything either.
    ///
    /// A host-screen surface rebuilds through the same seam, which stops and
    /// restarts only the capture and encode. The session itself does not end,
    /// so the indication naming the connected device stays up and the session
    /// record stays open across it.
    private func rebuildSilentCapture(on surface: CanvasSurfaceID) async {
        didRebuildSilentCapture[surface] = true
        onEvent?(
            surfaceLogName(surface) + " capture has delivered nothing at all since it started; "
                + "building it again once"
        )
        await applyStreamScale(streamScale[surface].appliedScale, on: surface)
    }

    /// The rebuilt stream delivered nothing either. This session ends the way
    /// a capture that could not start ends one, and the process records that
    /// it can no longer capture on this machine: every later canvas request,
    /// on this connection or the next, is refused rather than answered with a
    /// window that never updates.
    private func endSessionForDeadCapture(on surface: CanvasSurfaceID) async {
        onEvent?(surfaceLogName(surface) + " capture delivered nothing after being built again")
        // A display that idled to sleep mid-session is the one cause of this
        // silence that is neither a broken process nor a broken pipeline:
        // macOS draws nothing at all while it sleeps, and waking it is all it
        // takes. Tried once, and only once, before anything is given up on.
        // A host-screen session reads only the display it is capturing: some
        // other monitor sleeping says nothing about why this one is silent.
        // A session canvas has no such display to name, and display sleep is
        // machine-wide, so that one reads the machine.
        let capturedDisplay = controller.hostScreenDisplayID
        let displaysAsleep: Bool = {
            guard let displayWake else {
                return false
            }
            guard let capturedDisplay else {
                return displayWake.anyDisplayIsAsleep
            }
            return displayWake.sleepingDisplayIDs.contains(capturedDisplay)
        }()
        if displaysAsleep, !didWakeSleepingDisplaysForSilentCapture[surface] {
            didWakeSleepingDisplaysForSilentCapture[surface] = true
            await displayWake?.wakeDisplays(targets: capturedDisplay.map { [$0] } ?? [])
            didRebuildSilentCapture[surface] = false
            await rebuildSilentCapture(on: surface)
            return
        }
        hasEnded = true
        if displaysAsleep {
            // Nothing about this process is recorded as broken: it is not,
            // and refusing every later canvas on this machine would outlast
            // the sleeping screen that caused this by the whole run.
            onEvent?(HostCaptureAvailability.displaysAsleepLogLine)
            await tearDownSurfaces()
            _ = try? controller.handle(.goodbye(reason: GoodbyeReason.hostDisplaysAsleep))
            onStreamUnrecoverable?(GoodbyeReason.hostDisplaysAsleep)
            return
        }
        captureAvailability.markUnavailable(log: { [onEvent] line in onEvent?(line) })
        await tearDownSurfaces()
        _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
        onStreamUnrecoverable?(GoodbyeReason.captureUnavailable)
    }

    /// A session canvas's capture stopped on its own. Rebuilt once at the
    /// scale it was streaming; if that fails, or the rebuilt capture stops
    /// too, the session ends so the viewer is told instead of left on a
    /// picture that no longer updates. Kept apart from the host-screen
    /// recovery below: a canvas is this host's own display, with no
    /// sleeping or disconnected monitor to wait out.
    private func canvasCaptureStoppedOnItsOwn(on surface: CanvasSurfaceID, generation: Int) async {
        guard !hasEnded, isStreaming[surface], !isHostScreenSurface(surface),
              generation == canvasCaptureGeneration[surface] else {
            return
        }
        guard !didRebuildStoppedCanvasCapture[surface] else {
            onEvent?(surfaceLogName(surface) + " capture stopped on its own again after being built again")
            await endSessionForStoppedCanvasCapture()
            return
        }
        didRebuildStoppedCanvasCapture[surface] = true
        onEvent?(surfaceLogName(surface) + " capture stopped on its own; building it again once")
        do {
            try await media[surface].reconfigure(streamScale: streamScale[surface].appliedScale)
        } catch CanvasMediaReconfigurationError.recoveredToPreviousScale {
            // Still streaming, at the scale it already had.
        } catch {
            guard !hasEnded else {
                return
            }
            onEvent?(surfaceLogName(surface) + " could not rebuild its capture. \(HostOperatorLog.describe(error))")
            await endSessionForStoppedCanvasCapture()
            return
        }
        fidelity[surface].beginWarmUp()
    }

    private func endSessionForStoppedCanvasCapture() async {
        hasEnded = true
        await tearDownSurfaces()
        _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
        onStreamUnrecoverable?(GoodbyeReason.captureUnavailable)
    }

    /// `CanvasMediaStreaming.setCaptureStoppedHandler`'s own signal: capture
    /// stopped on its own, distinct from the tick-driven silence machinery
    /// above, which reads what a stream delivers rather than whether the
    /// stream itself is still there. `generation` guards a signal from a
    /// capture this coordinator has already moved on from -- see
    /// `hostScreenCaptureGeneration`.
    private func hostScreenCaptureStoppedOnItsOwn(generation: Int) {
        guard !hasEnded, isHostScreenStreaming, generation == hostScreenCaptureGeneration,
              !isHostScreenCaptureRebuildInFlight else {
            return
        }
        // Held for this Task's whole lifetime, recovery's own restart and
        // the drain that follows it alike -- see
        // `isHostScreenCaptureRebuildInFlight`'s own documentation for why
        // clearing it the moment recovery's own restart finishes, before
        // the drain begins, would reopen exactly the race this guards
        // against.
        isHostScreenCaptureRebuildInFlight = true
        hostScreenRecoveryTask = Task { @MainActor [weak self] in
            await self?.recoverHostScreenCapture(generation: generation)
            await self?.drainPendingHostScreenModeRequests()
            self?.hostScreenRecoveryTask = nil
        }
    }

    /// Runs every mode request parked while a rebuild owned the host-screen
    /// surface, latest first as a new one arrives while an earlier one is
    /// still being drained, until none is left. Called only from inside the
    /// `Task` `hostScreenCaptureStoppedOnItsOwn` starts, with
    /// `isHostScreenCaptureRebuildInFlight` already held from the moment
    /// that recovery began -- so this drains through `processMessage`
    /// directly, not back through `handle`, whose own park check would
    /// otherwise park what this is already in the middle of draining. Ends
    /// the moment `hasEnded` is true, whether that happened before this
    /// began or partway through: there is no live connection left to
    /// answer, and a capture built now would have nowhere to send to.
    /// Clears `isHostScreenCaptureRebuildInFlight` only once the queue is
    /// genuinely empty, which is the one moment a fresh request may reach
    /// `processMessage` again without parking.
    private func drainPendingHostScreenModeRequests() async {
        while let pending = pendingHostScreenModeRequest {
            pendingHostScreenModeRequest = nil
            guard !hasEnded else {
                break
            }
            _ = try? await processMessage(pending.message, writeResponse: pending.writeResponse)
        }
        isHostScreenCaptureRebuildInFlight = false
        // A settle dropped while a drained request rebuilt the capture is
        // reapplied here, clamped to the current mode's ceiling like the
        // recovery restart's own reapply.
        let surface = Self.hostScreenTelemetrySurface
        let target = Swift.min(
            lastRequestedScale[surface] ?? streamScale[surface].appliedScale,
            controller.hostScreenMaximumStreamScale ?? .infinity
        )
        if StreamScalePolicy.isWorthReconfiguring(from: streamScale[surface].appliedScale, to: target) {
            await applyStreamScale(target, on: surface)
        }
    }

    /// Brings a host-screen capture that stopped on its own back up on the
    /// same display, waking it first: macOS draws nothing while a display
    /// sleeps or is briefly off the bus, and a hardware mirror set's
    /// "primary" role can flip onto another member without any of this
    /// machine's own displays actually going anywhere. The session survives
    /// throughout -- the badge naming the connected device stays up and the
    /// session record stays open, exactly as a display-mode rebuild leaves
    /// them -- and only the capture is rebuilt, and only once this
    /// session's own target display is confirmed online, awake, and not now
    /// a mirror member.
    ///
    /// Bounded by `hostScreenCaptureRecoveryBoundSeconds` of elapsed
    /// wall-clock time, not a fixed count of retries: `wakeAndSettleDisplays`
    /// and `waitForDisplaysToWake` can each spend real seconds waiting
    /// inside one retry, so counting retries as if each were instant let a
    /// display gone for good be retried for minutes past the bound this
    /// names. A display gone for good ends the session the way an
    /// unavailable host screen already does, rather than retrying past that
    /// bound against a viewer that has long since frozen. A display that has
    /// become a mirror member is never captured in its place, and ends the
    /// session at once rather than waiting out the bound for an answer that
    /// will not change.
    ///
    /// `generation` is this recovery's own capture generation, re-checked
    /// after every suspension: a mode change deferred while this was
    /// running is handled once this returns, but nothing else this
    /// coordinator does is deferred, and a capture this recovery no longer
    /// answers for -- one a mode change rebuilt, or one a later stop
    /// deliberately tore down -- must never be rebuilt a second time or
    /// reported recovered out from under whatever replaced it.
    private func recoverHostScreenCapture(generation: Int) async {
        func isCurrent() -> Bool {
            !hasEnded && generation == hostScreenCaptureGeneration
        }
        let surfaceName = surfaceLogName(Self.hostScreenTelemetrySurface)
        onEvent?("\(surfaceName) capture stopped on its own; attempting to recover")
        let deadline = hostScreenNowSecondsProvider() + hostScreenCaptureRecoveryBoundSeconds
        while true {
            guard isCurrent() else {
                return
            }
            await displayWake?.wakeAndSettleDisplays()
            guard isCurrent() else {
                return
            }
            let gap = controller.hostScreenTargetAvailability()
            switch gap {
            case nil:
                await restartRecoveredHostScreenCapture()
                return
            case .mirrored:
                await endHostScreenSessionForRecoveryFailure(gapReason: gap)
                return
            case .asleep:
                if let id = controller.hostScreenDisplayID {
                    guard isCurrent() else {
                        return
                    }
                    await displayWake?.waitForDisplaysToWake(targets: [id])
                    guard isCurrent() else {
                        return
                    }
                }
            case .notOnline, .headlessStandIn, .createdBySensorium:
                break
            }
            guard hostScreenNowSecondsProvider() < deadline else {
                await endHostScreenSessionForRecoveryFailure(gapReason: gap)
                return
            }
            await hostScreenCaptureRecoveryWait(hostScreenCaptureRecoveryPollSeconds)
            guard isCurrent() else {
                return
            }
        }
    }

    /// The one successful outcome `recoverHostScreenCapture` retries
    /// toward: the target display read back online, awake, and not a
    /// mirror member. Rebuilds through the same seam a display-mode change
    /// already rebuilds through, at the geometry the display is on right
    /// now, and sends the viewer a key frame the moment it is back so the
    /// picture recovers at once rather than waiting for the next change.
    private func restartRecoveredHostScreenCapture() async {
        guard !hasEnded, let geometry = controller.hostScreenGeometry else {
            return
        }
        let surface = Self.hostScreenTelemetrySurface
        do {
            try await restartHostScreenStreaming(
                geometry: geometry,
                note: "capture recovered after stopping on its own"
            )
        } catch {
            guard !hasEnded else {
                return
            }
            onEvent?(surfaceLogName(surface) + " could not recover its capture. \(HostOperatorLog.describe(error))")
            hasEnded = true
            await tearDownSurfaces()
            _ = try? controller.handle(.goodbye(reason: GoodbyeReason.captureUnavailable))
            onStreamUnrecoverable?(GoodbyeReason.captureUnavailable)
            return
        }
        guard !hasEnded else {
            return
        }
        // The rebuild above always opens at this display's native or
        // hardware-clamped opening scale -- `HostScreenEncoderSizing` has
        // no awareness of anything the viewer asked for -- so the viewer's
        // latest stream-scale preference is reapplied here, directly:
        // `applyStreamScale`'s own gate would drop this, since this call
        // runs before recovery has released the surface
        // (`isHostScreenCaptureRebuildInFlight` is not cleared until the
        // whole drain the recovery function this is called from feeds into
        // is empty). `lastRequestedScale` survives a rebuild
        // untouched, whichever restart path just ran -- unlike
        // `streamScale[surface].appliedScale`, which a stop-and-start
        // rebuild resets to the opening scale and an in-place rebuild
        // leaves stale at whatever was applied before the capture died.
        let target = Swift.min(
            lastRequestedScale[surface] ?? streamScale[surface].appliedScale,
            controller.hostScreenMaximumStreamScale ?? .infinity
        )
        let openingScale = HostScreenEncoderSizing.resolve(for: geometry).configuration.streamScale
        if StreamScalePolicy.isWorthReconfiguring(from: openingScale, to: target) {
            await reconfigureStreamScale(target, on: surface)
            guard !hasEnded else {
                return
            }
        }
        resetCaptureDeliveryBookkeeping(for: surface)
        await streamingMedia(on: surface).requestKeyFrame()
        onEvent?(surfaceLogName(surface) + " capture recovered")
    }

    /// The target display never came back within the bound, or came back
    /// as a mirror member rather than its own picture. Ends the session the
    /// way an unavailable host screen already ends one: `hostDisplaysAsleep`
    /// names a remedy a person at the host can act on -- a screen that has
    /// to come back on -- covering both a display that stayed asleep or
    /// off the bus and one that is now mirroring another; neither is this
    /// process losing its own ability to capture, so `captureAvailability`
    /// is never marked and later sessions on this machine are not refused.
    private func endHostScreenSessionForRecoveryFailure(gapReason: HostScreenOfferGapReason?) async {
        guard !hasEnded else {
            return
        }
        hasEnded = true
        let words = gapReason?.words ?? HostScreenOfferGapReason.notOnline.words
        onEvent?(surfaceLogName(Self.hostScreenTelemetrySurface) + " did not come back (\(words)); ending the session")
        await tearDownSurfaces()
        _ = try? controller.handle(.goodbye(reason: GoodbyeReason.hostDisplaysAsleep))
        onStreamUnrecoverable?(GoodbyeReason.hostDisplaysAsleep)
    }

    /// Re-declares user activity for a live host-screen session, at
    /// `hostScreenKeepAwakeRedeclareIntervalSeconds`, rate-limited against
    /// the same clock the fidelity tick already runs on rather than a timer
    /// of its own. Host-screen only: a session canvas already holds every
    /// display awake through `holdDisplaysAwake()`'s own prevent-sleep
    /// assertion for the whole life of the session, with no one display it
    /// alone is answerable for staying lit, so it has no equivalent need.
    private func redeclareHostScreenKeepAwakeIfDue(atSeconds now: Double) {
        if let last = hostScreenLastKeepAwakeRedeclareAtSeconds,
           now - last < hostScreenKeepAwakeRedeclareIntervalSeconds {
            return
        }
        hostScreenLastKeepAwakeRedeclareAtSeconds = now
        displayWake?.redeclareUserActivityForLiveSession()
    }

    /// Wipes what the capture-delivery and fidelity tick machinery knows
    /// about a surface's stream, the same reset a display-mode rebuild
    /// already gets through `beginHostScreenCapture`'s own warm-up: a
    /// rebuilt capture answers for nothing the one it replaced delivered or
    /// failed to.
    private func resetCaptureDeliveryBookkeeping(for surface: CanvasSurfaceID) {
        previousCaptureDeliveryReading[surface] = nil
        captureDeliveryBaseline[surface] = nil
        previousFidelityReading[surface] = nil
        silentCaptureReports[surface] = 0
        didRebuildSilentCapture[surface] = false
        didWakeSleepingDisplaysForSilentCapture[surface] = false
    }

    private func observation(
        from reading: FidelityReading,
        since previous: FidelityReading,
        on surface: CanvasSurfaceID,
        atSeconds now: Double
    ) -> StreamFidelityObservation {
        let seconds = reading.atSeconds - previous.atSeconds
        let encode = latencyRecorder?.encodeLatencySinceCheckpoint(for: surface)
        return StreamFidelityObservation(
            // What the screen did, which is not the same as what this pipeline
            // encoded: a frame the host asked for while nothing was changing
            // is counted as captured, and one of them is the whole difference
            // between a still screen and a moving one.
            capturedDelta: (reading.counts.captured - previous.counts.captured)
                - (reading.counts.hostRequested - previous.counts.hostRequested),
            encodedDelta: reading.counts.encoded - previous.counts.encoded,
            encoderInputDroppedDelta: reading.counts.encoderInputDropped - previous.counts.encoderInputDropped,
            globalAdmissionDroppedDelta: reading.counts.globalAdmissionDropped - previous.counts.globalAdmissionDropped,
            sendQueueDroppedDelta: reading.sendQueueDropped - previous.sendQueueDropped,
            encodeP50Nanoseconds: encode?.p50,
            encodeSampleCount: encode?.count ?? 0,
            producedBitsPerSecond: Double((reading.producedBytes - previous.producedBytes) * 8) / seconds,
            // Absent unless both readings had a figure. The production video
            // sink always counts, so this is nil only in a test built on a
            // sink that leaves `sentVideoByteCount` at the protocol's default
            // -- never on a real connection, where half a delta would read
            // as a link carrying less than it did.
            sentBitsPerSecond: reading.sentBytes.flatMap { sent in
                previous.sentBytes.map { Double((sent - $0) * 8) / seconds }
            },
            // Absent rather than stale: `latestViewerTelemetry` hands back
            // nothing once a reading is too old, and nothing is exactly what
            // a decision must infer no viewer-side health from.
            viewer: controller.latestViewerTelemetry(for: surface, atSeconds: now).map {
                StreamFidelityViewerObservation(
                    decodeP95Nanoseconds: $0.decode?.p95Nanoseconds,
                    presentedFramesPerSecond: $0.presentedFramesPerSecond,
                    decodedFramesPerSecond: $0.decodedFramesPerSecond,
                    receivedBitsPerSecond: $0.receivedBitsPerSecond
                )
            },
            // This tick's own wall-clock length, for judging the encoder
            // against how long it actually had to produce `capturedDelta`
            // frames rather than against the applied rate's nominal period.
            tickDurationNanoseconds: Int64(seconds * 1_000_000_000)
        )
    }

    /// Carries out one decision: the frame rate and quality levers directly,
    /// the scale lever through the same debounced reconfigure path a viewer
    /// resize uses. A decision moves whichever levers differ from the ones in
    /// force, which for a resolution chosen straight from the encoder's
    /// measured cost can be several quantum steps in one reconfigure.
    private func apply(
        _ decision: StreamFidelityDecision,
        on surface: CanvasSurfaceID,
        revertingTo controllerBeforeTick: StreamFidelityController,
        atSeconds now: Double
    ) async {
        guard decision != .hold else {
            return
        }
        if decision == .refreshStill {
            await refreshStillPicture(on: surface)
            return
        }
        let level = fidelity[surface].currentLevel
        let previousLevel = controllerBeforeTick.currentLevel
        do {
            if level.framesPerSecond != previousLevel.framesPerSecond {
                try await streamingMedia(on: surface).apply(framesPerSecond: level.framesPerSecond)
            }
            if level.qualityScale != previousLevel.qualityScale {
                try await streamingMedia(on: surface).apply(qualityScale: level.qualityScale)
            }
        } catch {
            // What a surface streams is a claim about what is actually
            // being encoded, and the viewer is shown it. A lever that refused
            // to move leaves the previous picture the true one, so the
            // controller goes back to it rather than describing a picture
            // this host is not producing.
            fidelity[surface] = controllerBeforeTick
            fidelity[surface].changeDidNotApply(atSeconds: now)
            onEvent?(
                "fidelity change could not be applied on \(surfaceLogName(surface)); still "
                    + Self.fidelityDescription(previousLevel, requestedScale: controllerBeforeTick.requestedScale)
                    + ". \(HostOperatorLog.describe(error))"
            )
            return
        }
        if decision.requestsKeyFrame {
            await streamingMedia(on: surface).requestKeyFrame()
        }
        // The cost of the fidelity that was just left behind is no evidence
        // about the one now in force.
        latencyRecorder?.resetEncodeCheckpoint(for: surface)
        onEvent?(
            "fidelity now \(Self.fidelityDescription(level, requestedScale: fidelity[surface].requestedScale)) "
                + "on \(surfaceLogName(surface)) (\(Self.limitDescription(fidelity[surface].limitReason)))"
        )
        guard level.scaleStepsBelowRequested != previousLevel.scaleStepsBelowRequested else {
            return
        }
        // Through the ceiling, never as a request in its own right: that is
        // what lets the controller lower a scale a person chose outright, and what
        // keeps one debounce and one reconfigure path for every scale change
        // in the session.
        //
        // Re-asking for what the viewer wants, never for what is currently
        // streaming: scale steps are counted down from the ask, so feeding
        // an already-lowered scale back in would move the ask down with it
        // and spend the same resolution twice.
        requestStreamScale(fidelity[surface].requestedScale, on: surface)
    }

    /// One attempt per still period, whatever comes of it: the controller has
    /// already recorded that this still picture was refreshed, and a surface
    /// that cannot send the frame now will not be able to a second later
    /// either. The next thing to move on that screen starts a new period, and
    /// with it a new attempt.
    private func refreshStillPicture(on surface: CanvasSurfaceID) async {
        do {
            guard let frameBytes = try await streamingMedia(on: surface).refreshStillPicture() else {
                return
            }
            onEvent?(
                "still-screen refresh sent on \(surfaceLogName(surface)) "
                    + "(\(HostOperatorLog.describeFrameSize(bytes: frameBytes)) key frame)"
            )
        } catch StillFrameEncoderError.frameExceedsTransportLimit(let bytes) {
            // Its own line, because nothing went wrong: the picture was
            // encoded as softly as this host is willing to encode one and is
            // still larger than the link's frame format accepts, so it is not
            // sent at all rather than sent and refused at the write.
            onEvent?(
                "still-screen refresh skipped on \(surfaceLogName(surface)): "
                    + "\(HostOperatorLog.describeFrameSize(bytes: bytes)) exceeds the transport limit"
            )
        } catch {
            onEvent?(
                "still-screen refresh not sent on \(surfaceLogName(surface)). "
                    + HostOperatorLog.describe(error)
            )
        }
    }

    private static func fidelityDescription(
        _ level: StreamFidelityLevel,
        requestedScale: Double
    ) -> String {
        String(
            format: "%d fps, quality %d%%, %.2fx",
            level.framesPerSecond,
            Int((level.qualityScale * 100).rounded()),
            level.streamScale(requestedScale: requestedScale)
        )
    }

    private static func limitDescription(_ reason: StreamFidelityPressure?) -> String {
        switch reason {
        case .some(.encoder):
            return "limited by the encoder"
        case .some(.link):
            return "limited by the link"
        case .some(.viewer):
            return "limited by the viewer"
        case .some(.none), nil:
            return "no limit"
        }
    }

    /// What the log calls the message that failed, in the words the rest of
    /// the host log uses rather than the case name off the wire. Everything
    /// this does not name is simply "a request": the point of the line is the
    /// error beside it, and a message the host has no ordinary word for is
    /// still worth reporting.
    private static func requestDescription(of message: SensoriumMessage) -> String {
        switch message {
        case .canvasRequest:
            return "canvas request"
        case .displayCount:
            return "display count request"
        case .hostScreenRequest:
            return "host screen request"
        case .pairIntent, .pairRequest:
            return "pairing request"
        case .input:
            return "input"
        case .viewerDrawableSize:
            return "viewer size report"
        case .viewerFocus:
            return "viewer focus report"
        case .streamScalePreference:
            return "stream scale preference"
        case .clipboardSharing:
            return "clipboard sharing change"
        case .hello, .authenticatedHello:
            return "hello"
        case .timeSyncRequest, .timeSyncReply:
            return "time sync"
        default:
            return "request"
        }
    }

    /// One string for both rejection paths: the reason is the gate, not the
    /// canvas, and no display ID exists yet on either.
    private static let canvasCreationRejectedEvent =
        HostOperatorLog.describe(CanvasCreationGateError.creationInProgress)

    /// The name a host-screen log line uses for the machine on the other
    /// end. `controller.hostScreenDeviceName` reads its own armed device
    /// record and is only ever set once a request has actually been
    /// admitted -- never on a refusal, which is refused before that record
    /// is reached -- so a refusal always falls back to the generic phrase,
    /// never a public key or any other fingerprint of the connection.
    private func hostScreenLogName() -> String {
        guard let name = controller.hostScreenDeviceName, !name.isEmpty else {
            return "the connected machine"
        }
        return name
    }

    private static func nowSeconds() -> Double {
        Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    }

    private func startStreaming(on surface: CanvasSurfaceID, canvasDisplayID: UInt32) async throws {
        guard !isStreaming[surface] else {
            return
        }
        isStreaming[surface] = true
        let videoSink = videoSink
        let focus = focus
        let flow = flow
        let onEvent = onEvent
        let producedBytes = producedBytes
        let startedAt = Date()
        // Wired before `start`, so a capture that stops the instant it comes
        // up is still caught.
        canvasCaptureGeneration[surface] += 1
        let generation = canvasCaptureGeneration[surface]
        media[surface].setCaptureStoppedHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.canvasCaptureStoppedOnItsOwn(on: surface, generation: generation)
            }
        }
        try await media[surface].start(canvasDisplayID: canvasDisplayID) { packet in
            // The focused canvas's frames are preferred on the shared wire.
            // With no focus reported this is `.normal` for every surface,
            // which is plain fair share.
            let taken = videoSink.send(packet, surface: surface, priority: focus.sendPriority(for: surface))
            // Payload plus codec configuration, the same basis the viewer
            // counts received bytes on and `sentBytes` counts sent bytes on:
            // a fidelity decision comparing this against either must never
            // read a healthy link as starved merely because one side counted
            // a key frame's configuration and the other did not.
            producedBytes.record(
                bytes: packet.payload.count + (packet.codecConfiguration?.count ?? 0),
                surface: surface
            )
            if let report = flow.record(
                bytes: packet.payload.count,
                droppedFramesTotal: { videoSink.droppedVideoFrameCount },
                atSeconds: Date().timeIntervalSince(startedAt)
            ) {
                // Frames that reached the wire, which is not the same as what
                // the screen did: `ScreenCaptureFrameAdmission` already keeps
                // everything but a genuine change out of this pipeline, and
                // the still-screen refresh adds a frame nothing on screen
                // asked for. A quiet screen legitimately reports a fraction of
                // a frame a second here, and reports nothing at all once it
                // stops changing entirely -- which is why what the capture
                // stream delivered has its own line, per surface, from the
                // fidelity tick.
                onEvent?(String(
                    format: "video %d frames in %.1fs (%.1f frames/s, %.2f Mbit/s), %d dropped to keep up",
                    report.frames,
                    report.seconds,
                    report.framesPerSecond,
                    report.megabitsPerSecond,
                    report.droppedFrames
                ))
            }
            return taken
        }
    }

    /// Stops every streaming surface in `surfacesToStop` -- every surface by
    /// default. `displayCount`'s own live "take the second display
    /// down" path is the one caller that passes a narrower list, through
    /// `tearDownSurfaceLive(_:)`. Returns whether anything actually
    /// stopped, so a whole-connection caller can decide whether this alone
    /// -- or together with host-screen mode also having stopped -- is what
    /// makes `onSessionEnded` fire; a live, partial teardown never reads
    /// that return value, because taking one display down mid-session is
    /// not the session ending.
    ///
    /// A surface a host-screen capture is streaming is left alone here: it
    /// has no canvas pipeline to stop, and `stopHostScreenStreaming` is what
    /// ends it and resets the same per-surface state.
    @discardableResult
    private func stopStreaming(_ surfacesToStop: [CanvasSurfaceID] = CanvasSurfaceID.allCases) async -> Bool {
        var stopped: [CanvasSurfaceID] = []
        for surface in surfacesToStop where isStreaming[surface] && !isHostScreenSurface(surface) {
            isStreaming[surface] = false
            canvasCaptureGeneration[surface] += 1
            await media[surface].stop()
            stopped.append(surface)
        }
        guard !stopped.isEmpty else {
            return false
        }
        resetSurfaceState(after: stopped)
        return true
    }

    /// Puts every surface back where a fresh session finds it, once the
    /// streams in `stopped` have gone.
    private func resetSurfaceState(after stopped: [CanvasSurfaceID]) {
        // Every surface's lever hold-offs, not just the one(s) that stopped:
        // machine-wide encoder capacity is part of what made a lever
        // unaffordable, so a hold-off learned while a sibling canvas was also
        // encoding must not survive that sibling ending -- true whether the
        // sibling ended because the whole connection did, or because
        // `displayCount` took just it down live while this surface kept
        // streaming.
        for surface in CanvasSurfaceID.allCases {
            if stopped.contains(surface) {
                // The surface that stopped starts over completely. What it
                // streamed, the streaks behind it and the stage it was given
                // up to were all measurements of a pipeline that no longer
                // exists, and the one built for the next session deserves the
                // same benefit of the doubt as the first: exactly what the
                // viewer asked for, and a warm-up before anything it reports
                // is acted on. The scale
                // the viewer asked for is not a measurement and survives.
                fidelity[surface] = StreamFidelityController(
                    requestedScale: fidelity[surface].requestedScale
                )
                // The stream those counters described is gone, and the next
                // one gets the same benefit of the doubt as the first.
                captureDeliveryBaseline[surface] = nil
                silentCaptureReports[surface] = 0
                didRebuildSilentCapture[surface] = false
                didRebuildStoppedCanvasCapture[surface] = false
            } else {
                fidelity[surface].clearCeilings()
            }
            hasAppliedStreamScale[surface] = false
            streamScalePreference[surface] = .automatic
            clampedFromUserChoice[surface] = nil
            lastStreamScaleHold[surface] = nil
        }
    }

    /// Takes exactly `surface` down, live, mid-session: removing a display
    /// closes that window, driven by a `displayCount` message rather than
    /// the whole connection ending.
    /// Cancels only this surface's own scale debounce (a sibling surface's,
    /// if any, keeps running undisturbed) and stops its workspace; the
    /// media and hold-off half reuses `stopStreaming(_:)`
    /// narrowed to this one surface.
    private func tearDownSurfaceLive(_ surface: CanvasSurfaceID) async {
        streamScaleSettleTask[surface]?.cancel()
        streamScaleSettleTask[surface] = nil
        await stopStreaming([surface])
        if didStartWorkspace[surface] {
            workspaces[surface].stop(owner: owner)
            didStartWorkspace[surface] = false
        }
    }

    /// Stops host-screen capture if it is running. Never releases the
    /// display -- there is no release call to make in the first place;
    /// `CanvasMediaStreaming.stop()` only ever stops the `SCStream` and the
    /// encoder, neither of which is a display-configuration operation.
    @discardableResult
    private func stopHostScreenStreaming() async -> Bool {
        guard isHostScreenStreaming else {
            return false
        }
        let surface = Self.hostScreenTelemetrySurface
        isHostScreenStreaming = false
        isStreaming[surface] = false
        // A stop signal this capture reports from here on names a capture
        // this coordinator has already deliberately let go of.
        hostScreenCaptureGeneration += 1
        await hostScreenMedia?.stop()
        hostScreenMedia = nil
        hostScreenStreamStartedAt = nil
        hostScreenEncodeBase = nil
        hostScreenLastKeepAwakeRedeclareAtSeconds = nil
        // The same per-surface reset a canvas stream's own stop performs:
        // what it streamed, the readings behind it and the hold-offs it
        // learned were all measurements of a capture that no longer exists.
        resetSurfaceState(after: [surface])
        return true
    }

    /// Sizes the encoder from the real display's own geometry, builds the
    /// media object through the injected factory, and starts it -- the
    /// host-screen counterpart to `startStreaming(on:canvasDisplayID:)`,
    /// with no `CanvasSurfaceID` to key by and no workspace to place.
    private func startHostScreenStreaming(geometry: SessionSurfaceGeometry) async throws {
        guard !isHostScreenStreaming else {
            return
        }
        guard let hostScreenMediaFactory else {
            throw HostScreenBringUpError.noMediaFactoryConfigured
        }
        guard let displayID = controller.hostScreenDisplayID else {
            throw HostScreenBringUpError.displayIDUnavailable
        }
        let sizing = hostScreenEncoderSizing(for: geometry)
        let media = hostScreenMediaFactory(sizing.configuration)
        hostScreenMedia = media
        isHostScreenStreaming = true
        try await beginHostScreenCapture(media: media, sizing: sizing, displayID: displayID)
    }

    /// How big this geometry may actually be encoded, saying so out loud
    /// when the display is larger than the encoder will take.
    private func hostScreenEncoderSizing(for geometry: SessionSurfaceGeometry) -> HostScreenEncoderSizing.Result {
        let sizing = HostScreenEncoderSizing.resolve(for: geometry)
        if sizing.wasClamped {
            // Loud, not silent: a real display's own logical size is being
            // held below what it actually is, and that is worth knowing
            // about the moment it happens, not discovered later as "why is
            // this softer than the display."
            onEvent?(String(
                format: "host-screen display %dx%d exceeds the hardware encoder\u{2019}s own limit; encoding %dx%d instead",
                geometry.logicalWidth,
                geometry.logicalHeight,
                sizing.configuration.encodeWidth,
                sizing.configuration.encodeHeight
            ))
        }
        return sizing
    }

    /// Starts one host-screen capture and wires its packets into this
    /// session's video path -- shared by a session's first capture and by
    /// every one that replaces it when the display's mode changes, so both
    /// report and meter identically.
    private func beginHostScreenCapture(
        media: any CanvasMediaStreaming,
        sizing: HostScreenEncoderSizing.Result,
        displayID: UInt32
    ) async throws {
        let videoSink = videoSink
        let focus = focus
        let flow = flow
        let onEvent = onEvent
        let producedBytes = producedBytes
        if hostScreenStreamStartedAt == nil {
            hostScreenStreamStartedAt = Date()
        }
        let startedAt = hostScreenStreamStartedAt!
        let telemetrySurface = Self.hostScreenTelemetrySurface
        // A capture replacing another one keeps the surface streaming: the
        // session did not end, so what it streams, its readings and the
        // controller's own hold-offs all still describe this screen on this
        // link.
        let isReplacingLiveCapture = isStreaming[telemetrySurface]
        isStreaming[telemetrySurface] = true
        hostScreenEncodeBase = (sizing.configuration.width, sizing.configuration.height)
        if !isReplacingLiveCapture {
            // The controller counts its scale steps down from what this
            // capture actually opened at, which for a display larger than the
            // hardware encoder accepts is already below its own native size.
            let openingScale = sizing.configuration.streamScale
            streamScale[telemetrySurface].markApplied(openingScale)
            fidelity[telemetrySurface].setRequestedScale(openingScale)
        }
        // Wired before `start`, so a capture that stops on its own the
        // instant it comes up is still caught. Bumped first: a stop signal
        // for the capture this replaces, however this one turns out, is
        // never this generation's problem.
        hostScreenCaptureGeneration += 1
        let generation = hostScreenCaptureGeneration
        media.setCaptureStoppedHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.hostScreenCaptureStoppedOnItsOwn(generation: generation)
            }
        }
        try await media.start(canvasDisplayID: displayID) { packet in
            let taken = videoSink.send(
                packet, surface: telemetrySurface, priority: focus.sendPriority(for: telemetrySurface)
            )
            // Payload plus codec configuration, exactly as the canvas path
            // counts them: a fidelity decision comparing what this host
            // produced against what the viewer says it received must not read
            // a healthy link as starved because the two counted differently.
            producedBytes.record(
                bytes: packet.payload.count + (packet.codecConfiguration?.count ?? 0),
                surface: telemetrySurface
            )
            if let report = flow.record(
                bytes: packet.payload.count,
                droppedFramesTotal: { videoSink.droppedVideoFrameCount },
                atSeconds: Date().timeIntervalSince(startedAt)
            ) {
                onEvent?(String(
                    format: "host-screen video %d frames in %.1fs (%.1f frames/s, %.2f Mbit/s), %d dropped to keep up",
                    report.frames,
                    report.seconds,
                    report.framesPerSecond,
                    report.megabitsPerSecond,
                    report.droppedFrames
                ))
            }
            return taken
        }
        onEvent?(String(
            format: "host-screen capture started on display %d: encoding %dx%d",
            displayID,
            sizing.configuration.encodeWidth,
            sizing.configuration.encodeHeight
        ))
        guard isReplacingLiveCapture else {
            return
        }
        // A capture that has just been built and started owes the same
        // warm-up a rebuilt canvas pipeline owes: its opening key frame and
        // every buffer filling for the first time are not the cost of what it
        // is about to stream steadily.
        latencyRecorder?.resetEncodeCheckpoint(for: telemetrySurface)
        fidelity[telemetrySurface].beginWarmUp()
    }
}


/// One tick's raw reading of a surface, before any of it is turned into a
/// rate. The counters are cumulative for the life of the stream, so a
/// decision is only ever made from the difference between two of these.
private struct FidelityReading {
    var counts: HostFrameCounts
    var sendQueueDropped: Int
    var producedBytes: Int
    /// `nil` from a video sink that does not count what it writes.
    var sentBytes: Int?
    var atSeconds: Double
}

/// What a capture-delivery report found, when what it found asks for
/// something.
private enum SilentCaptureResponse {
    case rebuild
    case giveUp
}

private struct CaptureDeliveryReading {
    var counts: HostFrameCounts
    var atSeconds: Double
}

/// Bytes per surface, written from whichever thread produced or sent them and
/// read on the main actor. Separate from `FlowBox` beside it, which is one
/// report for the whole connection: what the viewer says it received is only
/// meaningful against its own surface's figures.
final class SurfaceByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = [Int](repeating: 0, count: CanvasSurfaceID.capacity)

    func record(bytes count: Int, surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        bytes[surface.index] += count
    }

    func total(for surface: CanvasSurfaceID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes[surface.index]
    }
}

/// Shares one monitor between the encoder's callback thread and the coordinator.
private final class FlowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: MediaFlowMonitor

    init(reportSeconds: Double) {
        monitor = MediaFlowMonitor(reportInterval: reportSeconds)
    }

    /// The running drop total is read here rather than passed in, so the read
    /// and the subtraction that turns two of them into an interval happen
    /// under one lock. Both surfaces report through this one monitor, and two
    /// readings taken outside it can reach it in the other order.
    func record(bytes: Int, droppedFramesTotal: () -> Int, atSeconds now: Double) -> MediaFlowReport? {
        lock.lock()
        defer { lock.unlock() }
        return monitor.record(
            packetBytes: bytes,
            droppedFramesTotal: droppedFramesTotal(),
            atSeconds: now
        )
    }
}
