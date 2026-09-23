#if canImport(AppKit)
import SensoriumCore
import CoreVideo
import Foundation

/// What one control message says about the live "Displays" control's second
/// display -- see `ClientSessionRunner.secondDisplayOutcome(for:)`.
public enum SecondDisplayOutcome: Equatable, Sendable {
    case ready(displayID: UInt32, logicalWidth: Int, logicalHeight: Int, hostSignature: Data?)
    case refused(reason: String)
}

/// What one control message says about the session-time host-screen flow --
/// see `ClientSessionRunner.hostScreenOutcome(for:)`. Both are the host's
/// own unprompted offer (`docs/host-screen-design.md` §2.3): `.offered` its list, `.refused` its
/// answer when this machine is not armed for host screen at all.
public enum HostScreenOutcome: Equatable, Sendable {
    case offered(displays: [HostScreenListEntry], challenge: Data)
    case refused(reason: String)
}

/// What one control message says about the host screen's own display mode
/// -- see `ClientSessionRunner.hostScreenModeOutcome(for:)`. The host sends
/// `.list` unprompted and again after every change it applies, so the
/// viewer never asks for one.
public enum HostScreenModeOutcome: Equatable, Sendable {
    case list(modes: [HostScreenModeEntry], currentModeID: String)
    case applied(geometry: SessionSurfaceGeometry, currentModeID: String)
    case refused(reason: String)
}

/// The host screen's own lock and unlock traffic, host to viewer: whether the
/// screen is locked, and what one unlock attempt did.
public enum HostScreenUnlockInbound: Equatable, Sendable {
    case lockState(locked: Bool)
    case result(HostScreenUnlockOutcome)
    /// The host's single-use challenge, minted in reply to a submit's
    /// `hostScreenUnlockChallengeRequest`, to be signed by a live presence
    /// check before the arm.
    case challenge(challenge: Data)
}

/// Pulls packets off a live connection and feeds each kind to the right place:
/// video to the decoder behind the canvas gate, control to the session.
///
/// The loop itself needs a socket, so nothing here runs in verification. Every
/// decision it defers to — frame admission, canvas gating, coordinate mapping,
/// clock synchronisation, latency percentiles — is verified separately without
/// I/O.
@MainActor
public final class ClientSessionRunner {
    private let connection: NetworkControlConnection
    /// Verifies a live "Displays" reply's signature -- see
    /// `ClientSessionController.verifyLiveCanvasReady(...)`. This runner
    /// does not hold the identity or pinned host key that check needs; the
    /// actor that paired with this host already does.
    private let session: ClientSessionController
    private let primaryWindow: ClientCanvasWindowController
    /// `var`, unlike `primaryWindow`: docs/ux-spec.md's "Displays" control
    /// can attach or detach this live, at any point after `start()`, not
    /// only at construction -- see `attachSecondDisplay`/`detachSecondDisplay`.
    private var secondaryWindow: ClientCanvasWindowController?
    private let router = SurfaceFrameRouter()
    /// The submit-time presence-arm sequence and its one pending-challenge
    /// awaiter. Owned here because the challenge reply lands in this runner's
    /// receive loop; the flow correlates that reply back to the submission
    /// waiting for it.
    private let unlockArmFlow = HostScreenUnlockArmFlow()
    public let latency = SessionLatencyMonitor()
    private var receiveTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    /// `nil` for a runner built without clipboard sync, which neither polls
    /// this machine's pasteboard nor applies anything the host sends. Turning
    /// sharing off is the engine's own state, not a `nil` here.
    private let clipboard: ClipboardSyncSession?
    /// The machine this session is streaming from, as every other viewer surface
    /// names it -- threaded into the HUD's own telemetry snapshot so its
    /// sentences can name the machine instead of the generic word "host".
    private let hostName: String?
    /// This host's address and port exactly as dialled -- threaded into the
    /// HUD's own telemetry snapshot for its "ADDRESS" row.
    private let hostAddress: String?
    /// One sparkline trend per surface, per series, keyed by surface ID --
    /// `SessionHUDSnapshot`'s own `SessionHUDTrend` fields, kept here across
    /// ticks since the snapshot rebuilt every tick has nowhere else to carry
    /// history forward from.
    private var endToEndLatencyTrends: [UInt32: SessionHUDTrend] = [:]
    private var videoInBitrateTrends: [UInt32: SessionHUDTrend] = [:]
    private var fpsTrends: [UInt32: SessionHUDTrend] = [:]
    /// What each surface had given up as of the previous tick, kept for the
    /// same reason the trends above are: the snapshot is rebuilt every tick,
    /// so whether a total is still growing has nowhere else to come from.
    private var previousViewerDrops: [UInt32: (beforeDecode: Int, beforePresent: Int)] = [:]
    private var clipboardTask: Task<Void, Never>?
    private var onEnded: (@Sendable (String) -> Void)?
    /// The pure staleness/availability state behind the telemetry overlay;
    /// see `SessionTelemetryTracker`. `ClientSessionRunner` only feeds it and
    /// pushes what it decides to each window -- it makes no display decision
    /// of its own.
    private var telemetryTracker = SessionTelemetryTracker()
    private var telemetryRefreshTask: Task<Void, Never>?
    /// The viewer's own view of what arrived: bytes counted in the receive
    /// loop and the dimensions of frames that actually decoded. Nothing else
    /// on the viewer counted a byte, and the host's Mbit/s is the host's
    /// number, not the viewer's.
    private let streamStatistics = ClientStreamStatistics()
    /// Builds the reading this viewer sends back about its own end of the
    /// wire. The host measures its own stages and can see none of these.
    private var viewerTelemetry = ViewerTelemetryBuilder()
    /// The host's own offer, kept from `.hostScreenList`: sent unprompted,
    /// once authenticated, to a machine armed for host screen.
    /// The Screen menu reads this on every open, the same lazy pull
    /// `displayCountMenuState` already uses elsewhere, so no separate
    /// "offer arrived" callback exists for it.
    public private(set) var hostScreenDisplays: [HostScreenListEntry] = []

    /// Fast at first so a session has an offset within a second, then slow
    /// enough to stay off the control path once it does.
    private static let clockSyncWarmupInterval = Duration.milliseconds(200)
    private static let clockSyncWarmupCount = 5
    private static let clockSyncInterval = Duration.seconds(10)
    /// The one surface `displayCount` ever names -- see
    /// `ClientSessionController.secondarySurfaceID`, which this mirrors
    /// rather than imports: that constant is private to an actor with no
    /// reason to expose a UInt32 literal as its own API surface.
    private nonisolated static let secondarySurfaceID: UInt32 = 1

    /// `secondaryWindow` is `nil` whenever this session opened only the
    /// primary canvas — the hard cap is two, and `SurfaceFrameRouter` never
    /// grows past the slot a caller registers here.
    public init(
        connection: NetworkControlConnection,
        session: ClientSessionController,
        window: ClientCanvasWindowController,
        secondaryWindow: ClientCanvasWindowController? = nil,
        clipboard: ClipboardSyncSession? = nil,
        hostName: String? = nil,
        hostAddress: String? = nil
    ) {
        self.connection = connection
        self.session = session
        self.primaryWindow = window
        self.secondaryWindow = secondaryWindow
        self.clipboard = clipboard
        self.hostName = hostName
        self.hostAddress = hostAddress
        router.setWindow(window, atSurfaceID: 0)
        router.setVideoSink(window.videoSink, atSurfaceID: 0)
        if let secondaryWindow {
            router.setWindow(secondaryWindow, atSurfaceID: 1)
            router.setVideoSink(secondaryWindow.videoSink, atSurfaceID: 1)
        }
    }

    /// docs/ux-spec.md's "Displays" control: sends the viewer's own live
    /// choice. The reply -- if the host answers at all; a decrease or a
    /// request that already matches the current state gets none -- arrives
    /// through the same receive loop as everything else and is reported
    /// through `onSecondDisplayReady`/`onSecondDisplayRefused` below, never
    /// returned here: this call cannot know the outcome before whatever
    /// packet carries it arrives, or before deciding none ever will.
    public func setDisplayCount(_ count: Int) async {
        try? await connection.send(.control(.displayCount(count)))
    }

    /// docs/ux-spec.md's "Clipboard" control: flips the local pasteboard
    /// engine that already implements on/off
    /// (`ClipboardSyncSession.setEnabled(_:)`) and
    /// sends the viewer's own choice. No reply is expected, so, like a
    /// "Displays" decrease, the caller's own choice is the only signal there
    /// ever is.
    /// A `nil` `clipboard` (sync was never constructed for this run) has no
    /// local engine to flip, but the wire message is still sent: the host's
    /// own state and this machine's engine are separate facts.
    public func setClipboardSharing(enabled: Bool) async {
        clipboard?.setEnabled(enabled)
        try? await connection.send(.control(.clipboardSharing(enabled: enabled)))
    }

    /// The live reply to a "Displays" increase that succeeded: the second
    /// display's own geometry, already verified
    /// (`ClientSessionController.verifyLiveCanvasReady`) by the time this
    /// fires.
    public var onSecondDisplayReady: ((_ displayID: UInt32, _ logicalWidth: Int, _ logicalHeight: Int) -> Void)?
    /// The live reply to an increase the host refused, in the host's own
    /// words -- docs/ux-spec.md: "a refusal must be said in the window in
    /// plain words with its reason, not logged."
    public var onSecondDisplayRefused: ((_ reason: String) -> Void)?

    /// The host screen's own display modes, and which one it is on. Fires
    /// whenever the host says so: once right after the session goes live,
    /// and again after every change it applies.
    public var onHostScreenModeList: ((_ modes: [HostScreenModeEntry], _ currentModeID: String) -> Void)?
    /// A change the host applied: the geometry the host screen now has, to
    /// be taken exactly as `hostScreenReady`'s own geometry is.
    public var onHostScreenModeApplied: ((_ geometry: SessionSurfaceGeometry, _ currentModeID: String) -> Void)?
    /// A change the host refused, in the host's own reason. The session is
    /// untouched: only this one request was refused.
    public var onHostScreenModeRefused: ((_ reason: String) -> Void)?

    /// The host's report of whether its screen is locked, sent unprompted on
    /// host-screen bring-up and again after every unlock attempt. Drives
    /// whether the viewer offers the unlock prompt.
    public var onHostScreenLockState: ((_ locked: Bool) -> Void)?
    /// The host's answer to an unlock request: what the attempt did. Drives the
    /// brief success or failure notice the viewer shows.
    public var onHostScreenUnlockResult: ((_ outcome: HostScreenUnlockOutcome) -> Void)?
    /// The host did not share a clipboard, its own copy or this machine's,
    /// and says why. Never ends the session.
    public var onClipboardRefused: ((ClipboardRefusal) -> Void)?

    /// The Resolution submenu's own action: asks the host to set the screen
    /// it is streaming to one of the modes it offered. The answer -- applied
    /// or refused -- arrives through the receive loop like everything else,
    /// never returned here.
    public func requestHostScreenMode(_ modeID: String) async {
        try? await connection.send(.control(.hostScreenModeRequest(modeID: modeID)))
    }

    /// Runs the submit-time unlock sequence -- request a single-use challenge,
    /// sign that exact challenge with a live presence check, arm, then send the
    /// unlock request -- and reports what it did. Triggered only when a person
    /// confirms the unlock with a password, never when the prompt appears, so an
    /// always-on headless host hitting its lock timer never provokes a presence
    /// prompt on its own. The host's spoken answer (unlocked, wrong password,
    /// still `.presenceRequired`) still arrives through the receive loop.
    ///
    /// The password is raw UTF-8 bytes so nothing here holds a `String` copy of
    /// it; the returned result is what the submit did, not that host answer, so
    /// the caller can say why a fail-closed abort sent nothing rather than leave
    /// the cleared field looking ignored.
    public func requestHostScreenUnlock(password: Data) async -> HostScreenUnlockSubmitResult {
        await unlockArmFlow.run(
            password: password,
            send: { message in try await self.connection.send(.control(message)) },
            sign: { challenge in try await self.session.signUnlockChallenge(challenge) }
        )
    }

    /// The host screen's own lock and unlock traffic, classified for the same
    /// reason `hostScreenModeOutcome(for:)` is: verifiable without the live
    /// connection and windows the receive loop needs.
    public nonisolated static func hostScreenUnlockInbound(for message: SensoriumMessage) -> HostScreenUnlockInbound? {
        switch message {
        case let .hostScreenLockState(locked):
            return .lockState(locked: locked)
        case let .hostScreenUnlockResult(outcome):
            return .result(outcome)
        case let .hostScreenUnlockChallenge(challenge):
            return .challenge(challenge: challenge)
        default:
            return nil
        }
    }

    /// The host's own unprompted offer, on the canvas connection -- design
    /// §2.3. Fires every time `hostScreenDisplays` is updated, so the Screen
    /// menu (built by whoever owns this runner, off a window that cannot
    /// reach across to a live actor synchronously) can be pushed a fresh
    /// state the same way `onSecondDisplayReady` already pushes one.
    public var onHostScreenOffered: ((_ displays: [HostScreenListEntry]) -> Void)?

    /// A person at the host ended this session from that machine. Fires
    /// before `onEnded`, so whoever owns this runner knows which kind of
    /// ending it is reading and does not redial into a session somebody just
    /// stopped.
    public var onStoppedByHost: (() -> Void)?

    /// The host ended this session for a reason it named, and the reason is
    /// one this version has words for. Fires before `onEnded`, for the same
    /// reason `onStoppedByHost` above does: an ending with a cause must not
    /// be shown as the dropped link it otherwise looks exactly like.
    public var onHostEnded: ((ViewerSessionFailure) -> Void)?

    /// Attaches a window this runner did not construct to a live second
    /// display -- the "Displays" menu's own increase, live, mid-session.
    /// Window construction needs AppKit-level dependencies (the menu, the
    /// shortcut forwarder, the saved-host store) this runner does not hold;
    /// building it is `ClientSessionHost`'s job in `Sensorium/main.swift`,
    /// the same as it already is for the primary window.
    public func attachSecondDisplay(_ window: ClientCanvasWindowController) async throws {
        secondaryWindow = window
        router.setWindow(window, atSurfaceID: 1)
        router.setVideoSink(window.videoSink, atSurfaceID: 1)
        if clipboard != nil {
            window.onDidBecomeKey = { [weak self] in self?.pollClipboardNow() }
        }
        try window.startDecoding(latency: latency) { [streamStatistics] frame in
            streamStatistics.recordDecodedFrame(
                surfaceID: 1,
                pixelWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        }
    }

    /// The live counterpart to a "Displays" decrease: stops surface 1's own
    /// decode session and unregisters its window from the router, mirroring
    /// what `teardown()` already does for every surface at session end,
    /// scoped to just this one. Returns the detached window, if there was
    /// one, so whoever owns its visible lifecycle (closing it, forgetting
    /// it) can act -- this runner decides nothing about that, the same
    /// boundary `videoRouting(for:)`'s own documentation already states.
    @discardableResult
    public func detachSecondDisplay() -> ClientCanvasWindowController? {
        guard let window = secondaryWindow else { return nil }
        window.stopDecoding()
        window.onDidBecomeKey = nil
        secondaryWindow = nil
        router.setWindow(nil, atSurfaceID: 1)
        router.setVideoSink(nil, atSurfaceID: 1)
        return window
    }

    /// Fires when the stream ends for any reason, including the host vanishing.
    /// Without it a dead host looks exactly like an idle one.
    ///
    /// `onDecodedFrame` is an observation seam for tests that need the real
    /// decoded pixel buffer (e.g. to confirm a resolution change actually took
    /// effect) without adding that concern to `SessionLatencyMonitor`. It is
    /// declared after `onEnded`, not before: Swift 6 matches an unlabeled
    /// trailing closure to the first parameter of function type, and the
    /// existing call site passes `onEnded` that way — putting a second
    /// closure parameter ahead of it would silently rebind that trailing
    /// closure to the wrong callback instead of failing to compile.
    public func start(
        onEnded: (@Sendable (String) -> Void)? = nil,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? = nil
    ) throws {
        self.onEnded = onEnded
        let statistics = streamStatistics
        // Wrapping rather than replacing the caller's seam: the resolution
        // the HUD shows must be the decoded frame's own, not a size derived
        // from a scale the host reported.
        try primaryWindow.startDecoding(latency: latency) { frame in
            statistics.recordDecodedFrame(
                surfaceID: 0,
                pixelWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            onDecodedFrame?(frame)
        }
        try secondaryWindow?.startDecoding(latency: latency) { frame in
            statistics.recordDecodedFrame(
                surfaceID: 1,
                pixelWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        }
        // Detached, not a child of whatever started this session: reading the
        // socket must not be scheduled behind the main actor's own work.
        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.receiveLoop()
        }
        // Armed here, not any earlier: pairing's retyped-digit wait and this
        // connection's own pre-live handshake can both sit silent on
        // purpose, bounded by their own timeouts. From here on the host is
        // expected to answer clock sync on its own schedule below.
        connection.beginHostSilenceWatch()
        clockTask = Task { [weak self] in
            await self?.clockSyncLoop()
        }
        if clipboard != nil {
            clipboardTask = Task { [weak self] in
                await self?.clipboardPollLoop()
            }
            primaryWindow.onDidBecomeKey = { [weak self] in self?.pollClipboardNow() }
            secondaryWindow?.onDidBecomeKey = { [weak self] in self?.pollClipboardNow() }
        }
        telemetryRefreshTask = Task { [weak self] in
            await self?.telemetryRefreshLoop()
        }
    }

    public func stop() {
        onEnded = nil
        connection.endHostSilenceWatch()
        receiveTask?.cancel()
        receiveTask = nil
        clockTask?.cancel()
        clockTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        primaryWindow.onDidBecomeKey = nil
        secondaryWindow?.onDidBecomeKey = nil
        telemetryRefreshTask?.cancel()
        telemetryRefreshTask = nil
        // Fire-and-forget: `stop()` is not `async`, and nothing here observes exactly when teardown
        // finishes — it only resets local decoder state on each window.
        let router = router
        Task { @MainActor in
            await router.teardown()
        }
    }

    public func latencySummary() async -> String? {
        // Read from the windows' own counters here rather than pushed from the
        // decode path: a frame is given up on a thread that cannot await an
        // actor, and this is the one place the total is reported.
        await latency.setDroppedAtViewerCount(router.droppedFrameCount())
        return await latency.summaryLine()
    }

    /// Polls this machine's pasteboard now rather than at the next interval,
    /// and puts anything to send on the connection before returning. Run the
    /// moment a session window takes key focus, so a copy made in another app
    /// goes out ahead of any keystroke sent after that: without it, Command-V
    /// typed after switching back could paste the host's old clipboard.
    public func pollClipboardNow() {
        guard let packet = clipboard?.poll() else {
            return
        }
        connection.enqueue(packet)
    }

    /// macOS has no pasteboard-change notification, so a local copy is found
    /// by polling `changeCount`; `ClipboardSyncSession` decides whether
    /// anything actually changed and whether it may be sent. A send failure is
    /// left to the receive loop to report — unlike clock sync, a clipboard is
    /// not evidence about whether the session is alive.
    private func clipboardPollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds))
            } catch {
                return
            }
            guard let packet = clipboard?.poll() else {
                continue
            }
            try? await connection.send(packet)
        }
    }

    private func clockSyncLoop() async {
        var sent = 0
        while !Task.isCancelled {
            let request = await latency.makeClockRequest(
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
            do {
                try await connection.send(request)
            } catch {
                // A send failure is transport loss; ending only this loop
                // would leave the session looking alive while nothing flows.
                onEnded?("clock-sync send failed: \(error)")
                return
            }
            sent += 1
            let interval = sent < Self.clockSyncWarmupCount
                ? Self.clockSyncWarmupInterval
                : Self.clockSyncInterval
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    /// Ticks independently of whether new telemetry arrived, which is the
    /// only way a reading that stopped arriving is ever shown as stale: a
    /// display that only updates on receipt would otherwise freeze on the
    /// last good number forever once the host stops sending.
    private func telemetryRefreshLoop() async {
        while !Task.isCancelled {
            let nowNanoseconds = MonotonicClock.nowNanoseconds()
            await refreshTelemetryDisplay(nowNanoseconds: nowNanoseconds)
            await sendViewerTelemetry(nowNanoseconds: nowNanoseconds)
            do {
                try await Task.sleep(for: .seconds(TelemetryPolicy.sendIntervalSeconds))
            } catch {
                return
            }
        }
    }

    /// Recomputes and pushes both surfaces' telemetry display. Cheap and
    /// idempotent to call on every tick and every receive: `router.updateTelemetry`
    /// is a no-op for a surface with no registered window.
    private func refreshTelemetryDisplay(nowNanoseconds: Int64) async {
        for surfaceID: UInt32 in [0, 1] {
            let availability = telemetryTracker.availability(surfaceID: surfaceID, nowNanoseconds: nowNanoseconds)
            let clientMetrics = await latency.metrics(forSurfaceID: surfaceID)
            let isAttentionWorthy = TelemetryAttentionThreshold.isAttentionWorthy(
                availability: availability,
                clientEndToEndP50Nanoseconds: clientMetrics.samples(for: .endToEnd).p50
            )
            let viewport = viewport(forSurfaceID: surfaceID)
            let stream = streamStatistics.reading(surfaceID: surfaceID, atNanoseconds: nowNanoseconds)

            // One append per tick per series, oldest-first like the buffer
            // itself -- a reading this tick never sent (`nil`) leaves the
            // trend exactly where it was rather than plotting a fabricated
            // point.
            var endToEndLatencyTrend = endToEndLatencyTrends[surfaceID] ?? SessionHUDTrend()
            if let endToEndP50 = clientMetrics.samples(for: .endToEnd).p50 {
                endToEndLatencyTrend.append(Double(endToEndP50) / 1_000_000)
            }
            endToEndLatencyTrends[surfaceID] = endToEndLatencyTrend

            var videoInBitrateTrend = videoInBitrateTrends[surfaceID] ?? SessionHUDTrend()
            if let bitsPerSecond = stream.bitsPerSecond {
                videoInBitrateTrend.append(bitsPerSecond)
            }
            videoInBitrateTrends[surfaceID] = videoInBitrateTrend

            var fpsTrend = fpsTrends[surfaceID] ?? SessionHUDTrend()
            if let framesPerSecond = hostSample(availability)?.framesPerSecond {
                fpsTrend.append(framesPerSecond)
            }
            fpsTrends[surfaceID] = fpsTrend

            let droppedBeforeDecode = router.droppedBeforeDecodeCount(surfaceID: surfaceID)
            let droppedBeforePresent = router.droppedBeforePresentCount(surfaceID: surfaceID)
            // The first tick has no previous one to have grown from, and a
            // window that kept counting across a reconnect would otherwise
            // look like it had just skipped everything it ever skipped.
            let viewerDropsGrew = previousViewerDrops[surfaceID].map {
                droppedBeforeDecode > $0.beforeDecode || droppedBeforePresent > $0.beforePresent
            } ?? false
            previousViewerDrops[surfaceID] = (droppedBeforeDecode, droppedBeforePresent)

            let snapshot = SessionHUDSnapshot(
                surfaceID: surfaceID,
                availability: availability,
                clientMetrics: clientMetrics,
                stream: stream,
                requestedStreamScale: await viewport?.requestedStreamScale,
                requestedDrawablePixelWidth: await viewport?.requestedDrawablePixelWidth,
                requestedDrawablePixelHeight: await viewport?.requestedDrawablePixelHeight,
                streamScalePreference: await viewport?.currentStreamScalePreference ?? .automatic,
                decoder: router.decoderHardwareAcceleration(surfaceID: surfaceID),
                isAttentionWorthy: isAttentionWorthy,
                isPointerCaptured: router.isPointerCaptured(surfaceID: surfaceID),
                presentCompletionP50Nanoseconds: router.presentCompletionLatency(surfaceID: surfaceID).p50,
                presentationHoldNanoseconds: router.presentationHoldNanoseconds(surfaceID: surfaceID),
                hostName: hostName,
                hostAddress: hostAddress,
                endToEndLatencyTrend: endToEndLatencyTrend,
                videoInBitrateTrend: videoInBitrateTrend,
                fpsTrend: fpsTrend,
                viewerDroppedBeforeDecode: droppedBeforeDecode,
                viewerDroppedBeforePresent: droppedBeforePresent,
                viewerDropsGrew: viewerDropsGrew
            )
            router.updateSessionHUD(surfaceID: surfaceID, snapshot: snapshot)
        }
    }

    /// One reading per open canvas, once per tick, on the same schedule and
    /// from the same instant as the display refresh above -- the host's own
    /// telemetry cadence, so the two ends of one session are describing the
    /// same second rather than two drifting ones.
    ///
    /// A send failure is ignored rather than reported as session loss. Unlike
    /// clock sync, a reading that did not go out is not evidence the session
    /// is dead, and the host already treats a reading that stopped arriving
    /// as no reading at all.
    private func sendViewerTelemetry(nowNanoseconds: Int64) async {
        // Only canvases that exist. A permanently empty second reading would
        // cost a message a second and tell the host nothing it does not
        // already know from the absence of one.
        let surfaceIDs: [UInt32] = secondaryWindow == nil ? [0] : [0, Self.secondarySurfaceID]
        for surfaceID in surfaceIDs {
            let metrics = await latency.metrics(forSurfaceID: surfaceID)
            let sample = viewerTelemetry.sample(
                surfaceID: surfaceID,
                metrics: metrics,
                stream: streamStatistics.reading(surfaceID: surfaceID, atNanoseconds: nowNanoseconds),
                // Every presented frame records this stage, so its lifetime
                // count is how many frames this canvas has actually put on
                // screen -- the builder turns two of them into a rate.
                presentedFrameCount: metrics.samples(for: .present).count,
                atNanoseconds: nowNanoseconds
            )
            try? await connection.send(.control(.viewerTelemetry(sample)))
        }
    }

    /// The window's viewport owns what this viewer asked the host for and
    /// this canvas's own stream-scale choice; neither is on the wire in this
    /// direction.
    private func viewport(forSurfaceID surfaceID: UInt32) -> ClientViewportController? {
        switch surfaceID {
        case 0: return primaryWindow.canvasObserver()
        case 1: return secondaryWindow?.canvasObserver()
        default: return nil
        }
    }

    /// The host's own reading behind an availability case, if it has one --
    /// `SessionHUDPanel.hostSample`'s own logic, needed here too since the
    /// host's frame rate has nowhere else to be read from for the FPS trend.
    private func hostSample(_ availability: SurfaceTelemetryAvailability) -> SurfaceTelemetrySample? {
        switch availability {
        case .unavailable: return nil
        case let .fresh(sample), let .stale(sample): return sample
        }
    }


    /// Which surface a video packet belongs to, as `ReceivedVideoDispatch`
    /// decides it. Named here too because this is where a reader of the
    /// receive loop looks for it, and because the loop needs a live connection
    /// and AppKit windows while the mapping itself needs neither.
    ///
    /// A surface with no registered window (surface 1 whenever this session
    /// opened only the primary canvas) is still admitted into its own ingress
    /// by `SurfaceFrameRouter`, but `route` returns before ever handing a frame
    /// to a decoder, so those frames are never decoded at all.
    public nonisolated static func videoRouting(
        for packet: SensoriumTransportPacket
    ) -> (surfaceID: UInt32, frame: EncodedVideoFramePacket)? {
        ReceivedVideoDispatch.routing(for: packet)
    }

    /// The live "Displays" control's own reply, if `message` is one --
    /// pulled out for the same reason `videoRouting(for:)` is: verifiable
    /// without the live connection and windows the receive loop itself
    /// needs. Surface 0's own `canvasReady`/`canvasRefused` belong to
    /// `connect()`, read before this loop ever starts; matching only
    /// `secondarySurfaceID` here is what keeps one from being misread as
    /// the other if either somehow arrived twice.
    public nonisolated static func secondDisplayOutcome(for message: SensoriumMessage) -> SecondDisplayOutcome? {
        if case let .canvasReady(displayID, logicalWidth, logicalHeight, hostSignature, surfaceID, _) = message,
           surfaceID == secondarySurfaceID {
            return .ready(displayID: displayID, logicalWidth: logicalWidth, logicalHeight: logicalHeight, hostSignature: hostSignature)
        }
        if case let .canvasRefused(reason, surfaceID) = message, surfaceID == secondarySurfaceID {
            return .refused(reason: reason)
        }
        return nil
    }

    /// The session-time host-screen flow's own classification, pulled out
    /// for the same reason `secondDisplayOutcome(for:)` above is: verifiable
    /// without the live connection and windows the receive loop needs.
    public nonisolated static func hostScreenOutcome(for message: SensoriumMessage) -> HostScreenOutcome? {
        switch message {
        case let .hostScreenList(displays, challenge):
            return .offered(displays: displays, challenge: challenge)
        case let .hostScreenRefused(reason):
            return .refused(reason: reason)
        default:
            return nil
        }
    }

    /// Whether this message is the host saying a person there ended the
    /// session, rather than the ordinary ending a dropped transport looks
    /// exactly like from here. Pulled out for the same reason
    /// `hostScreenOutcome(for:)` above is: verifiable without a live
    /// connection.
    public nonisolated static func isStoppedByHost(_ message: SensoriumMessage) -> Bool {
        guard case let .goodbye(reason) = message else {
            return false
        }
        return reason == GoodbyeReason.stoppedByHost
    }

    /// The other endings a host names on its way out, classified for the
    /// same reason `isStoppedByHost(_:)` above is: verifiable without a live
    /// connection. `nil` for everything else, including a person at the host
    /// pressing Stop, which has its own ending already, and including a
    /// reason this version has never seen -- a token nobody here knows is
    /// left to read as the dropped link it arrives as, rather than dressed
    /// up in a cause this version invented for it.
    public nonisolated static func hostEnding(for message: SensoriumMessage) -> ViewerSessionFailure? {
        guard case let .goodbye(reason) = message else {
            return nil
        }
        switch reason {
        case GoodbyeReason.hostDisplaysAsleep:
            return .hostDisplaysAsleep
        case GoodbyeReason.captureUnavailable:
            return .hostCaptureUnavailable
        default:
            return nil
        }
    }

    /// The host screen's own display-mode traffic, classified for the same
    /// reason `hostScreenOutcome(for:)` above is: verifiable without the
    /// live connection and windows the receive loop needs.
    public nonisolated static func hostScreenModeOutcome(for message: SensoriumMessage) -> HostScreenModeOutcome? {
        switch message {
        case let .hostScreenModeList(modes, currentModeID):
            return .list(modes: modes, currentModeID: currentModeID)
        case let .hostScreenModeApplied(geometry, currentModeID):
            return .applied(geometry: geometry, currentModeID: currentModeID)
        case let .hostScreenModeRefused(reason):
            return .refused(reason: reason)
        default:
            return nil
        }
    }

    /// The host's report that it did not share a clipboard, classified for
    /// the same reason `hostScreenOutcome(for:)` above is: verifiable without
    /// a live connection.
    public nonisolated static func clipboardRefusal(for message: SensoriumMessage) -> ClipboardRefusal? {
        guard case let .clipboardRefused(refusal) = message else {
            return nil
        }
        return refusal
    }

    /// Nonisolated, and started on a task of its own, because the main actor is
    /// where this viewer draws, lays out its chrome and handles input. A packet
    /// that had to wait for all of that would arrive in a burst with the
    /// packets behind it, and a burst is what makes a viewer give up frames it
    /// could have decoded in a few milliseconds each.
    ///
    /// Video takes no main-actor step at all: `ReceivedVideoDispatch` counts it
    /// and hands it to the surface's own decoder, both of which are safe from
    /// any thread. Control messages still hop to the main actor, where the
    /// session state they change lives; they are rare and none of them is a
    /// frame.
    private nonisolated func receiveLoop() async {
        let video = ReceivedVideoDispatch(statistics: streamStatistics, router: router)
        while !Task.isCancelled {
            do {
                let packet = try await connection.receivePacket()
                let receivedAt = MonotonicClock.nowNanoseconds()
                switch packet {
                case .video, .videoForSurface:
                    try await video.dispatch(packet, receivedAtNanoseconds: receivedAt)
                case let .control(message):
                    if await handleControlMessage(message, receivedAtNanoseconds: receivedAt) {
                        return
                    }
                case let .clipboard(content):
                    await applyClipboard(content)
                case .unrecognized:
                    // A machine running a newer protocol sent a tag this build
                    // doesn't know. The frame's length prefix already let the
                    // codec skip its bytes cleanly; drop it and keep going
                    // rather than ending the session over it.
                    continue
                }
            } catch {
                await reportEnded("\(error)")
                return
            }
        }
    }

    /// Everything one control message changes, on the actor that owns it.
    /// Returns whether this session is over, which is the one thing the receive
    /// loop itself has to act on.
    private func handleControlMessage(_ message: SensoriumMessage, receivedAtNanoseconds receivedAt: Int64) async -> Bool {
        if case let .timeSyncReply(clientTime, hostTime) = message {
            await latency.receiveClockReply(
                clientTimeNanoseconds: clientTime,
                hostTimeNanoseconds: hostTime,
                receivedAtNanoseconds: receivedAt
            )
        }
        if case let .inputApplied(sequence) = message {
            if let sentAtNanoseconds = await session.resolvePendingInputSend(sequence: sequence) {
                await latency.recordInputRoundTrip(
                    sentAtNanoseconds: sentAtNanoseconds,
                    repliedAtNanoseconds: receivedAt
                )
            }
        }
        if case let .telemetry(surfaces) = message {
            telemetryTracker.receive(surfaces: surfaces, atNanoseconds: receivedAt)
            await refreshTelemetryDisplay(nowNanoseconds: receivedAt)
        }
        // The live "Displays" control's own reply. Surface 0's
        // canvasReady/canvasRefused belong to `connect()`, read
        // there before this loop ever starts -- `secondDisplayOutcome`
        // matches only `secondarySurfaceID`, so neither is
        // misread as this one if either somehow arrived twice.
        switch Self.secondDisplayOutcome(for: message) {
        case let .ready(displayID, logicalWidth, logicalHeight, hostSignature):
            do {
                try await session.verifyLiveCanvasReady(
                    displayID: displayID,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    hostSignature: hostSignature,
                    surfaceID: Self.secondarySurfaceID
                )
                onSecondDisplayReady?(displayID, logicalWidth, logicalHeight)
            } catch {
                // An unverifiable reply is the same class of
                // problem an unverifiable primary canvasReady
                // is: not a request to show words about, a
                // reason to stop trusting this connection.
                onEnded?("second display reply failed verification: \(error)")
                return true
            }
        case let .refused(reason):
            onSecondDisplayRefused?(reason)
        case nil:
            break
        }
        // A person at the host pressed Stop. Reported as its
        // own ending, not as the dropped transport that arrives
        // in the same shape, because this one must never be
        // redialled.
        if Self.isStoppedByHost(message) {
            onStoppedByHost?()
            onEnded?("a person at the host ended this session")
            return true
        }
        // An ending the host gave a cause for. Reported as its own ending
        // for the same reason Stop is: the viewer would otherwise show the
        // dropped link this arrives as and say nothing about why.
        if let ending = Self.hostEnding(for: message) {
            onHostEnded?(ending)
            onEnded?("the host ended this session")
            return true
        }
        // The host's own unprompted offer, on the canvas
        // connection this runner already holds.
        // A refusal here (machine not armed) ends the whole
        // session. `onEnded` here only reaches a console log,
        // never a window -- the live host-screen-refused path a
        // person actually sees goes through
        // `ViewerSessionFailureCopy`.
        switch Self.hostScreenOutcome(for: message) {
        case let .offered(displays, _):
            hostScreenDisplays = displays
            onHostScreenOffered?(displays)
        case let .refused(reason):
            onEnded?(HostScreenRefusalCopy.line(reason: reason))
            return true
        case nil:
            break
        }
        // The host screen's own display mode. None of these
        // ends a session, including the refusal: the picture
        // keeps arriving at whatever mode the screen is on.
        switch Self.hostScreenModeOutcome(for: message) {
        case let .list(modes, currentModeID):
            onHostScreenModeList?(modes, currentModeID)
        case let .applied(geometry, currentModeID):
            // Moves the bound `sendInput` enforces before the
            // callback below moves whichever mapper a viewer or
            // probe keeps, so neither can read this event and end
            // up disagreeing with the other about where the
            // display's edge now is.
            await session.hostScreenModeDidApply(geometry: geometry)
            onHostScreenModeApplied?(geometry, currentModeID)
        case let .refused(reason):
            onHostScreenModeRefused?(reason)
        case nil:
            break
        }
        if let refusal = Self.clipboardRefusal(for: message) {
            onClipboardRefused?(refusal)
        }
        // The host screen's lock state and unlock answers. None ends a
        // session: an unlock is a control on a live host-screen session, not a
        // reason to drop one.
        switch Self.hostScreenUnlockInbound(for: message) {
        case let .lockState(locked):
            onHostScreenLockState?(locked)
        case let .result(outcome):
            onHostScreenUnlockResult?(outcome)
        case let .challenge(challenge):
            // Correlated back to the one unlock submission waiting for it; a
            // challenge with none waiting (late, duplicate, or unsolicited) is
            // ignored inside the flow.
            unlockArmFlow.deliverChallenge(challenge)
        case nil:
            break
        }
        return false
    }

    /// Session-scoped, not surface-scoped: one pasteboard per machine however
    /// many canvases this session opened, and the pasteboard belongs to the
    /// main actor.
    private func applyClipboard(_ content: ClipboardContent) {
        clipboard?.receive(content)
    }

    /// Reports the session's ending from the receive loop, which no longer runs
    /// on the actor the callback belongs to.
    private func reportEnded(_ reason: String) {
        // A submission still waiting for a challenge on a connection that just
        // dropped is resolved as a failure now, rather than left to wait out
        // the full challenge timeout.
        unlockArmFlow.abandonPendingUnlock()
        onEnded?(reason)
    }
}
#endif
