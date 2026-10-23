import Foundation
import SensoriumClient
import SensoriumCore

#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec) && canImport(COpenSSL)

/// The two verbs that open a real window on this machine.
///
/// `view` dials a paired host and shows what it streams. `view-selftest`
/// opens the same window with no host at all and presents one frame this
/// process drew for itself, which is the only check available on a machine
/// with nothing to dial.
///
/// Both take over the process: the window, the compositor connection and the
/// GL context all belong to the event loop's thread, and that thread is this
/// one. Neither returns.
enum ViewVerbs {
    /// The verbs this file owns, taken straight from the command line.
    ///
    /// Called before anything in this process has awaited, because that is
    /// the only moment the event loop can still take over the main queue --
    /// see `GLibMainLoop`. Anything else is left to the rest of the probe.
    @MainActor
    static func dispatchIfRequested() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        // Captured-pointer mode and clipboard sharing are asked for by flag
        // rather than by position, so the seconds argument keeps the place it
        // has always had.
        let capturesPointer = arguments.contains("--capture")
        let sharesClipboard = arguments.contains("--clipboard")
        let clipboardRoundtrip = arguments.contains("--clipboard-roundtrip")
        let diagnosticsWheel = arguments.contains("--diagnostics-wheel")
        // What the viewer's own `--trace` asks of a session window: say what
        // the first real draw found, for a run diagnosing a picture that is
        // not on screen.
        let tracesPresentation = arguments.contains("--trace")
        // Streams the host's offered screen rather than a session canvas,
        // which a host only creates when its owner has offered one.
        let streamsHostScreen = arguments.contains("--host-screen")
        // Benchmark runs: `--pointer-plan` drives synthetic pointer motion on
        // a schedule, and `--no-interaction-release` leaves the presenter
        // unaware of input so the two pacing behaviours can be compared.
        let releasesOnInteraction = !arguments.contains("--no-interaction-release")
        var pointerPlan: BenchmarkPointerPlan?
        if let flagIndex = arguments.firstIndex(of: "--pointer-plan") {
            guard flagIndex + 1 < arguments.count,
                  let plan = BenchmarkPointerPlan(parsing: arguments[flagIndex + 1]) else {
                say("usage: --pointer-plan move:<seconds>|still:<seconds>[,...], for example move:20,still:40,move:20")
                exit(2)
            }
            pointerPlan = plan
            arguments.remove(at: flagIndex + 1)
            arguments.remove(at: flagIndex)
        }
        arguments.removeAll {
            $0 == "--capture" || $0 == "--clipboard" || $0 == "--clipboard-roundtrip" || $0 == "--trace"
                || $0 == "--host-screen" || $0 == "--no-interaction-release"
        }
        switch arguments.first {
        case "view":
            guard arguments.count == 3 || arguments.count == 4, let port = UInt16(arguments[2]) else {
                say("usage: SensoriumViewerProbe view <host> <port> [seconds] [--capture] [--clipboard] [--trace] [--host-screen] [--pointer-plan <spec>] [--no-interaction-release]")
                exit(2)
            }
            let host = arguments[1]
            let seconds = arguments.count == 4 ? Int(arguments[3]) : nil
            takeOverTheProcess {
                await view(
                    host: host,
                    port: port,
                    seconds: seconds,
                    capturesPointer: capturesPointer,
                    sharesClipboard: sharesClipboard,
                    tracesPresentation: tracesPresentation,
                    streamsHostScreen: streamsHostScreen,
                    pointerPlan: pointerPlan,
                    releasesOnInteraction: releasesOnInteraction
                )
            }
        case "view-selftest":
            takeOverTheProcess { await selftest(clipboardRoundtrip: clipboardRoundtrip, diagnosticsWheel: diagnosticsWheel) }
        default:
            return
        }
    }

    /// Schedules the verb, hands this thread to the event loop, and exits
    /// with whatever the verb decided once the loop has ended.
    ///
    /// The verb runs as a job on the main actor rather than being awaited
    /// here, because an `await` at this point would cost this process the
    /// main queue before the loop ever had it.
    @MainActor
    private static func takeOverTheProcess(_ body: @escaping @MainActor () async -> Int32) -> Never {
        guard GLibMainLoop.attachMainQueue() else {
            say("The event loop could not take over this process's main queue, so no window can be driven from it.")
            exit(1)
        }
        let status = ExitStatus()
        Task { @MainActor in
            status.code = await body()
            GLibMainLoop.stop()
        }
        GLibMainLoop.run()
        exit(status.code)
    }

    // MARK: - view

    /// `seconds` bounds the run: a check rig that dials a machine someone
    /// else is using should give it back. Without one the session runs until
    /// the host ends it or the window is closed.
    ///
    /// `capturesPointer` starts captured-pointer mode at the first left click
    /// inside the window, which is the only way to reach it here: the menu
    /// item the macOS viewer offers has no counterpart on this rig.
    ///
    /// `streamsHostScreen` asks for the host's offered screen, as the viewer
    /// app does by default, instead of a session canvas.
    ///
    /// `pointerPlan` sends synthetic pointer motion through the session's
    /// public input path, timed from the first presented frame. With or
    /// without one, a run that streams ends by printing a `bench-viewer` line
    /// of JSON: frame counts, latency percentiles and the longest freeze.
    /// `releasesOnInteraction` is whether the frame presenter learns of the
    /// input this process sends; off, it paces as it does with nobody at the
    /// keyboard.
    ///
    /// `sharesClipboard` is off unless asked for, unlike the viewer app. A
    /// clipboard session is built either way, so a tag 3 packet always
    /// reaches the real apply path rather than being silently dropped by a
    /// nil one; with the flag off, that path refuses it, and the host is told
    /// to share nothing.
    @MainActor
    private static func view(
        host: String,
        port: UInt16,
        seconds: Int?,
        capturesPointer: Bool,
        sharesClipboard: Bool,
        tracesPresentation: Bool,
        streamsHostScreen: Bool,
        pointerPlan: BenchmarkPointerPlan?,
        releasesOnInteraction: Bool
    ) async -> Int32 {
        guard let identity = ViewerProbe.loadIdentity() else { return 1 }
        let store = FileSavedHostStore(url: ViewerProbe.savedHostURL())
        guard case let .success(saved) = SavedHostLookup.resolve(host: host, in: store.loadAll()) else {
            // Never a dial with no pin: an unpaired address is the pairing
            // flow's business, and dialling it would trust whatever answered.
            say("host not paired: run pair first")
            return 1
        }
        let connection = OpenSSLQUICConnection(
            host: host,
            port: port,
            tlsCertificateHash: saved.tlsCertificateHash
        )
        var openWindow: WaylandSessionWindow?
        var shortcuts: SystemShortcutForwarder?
        let window: WaylandSessionWindow
        let runner: ClientSessionRunner
        let controller: ClientSessionController
        let bench = BenchRun(plan: pointerPlan)
        var benchTasks: [Task<Void, Never>] = []
        defer { benchTasks.forEach { $0.cancel() } }
        do {
            try await connection.start(timeout: SessionTimeouts.remoteDefault.handshake)
            controller = ClientSessionController(
                transport: connection,
                identity: identity,
                pinnedHostPublicKey: saved.hostPublicKey,
                decoderPreference: ViewerDecoderSelection.platformRequestedProfile
            )
            // The window is built before the session connects, and its
            // viewport registered before that, because the canvas-ready
            // message that opens the viewport's own gate arrives inside
            // `connect()`. A viewport that is not listening by then holds
            // every frame of the session back. The title is the address
            // until the handshake says whose machine this is.
            // The session-taking initialiser is the one that hands the
            // presenter the session's input stamp; the sink-taking one
            // leaves it unattached.
            if releasesOnInteraction {
                window = try WaylandSessionWindow(
                    title: saved.displayName,
                    session: controller,
                    makeDecoder: AVCodecVideoDecoder.factory
                )
            } else {
                window = try WaylandSessionWindow(
                    title: saved.displayName,
                    pointerSink: controller,
                    makeDecoder: AVCodecVideoDecoder.factory
                )
            }
            openWindow = window
            if tracesPresentation {
                window.onFirstDrawDiagnostics = { say("Sensorium: \($0)") }
            }
            await controller.setCanvasObserver(window.canvasObserver())
            switch try await controller.connect(
                deviceName: ViewerProbe.deviceName(),
                target: streamsHostScreen ? .offeredHostScreen(preferredDisplayIdentity: nil) : .sessionCanvas
            ) {
            case let .canvas(displayID, _):
                say("Session canvas ready, display \(displayID).")
            case let .hostScreen(geometry, _, _):
                say("Host screen ready, \(geometry.logicalWidth)x\(geometry.logicalHeight).")
                bench.bounds = (Double(geometry.logicalWidth), Double(geometry.logicalHeight))
            }
            window.updateTitle(ViewerWindowTitle.resolve(
                hostMachineName: await controller.hostMachineName,
                savedHost: saved.host,
                fallback: saved.displayName
            ))
            let clipboard: ClipboardSyncSession?
            if let pasteboard = window.pasteboard {
                clipboard = ClipboardSyncSession(
                    engine: ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: sharesClipboard),
                    log: { say($0) }
                )
            } else {
                clipboard = nil
                if sharesClipboard {
                    say("Clipboard is not available on this compositor.")
                }
            }
            runner = ClientSessionRunner(
                connection: connection,
                session: controller,
                window: window,
                clipboard: clipboard,
                hostName: saved.displayName,
                hostAddress: "\(saved.host):\(saved.port)"
            )
            let ending = SessionEnding()
            window.onClosed = { ending.finish("the window was closed") }
            window.capturesPointerAtFirstClick = capturesPointer
            window.onPointerCaptureChanged = { isCaptured in
                say(isCaptured
                    ? "Pointer captured. Ctrl-Alt-Super-Escape gives it back."
                    : "Pointer released.")
            }
            window.onReleaseToLocalMachine = { say("Released to this machine.") }
            // What `main.swift` does for the macOS viewer: the forwarder is
            // the one place that decides where a reserved chord goes, and the
            // window is the target it decides for. Accessibility is a macOS
            // permission with no Linux counterpart, so it is simply granted
            // here; what actually decides whether reserved chords arrive is
            // the compositor's own shortcut inhibitor.
            let interceptor = WaylandShortcutInterceptor(inhibiting: window)
            window.shortcutInterceptor = interceptor
            shortcuts = SystemShortcutForwarder(
                mode: .default,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: interceptor
            )
            shortcuts?.register(window)
            // Before `start()`, as the viewer app does: the host starts each
            // connection off and follows this message.
            await runner.setClipboardSharing(enabled: sharesClipboard)
            try runner.start(onEnded: { reason in
                Task { @MainActor in ending.finish(reason) }
            })
            shortcuts?.startInterceptingIfPermitted(log: { say($0) })
            benchTasks = bench.start(window: window, controller: controller)
            if let seconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    ending.finish("ran for the \(seconds) seconds asked of it")
                }
            }
            say("Session ended: \(await ending.reason())")
        } catch {
            shortcuts?.stop()
            openWindow?.close()
            await connection.close()
            say("\(error)")
            return 1
        }
        benchTasks.forEach { $0.cancel() }
        let endedAt = MonotonicClock.nowNanoseconds()
        let latencyLine = await runner.latencySummary()
        let report = bench.report(
            window: window,
            metrics: await runner.latency.metrics(),
            latencySummary: latencyLine,
            releasesOnInteraction: releasesOnInteraction,
            endedAtNanoseconds: endedAt
        )
        shortcuts?.stop()
        runner.stop()
        // Ends the session the way the macOS viewer does -- input released,
        // goodbye sent, transport closed -- so the host records a session
        // that ended rather than one that dropped.
        await controller.disconnect()
        say(summary(of: window))
        say(report)
        window.close()
        return 0
    }

    // MARK: - view-selftest

    /// Opens the window with nothing behind it, shows one frame this process
    /// made, and closes. What it proves is the whole local path: a compositor
    /// connection, a configured surface, an EGL context, the software upload
    /// and the colour conversion.
    @MainActor
    private static func selftest(clipboardRoundtrip: Bool, diagnosticsWheel: Bool) async -> Int32 {
        let window: WaylandSessionWindow
        do {
            window = try WaylandSessionWindow(
                title: "Sensorium self-check",
                pointerSink: UnreportedInput(),
                makeDecoder: AVCodecVideoDecoder.factory
            )
        } catch {
            say("The window could not be opened: \(error)")
            return 1
        }
        let size = window.drawablePixelSize
        guard let frame = SyntheticNV12Frame.bands(width: size.width, height: size.height) else {
            say("A synthetic frame could not be allocated.")
            window.close()
            return 1
        }
        // What a live session's own canvas-ready message does. Without it the
        // viewport holds every frame back, which is the right answer when
        // there is a host and the wrong one here.
        let viewport = window.canvasObserver()
        await viewport.canvasDidBecomeReady()
        await viewport.presentDecodedFrame(frame)
        if diagnosticsWheel {
            window.performMenuCommand(.zoom)
            try? await Task.sleep(for: .milliseconds(300))
            await window.show()
            var state = ViewerSessionStateMachine(hostName: "Workstation")
            window.apply(status: state.handle(.canvasReady))
            window.updateSessionHUD(SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: frame.width, pixelHeight: frame.height, bitsPerSecond: nil),
                requestedStreamScale: 1,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Workstation",
                hostAddress: "mini.tail1234.ts.net:7777"
            ))
            window.performMenuCommand(.toggleTelemetryOverlay)
            say("diagnostics-wheel: ready")
        }
        try? await Task.sleep(for: .seconds(diagnosticsWheel ? 30 : 3))
        say("Self-check drew \(frame.width)x\(frame.height) into \(size.width)x\(size.height). \(summary(of: window))")
        let status = clipboardRoundtrip ? await runClipboardRoundtrip(window: window) : 0
        window.close()
        return status
    }

    /// Standalone proof that this client's Wayland clipboard really talks to
    /// the compositor, with no host involved: writes a known string once this
    /// window has keyboard focus, for an external `wl-paste -n` to read back,
    /// then waits for an external `wl-copy` to show up as a decision this
    /// pasteboard's own engine offers to send.
    @MainActor
    private static func runClipboardRoundtrip(window: WaylandSessionWindow) async -> Int32 {
        var attempts = 0
        while !window.viewerWindowState.hasKeyFocus {
            guard attempts < 200 else {
                say("clipboard-roundtrip: the window never gained keyboard focus")
                return 1
            }
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        guard let pasteboard = window.pasteboard else {
            say("clipboard-roundtrip: this compositor has no wl_data_device_manager")
            return 1
        }
        pasteboard.write(.text(roundtripText))
        say("clipboard-roundtrip: wrote \(roundtripText)")

        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        for _ in 0..<75 {
            try? await Task.sleep(for: .milliseconds(200))
            switch engine.poll() {
            case .nothingToSend:
                continue
            case let .send(content):
                say("clipboard-roundtrip: \(describe(.send(content)))")
            case let .refused(reason):
                say("clipboard-roundtrip: refused: \(reason.logReason)")
            }
        }
        return 0
    }

    private static let roundtripText = "sensorium-selftest"

    /// The exact decision, content included -- unlike `ClipboardContent`'s
    /// own `description`, which never carries a payload. This is the
    /// self-check rig printing to its own stdout for a human to compare
    /// against what `wl-copy` was given, not a log line this project ships.
    private static func describe(_ decision: ClipboardSendDecision) -> String {
        switch decision {
        case .nothingToSend:
            ".nothingToSend"
        case let .send(.text(text)):
            ".send(.text(\"\(text)\"))"
        case let .send(.image(format, data)):
            ".send(.image(\(format.rawValue), \(data.count) bytes))"
        case let .refused(reason):
            ".refused(\(reason.logReason))"
        }
    }

    // MARK: - Shared

    /// What the run did, in one line: the presenter's own count of what
    /// reached the screen, what never got there, and how late the frames that
    /// did were.
    @MainActor
    private static func summary(of window: WaylandSessionWindow) -> String {
        let latency = window.meanPresentLatencyNanoseconds
            .map { "\(Double($0) / 1_000_000) ms" } ?? "no sample"
        let presented = window.presentedFrameCount
        return "Presented \(presented) \(presented == 1 ? "frame" : "frames"), dropped \(window.droppedFrameCount), mean present latency \(latency)."
    }

    private static func say(_ line: String) {
        print(line)
        fflush(nil)
    }
}

/// What a benchmark run measures and drives while a `view` session streams:
/// when the first frame reached the screen, how long the picture stood still
/// between frames, and the synthetic pointer a `BenchmarkPointerPlan` asks for.
@MainActor
private final class BenchRun {
    let plan: BenchmarkPointerPlan?
    /// The extent synthetic pointer motion stays inside. A session canvas
    /// accepts input over the same 1920x1200 the controller checks against;
    /// a host screen's own size replaces it.
    var bounds: (width: Double, height: Double) = (1920, 1200)
    private var firstFrameAtNanoseconds: Int64?
    private var gaps: PresentGapTracker
    private var inputsSent = 0
    private var inputsRefused = 0

    /// Frames are noticed by polling the presenter's count, so a gap is
    /// resolved to this interval.
    private static let samplingIntervalMilliseconds = 2.0
    private static let pointerRate = 60.0

    init(plan: BenchmarkPointerPlan?) {
        self.plan = plan
        gaps = PresentGapTracker(plan: plan)
    }

    func start(window: WaylandSessionWindow, controller: ClientSessionController) -> [Task<Void, Never>] {
        var tasks = [Task { @MainActor in await self.sampleFrames(of: window) }]
        if plan != nil {
            tasks.append(Task { @MainActor in await self.drivePointer(through: controller) })
        }
        return tasks
    }

    private func secondsSinceFirstFrame(at nowNanoseconds: Int64) -> Double? {
        firstFrameAtNanoseconds.map { Double(nowNanoseconds - $0) / 1_000_000_000 }
    }

    private func sampleFrames(of window: WaylandSessionWindow) async {
        var seen = 0
        while !Task.isCancelled {
            let count = window.presentedFrameCount
            if count > seen {
                seen = count
                let now = MonotonicClock.nowNanoseconds()
                if firstFrameAtNanoseconds == nil { firstFrameAtNanoseconds = now }
                gaps.notePresented(atNanoseconds: now, secondsIntoPlan: secondsSinceFirstFrame(at: now))
            }
            try? await Task.sleep(for: .milliseconds(Self.samplingIntervalMilliseconds))
        }
    }

    /// Sends one pointer position per tick, at `pointerRate`, on absolute
    /// deadlines so a slow send does not stretch the rate.
    private func drivePointer(through controller: ClientSessionController) async {
        guard let plan else { return }
        while firstFrameAtNanoseconds == nil {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let clock = ContinuousClock()
        let origin = clock.now
        var tick = 0
        while !Task.isCancelled {
            let seconds = Double(tick) / Self.pointerRate
            guard seconds < plan.totalSeconds else { return }
            if plan.isMoving(atSeconds: seconds) {
                let point = BenchmarkPointerPlan.pointerPosition(atSeconds: seconds, width: bounds.width, height: bounds.height)
                do {
                    try await controller.sendInput(.pointerMoved(x: point.x, y: point.y), surfaceID: 0)
                    inputsSent += 1
                } catch {
                    inputsRefused += 1
                }
            }
            tick += 1
            try? await clock.sleep(until: origin + .seconds(Double(tick) / Self.pointerRate))
        }
    }

    func report(
        window: WaylandSessionWindow,
        metrics: SessionMetrics,
        latencySummary: String?,
        releasesOnInteraction: Bool,
        endedAtNanoseconds: Int64
    ) -> String {
        func milliseconds(_ nanoseconds: Int64?) -> Any {
            nanoseconds.map { Double($0) / 1_000_000 } ?? NSNull()
        }
        let presented = window.presentedFrameCount
        let runSeconds = secondsSinceFirstFrame(at: endedAtNanoseconds)
        let roundTrip = metrics.samples(for: .inputRoundTrip)
        var fields: [String: Any] = [
            "pointerPlan": plan?.specification ?? NSNull(),
            "interactionRelease": releasesOnInteraction,
            "latencySummary": latencySummary ?? NSNull(),
            "traces": BenchmarkReport.traceObjects(from: metrics.traceLines()),
            "presentedFrames": presented,
            "decodedFrames": metrics.samples(for: .decode).count,
            "droppedFrames": window.droppedFrameCount,
            "meanPresentLatencyMs": milliseconds(window.meanPresentLatencyNanoseconds),
            "inputRoundTripP50Ms": milliseconds(roundTrip.p50),
            "inputRoundTripP95Ms": milliseconds(roundTrip.p95),
            "inputRoundTripCount": roundTrip.count,
            "syntheticInputsSent": inputsSent,
            "syntheticInputsRefused": inputsRefused,
            "longestPresentGapMs": milliseconds(gaps.longestGapNanoseconds),
            "longestPresentGapDuringMoveMs": milliseconds(gaps.longestMovingGapNanoseconds),
            "firstFrameAfterMoveStartMs": milliseconds(gaps.firstFrameAfterMoveStartNanoseconds),
            "presentGapResolutionMs": Self.samplingIntervalMilliseconds
        ]
        if let runSeconds, runSeconds > 0 {
            fields["measuredSeconds"] = runSeconds
            fields["meanPresentedFps"] = Double(presented) / runSeconds
            fields["meanDecodedFps"] = Double(metrics.samples(for: .decode).count) / runSeconds
        }
        return BenchmarkReport.line(fields)
    }
}

/// The verb's own exit status, written once the verb has finished and read
/// once the loop it was running on has ended.
@MainActor
private final class ExitStatus {
    var code: Int32 = 0
}

/// Why the session stopped, from whichever of the two ends reported it first.
@MainActor
private final class SessionEnding {
    private var reported: String?
    private var waiting: CheckedContinuation<String, Never>?

    func finish(_ reason: String) {
        guard reported == nil else { return }
        reported = reason
        waiting?.resume(returning: reason)
        waiting = nil
    }

    func reason() async -> String {
        if let reported { return reported }
        return await withCheckedContinuation { continuation in
            if let reported {
                continuation.resume(returning: reported)
            } else {
                waiting = continuation
            }
        }
    }
}

/// A sink for a window with no session behind it. The self-check has no host
/// to tell anything to, and nothing it reports is anyone's business.
private struct UnreportedInput: CanvasInputSending {
    func sendInput(_ event: SensoriumInputEvent) async throws {}
    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws {}
    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {}
}

#else

/// No compositor, no EGL, no decoder: these verbs exist only where a Linux
/// viewer can be built.
enum ViewVerbs {
    @MainActor
    static func dispatchIfRequested() {}
}

#endif
