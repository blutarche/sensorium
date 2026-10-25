import Foundation
import SensoriumClient
import SensoriumCore

#if canImport(CCairo)

/// `render-chrome <output-dir>`: paints every session-window overlay to a PNG
/// with no compositor at all, so the Linux chrome's own paint code
/// (`SessionChromePainter`, by way of `SessionChromeRenderPreview`) can be
/// checked by eye on a machine with no display attached. Every word and every
/// state comes from the real types the window itself draws from --
/// `ViewerSessionStateMachine`, `SessionHUDPanel`, `HostScreenRefusalCopy` --
/// never invented copy.
@MainActor
enum RenderChromeVerb {
    private static let hostName = "Workstation"
    private static let windowWidth: Double = 1280
    private static let windowHeight: Double = 800
    private static let scales: [Double] = [1.0, 1.5, 2.0]

    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "render-chrome" else { return }
        guard arguments.count == 2 else {
            say("usage: SensoriumViewerProbe render-chrome <output-dir>")
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            say("could not create \(directory.path): \(error)")
            exit(1)
        }
        var failures = 0
        for scale in scales {
            failures += render(scale: scale, into: directory)
        }
        if failures > 0 {
            say("\(failures) render(s) failed")
            exit(1)
        }
        say("wrote every render to \(directory.path)")
        exit(0)
    }

    /// Every overlay and composite for one scale. Returns the number that
    /// failed to write, so the caller can fail the whole run without
    /// stopping partway through -- a later scale's failure is worth knowing
    /// about too.
    private static func render(scale: Double, into directory: URL) -> Int {
        var failures = 0

        func write(_ name: String, _ succeeded: Bool) {
            let path = directory.appendingPathComponent("\(name)@\(scaleTag(scale)).png").path
            if succeeded {
                say("wrote \(path)")
            } else {
                say("FAILED to write \(path)")
                failures += 1
            }
        }

        // The three statuses the status panel actually reaches: a fresh
        // dial, a reconnect with its own two-button row, and a session the
        // host ended, with the three-button recovery row -- exactly what
        // `ViewerSessionStateMachine` produces, never hand-written copy.
        var machine = ViewerSessionStateMachine(hostName: hostName)
        write("status-connecting", SessionChromeRenderPreview.renderOverlay(
            .statusPanel(machine.status), scale: scale, to: url("status-connecting", scale, directory)
        ))

        machine.handle(.canvasReady)
        machine.handle(.connectStarted)
        write("status-reconnecting", SessionChromeRenderPreview.renderOverlay(
            .statusPanel(machine.status), scale: scale, to: url("status-reconnecting", scale, directory)
        ))

        machine.handle(.hostEnded(reasonLine: ViewerSessionFailureCopy.line(for: .hostDisplaysAsleep, hostLabel: hostName)))
        write("status-ended", SessionChromeRenderPreview.renderOverlay(
            .statusPanel(machine.status), scale: scale, to: url("status-ended", scale, directory)
        ))

        let states: [(String, [ViewerSessionEvent])] = [
            ("status-gave-up", [.canvasReady, .sessionEnded, .gaveUp]),
            ("status-stopped-by-host", [.canvasReady, .stoppedByHost(
                reasonLine: ViewerSessionFailureCopy.line(for: .stoppedByHost, hostLabel: hostName))]),
            ("status-host-screen-refused", [.hostScreenConnectEnded(
                reasonLine: ViewerSessionFailureCopy.line(for: .hostScreenRefused(reason: "host-screen-presence-declined"),
                                                          hostLabel: hostName),
                offersVirtualDisplay: false, screenNeverCameUp: true)]),
            ("status-host-screen-private-desktop", [.hostScreenConnectEnded(
                reasonLine: ViewerSessionFailureCopy.line(for: .hostScreenRefused(reason: "host-screen-presence-declined"),
                                                          hostLabel: hostName),
                offersVirtualDisplay: true, screenNeverCameUp: true)]),
            ("status-unverified-host", [.unverifiedHostConnectEnded(
                reasonLine: ViewerSessionFailureCopy.line(for: .unverifiedHost, hostLabel: hostName))])
        ]
        for (name, events) in states {
            var fixture = ViewerSessionStateMachine(hostName: hostName)
            for event in events { fixture.handle(event) }
            write(name, SessionChromeRenderPreview.renderOverlay(
                .statusPanel(fixture.status), scale: scale, to: url(name, scale, directory)
            ))
        }

        let refusalLine = DisplayCountRefusalCopy.line(reason: "display-count-exceeds-host-limit", hostLabel: hostName)
        write("notice", SessionChromeRenderPreview.renderOverlay(
            .notice(refusalLine), scale: scale, to: url("notice", scale, directory)
        ))

        write("hud", SessionChromeRenderPreview.renderOverlay(
            .diagnostics(blocks: diagnosticsBlocks(isAttentionWorthy: false), isFlagged: false),
            scale: scale,
            to: url("hud", scale, directory)
        ))

        write("hud-flagged", SessionChromeRenderPreview.renderOverlay(
            .diagnostics(blocks: diagnosticsBlocks(isAttentionWorthy: true), isFlagged: true),
            scale: scale,
            to: url("hud-flagged", scale, directory)
        ))

        // An address too wide for its row: the host gives up its middle and
        // the ":port" stays whole.
        write("hud-long-address", SessionChromeRenderPreview.renderOverlay(
            .diagnostics(
                blocks: diagnosticsBlocks(
                    isAttentionWorthy: false, hostAddress: "render-node-west-wing-07.tail1234.ts.net:7777"
                ),
                isFlagged: false
            ),
            scale: scale,
            to: url("hud-long-address", scale, directory)
        ))

        // A panel shorter than its readings, scrolled to the top, partway and
        // to the end: a row is cut at the padding, never at the border.
        let scrollingBlocks = diagnosticsBlocks(isAttentionWorthy: false)
        let scrollingHeight = 360.0
        let furthest = SessionChromeRenderPreview.diagnosticsSize(blocks: scrollingBlocks).height - scrollingHeight
        for (name, offset) in [("top", 0.0), ("middle", 331.0), ("bottom", furthest)] {
            write("hud-scrolled-\(name)", SessionChromeRenderPreview.renderDiagnosticsViewport(
                blocks: scrollingBlocks,
                width: SessionChromeRenderPreview.diagnosticsSize(blocks: scrollingBlocks).width,
                height: scrollingHeight,
                offset: offset,
                scale: scale,
                to: url("hud-scrolled-\(name)", scale, directory)
            ))
        }

        write("strip-handle", SessionChromeRenderPreview.renderOverlay(
            .stripHandle, scale: scale, to: url("strip-handle", scale, directory)
        ))

        // The strip's own icon-only clusters and the pin.
        write("strip", SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: hostName, isPinned: false),
            scale: scale,
            width: windowWidth,
            to: url("strip", scale, directory)
        ))

        write("strip-pinned", SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: .shown, hostName: hostName, isPinned: true),
            scale: scale,
            width: windowWidth,
            to: url("strip-pinned", scale, directory)
        ))

        var confirmingStrip = ShortcutStripModel(phase: .live)
        confirmingStrip.toggleRequested()
        _ = confirmingStrip.press(.lockScreen)
        write("strip-confirm", SessionChromeRenderPreview.renderOverlay(
            .strip(visibility: confirmingStrip.visibility, hostName: hostName, isPinned: false),
            scale: scale,
            width: windowWidth,
            to: url("strip-confirm", scale, directory)
        ))

        // The composites: what a real window's chrome looks like live (only
        // the handle) and lost (the status panel, handle hidden) -- both
        // decided by `SessionChromeState` itself, never assembled by hand.
        var liveState = SessionChromeState()
        var liveMachine = ViewerSessionStateMachine(hostName: hostName)
        liveMachine.handle(.canvasReady)
        liveState.apply(status: liveMachine.status, now: 0)
        write("composite-live", SessionChromeRenderPreview.renderComposite(
            state: liveState,
            hostName: hostName,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            scale: scale,
            to: url("composite-live", scale, directory)
        ))

        for (name, target) in [("strip-action-tooltip", ShortcutStripTooltipTarget.action(.showDesktop)),
                               ("strip-pin-tooltip", .pin), ("strip-handle-tooltip", .handle)] {
            var tooltipState = liveState
            if target != .handle {
                tooltipState.toggleStripRequested(now: 0)
                tooltipState.pointerOnStrip(isOnHandleSpot: false, now: 0)
            } else {
                tooltipState.pointerOverHandle(true, now: 0)
                tooltipState.pointerOnStrip(isOnHandleSpot: true, now: 0)
                _ = tooltipState.escapePressed()
                tooltipState.pointerOverHandle(true, now: 0)
            }
            tooltipState.pointerRests(onTooltipTarget: target, now: 0)
            tooltipState.tick(now: ShortcutStripTooltip.delaySeconds)
            write(name, SessionChromeRenderPreview.renderComposite(
                state: tooltipState, hostName: hostName, windowWidth: windowWidth, windowHeight: windowHeight,
                scale: scale, to: url(name, scale, directory)
            ))
        }

        // A fourth composite: a fresh dial, before a first frame has ever
        // arrived -- the opaque scrim case, with no frozen picture to mark
        // stale.
        var connectingState = SessionChromeState()
        let connectingMachine = ViewerSessionStateMachine(hostName: hostName)
        connectingState.apply(status: connectingMachine.status, now: 0)
        write("composite-connecting", SessionChromeRenderPreview.renderComposite(
            state: connectingState,
            hostName: hostName,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            scale: scale,
            to: url("composite-connecting", scale, directory)
        ))

        var lostState = SessionChromeState()
        var lostMachine = ViewerSessionStateMachine(hostName: hostName)
        lostMachine.handle(.canvasReady)
        lostMachine.handle(.sessionEnded)
        lostState.apply(status: lostMachine.status, now: 0)
        write("composite-lost", SessionChromeRenderPreview.renderComposite(
            state: lostState,
            hostName: hostName,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            scale: scale,
            to: url("composite-lost", scale, directory)
        ))

        // A third composite with the strip pinned open and both the
        // diagnostics panel and a notice on screen at once, all below the
        // band the pinned strip claims -- the one arrangement the two
        // overlays above never show, since neither pins the strip.
        var pinnedState = SessionChromeState(isStripPinned: true)
        var pinnedMachine = ViewerSessionStateMachine(hostName: hostName)
        pinnedMachine.handle(.canvasReady)
        pinnedState.apply(status: pinnedMachine.status, now: 0)
        pinnedState.apply(telemetry: diagnosticsTelemetry())
        pinnedState.toggleDiagnosticsRequested()
        pinnedState.showNotice(refusalLine, now: 0)
        write("composite-pinned-diagnostics", SessionChromeRenderPreview.renderComposite(
            state: pinnedState,
            hostName: hostName,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            scale: scale,
            to: url("composite-pinned-diagnostics", scale, directory)
        ))

        return failures
    }

    /// The HUD's rows. `isAttentionWorthy: true` builds a reading with every
    /// warn-toned field filled in -- dropped frames, a limited fidelity, a
    /// stale reading, CPU decoding with its guide link -- so the panel's own warn rows are all on screen at
    /// once; `false` clears the frame drops that `TelemetryAttentionThreshold`
    /// itself would flag, so an unflagged render never shows a warn-worthy
    /// drop count inside a plain border, a combination the real HUD never
    /// draws.
    private static func diagnosticsBlocks(isAttentionWorthy: Bool, hostAddress: String? = nil) -> [SessionHUDBlock] {
        var machine = ViewerSessionStateMachine(hostName: hostName)
        machine.handle(.canvasReady)
        return SessionHUDPanel.blocks(
            telemetry: diagnosticsTelemetry(isAttentionWorthy: isAttentionWorthy, hostAddress: hostAddress),
            session: machine.status
        )
    }

    /// The reading itself, kept separate from `diagnosticsBlocks()` so a
    /// composite that carries `SessionChromeState`'s own telemetry, rather
    /// than a bare block list, can build from the same numbers.
    private static func diagnosticsTelemetry(isAttentionWorthy: Bool = true, hostAddress: String? = nil) -> SessionHUDSnapshot {
        var clientMetrics = SessionMetrics()
        clientMetrics.record(stage: .receive, startedAtNanoseconds: 0, endedAtNanoseconds: 3_200_000)
        clientMetrics.record(stage: .decode, startedAtNanoseconds: 0, endedAtNanoseconds: 4_100_000)
        clientMetrics.record(stage: .present, startedAtNanoseconds: 0, endedAtNanoseconds: 6_800_000)
        clientMetrics.record(stage: .endToEnd, startedAtNanoseconds: 0, endedAtNanoseconds: 18_500_000)
        clientMetrics.record(stage: .inputRoundTrip, startedAtNanoseconds: 0, endedAtNanoseconds: 22_000_000)

        let sample = SurfaceTelemetrySample(
            surfaceID: 1,
            capture: StageLatencySample(p50Nanoseconds: 1_800_000, p95Nanoseconds: 3_100_000),
            encode: StageLatencySample(p50Nanoseconds: 5_400_000, p95Nanoseconds: 9_200_000),
            send: StageLatencySample(p50Nanoseconds: 1_100_000, p95Nanoseconds: 2_000_000),
            framesPerSecond: 58.4,
            encoderInputDropped: isAttentionWorthy ? 2 : 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: isAttentionWorthy ? 1 : 0,
            appliedStreamScale: 1.0,
            sustainableScaleCeiling: 1.0,
            clampedFromUserChoice: nil,
            hostRequestedStreamScale: 1.5,
            appliedFramesPerSecond: 30,
            qualityScale: 0.72,
            fidelityLimitReason: FidelityLimitReason.encoder
        )

        return SessionHUDSnapshot(
            surfaceID: 1,
            availability: .fresh(sample),
            clientMetrics: clientMetrics,
            stream: ClientStreamReading(pixelWidth: 1920, pixelHeight: 1080, bitsPerSecond: 41_500_000, decodedFrameCount: 9_812),
            requestedStreamScale: 1.5,
            requestedDrawablePixelWidth: 2560,
            requestedDrawablePixelHeight: 1600,
            streamScalePreference: .automatic,
            decoder: isAttentionWorthy ? .softwareFallback : .hardwareAccelerated,
            isAttentionWorthy: isAttentionWorthy,
            isPointerCaptured: true,
            presentCompletionP50Nanoseconds: 4_600_000,
            presentationHoldNanoseconds: 2_300_000,
            hostName: hostName,
            hostAddress: hostAddress ?? "\(hostName).tail1234.ts.net:7777",
            endToEndLatencyTrend: SessionHUDTrend(samples: [14, 16, 15, 19, 18.5, 17, 18.5]),
            videoInBitrateTrend: SessionHUDTrend(samples: [38, 40, 41.5, 39, 42, 41.5]),
            fpsTrend: SessionHUDTrend(samples: [59, 58, 60, 57, 58.4]),
            viewerDroppedBeforeDecode: 4,
            viewerDroppedBeforePresent: 1,
            viewerDropsGrew: true,
            softwareDecodeGuide: ViewerRelease.fasterVideoGuide
        )
    }

    private static func url(_ name: String, _ scale: Double, _ directory: URL) -> URL {
        directory.appendingPathComponent("\(name)@\(scaleTag(scale)).png")
    }

    private static func scaleTag(_ scale: Double) -> String {
        scale == scale.rounded() ? "\(Int(scale))x" : "\(scale)x"
    }

    private static func say(_ line: String) {
        print(line)
        fflush(nil)
    }
}

#else

enum RenderChromeVerb {
    @MainActor
    static func runIfRequested() {}
}

#endif
