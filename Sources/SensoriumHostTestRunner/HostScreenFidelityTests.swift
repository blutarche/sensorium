import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Adaptive fidelity and capture telemetry on a host-screen session.
///
/// A session streams either a session canvas or one existing screen of this
/// machine, and the person watching is owed the same picture control either way:
/// the same ladder, the same capture-delivery report, the same recovery from
/// a capture that delivers nothing, and the same figures behind the viewer's
/// own readout. These drive the coordinator through a host-screen bring-up
/// and then tick it exactly as `HostNetworkSession` does.
///
/// The canvas media slots are fakes that record everything: a decision that
/// reached them rather than the host-screen media would be a session steering
/// a pipeline it is not streaming.
@MainActor
private func fidelityTestDisplay(
    id: UInt32 = 7,
    logicalWidth: Int = 2560,
    logicalHeight: Int = 1440,
    pixelWidth: Int = 5120,
    pixelHeight: Int = 2880
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        modeWidth: logicalWidth,
        modeHeight: logicalHeight,
        modePixelWidth: pixelWidth,
        modePixelHeight: pixelHeight,
        bounds: CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private final class FidelityIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

private let fidelityCurrentMode = HostScreenModeEntry(
    modeID: "5120x2880@2560x1440@60",
    width: 2560,
    height: 1440,
    pixelWidth: 5120,
    pixelHeight: 2880,
    refreshRate: 60,
    isHiDPI: true
)

private let fidelityReadableMode = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

/// Stands in for the real badge window, which would put an `NSPanel` on a
/// physical display. Kept as its own copy, since the equivalent fake in
/// `HostScreenCoordinatorTests.swift` is private to that file.
@MainActor
private final class FidelityBadgeDisplay: HostScreenBadgeDisplaying {
    func show() {}
    func hide() {}
}

@MainActor
private func fidelityModeController(displayID: UInt32) -> FakeHostScreenModeController {
    let modes = FakeHostScreenModeController()
    modes.modesByDisplay[displayID] = [fidelityCurrentMode, fidelityReadableMode]
    modes.currentModeIDByDisplay[displayID] = fidelityCurrentMode.modeID
    return modes
}

/// A host-screen session ready to be ticked: an admitted controller, the
/// coordinator around it, and the canvas media slots that must stay
/// untouched for the whole of it.
@MainActor
private func makeFidelityFixture(
    display: DisplaySnapshot,
    flowReportSeconds: Double = MediaFlowMonitor.defaultReportInterval,
    onEvent: (@Sendable (String) -> Void)? = nil,
    onSessionEnded: (@Sendable () -> Void)? = nil,
    modeController: FakeHostScreenModeController? = nil,
    latencyRecorder: HostMediaLatencyRecorder? = nil,
    // Never the process-wide default: a test that drives a capture all the
    // way to dead would otherwise refuse every canvas request in every group
    // that runs after it.
    captureAvailability: HostCaptureAvailability = HostCaptureAvailability(),
    streamScaleClock: SteppedClock? = nil,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration, CGDirectDisplayID) -> any CanvasMediaStreaming
) -> (
    coordinator: HostSessionCoordinator,
    controller: HostSessionController,
    canvasMedia: FakeScalableCanvasMedia
) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: FidelityIdleSignal(),
        hostScreenModeController: modeController
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))

    let canvasMedia = FakeScalableCanvasMedia()
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in canvasMedia },
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        latencyRecorder: latencyRecorder,
        streamScaleSettleSeconds: 0.05,
        streamScaleSettleWait: { seconds in
            if let streamScaleClock {
                await streamScaleClock.wait(seconds)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        },
        streamScaleNowSecondsProvider: {
            streamScaleClock?.now ?? Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
        },
        flowReportSeconds: flowReportSeconds,
        onEvent: onEvent,
        onSessionEnded: onSessionEnded,
        hostScreenMediaFactory: hostScreenMediaFactory,
        captureAvailability: captureAvailability
    )
    return (coordinator, controller, canvasMedia)
}

@MainActor
private func startFidelitySession(_ fixture: (
    coordinator: HostSessionCoordinator,
    controller: HostSessionController,
    canvasMedia: FakeScalableCanvasMedia
), whileAdmitted messagesBeforeCapture: [SensoriumMessage] = []) async {
    guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return
    }
    // The reply comes back through the writer, and a fixture with a mode
    // controller writes its mode list straight after it, so the first
    // written message is the one that says the session was admitted.
    var written: [SensoriumMessage] = []
    _ = try! await fixture.coordinator.handle(.hostScreenRequest(
        token: entry.opaqueToken,
        resumeTicket: nil
    )) { message in
        written.append(message)
        // The viewer is told the screen is ready before capture exists, and
        // may answer at once; what it sends here lands before the picture.
        if case .hostScreenReady = message {
            for early in messagesBeforeCapture {
                _ = try await fixture.coordinator.handleWritingResponse(early)
            }
        }
    }
    guard case .hostScreenReady = written.first else {
        expect(false, "the fixture's host-screen request is admitted, got \(written)")
        return
    }
}

/// One tick's worth of a stream capturing steadily and losing `dropped` of
/// those frames before the encoder ever sees them. Six in sixty is past
/// `StreamFidelityPressure.admissionDropFraction`, which is what names the
/// encoder as the stage under pressure.
private func fidelityPressureCounts(afterTicks ticks: Int, droppingPerTick dropped: Int) -> HostFrameCounts {
    HostFrameCounts(
        captured: 60 * ticks,
        encoded: (60 - dropped) * ticks,
        encodeSubmissionFailures: 0,
        encoderInputDropped: dropped * ticks
    )
}

@MainActor
func runHostScreenFidelityTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    do {
        // The capture-delivery report reads the host-screen media's counters
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            flowReportSeconds: 5,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        // The first tick is only the reading the next one is measured
        // against. The canvas media's counters stay at zero throughout, so a
        // report built from them would say nothing was delivered at all.
        await fixture.coordinator.tickFidelity(atSeconds: 0)
        hostScreenMedia.frameCounts = HostFrameCounts(
            captured: 0,
            encoded: 0,
            encodeSubmissionFailures: 0,
            unchangedFrames: 100,
            noChangeNotices: 5,
            otherStatusDeliveries: 10
        )
        await fixture.coordinator.tickFidelity(atSeconds: 5)

        let captureLines = events.messages.filter { $0.contains(" capture over ") }
        expect(
            captureLines == [
                "host-screen display 7 capture over 5.0s: 0 screen changes, 100 unchanged frames, "
                    + "5 no-change notices, 10 other deliveries",
            ],
            "a host-screen session says what its capture stream delivered, from the host-screen media's own "
                + "counters and naming the screen it is actually streaming, got \(captureLines)"
        )
        expect(
            fixture.canvasMedia.appliedFramesPerSecond.isEmpty
                && fixture.canvasMedia.appliedQualityScales.isEmpty,
            "and nothing about it reaches the canvas media this session never streamed"
        )
    }
    print("PASS: a host-screen session reports what its capture stream delivered, from the media it is actually streaming")

    do {
        // Sustained pressure steps the host-screen media's own fidelity down
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        // One tick to read the counters the next takes its deltas against,
        // three of warm-up, then one pressured tick per step with the
        // two-second floor between two visible changes.
        for tick in 0...8 {
            hostScreenMedia.frameCounts = fidelityPressureCounts(afterTicks: tick + 1, droppingPerTick: 6)
            await fixture.coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            hostScreenMedia.appliedFramesPerSecond == [45, 30],
            "sustained encoder pressure walks the host screen's frame rate down one step at a time, got "
                + "\(hostScreenMedia.appliedFramesPerSecond)"
        )
        expect(
            fixture.canvasMedia.appliedFramesPerSecond.isEmpty,
            "through the media the session streams, never the canvas media it does not, got "
                + "\(fixture.canvasMedia.appliedFramesPerSecond)"
        )
        expect(
            fixture.coordinator.appliedFramesPerSecond(for: surfaceZero) == 30
                && fixture.coordinator.fidelityLimitReason(for: surfaceZero) == FidelityLimitReason.encoder,
            "and the viewer is told the rate actually applied and which stage held it back, got "
                + "\(fixture.coordinator.appliedFramesPerSecond(for: surfaceZero)) fps"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.count == 2,
            "one line per applied change, got \(events.messages.filter { $0.hasPrefix("fidelity now") })"
        )
    }
    print("PASS: sustained pressure on a host-screen session steps its fidelity down through the media it is streaming")

    do {
        // The viewer's decoder is named with the device and the display
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in FakeScalableCanvasMedia() }
        )
        await startFidelitySession(fixture)
        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerTelemetry(
                ViewerTelemetrySample(
                    surfaceID: surfaceZero.wireValue,
                    endToEnd: nil,
                    receive: nil,
                    decode: nil,
                    presentedFramesPerSecond: 30,
                    decodedFramesPerSecond: 30,
                    receivedBitsPerSecond: nil,
                    decodesInHardware: false
                )
            )
        )
        let decoderLines = events.messages.filter { $0.contains("decodes in") }
        expect(
            decoderLines == ["viewer Kestrel Laptop Pro decodes in software on host-screen display 7"],
            "the line names the armed device and the display it is watching, got \(decoderLines)"
        )
    }
    print("PASS: a host-screen session names the viewer's decoder with the device and the display it streams")

    do {
        // Stopping the session stops the ticking with it
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            flowReportSeconds: 5,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        await fixture.coordinator.tickFidelity(atSeconds: 0)
        hostScreenMedia.frameCounts = HostFrameCounts(
            captured: 0,
            encoded: 0,
            encodeSubmissionFailures: 0,
            unchangedFrames: 100
        )
        await fixture.coordinator.tickFidelity(atSeconds: 5)
        expect(
            events.messages.filter { $0.contains(" capture over ") }.count == 1,
            "the live session reports once per interval"
        )

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: "test teardown"))
        expect(
            hostScreenMedia.stopCount == 1,
            "teardown stops the host-screen capture exactly once, got \(hostScreenMedia.stopCount)"
        )
        expect(
            fixture.canvasMedia.stopCount == 0,
            "and never stops a canvas media this session never started, got \(fixture.canvasMedia.stopCount)"
        )

        // A stopped surface has nothing to decide about. Everything the tick
        // would read is moved underneath it to prove it is not being read.
        fixture.canvasMedia.frameCounts = fidelityPressureCounts(afterTicks: 40, droppingPerTick: 6)
        for tick in 10...30 {
            await fixture.coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            events.messages.filter { $0.contains(" capture over ") }.count == 1,
            "and a tick after the session ended reports nothing, got "
                + "\(events.messages.filter { $0.contains(" capture over ") })"
        )
        expect(
            fixture.canvasMedia.appliedFramesPerSecond.isEmpty
                && fixture.canvasMedia.reconfiguredScales.isEmpty,
            "and steers nothing, got \(fixture.canvasMedia.appliedFramesPerSecond)"
        )
    }
    print("PASS: ending a host-screen session clears its streaming surface, so a later tick decides nothing")

    do {
        // A display-mode change keeps the surface streaming and warms up
        let display = fidelityTestDisplay()
        let modes = fidelityModeController(displayID: display.id)
        var captures: [FakeScalableCanvasMedia] = []
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-fidelity-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let accountable = HostScreenAccountableMedia(
            rawFactory: { _, _ in
                let capture = FakeScalableCanvasMedia()
                captures.append(capture)
                return capture
            },
            sessionLog: HostScreenSessionLogStore(url: logURL),
            deviceName: { "Kestrel Laptop Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _, _ in FidelityBadgeDisplay() }
        )
        let fixture = makeFidelityFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { accountable.makeMedia($0, displayID: $1) }
        )
        await startFidelitySession(fixture)
        await fixture.coordinator.tickFidelity(atSeconds: 0)

        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fidelityReadableMode.modeID)) { _ in }
        guard captures.count == 2 else {
            expect(false, "the mode change builds a second capture inside the same session, got \(captures.count)")
            return
        }

        // The warm-up the rebuilt capture is owed: its opening key frame and
        // every buffer filling for the first time are not the cost of what it
        // is about to stream steadily.
        for tick in 1...StreamFidelityController.warmUpTicks {
            captures[1].frameCounts = fidelityPressureCounts(afterTicks: tick, droppingPerTick: 6)
            await fixture.coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            captures[1].appliedFramesPerSecond.isEmpty,
            "a rebuilt capture's first ticks decide nothing, got \(captures[1].appliedFramesPerSecond)"
        )

        for tick in (StreamFidelityController.warmUpTicks + 1)...(StreamFidelityController.warmUpTicks + 4) {
            captures[1].frameCounts = fidelityPressureCounts(afterTicks: tick, droppingPerTick: 6)
            await fixture.coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            captures[1].appliedFramesPerSecond == [45, 30],
            "then the surface is still streaming and the controller steers the capture that replaced the first. "
                + "This display is already at the minimum scale, so the frame rate is the lever left to it. Got "
                + "\(captures[1].appliedFramesPerSecond)"
        )
        expect(
            captures[0].appliedFramesPerSecond.isEmpty,
            "never the capture the mode change already stopped, got \(captures[0].appliedFramesPerSecond)"
        )
    }
    print("PASS: a host-screen display-mode change keeps the surface streaming and warms the rebuilt capture up")

    do {
        // The session's own poll ticks a host-screen session too
        let display = fidelityTestDisplay()
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceActivitySignal: FidelityIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(offered, _) = try! controller.offerHostScreenList(),
              let entry = offered.first else {
            expect(false, "the fixture's offer names at least one display")
            return
        }

        // A frame this surface really captured, so the snapshot the poll
        // builds has a surface to report on at all.
        let latencyRecorder = HostMediaLatencyRecorder()
        latencyRecorder.recordCapture(
            surface: surfaceZero, presentationTimeNanoseconds: 0, atNanoseconds: 0
        )
        let channel = FakeHostByteChannel(scriptedPackets: [
            .control(.hostScreenRequest(
                token: entry.opaqueToken,
                resumeTicket: nil
            ))
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            latencyRecorder: latencyRecorder
        )
        let hostScreenMedia = FakeScalableCanvasMedia()
        session.attach(coordinator: HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: session,
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace()),
            latencyRecorder: latencyRecorder,
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        ))
        session.start()
        // Two send intervals, so a tick has genuinely come round rather than
        // being caught on the edge of the first one.
        try! await Task.sleep(for: .seconds(TelemetryPolicy.sendIntervalSeconds * 2.5))
        let telemetryPackets = channel.sentPackets.compactMap { packet -> [SurfaceTelemetrySample]? in
            guard case let .control(.telemetry(surfaces)) = packet else { return nil }
            return surfaces
        }
        expect(
            !telemetryPackets.isEmpty,
            "a live host-screen session sends the figures its viewer's readout is built from, got "
                + "\(channel.sentPackets.count) packets and no telemetry among them"
        )
        expect(
            telemetryPackets.contains { samples in
                samples.contains {
                    $0.surfaceID == surfaceZero.wireValue && $0.appliedFramesPerSecond != nil
                }
            },
            "naming the frame rate the fidelity ladder actually applied, got \(telemetryPackets)"
        )
        expect(
            !controller.isSessionAuthenticatedAndActive,
            "while the narrower gate that lets a connection write this machine's pasteboard is untouched: a "
                + "host-screen session opens no canvas of its own"
        )
        session.stop()
    }
    print("PASS: a host-screen session's own poll ticks the fidelity ladder and sends the viewer its figures")

    do {
        // Every per-surface line names the screen, never a canvas
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let ended = DiagnosticsRecorder()
        let availability = HostCaptureAvailability()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            flowReportSeconds: 1,
            onEvent: { events.record($0) },
            onSessionEnded: { ended.record("ended") },
            captureAvailability: availability,
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        // A capture that starts and then delivers nothing of any kind: the
        // counters never move off the baseline the first tick took.
        for tick in 0...4 {
            await fixture.coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            fixture.coordinator.hasEnded && ended.messages == ["ended"] && availability.isUnavailable,
            "the scenario reaches the dead-capture path it is about"
        )
        expect(
            events.messages.contains(
                "host-screen display 7 capture has delivered nothing at all since it started; "
                    + "building it again once"
            ),
            "the rebuild line names the screen this session streams, got \(events.messages)"
        )
        expect(
            events.messages.contains("host-screen display 7 capture delivered nothing after being built again"),
            "and so does the line that gives up on it, got \(events.messages)"
        )
        expect(
            !events.messages.contains { $0.contains("canvas 0") },
            "nothing a person reads calls a host screen a canvas, got "
                + "\(events.messages.filter { $0.contains("canvas 0") })"
        )
    }
    print("PASS: a host-screen session's own log lines name the screen it streams, never a canvas it never created")
}

/// The viewer's own window geometry on a host-screen session.
///
/// A host-screen session owns no canvas, so every scale decision has to be
/// taken against the real display's geometry instead. The viewer reports the
/// size of the window it is drawing into, the host encodes at that fraction
/// of the screen's logical size, and two hard ceilings bound it: the
/// display's own pixels, beyond which there is nothing further to encode, and
/// the largest frame the hardware H.264 encoder accepts.
@MainActor
func runHostScreenViewerGeometryTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]
    let surfaceOne = CanvasSurfaceID.allCases[1]

    do {
        // The viewer's drawable size sets the host screen's stream scale
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(
                logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160
            ),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3360, pixelHeight: 1890, surfaceID: nil, maximumScale: nil)
        )
        expect(
            fixture.controller.requestedStreamScale(for: surfaceZero) == 1.75,
            "a host-screen session derives the stream scale from the real display's own logical size, got "
                + "\(String(describing: fixture.controller.requestedStreamScale(for: surfaceZero)))"
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.75] },
            "and the media it is actually streaming is reconfigured to it, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
        expect(
            fixture.canvasMedia.reconfiguredScales.isEmpty,
            "never the canvas media this session never started, got \(fixture.canvasMedia.reconfiguredScales)"
        )
    }
    print("PASS: a host-screen session honours the viewer's drawable size")

    do {
        // The encode is exactly the size the viewer draws, not a nearby step
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 1926, surfaceID: nil, maximumScale: nil)
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { !hostScreenMedia.reconfiguredScales.isEmpty },
            "a 3840x1926 drawable over a 2560x1440 screen rebuilds the stream"
        )
        let geometry = fixture.controller.hostScreenGeometry!
        let applied = hostScreenMedia.reconfiguredScales.last!
        let target = HostScreenEncoderSizing.resolve(for: geometry).configuration
            .scaled(toStreamScale: applied)
        expect(
            target.encodeWidth == 3424 && target.encodeHeight == 1926,
            "and encodes exactly the 3424x1926 the viewer draws, got "
                + "\(target.encodeWidth)x\(target.encodeHeight) at \(applied)x"
        )
        expect(
            events.messages.contains("stream scale now 1.34x: encoding 3424x1926"),
            "and says so in the log, got \(events.messages.filter { $0.hasPrefix("stream scale now") })"
        )
    }
    print("PASS: a host-screen session encodes exactly the size the viewer draws")

    do {
        // The display's own pixels are a ceiling on the scale
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(
                logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 1920, pixelHeight: 1080
            ),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil)
        )
        expect(
            fixture.controller.requestedStreamScale(for: surfaceZero) == 1.0,
            "a viewer asking for more pixels than the display has gets the display's own size, got "
                + "\(String(describing: fixture.controller.requestedStreamScale(for: surfaceZero)))"
        )
        try! await Task.sleep(for: .milliseconds(300))
        expect(
            hostScreenMedia.reconfiguredScales.allSatisfy { $0 <= 1.0 },
            "and nothing above it ever reaches the encoder, got \(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: the host screen's own pixel count is a ceiling on the stream scale")

    do {
        // The hardware encoder's largest frame is the other ceiling
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 5120, pixelHeight: 2880, surfaceID: nil, maximumScale: nil)
        )
        // 2560 logical points times 1.6 is exactly
        // `VideoEncoderConfiguration.hardwareH264MaxDimension`.
        expect(
            fixture.controller.requestedStreamScale(for: surfaceZero) == 1.6,
            "a 5K host screen is held at the largest frame the hardware encoder accepts, got "
                + "\(String(describing: fixture.controller.requestedStreamScale(for: surfaceZero)))"
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.6] },
            "and that is what the encoder is asked for, got \(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: the hardware encoder's own limit is a ceiling on the host screen's stream scale")

    do {
        // A chosen scale works on a host screen, under the same ceilings
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(1.5), surfaceID: nil)
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
            "a person's own choice of scale reaches a host-screen session's encoder, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )

        _ = try! await fixture.coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(2.0), surfaceID: nil)
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5, 1.6] },
            "and is held at the same ceilings the viewer's geometry is, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: a chosen stream scale reaches a host-screen session and is held at its ceilings")

    do {
        // A fixed choice sent before the picture starts is applied when capture comes up
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        _ = try! await fixture.coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(1.5), surfaceID: nil)
        )
        await startFidelitySession(fixture)
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
            "a fixed choice stored before capture existed is applied at bring-up, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: a fixed stream scale sent before a host-screen session starts is applied at bring-up")

    do {
        // Held at the host screen's ceiling, and said so
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        _ = try! await fixture.coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(2.0), surfaceID: nil)
        )
        await startFidelitySession(fixture)
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.6] },
            "a stored fixed choice above the host screen's ceiling is applied at the ceiling, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
        expect(
            fixture.coordinator.clampedStreamScaleFromUserChoice(for: surfaceZero) == 2.0,
            "and reported to the viewer as a clamp of what was chosen"
        )
    }
    print("PASS: a stored fixed stream scale is held at the host screen's ceiling at bring-up")

    do {
        // A fixed choice made after a drawable report still wins at bring-up
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture, whileAdmitted: [
            .viewerDrawableSize(pixelWidth: 3200, pixelHeight: 1800, surfaceID: nil, maximumScale: nil),
            .streamScalePreference(.fixed(1.5), surfaceID: nil),
        ])
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
            "a fixed choice made after a drawable report is what bring-up applies, not the drawable's fit, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: a fixed stream scale outranks an earlier drawable report at host-screen bring-up")

    do {
        // An automatic preference still applies the stored drawable request at bring-up
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture, whileAdmitted: [
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil),
        ])
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
            "under .automatic a stored drawable request is applied at bring-up, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: an automatic stream scale applies the stored drawable request at host-screen bring-up")

    do {
        // The viewer's focus report is accepted on a host-screen session
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! fixture.controller.handle(.viewerFocus(surfaceID: nil, hasViewerFocus: true))
        expect(
            fixture.controller.focusedSurface == surfaceZero,
            "a host-screen session accepts the viewer's focus report, got "
                + "\(String(describing: fixture.controller.focusedSurface?.wireValue))"
        )
        _ = try! fixture.controller.handle(.viewerFocus(surfaceID: nil, hasViewerFocus: false))
        expect(
            fixture.controller.focusedSurface == nil,
            "and clears it when the person looks at a local app"
        )
    }
    print("PASS: a host-screen session accepts the viewer's focus report")

    do {
        // A report naming the surface no host-screen session streams is refused
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            {
                _ = try fixture.controller.handle(.viewerDrawableSize(
                    pixelWidth: 3840, pixelHeight: 2160, surfaceID: surfaceOne.wireValue, maximumScale: nil
                ))
            },
            "a drawable size naming a surface this host-screen session does not stream is refused"
        )
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            {
                _ = try fixture.controller.handle(.viewerFocus(
                    surfaceID: surfaceOne.wireValue, hasViewerFocus: true
                ))
            },
            "and so is a focus report naming it"
        )
        expect(
            fixture.controller.requestedStreamScale(for: surfaceOne) == nil,
            "neither leaves anything behind on that surface"
        )
    }
    print("PASS: a host-screen session refuses a report naming a surface it does not stream")

    do {
        // Neither a canvas nor a host screen, and no authentication
        let unauthenticated = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            {
                _ = try unauthenticated.handle(.viewerDrawableSize(
                    pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil
                ))
            },
            "an unauthenticated peer cannot size this host's encoder"
        )
        let authenticated = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            {
                _ = try authenticated.handle(.viewerDrawableSize(
                    pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil
                ))
            },
            "and a connection streaming neither a canvas nor a host screen has nothing to size"
        )
    }
    print("PASS: a drawable size still needs authentication and something actually streaming")

    do {
        // A screen that goes quiet takes its resolution back
        let hostScreenMedia = FakeScalableCanvasMedia()
        let latency = HostMediaLatencyRecorder()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(
                logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160
            ),
            onEvent: { events.record($0) },
            latencyRecorder: latency,
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)
        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil)
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [2.0] },
            "the session opens at the scale the viewer's window asked for, got \(hostScreenMedia.reconfiguredScales)"
        )

        var captured = 0
        var dropped = 0
        var presentationTime: Int64 = 0
        /// One second of a host screen producing `frames` changes and losing
        /// `losses` of them before the encoder. Every frame that did reach the
        /// encoder is timed, cheaply: an encode that fits the frame period is
        /// exactly the evidence fidelity is taken back on, and a quiet screen
        /// produces few such samples rather than none.
        func tick(atSeconds seconds: Double, frames: Int, losses: Int) async {
            captured += frames
            dropped += losses
            for _ in 0..<(frames - losses) {
                presentationTime += 16_666_666
                latency.recordEncodeSubmit(
                    surface: surfaceZero,
                    presentationTimeNanoseconds: presentationTime,
                    atNanoseconds: presentationTime
                )
                latency.recordEncodeOutput(
                    surface: surfaceZero,
                    presentationTimeNanoseconds: presentationTime,
                    atNanoseconds: presentationTime + 5_000_000
                )
            }
            hostScreenMedia.frameCounts = HostFrameCounts(
                captured: captured,
                encoded: captured - dropped,
                encodeSubmissionFailures: 0,
                encoderInputDropped: dropped
            )
            await fixture.coordinator.tickFidelity(atSeconds: seconds)
            // A scale change is debounced before it reaches the encoder, so
            // the settle window has to actually pass between two ticks.
            try? await Task.sleep(for: .milliseconds(80))
        }

        var seconds = 0.0
        while seconds < 40, fixture.coordinator.appliedStreamScale(for: surfaceZero) == 2.0 {
            await tick(atSeconds: seconds, frames: 60, losses: 6)
            seconds += 1
        }
        expect(
            fixture.coordinator.appliedStreamScale(for: surfaceZero) == 1.75,
            "sustained encoder pressure eventually spends resolution, got "
                + "\(fixture.coordinator.appliedStreamScale(for: surfaceZero))"
        )

        // Three frames a second is a person reading a page, not a screen so
        // still that the ladder's whole-scale lift applies: it is above
        // `StreamFidelityPressure.stillCapturedDeltaLimit`, so this resolution has
        // to be earned back the ordinary way, on the ordinary run of
        // unpressured ticks.
        let quietFrom = seconds
        while seconds < quietFrom + 40, fixture.coordinator.appliedStreamScale(for: surfaceZero) < 2.0 {
            await tick(atSeconds: seconds, frames: 3, losses: 0)
            seconds += 1
        }
        expect(
            fixture.coordinator.appliedStreamScale(for: surfaceZero) == 2.0,
            "a quiet screen takes the resolution back: a tick with nothing wrong in it is clean evidence even "
                + "when few frames were produced, got "
                + "\(fixture.coordinator.appliedStreamScale(for: surfaceZero)) after "
                + "\(Int(seconds - quietFrom)) quiet ticks"
        )
        expect(
            hostScreenMedia.reconfiguredScales.last == 2.0,
            "and the media it is streaming is reconfigured back up to it, got "
                + "\(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: a host-screen session takes its resolution back on a quiet screen")

    do {
        // The line a person reads names the scale they chose
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        // This display is 2560 points wide, so the hardware encoder's own
        // limit holds it to 1.60x however much a person asks for.
        _ = try! await fixture.coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(2.0), surfaceID: nil)
        )
        expect(
            events.messages.contains(
                "stream scale 2.00x requested but clamped to 1.60x by the host screen\u{2019}s own pixels "
                    + "and this machine\u{2019}s encoder"
            ),
            "the clamp line names what the person chose and what streams instead, got \(events.messages)"
        )

        // Two ceilings can cut one request down in turn, and only the first of
        // them sees the number a person actually chose. What survives the
        // first is nobody's request, so it is never what the second reports.
        expect(
            HostSessionCoordinator.scaleAPersonAskedFor(
                StreamScaleResolution(scale: 1.25, clampedFromUserChoice: 2.0)
            ) == 2.0,
            "a resolution already cut down from a person's choice still reports that choice, got "
                + "\(HostSessionCoordinator.scaleAPersonAskedFor(StreamScaleResolution(scale: 1.25, clampedFromUserChoice: 2.0)))"
        )
        expect(
            HostSessionCoordinator.scaleAPersonAskedFor(
                StreamScaleResolution(scale: 1.5, clampedFromUserChoice: nil)
            ) == 1.5,
            "and a resolution nothing has cut down reports itself"
        )
    }
    print("PASS: a clamped host-screen scale is logged against the scale a person chose")

    do {
        // The host echoes the scale it derived, and logs it once per change
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(
                id: 7, logicalWidth: 2048, logicalHeight: 1152, pixelWidth: 4096, pixelHeight: 2304
            ),
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)

        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3584, pixelHeight: 2016, surfaceID: nil, maximumScale: nil)
        )
        expect(
            fixture.coordinator.hostRequestedStreamScale(for: surfaceZero) == 1.75,
            "the coordinator holds the scale it derived, for the telemetry tick to echo, got "
                + "\(String(describing: fixture.coordinator.hostRequestedStreamScale(for: surfaceZero)))"
        )
        expect(
            events.messages.filter { $0.hasPrefix("viewer drawable") } == [
                "viewer drawable 3584x2016 px on host-screen display 7: scale 1.75x",
            ],
            "one operator line names the drawable size and the scale derived from it, got "
                + "\(events.messages.filter { $0.hasPrefix("viewer drawable") })"
        )

        // The same drawable size again decides nothing new
        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3584, pixelHeight: 2016, surfaceID: nil, maximumScale: nil)
        )
        expect(
            events.messages.filter { $0.hasPrefix("viewer drawable") }.count == 1,
            "repeating the same drawable size logs nothing further, got "
                + "\(events.messages.filter { $0.hasPrefix("viewer drawable") })"
        )

        // A later resize that derives a different scale gets its own line
        _ = try! await fixture.coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3072, pixelHeight: 1728, surfaceID: nil, maximumScale: nil)
        )
        expect(
            fixture.coordinator.hostRequestedStreamScale(for: surfaceZero) == 1.5,
            "a later resize updates the echoed scale, got "
                + "\(String(describing: fixture.coordinator.hostRequestedStreamScale(for: surfaceZero)))"
        )
        expect(
            events.messages.filter { $0.hasPrefix("viewer drawable") } == [
                "viewer drawable 3584x2016 px on host-screen display 7: scale 1.75x",
                "viewer drawable 3072x1728 px on host-screen display 7: scale 1.50x",
            ],
            "and gets its own log line, got \(events.messages.filter { $0.hasPrefix("viewer drawable") })"
        )

        // The telemetry sample itself carries what the coordinator echoes
        hostScreenMedia.frameCounts = HostFrameCounts(captured: 10, encoded: 10, encodeSubmissionFailures: 0)
        var builder = HostTelemetrySnapshotBuilder()
        let samples = builder.snapshot(
            metrics: { _ in SessionMetrics() },
            frameCounts: { $0 == surfaceZero ? hostScreenMedia.frameCounts : HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0) },
            sendQueueDropped: { _ in 0 },
            appliedStreamScale: { fixture.coordinator.appliedStreamScale(for: $0) },
            sustainableScaleCeiling: { fixture.coordinator.sustainableScaleCeiling(for: $0) },
            clampedFromUserChoice: { fixture.coordinator.clampedStreamScaleFromUserChoice(for: $0) },
            hostRequestedStreamScale: { fixture.coordinator.hostRequestedStreamScale(for: $0) },
            appliedFramesPerSecond: { fixture.coordinator.appliedFramesPerSecond(for: $0) },
            qualityScale: { fixture.coordinator.appliedQualityScale(for: $0) },
            fidelityLimitReason: { fixture.coordinator.fidelityLimitReason(for: $0) },
            atNanoseconds: 1_000_000_000
        )
        expect(
            samples.count == 1 && samples[0].hostRequestedStreamScale == 1.5,
            "the telemetry sample carries the scale the host derived, for the viewer's own telemetry to echo, got "
                + "\(samples.first?.hostRequestedStreamScale.map(String.init(describing:)) ?? "no sample")"
        )
    }
    print("PASS: a host-screen session echoes the scale it derived and logs it once per change")

    do {
        // A viewer sizes its window as soon as it is told the screen is
        // ready, which can be before capture has started. Its request must
        // still be applied once the stream is running, not lost to a settle
        // timer that fired too early.
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the fixture's offer names at least one display")
            return
        }
        let coordinator = fixture.coordinator
        _ = try! await coordinator.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) { message in
            guard case .hostScreenReady = message else { return }
            _ = try await coordinator.handle(
                .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2160, surfaceID: nil, maximumScale: nil)
            ) { _ in }
            try await Task.sleep(for: .milliseconds(300))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
            "a scale asked for before capture started is applied once it runs, got \(hostScreenMedia.reconfiguredScales)"
        )
    }
    print("PASS: a stream scale asked for before a host-screen capture starts is applied once it runs")
}

/// The coordinator's stream-scale holds, on a clock that moves only when a
/// test advances it. A wait is a suspended sleeper that resumes once the
/// clock passes its deadline, or at once if its task is cancelled, so a
/// two-second hold costs no real time and a report that arrives during a
/// hold arrives exactly where the test puts it.
private final class SteppedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowSeconds: Double = 0
    private var nextID = 0
    private var sleepers: [Int: (deadline: Double, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var cancelledBeforeSleeping: Set<Int> = []

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return nowSeconds
    }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func wait(_ seconds: Double) async {
        let id = allocateSleeperID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                let wasCancelled = cancelledBeforeSleeping.remove(id) != nil
                if !wasCancelled {
                    sleepers[id] = (nowSeconds + seconds, continuation)
                }
                lock.unlock()
                if wasCancelled {
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil {
                cancelledBeforeSleeping.insert(id)
            }
            lock.unlock()
            sleeper?.continuation.resume()
        }
    }

    private func allocateSleeperID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    func advance(by seconds: Double) {
        lock.lock()
        nowSeconds += seconds
        let due = sleepers.filter { $0.value.deadline <= nowSeconds }.map(\.key)
        let continuations = due.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        lock.unlock()
        continuations.forEach { $0.resume() }
    }
}

/// A window being dragged or a strip of controls appearing reports a new
/// drawable size on every frame, and each rebuild of capture and encode is a
/// visible gap. The host waits for the drawable to stop moving, then streams
/// exactly the latest size. Every step below is a binary fraction of a
/// second, so the clock's sums are exact.
@MainActor
func runHostScreenDrawableCoalescingTests() async {
    func drawable(_ width: Double, _ height: Double) -> SensoriumMessage {
        .viewerDrawableSize(pixelWidth: width, pixelHeight: height, surfaceID: nil, maximumScale: nil)
    }

    /// A host-screen session on a 2560x1440 display whose holds run on
    /// `clock`, already streaming at 1.5x when `streamingAtOneAndAHalf`.
    func coalescingSession(
        clock: SteppedClock,
        events: DiagnosticsRecorder,
        streamingAtOneAndAHalf: Bool
    ) async -> (coordinator: HostSessionCoordinator, media: FakeScalableCanvasMedia) {
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeFidelityFixture(
            display: fidelityTestDisplay(),
            onEvent: { events.record($0) },
            streamScaleClock: clock,
            hostScreenMediaFactory: { _, _ in hostScreenMedia }
        )
        await startFidelitySession(fixture)
        if streamingAtOneAndAHalf {
            _ = try! await fixture.coordinator.handleWritingResponse(drawable(3840, 2160))
            expect(
                await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 },
                "a drawable report starts a hold"
            )
            clock.advance(by: 0.25)
            expect(
                await waitUntil(timeoutSeconds: 2) { hostScreenMedia.reconfiguredScales == [1.5] },
                "a 3840x2160 drawable streams at 1.5x a quarter second after it arrives, got "
                    + "\(hostScreenMedia.reconfiguredScales)"
            )
        }
        return (fixture.coordinator, hostScreenMedia)
    }

    do {
        // Two reports within the hold: only the latest is applied
        let clock = SteppedClock()
        let events = DiagnosticsRecorder()
        let session = await coalescingSession(clock: clock, events: events, streamingAtOneAndAHalf: false)

        _ = try! await session.coordinator.handleWritingResponse(drawable(3840, 2034))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "the first report starts a hold")
        clock.advance(by: 0.125)
        _ = try! await session.coordinator.handleWritingResponse(drawable(3840, 1926))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "the second report restarts it")
        clock.advance(by: 0.125)
        try! await Task.sleep(for: .milliseconds(20))
        expect(
            session.media.reconfiguredScales.isEmpty,
            "a quarter second after the first report but not the latest, nothing is rebuilt, got "
                + "\(session.media.reconfiguredScales)"
        )
        clock.advance(by: 0.125)
        expect(
            await waitUntil(timeoutSeconds: 2) { session.media.reconfiguredScales == [1.3375] },
            "drawables of 3840x2034 then 3840x1926 within 250 ms rebuild once, at the latest size, got "
                + "\(session.media.reconfiguredScales)"
        )
        expect(
            events.messages.filter { $0.hasPrefix("stream scale now") }
                == ["stream scale now 1.34x: encoding 3424x1926"],
            "and the one rebuild encodes 3424x1926, got \(events.messages.filter { $0.hasPrefix("stream scale now") })"
        )
    }
    print("PASS: drawable reports within the hold rebuild once, at the latest size")

    do {
        // Growth, or a drop of more than one quantum, follows a quarter second later
        let clock = SteppedClock()
        let session = await coalescingSession(clock: clock, events: DiagnosticsRecorder(), streamingAtOneAndAHalf: true)

        // Less than one quantum of growth.
        _ = try! await session.coordinator.handleWritingResponse(drawable(4096, 2304))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "a larger drawable starts a hold")
        clock.advance(by: 0.25)
        expect(
            await waitUntil(timeoutSeconds: 2) { session.media.reconfiguredScales == [1.5, 1.6] },
            "a window that grew is streamed at its new size a quarter second later, got "
                + "\(session.media.reconfiguredScales)"
        )

        _ = try! await session.coordinator.handleWritingResponse(drawable(2880, 1620))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "a much smaller drawable starts a hold")
        clock.advance(by: 0.25)
        expect(
            await waitUntil(timeoutSeconds: 2) { session.media.reconfiguredScales == [1.5, 1.6, 1.125] },
            "and one that shrank by more than one quantum is too, got \(session.media.reconfiguredScales)"
        )
    }
    print("PASS: growth and a large shrink are followed a quarter second after the drawable holds still")

    do {
        // A small shrink that reverts within two seconds rebuilds nothing
        let clock = SteppedClock()
        let session = await coalescingSession(clock: clock, events: DiagnosticsRecorder(), streamingAtOneAndAHalf: true)

        _ = try! await session.coordinator.handleWritingResponse(drawable(3840, 1926))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "a small shrink starts a hold")
        clock.advance(by: 1.0)
        _ = try! await session.coordinator.handleWritingResponse(drawable(3840, 2160))
        // Long enough for a settle timer this report started to reach its wait.
        try! await Task.sleep(for: .milliseconds(50))
        expect(
            clock.sleeperCount == 0,
            "a report back at the size already streaming ends the hold, with nothing left waiting"
        )
        clock.advance(by: 2.0)
        try! await Task.sleep(for: .milliseconds(20))
        expect(
            session.media.reconfiguredScales == [1.5],
            "a band that shows for a second and hides again rebuilds nothing, got "
                + "\(session.media.reconfiguredScales)"
        )
    }
    print("PASS: a small shrink that reverts within two seconds rebuilds nothing")

    do {
        // A small shrink that holds for two seconds rebuilds to the exact size
        let clock = SteppedClock()
        let session = await coalescingSession(clock: clock, events: DiagnosticsRecorder(), streamingAtOneAndAHalf: true)

        _ = try! await session.coordinator.handleWritingResponse(drawable(3840, 1926))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "a small shrink starts a hold")
        clock.advance(by: 1.875)
        try! await Task.sleep(for: .milliseconds(20))
        expect(
            session.media.reconfiguredScales == [1.5],
            "short of two seconds a small shrink has rebuilt nothing, got \(session.media.reconfiguredScales)"
        )
        clock.advance(by: 0.125)
        expect(
            await waitUntil(timeoutSeconds: 2) { session.media.reconfiguredScales == [1.5, 1.3375] },
            "a window that stays slightly smaller for two seconds ends up streamed at its exact size, got "
                + "\(session.media.reconfiguredScales)"
        )
    }
    print("PASS: a small shrink that holds for two seconds rebuilds to the exact size")

    do {
        // A report that encodes at the size already streaming rebuilds nothing
        let clock = SteppedClock()
        let session = await coalescingSession(clock: clock, events: DiagnosticsRecorder(), streamingAtOneAndAHalf: false)

        _ = try! await session.coordinator.handleWritingResponse(drawable(3424, 2000))
        expect(await waitUntil(timeoutSeconds: 2) { clock.sleeperCount == 1 }, "the first report starts a hold")
        clock.advance(by: 0.25)
        expect(
            await waitUntil(timeoutSeconds: 2) { session.media.reconfiguredScales == [1.3375] },
            "a 3424x2000 drawable streams at 1.3375x, got \(session.media.reconfiguredScales)"
        )
        // One pixel wider is 3425 / 2560 = 1.337890625x, which encodes at
        // 3425 x 1926.6 and rounds to the same even 3424x1926.
        _ = try! await session.coordinator.handleWritingResponse(drawable(3425, 2000))
        try! await Task.sleep(for: .milliseconds(50))
        expect(clock.sleeperCount == 0, "a report that encodes at the same size starts no hold")
        clock.advance(by: 2.0)
        try! await Task.sleep(for: .milliseconds(20))
        expect(
            session.media.reconfiguredScales == [1.3375],
            "and rebuilds nothing, got \(session.media.reconfiguredScales)"
        )
        expect(
            session.coordinator.appliedStreamScale(for: CanvasSurfaceID.allCases[0]) == 3425.0 / 2560,
            "while the viewer is told the scale it asked for is the one applied, so it reports nothing held back"
        )
    }
    print("PASS: a drawable report that encodes at the size already streaming rebuilds nothing")
}
