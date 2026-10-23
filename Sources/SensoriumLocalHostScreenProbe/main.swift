import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import Network
import SensoriumClient
import SensoriumCore
import SensoriumHost

/// Opt-in single-machine acceptance probe for host-screen mode. It uses the
/// production viewer window, frame runner, surface-event router, authenticated
/// transport, and the host's own injector, against one of this machine's real
/// displays -- the sibling of `SensoriumLocalWorkspaceInputProbe`, which does
/// the same for a session canvas.
///
/// usage:
///   SensoriumLocalHostScreenProbe pair <tailnet-host> <port> <pairing-code>
///   SensoriumLocalHostScreenProbe arm <arming-file-path>
///   SensoriumLocalHostScreenProbe wait-idle <timeout-seconds>
///   SensoriumLocalHostScreenProbe enter <tailnet-host> <port>
///   SensoriumLocalHostScreenProbe lock-typing <tailnet-host> <port> <screenshot-directory>
///
/// `arm` stands in for the arming ceremony a person performs in the host app's
/// own interface (docs/host-screen-design.md §2.1). No wire message can create
/// or widen an arming record, so an automated rig has no way to arm itself
/// except by writing the host's own file directly. It writes only the path it
/// is given, which `Scripts/run-real-local-host-screen-smoke.sh` points at a
/// throwaway `HOME` under `.build/` -- never at anyone's real one.
///
/// `enter` opens a second window of its own, holding an editable text view, on
/// the armed display. That window is the thing being driven: the host injects
/// into a real display, and what lands there is read back from AppKit and from
/// `NSEvent.mouseLocation` -- this process's own view of the machine, not any
/// bookkeeping the session kept.
///
/// Before the display-mode round trip, `enter` also proves motion-time
/// resolution: a large window of dense, scrollable content stands on the armed
/// display, the viewer scrolls it for a moment, and the sizes of the decoded
/// frames are judged by `StreamMotionProof` -- the motion size while the scroll
/// runs, the full size soon after it stops, and the full size from then on. It
/// prints the verdict as `motion_check=` and leaves failing the run to
/// `Scripts/run-real-local-host-screen-smoke.sh`, which reports each failure
/// on its own. It runs ahead of the mode round trip so the stream is measured
/// on the display's own mode, the one the person at this machine really uses.
@main
@MainActor
struct SensoriumLocalHostScreenProbe {
    private struct SavedApproval: Codable {
        let hostPublicKey: Data
        /// Carried even over TCP, where nothing pins it: the host binds every
        /// authenticated hello to its own certificate hash.
        let tlsCertificateHash: Data?
    }

    private static let deviceName = "Sensorium local host screen probe"

    /// Unlike the canvas probes, this one needs AppKit to actually deliver the
    /// injected pointer and key events to a window of its own, which only a
    /// running `NSApplication` event loop does. A Swift `async` `main` leaves
    /// the main thread draining the main queue with no run loop on it, so the
    /// work runs as a main-actor task *inside* `NSApplication.run()` instead.
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        // No bundle, so no `Info.plist` to declare this: a probe that cannot
        // become frontmost cannot be typed into, and typing into it is the
        // whole measurement.
        application.setActivationPolicy(.regular)
        let status = ExitStatus()
        Task { @MainActor in
            do {
                try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            } catch {
                print("local host screen probe failed: \(error)")
                status.code = 1
            }
            stopEventLoop()
        }
        application.run()
        Foundation.exit(status.code)
    }

    private static func run(arguments: [String]) async throws {
        guard let mode = arguments.first else {
            usageAndExit()
        }
        switch mode {
        case "pair":
            guard arguments.count == 4 else { usageAndExit() }
            try await pair(host: arguments[1], rawPort: arguments[2], code: arguments[3])
        case "arm":
            guard arguments.count == 2 else { usageAndExit() }
            try arm(armingFilePath: arguments[1])
        case "wait-idle":
            guard arguments.count == 2 else { usageAndExit() }
            await waitForNobodyAtThisMac(rawTimeout: arguments[1])
        case "enter":
            guard arguments.count == 3 else { usageAndExit() }
            try await enter(host: arguments[1], rawPort: arguments[2])
        case "lock-typing":
            guard arguments.count == 4 else { usageAndExit() }
            try await lockTyping(host: arguments[1], rawPort: arguments[2], shotDirectory: arguments[3])
        default:
            usageAndExit()
        }
    }

    /// `stop(_:)` is only read between events, so a loop with nothing else
    /// arriving would sit there forever without one to read it.
    private static func stopEventLoop() {
        NSApplication.shared.stop(nil)
        let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let wake {
            NSApplication.shared.postEvent(wake, atStart: true)
        }
    }

    private static func pair(host: String, rawPort: String, code: String) async throws {
        let port = try endpointPort(rawPort)
        try createStateDirectory()
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(transport: connection, identity: identity)
        let approval = try await session.pair(deviceName: deviceName, code: code)
        try JSONEncoder().encode(SavedApproval(hostPublicKey: approval.hostPublicKey, tlsCertificateHash: approval.tlsCertificateHash))
            .write(to: approvalURL(), options: .atomic)
        await connection.close()
        print("host_screen_probe_paired=yes")
    }

    /// Writes the host's arming record through the host's own store, so this
    /// rig cannot drift from the format the host reads. Names this probe's own
    /// device key; arming is per machine, so the display `enter` will open its
    /// window on is only printed, never armed for.
    private static func arm(armingFilePath: String) throws {
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        guard let display = targetDisplay() ?? DisplayInventory.online().first else {
            throw HostScreenProbeError.noTargetDisplay
        }
        HostScreenArmingStore(url: URL(fileURLWithPath: armingFilePath)).arm(
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: deviceName,
                armedAt: Date()
            )
        )
        print("host_screen_probe_armed_display=\(HostScreenDisplayIdentity(display).wireStableIdentifier)")
        print("host_screen_probe_armed_display_id=\(display.id)")
    }

    /// docs/host-screen-design.md §6.2: a host-screen session starts without asking only when
    /// nobody has touched this machine for several minutes. Anyone who starts this
    /// rig has, by definition, just touched it, so the rig waits that out
    /// rather than leaving a prompt on a real screen with nobody expecting it.
    /// Waiting cannot be skipped from the wire and is not a way around the
    /// rule: it is the same reading the host itself takes, read here first so
    /// a run that could only ever be refused says so instead.
    private static func waitForNobodyAtThisMac(rawTimeout: String) async {
        guard let timeout = Double(rawTimeout), timeout > 0 else {
            usageAndExit()
        }
        // A second past the host's own threshold, because the host refuses an
        // exact tie: "an exact tie resolves toward asking."
        let required = HostScreenPresenceRule.recommendedPresenceThreshold + 1
        let signal = CoreGraphicsLocalActivitySignal()
        let deadline = Date().addingTimeInterval(timeout)
        var lastReported = -1.0
        while Date() < deadline {
            guard case let .idleFor(seconds) = signal.currentReading() else {
                break
            }
            if seconds > required {
                print("host_screen_probe_idle_seconds=\(Int(seconds))")
                return
            }
            if lastReported < 0 || lastReported - seconds > 5 {
                print("host_screen_probe_waiting_for_idle_seconds=\(Int(required - seconds))")
            }
            lastReported = seconds
            try? await Task.sleep(for: .seconds(5))
        }
        print("BLOCKED: someone is using this machine, so the host would ask them before sharing a screen. "
            + "Leave it alone for \(Int(required / 60)) minutes and run this again.")
        Foundation.exit(3)
    }

    private static func enter(host: String, rawPort: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        guard let display = targetDisplay(), let screen = screen(for: display) else {
            throw HostScreenProbeError.noTargetDisplay
        }

        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            tlsCertificateHash: approval.tlsCertificateHash,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Host Screen", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        let outcome = try await session.connect(
            deviceName: deviceName,
            target: .hostScreen(displayIdentity: HostScreenDisplayIdentity(display).wireStableIdentifier)
        )
        guard case let .hostScreen(geometry, _, _) = outcome else {
            throw HostScreenProbeError.sessionIsNotHostScreen
        }
        print("host_screen_geometry=\(geometry.logicalWidth)x\(geometry.logicalHeight)@\(geometry.backingScale)")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)

        let modeRoundTrip = HostScreenModeRoundTrip(display: display)
        modeRoundTrip.observe(runner)

        let decodedSizes = DecodedFrameSizes()
        try runner.start(onDecodedFrame: { frame in decodedSizes.record(width: frame.width, height: frame.height) })
        print("host_screen_viewer_started=yes")

        try await proveMotionResolution(
            session: session,
            geometry: geometry,
            display: display,
            screen: screen,
            decodedSizes: decodedSizes
        )

        await modeRoundTrip.run(runner: runner, frameCount: { await presentedFrameCount(runner) })

        // A mode change above replaces both the geometry and the display's
        // own bounds; the session-start `geometry` and `display` snapshot
        // are stale from that point on, exactly as they would be for a real
        // viewer, which is why `onHostScreenModeApplied` re-reads both too.
        let modeApplied = modeRoundTrip.applied
        let currentGeometry = modeApplied?.geometry ?? geometry
        let currentDisplay = modeApplied != nil
            ? (DisplayInventory.active().first { $0.id == display.id } ?? display)
            : display
        // `screen`, resolved before the mode change ran, is the same stale
        // trap: AppKit's own `NSScreen.frame` for the armed display has
        // moved on to the new size, and a window built from the old one
        // centres itself over a rectangle that no longer describes anything
        // on screen.
        guard let currentScreen = modeApplied != nil ? Self.screen(for: currentDisplay) : screen else {
            throw HostScreenProbeError.noTargetScreenAfterModeChange
        }

        let target = TargetWindow(screen: currentScreen)
        target.show()
        // The armed display and the display the window actually stands on
        // have to be the same one, or every coordinate below is measured
        // against a display nobody is streaming.
        guard let standingOn = activeDisplay(containing: target.centreInGlobalDisplaySpace()),
              standingOn.id == display.id else {
            throw HostScreenProbeError.windowNotOnArmedDisplay
        }
        print("host_screen_probe_window_display_id=\(standingOn.id)")

        // The viewer's own input path: the surface router over a viewport
        // built from the geometry the host reported for the display it is
        // streaming, rather than any canvas preset.
        let inputViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(currentGeometry.logicalWidth),
                logicalHeight: Double(currentGeometry.logicalHeight)
            ),
            pointerSink: session
        )
        let router = CanvasSurfaceEventRouter(viewport: inputViewport)
        // A viewport the same size as the display it drives makes the mapping
        // one to one, so a point measured on this machine is the point the host is
        // asked to move to.
        _ = await router.route(.boundsChanged(
            width: Double(currentGeometry.logicalWidth),
            height: Double(currentGeometry.logicalHeight)
        ))
        await inputViewport.canvasDidBecomeReady()

        let targetPoint = target.textCentreInScreenSpace()
        let local = displayLocalPoint(targetPoint, on: currentDisplay)
        print("pointer_target=\(local.x),\(local.y)")
        // The router reads a view's own bottom-left origin, so the display's
        // top-down coordinate is flipped back before it goes in.
        let move = await router.route(.pointerMoved(
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))
        guard case .delivered = move else {
            print("pointer_moved=no")
            print("pointer_route=\(Self.describe(move)) "
                + "viewport=\(currentGeometry.logicalWidth)x\(currentGeometry.logicalHeight) "
                + "local=\(local.x),\(local.y)")
            throw HostScreenProbeError.pointerNotDelivered
        }
        let pointerLanded = await pollUntil(seconds: 5) {
            hypot(
                NSEvent.mouseLocation.x - targetPoint.x,
                NSEvent.mouseLocation.y - targetPoint.y
            ) <= 3.0
        }
        print("pointer_landed_at=\(NSEvent.mouseLocation.x),\(NSEvent.mouseLocation.y)")
        print("pointer_moved=\(pointerLanded ? "yes" : "no")")

        _ = await router.route(.pointerButton(
            button: .left,
            isDown: true,
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))
        _ = await router.route(.pointerButton(
            button: .left,
            isDown: false,
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))

        // Retried, bounded, for the same reason the canvas probe retries its
        // own: a key goes to whatever holds this machine's one keyboard focus, and
        // the click above only asks for it -- AppKit grants it on its own
        // schedule, and a key posted before that lands somewhere else.
        var typed = false
        for _ in 0..<30 {
            target.takeKeyboardFocus()
            _ = await router.route(.key(keyCode: keyCodeA, isDown: true, modifiers: []))
            _ = await router.route(.key(keyCode: keyCodeA, isDown: false, modifiers: []))
            try? await Task.sleep(for: .milliseconds(200))
            if target.typedText().contains("a") {
                typed = true
                break
            }
        }
        print("text_typed=\(typed ? "yes" : "no")")

        try await Task.sleep(for: .seconds(2))
        let presented = await runner.latency.metrics().samples(for: .present).count
        print("host_screen_frames=\(presented)")
        runner.stop()
        await session.disconnect(reason: "host-screen-probe-complete")
        target.close()

        await modeRoundTrip.verifyRestored()

        guard presented > 0 else {
            throw HostScreenProbeError.noPresentedFrames
        }
        guard pointerLanded else {
            throw HostScreenProbeError.pointerNeverLanded
        }
        guard typed else {
            throw HostScreenProbeError.textNeverTyped
        }
        if let modeChangeError = modeRoundTrip.error {
            throw modeChangeError
        }
    }

    /// The viewer-driven display-mode round trip against the real
    /// `CoreGraphicsHostScreenModeController`, shared by `enter` and
    /// `lock-typing`: a mode change requested mid-session, applied without
    /// interrupting the picture, and the mode this display had before always
    /// put back. It reads the exchange from the runner's own callbacks, exactly
    /// as a real viewer would, never by asking the host what it just did.
    ///
    /// Frame progress is supplied by the caller. `enter` counts presented
    /// frames; `lock-typing` counts decoded ones, because the lock screen
    /// covers the probe's own window and nothing is presented there.
    @MainActor
    private final class HostScreenModeRoundTrip {
        private let display: DisplaySnapshot
        private var offeredModes: [HostScreenModeEntry] = []
        private var offeredCurrentModeID: String?
        private var modeRefused: String?
        private var originalMode: CGDisplayMode?
        private var originalModeSnapshot: DisplayModeSnapshot?
        private var wasSkipped = false

        /// The geometry and mode the host reported when it applied the change.
        private(set) var applied: (geometry: SessionSurfaceGeometry, currentModeID: String)?
        private(set) var error: Error?

        init(display: DisplaySnapshot) {
            self.display = display
        }

        /// Must be called before the runner starts, so the mode list that
        /// arrives with the session is not missed.
        func observe(_ runner: ClientSessionRunner) {
            runner.onHostScreenModeList = { [self] modes, currentModeID in
                offeredModes = modes
                offeredCurrentModeID = currentModeID
            }
            runner.onHostScreenModeApplied = { [self] geometry, currentModeID in
                applied = (geometry, currentModeID)
            }
            runner.onHostScreenModeRefused = { [self] reason in
                modeRefused = reason
            }
        }

        func run(runner: ClientSessionRunner, frameCount: () async -> Int) async {
            // The mode this display was on before any of this touched it, held
            // as the live `CGDisplayMode` object itself, not just a description
            // of it, because the probe-side fallback restore below needs to hand
            // CoreGraphics that exact object, never one re-derived from a
            // description of it.
            originalMode = CGDisplayCopyDisplayMode(display.id)
            originalModeSnapshot = originalMode.map(DisplayModeSnapshot.init)
            print("mode_before=\(originalModeSnapshot?.line ?? "unknown")")

            let poll = SensoriumLocalHostScreenProbe.pollUntil
            if await poll(10, { !offeredModes.isEmpty }) == false {
                print("mode_requested=none")
                print("mode_applied=no")
                error = HostScreenProbeError.modeListNeverArrived
            } else if await SensoriumLocalHostScreenProbe.pollFrames(
                atLeast: 1, within: 10, frameCount: frameCount
            ) == false {
                print("mode_requested=none")
                print("mode_applied=no")
                error = HostScreenProbeError.noPresentedFrames
            } else if let target = SensoriumLocalHostScreenProbe.largestOtherHiDPIMode(
                in: offeredModes, excluding: offeredCurrentModeID
            ) {
                print("mode_requested=\(target.modeID)")
                let framesBeforeRequest = await frameCount()
                await runner.requestHostScreenMode(target.modeID)
                let arrived = await poll(15, { applied != nil || modeRefused != nil })
                if !arrived {
                    print("mode_applied=no")
                    error = HostScreenProbeError.modeChangeTimedOut
                } else if let modeRefused {
                    print("mode_applied=no")
                    error = HostScreenProbeError.modeChangeRefused(modeRefused)
                } else {
                    print("mode_applied=yes")
                    // Frames must resume quickly, not merely eventually: a host
                    // that keeps the old capture's packet sequencer picks back
                    // up within a frame or two, while one that restarted it at
                    // zero is silently discarded by the viewer's own
                    // `VideoFrameIngress` until the new count climbs back past
                    // the old one, which can take minutes at a low frame rate.
                    if let resumedWithin = await SensoriumLocalHostScreenProbe.pollFramesElapsed(
                        atLeast: framesBeforeRequest + 5, within: 3, frameCount: frameCount
                    ) {
                        print(String(format: "mode_frames_resumed_within=%.1f", resumedWithin))
                    } else {
                        error = HostScreenProbeError.framesDidNotResumeAfterModeChange
                    }
                    let displayID = display.id
                    let pixelMatched = await poll(5, {
                        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
                        return mode.pixelWidth == target.pixelWidth && mode.pixelHeight == target.pixelHeight
                    })
                    if !pixelMatched, error == nil {
                        error = HostScreenProbeError.displayModeDidNotMatchRequest
                    }
                }
            } else {
                print("mode_requested=none")
                print("mode_applied=skipped-single-mode")
                wasSkipped = true
            }
        }

        /// The one unacceptable outcome on a real display: leaving it on a
        /// mode nobody asked to keep. Checked after the session has ended, as
        /// the design requires ("restored when the session ends"), and polled
        /// because that restoration can be asynchronous.
        func verifyRestored() async {
            guard !wasSkipped else { return }
            let displayID = display.id
            let originalModeSnapshot = originalModeSnapshot
            let matchesOriginal = { () -> Bool in
                guard let originalModeSnapshot else { return true }
                guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
                return DisplayModeSnapshot(mode) == originalModeSnapshot
            }
            let poll = SensoriumLocalHostScreenProbe.pollUntil
            if await poll(10, matchesOriginal) {
                print("mode_restored=yes")
                print("mode_restored_by=host")
            } else if let originalMode,
                      SensoriumLocalHostScreenProbe.probeRestoreMode(originalMode, on: displayID) {
                let restoredByProbe = await poll(5, matchesOriginal)
                print("mode_restored=\(restoredByProbe ? "yes" : "no")")
                print("mode_restored_by=probe")
                if !restoredByProbe {
                    error = error ?? HostScreenProbeError.displayNotRestored
                }
            } else {
                print("mode_restored=no")
                print("mode_restored_by=probe")
                error = error ?? HostScreenProbeError.displayNotRestored
            }
        }
    }

    /// How many scroll events the motion proof sends, and how far apart. A steady
    /// 60 a second is what a held trackpad flick looks like to the host. The
    /// step is not a multiple of the content's row height, so no two rows of
    /// the picture line up with the rows they replace.
    private static let motionScrollEventCount = 90
    private static let motionScrollInterval = 1.0 / 60
    private static let motionScrollStepPoints = 30.0
    /// How long the picture is left alone before its full size is read, and
    /// how long it is watched after the scroll stops. The host settles 0.5 s
    /// after the last change, so the first outlasts the picture opening and
    /// the second is several times the time `StreamMotionProof` allows.
    private static let motionQuietSeconds = 3.0

    /// Scrolls a large window of dense content standing on the armed display
    /// through the viewer's own input path, and judges the decoded frame sizes
    /// it saw. The window covers most of the display so that a scroll changes
    /// most of the picture, which is what the host reads as motion.
    private static func proveMotionResolution(
        session: ClientSessionController,
        geometry: SessionSurfaceGeometry,
        display: DisplaySnapshot,
        screen: NSScreen,
        decodedSizes: DecodedFrameSizes
    ) async throws {
        let scrollWindow = ScrollTargetWindow(screen: screen)
        scrollWindow.show()
        defer { scrollWindow.close() }
        guard let standingOn = activeDisplay(containing: scrollWindow.centreInGlobalDisplaySpace()),
              standingOn.id == display.id else {
            throw HostScreenProbeError.windowNotOnArmedDisplay
        }

        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(geometry.logicalWidth),
                logicalHeight: Double(geometry.logicalHeight)
            ),
            pointerSink: session
        )
        let router = CanvasSurfaceEventRouter(viewport: viewport)
        _ = await router.route(.boundsChanged(width: Double(geometry.logicalWidth), height: Double(geometry.logicalHeight)))
        await viewport.canvasDidBecomeReady()

        // Request a known full size and verify it arrives; the host may
        // still clamp the request to its measured fidelity ceiling.
        let requestedScale = StreamScalePolicy.maximumScale
        try await session.sendStreamScalePreference(.fixed(requestedScale))
        let settledConfiguration = HostScreenEncoderSizing.resolve(for: geometry).configuration.scaled(
            toStreamScale: min(requestedScale, HostScreenEncoderSizing.maximumStreamScale(for: geometry))
        )
        let fullSize = StreamMotionProof.FrameSize(
            width: settledConfiguration.encodeWidth,
            height: settledConfiguration.encodeHeight
        )
        guard await pollUntil(seconds: 10, condition: {
            guard let latest = decodedSizes.latest else { return false }
            return latest.width == fullSize.width && latest.height == fullSize.height
        }) else {
            throw HostScreenProbeError.noPresentedFrames
        }
        try await Task.sleep(for: .seconds(motionQuietSeconds))

        let local = displayLocalPoint(scrollWindow.centreInScreenSpace(), on: display)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastScrollAt = startedAt
        for index in 0..<motionScrollEventCount {
            let wait = startedAt + Double(index) * motionScrollInterval - ProcessInfo.processInfo.systemUptime
            if wait > 0 {
                try await Task.sleep(for: .seconds(wait))
            }
            let delivery = await router.route(.scrolled(
                deltaX: 0,
                deltaY: -motionScrollStepPoints,
                x: local.x,
                y: Double(geometry.logicalHeight) - local.y,
                phase: nil,
                momentumPhase: nil
            ))
            guard case .delivered = delivery else {
                print("motion_scroll_route=\(describe(delivery))")
                throw HostScreenProbeError.pointerNotDelivered
            }
            lastScrollAt = ProcessInfo.processInfo.systemUptime
        }
        try await Task.sleep(for: .seconds(motionQuietSeconds))

        let frames = decodedSizes.frames(since: startedAt).map { arrival in
            StreamMotionProof.Frame(
                milliseconds: Int(((arrival.uptime - startedAt) * 1000).rounded()),
                size: StreamMotionProof.FrameSize(width: arrival.width, height: arrival.height)
            )
        }
        try await session.sendStreamScalePreference(.automatic)
        let proof = StreamMotionProof.judge(
            fullSize: fullSize,
            expectedMotionSize: settledConfiguration.motionConfiguration.map {
                StreamMotionProof.FrameSize(width: $0.encodeWidth, height: $0.encodeHeight)
            },
            frames: frames,
            lastScrollMilliseconds: Int(((lastScrollAt - startedAt) * 1000).rounded())
        )
        for line in proof.lines {
            print(line)
        }
    }

    /// ANSI `a`. One printable character is all this needs, and the one the
    /// script looks for in the text view afterwards.
    private static let keyCodeA: UInt16 = 0

    /// The offered mode most worth proving the round trip with: the sharpest
    /// picture the display can show that is not the one it is already on. A
    /// display armed with only one usable mode has nothing to change to, and
    /// that is reported as skipped rather than as a failure.
    private static func largestOtherHiDPIMode(
        in modes: [HostScreenModeEntry], excluding currentModeID: String?
    ) -> HostScreenModeEntry? {
        modes
            .filter { $0.modeID != currentModeID }
            .sorted { lhs, rhs in
                if lhs.isHiDPI != rhs.isHiDPI {
                    return lhs.isHiDPI
                }
                return lhs.pixelWidth * lhs.pixelHeight > rhs.pixelWidth * rhs.pixelHeight
            }
            .first
    }

    private static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Proves the viewer's keys reach the host's lock screen password field.
    /// It locks this machine if it is not locked already, types five letters
    /// (never Return, so nothing is submitted) with no click first, and
    /// compares the lower-centre of the streamed frame before and after: the
    /// lock screen centres its password field horizontally in the lower part
    /// of the display, and typing changes it. It empties the field before
    /// typing and again after, and fails if the field is not left empty. It
    /// then runs the display-mode round trip on the locked display and checks
    /// the display is back on its own mode after disconnecting. The machine is
    /// left locked.
    private static func lockTyping(host: String, rawPort: String, shotDirectory: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        // A locked machine's display may be asleep and so not active; fall
        // back to any online one.
        guard let display = targetDisplay() ?? DisplayInventory.online().first else {
            throw HostScreenProbeError.noTargetDisplay
        }
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            tlsCertificateHash: approval.tlsCertificateHash,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Lock Typing Probe", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        let outcome = try await session.connect(
            deviceName: deviceName,
            target: .hostScreen(displayIdentity: HostScreenDisplayIdentity(display).wireStableIdentifier)
        )
        guard case let .hostScreen(geometry, _, _) = outcome else {
            throw HostScreenProbeError.sessionIsNotHostScreen
        }
        print("host_screen_geometry=\(geometry.logicalWidth)x\(geometry.logicalHeight)@\(geometry.backingScale)")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)
        let latest = LatestDecodedFrame()
        let modeRoundTrip = HostScreenModeRoundTrip(display: display)
        modeRoundTrip.observe(runner)
        try runner.start(onDecodedFrame: { frame in latest.set(frame.pixelBuffer) })
        // Decoded, not presented: a locked host's lock screen covers this
        // probe's own window on the same machine, so nothing is ever presented.
        guard await pollUntil(seconds: 10, condition: { latest.get() != nil }) else {
            throw HostScreenProbeError.noPresentedFrames
        }

        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(geometry.logicalWidth),
                logicalHeight: Double(geometry.logicalHeight)
            ),
            pointerSink: session
        )
        let router = CanvasSurfaceEventRouter(viewport: viewport)
        _ = await router.route(.boundsChanged(width: Double(geometry.logicalWidth), height: Double(geometry.logicalHeight)))
        await viewport.canvasDidBecomeReady()

        print("started_locked=\(screenIsLocked() ? "yes" : "no")")
        if !screenIsLocked() {
            let delivery = await viewport.sendKeySequence(ShortcutStripAction.lockScreen.events())
            print("lock_chord_route=\(describe(delivery))")
            _ = await pollUntil(seconds: 15) { screenIsLocked() }
        }
        guard screenIsLocked() else { throw HostScreenProbeError.screenNeverLocked }
        print("screen_locked=yes")
        // The lock screen takes a few seconds to finish drawing its password field.
        try await Task.sleep(for: .seconds(8))

        // Starts from an empty field, whatever an earlier run or person left in it.
        try await pressBackspace(times: 20, through: router)
        try await Task.sleep(for: .seconds(1))

        let directory = URL(fileURLWithPath: shotDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let before = latest.get() else { throw HostScreenProbeError.noPresentedFrames }
        let beforeFrame = try LockScreenFrame(before)
        try beforeFrame.writePNG(to: directory.appendingPathComponent("lock-before-typing.png"))

        // ANSI z, x, c, v, b.
        for code: UInt16 in [6, 7, 8, 9, 11] {
            _ = await router.route(.key(keyCode: code, isDown: true, modifiers: []))
            _ = await router.route(.key(keyCode: code, isDown: false, modifiers: []))
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(3))
        guard let after = latest.get() else { throw HostScreenProbeError.noPresentedFrames }
        let afterFrame = try LockScreenFrame(after)
        try afterFrame.writePNG(to: directory.appendingPathComponent("lock-after-typing.png"))

        let changed = beforeFrame.passwordRegionDiffers(from: afterFrame)
        print("lock_typing_field_changed=\(changed ? "yes" : "no")")

        // Leaves the field as it found it: empty. Polled because the caret
        // blinks, and a frame caught mid-blink differs from `before` by it.
        try await pressBackspace(times: 10, through: router)
        let cleared = await pollUntil(seconds: 3) {
            guard let frame = latest.get(), let now = try? LockScreenFrame(frame) else { return false }
            return !beforeFrame.passwordRegionDiffers(from: now)
        }
        if let frame = latest.get() {
            try LockScreenFrame(frame).writePNG(to: directory.appendingPathComponent("lock-after-clearing.png"))
        }
        print("lock_typing_field_cleared=\(cleared ? "yes" : "no")")

        let escape: UInt16 = 53
        _ = await router.route(.key(keyCode: escape, isDown: true, modifiers: []))
        _ = await router.route(.key(keyCode: escape, isDown: false, modifiers: []))
        try await Task.sleep(for: .seconds(1))

        // Decoded frames, for the same reason the first frame above is: the
        // lock screen covers this probe's own window, so none is presented.
        await modeRoundTrip.run(runner: runner, frameCount: { latest.count })
        runner.stop()
        await session.disconnect(reason: "lock-typing-probe-complete")
        await modeRoundTrip.verifyRestored()
        if !changed { throw HostScreenProbeError.lockFieldUnchanged }
        if !cleared { throw HostScreenProbeError.lockFieldNotCleared }
        if let modeChangeError = modeRoundTrip.error { throw modeChangeError }
    }

    private static func pressBackspace(times: Int, through router: CanvasSurfaceEventRouter) async throws {
        let delete: UInt16 = 51
        for _ in 0..<times {
            _ = await router.route(.key(keyCode: delete, isDown: true, modifiers: []))
            _ = await router.route(.key(keyCode: delete, isDown: false, modifiers: []))
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    /// `PointerDelivery` carries no description of its own; this names each
    /// case (and the point a `.delivered` one actually carried) for the one
    /// diagnostic line printed when a route is anything else.
    private static func describe(_ delivery: PointerDelivery) -> String {
        switch delivery {
        case let .delivered(point): return "delivered(\(point.x),\(point.y))"
        case .deliveredWithoutLocation: return "deliveredWithoutLocation"
        case .coalesced: return "coalesced"
        case .droppedNoViewport: return "droppedNoViewport"
        case .droppedInvalidLocation: return "droppedInvalidLocation"
        case .droppedNotConnected: return "droppedNotConnected"
        case .droppedFailed: return "droppedFailed"
        case .droppedNoChange: return "droppedNoChange"
        }
    }

    private static func presentedFrameCount(_ runner: ClientSessionRunner) async -> Int {
        await runner.latency.metrics().samples(for: .present).count
    }

    private static func pollFrames(
        atLeast minimum: Int, within seconds: Int, frameCount: () async -> Int
    ) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if await frameCount() >= minimum { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await frameCount() >= minimum
    }

    /// `pollFrames` without the elapsed time it already measures internally
    /// but never reports -- used where how quickly frames resumed is itself
    /// the thing under test, not just whether they eventually did.
    private static func pollFramesElapsed(
        atLeast minimum: Int, within seconds: Int, frameCount: () async -> Int
    ) async -> Double? {
        let startedAt = Date()
        for _ in 0..<(seconds * 10) {
            if await frameCount() >= minimum { return Date().timeIntervalSince(startedAt) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await frameCount() >= minimum ? Date().timeIntervalSince(startedAt) : nil
    }

    /// The last-resort restore this rig owns, used only when the host's own
    /// restore-on-disconnect (CLAUDE.md: "restored when the session ends or
    /// the host quits") did not put the display back within the poll window
    /// above. The same three public CoreGraphics calls
    /// `CoreGraphicsHostScreenModeController` uses, completed `.forSession`
    /// so nothing here can outlive this login session either.
    private static func probeRestoreMode(_ mode: CGDisplayMode, on displayID: UInt32) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            return false
        }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }

    /// The display is on right now, in real pixels and refresh rate --
    /// enough to tell one mode from another without re-deriving anything
    /// `HostScreenModePresentation` already names on the wire.
    private struct DisplayModeSnapshot: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double

        init(_ mode: CGDisplayMode) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            refreshRate = mode.refreshRate
        }

        var line: String { "\(pixelWidth)x\(pixelHeight)@\(Int(refreshRate.rounded()))" }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pixelWidth == rhs.pixelWidth
                && lhs.pixelHeight == rhs.pixelHeight
                && Int(lhs.refreshRate.rounded()) == Int(rhs.refreshRate.rounded())
        }
    }

    /// The display this rig arms and drives: the main one, which is where a
    /// window opened with no placement of its own already goes. `enter`
    /// re-checks that its window really stands here before measuring anything
    /// against it.
    private static func targetDisplay() -> DisplaySnapshot? {
        let displays = DisplayInventory.active()
        return displays.first { $0.main } ?? displays.first
    }

    private static func screen(for display: DisplaySnapshot) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
    }

    private static func activeDisplay(containing point: CGPoint) -> DisplaySnapshot? {
        DisplayInventory.active().first { $0.bounds.contains(point) }
    }

    /// AppKit measures the screen space from the bottom-left of the display
    /// holding the menu bar; CoreGraphics, which is what a display's own
    /// bounds and the host's injector both speak, measures down from that same
    /// display's top-left.
    private static func globalDisplayPoint(_ screenPoint: CGPoint) -> CGPoint {
        let menuBarScreen = NSScreen.screens.first
        let flipHeight = menuBarScreen?.frame.maxY ?? 0
        return CGPoint(x: screenPoint.x, y: flipHeight - screenPoint.y)
    }

    private static func displayLocalPoint(_ screenPoint: CGPoint, on display: DisplaySnapshot) -> CGPoint {
        let global = globalDisplayPoint(screenPoint)
        return CGPoint(x: global.x - display.bounds.origin.x, y: global.y - display.bounds.origin.y)
    }

    private static func pollUntil(seconds: Int, condition: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func endpointPort(_ rawPort: String) throws -> NWEndpoint.Port {
        guard let rawPort = UInt16(rawPort), let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw HostScreenProbeError.invalidPort
        }
        return port
    }

    private static func createStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory(),
            withIntermediateDirectories: true
        )
    }

    private static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sensorium", isDirectory: true)
    }

    private static func identityURL() -> URL {
        stateDirectory().appendingPathComponent("local-host-screen-probe-identity.json")
    }

    private static func approvalURL() -> URL {
        stateDirectory().appendingPathComponent("local-host-screen-probe-approval.json")
    }

    private static func usageAndExit() -> Never {
        print("usage: SensoriumLocalHostScreenProbe <pair|arm|wait-idle|enter> "
            + "<tailnet-host|arming-file-path|timeout-seconds> [port] [pairing-code]")
        Foundation.exit(2)
    }
}

/// The window the host is asked to drive: an editable text view on the armed
/// display, floating above the viewer window this probe also opens, so a click
/// aimed at its centre reaches it rather than whatever else this process has
/// on screen.
@MainActor
private final class TargetWindow {
    private let window: NSWindow
    private let textView: NSTextView

    init(screen: NSScreen) {
        let size = CGSize(width: 480, height: 260)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Sensorium host screen probe target"
        window.level = .floating
        textView = NSTextView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width, .height]
        window.contentView = textView
    }

    func show() {
        window.setFrameOrigin(window.frame.origin)
        takeKeyboardFocus()
    }

    func takeKeyboardFocus() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
    }

    func typedText() -> String {
        textView.string
    }

    /// The centre of the text view, in AppKit's own screen space.
    func textCentreInScreenSpace() -> CGPoint {
        let centre = CGPoint(x: textView.bounds.midX, y: textView.bounds.midY)
        let inWindow = textView.convert(centre, to: nil)
        return window.convertPoint(toScreen: inWindow)
    }

    /// The window's centre where a display's own bounds can be asked about it.
    func centreInGlobalDisplaySpace() -> CGPoint {
        let menuBarScreen = NSScreen.screens.first
        let flipHeight = menuBarScreen?.frame.maxY ?? 0
        return CGPoint(x: window.frame.midX, y: flipHeight - window.frame.midY)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// A large window of dense, text-like content standing on the armed display,
/// opened to the middle of a very tall document so a scroll in either
/// direction moves it. Drawn as rows of words rather than glyphs: every row
/// differs from its neighbours, so a scroll changes nearly every pixel it
/// covers, as scrolling a page of text does.
@MainActor
private final class ScrollTargetWindow {
    private static let rowCount = 4000

    private let window: NSWindow

    init(screen: NSScreen) {
        let visible = screen.visibleFrame
        let frame = visible.insetBy(dx: visible.width * 0.1, dy: visible.height * 0.1)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Sensorium host screen probe scroll target"
        window.level = .floating
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.autoresizingMask = [.width, .height]
        let document = DenseRowsView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: scrollView.contentSize.width,
                height: CGFloat(Self.rowCount) * DenseRowsView.rowHeight
            )
        )
        scrollView.documentView = document
        window.contentView = scrollView
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// The window's centre, in AppKit's own screen space.
    func centreInScreenSpace() -> CGPoint {
        CGPoint(x: window.frame.midX, y: window.frame.midY)
    }

    /// The window's centre where a display's own bounds can be asked about it.
    func centreInGlobalDisplaySpace() -> CGPoint {
        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: window.frame.midX, y: flipHeight - window.frame.midY)
    }

    func close() {
        window.orderOut(nil)
    }
}

private final class DenseRowsView: NSView {
    static let rowHeight: CGFloat = 12

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        NSColor.black.setFill()
        let firstRow = max(0, Int(dirtyRect.minY / Self.rowHeight))
        let lastRow = Int(dirtyRect.maxY / Self.rowHeight)
        guard firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            // A different word layout for every row, the same one every time
            // the row is drawn.
            var state = UInt64(row) &* 0x9E37_79B9_7F4A_7C15 | 1
            var x: CGFloat = 8
            while x < bounds.width - 8 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let word = CGFloat(12 + (state >> 33) % 60)
                NSRect(x: x, y: CGFloat(row) * Self.rowHeight + 3, width: word, height: 6).fill()
                x += word + 6
            }
        }
    }
}

/// The size of every frame the viewer decoded and when, written from the
/// runner's decode callback and read from the probe's task.
private final class DecodedFrameSizes: @unchecked Sendable {
    struct Arrival {
        let uptime: Double
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var arrivals: [Arrival] = []

    func record(width: Int, height: Int) {
        let arrival = Arrival(uptime: ProcessInfo.processInfo.systemUptime, width: width, height: height)
        lock.lock()
        arrivals.append(arrival)
        lock.unlock()
    }

    var latest: Arrival? {
        lock.lock()
        defer { lock.unlock() }
        return arrivals.last
    }

    func frames(since uptime: Double) -> [Arrival] {
        lock.lock()
        defer { lock.unlock() }
        return arrivals.filter { $0.uptime >= uptime }
    }
}

/// The exit code `main` reports once `NSApplication.run()` has returned, since
/// the work that decides it finishes inside the event loop rather than around
/// it.
@MainActor
private final class ExitStatus {
    var code: Int32 = 0
}

private enum HostScreenProbeError: Error {
    case invalidPort
    case noTargetDisplay
    case noTargetScreenAfterModeChange
    case sessionIsNotHostScreen
    case windowNotOnArmedDisplay
    case pointerNotDelivered
    case pointerNeverLanded
    case textNeverTyped
    case noPresentedFrames
    case modeListNeverArrived
    case modeChangeTimedOut
    case modeChangeRefused(String)
    case framesDidNotResumeAfterModeChange
    case displayModeDidNotMatchRequest
    case displayNotRestored
    case screenNeverLocked
    case lockFieldUnchanged
    case lockFieldNotCleared
}

/// The newest decoded frame and how many have been decoded, written from the
/// runner's decode callback and read from the probe's task.
private final class LatestDecodedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var decodedCount = 0

    func set(_ newBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = newBuffer
        decodedCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodedCount
    }

    func get() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// One streamed frame copied into RGBA bytes, so two frames can be compared
/// without depending on the decoder's pixel format.
private struct LockScreenFrame {
    let width: Int
    let height: Int
    private let pixels: [UInt8]
    private let image: CIImage

    init(_ buffer: CVPixelBuffer) throws {
        image = CIImage(cvPixelBuffer: buffer)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw HostScreenProbeError.noPresentedFrames
        }
        CIContext().render(
            image,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: image.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        pixels = bytes
    }

    func writePNG(to url: URL) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw HostScreenProbeError.noPresentedFrames
        }
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Compares only the band where the lock screen draws its password
    /// field: centred, between 88% and 95% of the frame's height. The
    /// animated avatar sits just above that band and must stay out of it, or
    /// its motion alone would read as typed dots.
    func passwordRegionDiffers(from other: LockScreenFrame) -> Bool {
        guard width == other.width, height == other.height else { return true }
        let channelThreshold = 24
        let minimumChangedPixels = 20
        var changed = 0
        for y in (height * 88 / 100)..<(height * 95 / 100) {
            for x in (width * 44 / 100)..<(width * 56 / 100) {
                let offset = (y * width + x) * 4
                for channel in 0..<3 where abs(Int(pixels[offset + channel]) - Int(other.pixels[offset + channel])) > channelThreshold {
                    changed += 1
                    break
                }
            }
        }
        return changed >= minimumChangedPixels
    }
}
