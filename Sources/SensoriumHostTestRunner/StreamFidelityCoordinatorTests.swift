import Foundation
import SensoriumCore
import SensoriumHost

/// `HostSessionCoordinator` driving `StreamFidelityController`: one controller
/// per streaming surface, one tick per telemetry interval, and every decision
/// applied through the same `CanvasMediaStreaming` seam the rest of the media
/// path uses. Nothing here touches ScreenCaptureKit or VideoToolbox.
///
/// Pressure is stated as ground-truth frame counts rather than measured
/// latency, because that is what a real surface reports: the classifier's own
/// admission-drop rule is what these scenarios drive, and the injected clock
/// makes every step deterministic without a single sleep.
@MainActor
func runStreamFidelityCoordinatorTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    /// One tick's worth of a surface that is capturing steadily and losing
    /// `dropped` of those frames before they ever reach the encoder. Six in
    /// sixty is past `StreamFidelityPressure.admissionDropFraction`, which is
    /// what makes the encoder the class under pressure.
    func counts(afterTicks ticks: Int, droppingPerTick dropped: Int) -> HostFrameCounts {
        HostFrameCounts(
            captured: 60 * ticks,
            encoded: (60 - dropped) * ticks,
            encodeSubmissionFailures: 0,
            encoderInputDropped: dropped * ticks
        )
    }

    /// One tick's worth of a surface that is streaming but has nothing to
    /// show: the same picture delivered again. Quiet, which the coordinator
    /// reads very differently from a stream delivering nothing whatsoever.
    func quietCounts(afterTicks ticks: Int) -> HostFrameCounts {
        HostFrameCounts(
            captured: 0,
            encoded: 0,
            encodeSubmissionFailures: 0,
            unchangedFrames: ticks
        )
    }

    /// What the pipeline and then the transport tell the recorder about a
    /// still-screen refresh handed over at `seconds`, on the clock the
    /// fidelity ticks run on, whose write ended `milliseconds` later.
    func sendRefresh(
        _ recorder: HostMediaLatencyRecorder,
        on surface: CanvasSurfaceID = surfaceZero,
        atSeconds seconds: Double,
        taking milliseconds: Int64,
        succeeded: Bool = true
    ) {
        let handedOffAt = Int64(seconds * 1_000_000_000)
        recorder.recordHostRequestedFrameHandOff(
            surface: surface,
            presentationTimeNanoseconds: handedOffAt,
            atNanoseconds: handedOffAt
        )
        recorder.recordSendCompleted(
            surface: surface,
            presentationTimeNanoseconds: handedOffAt,
            atNanoseconds: handedOffAt + milliseconds * 1_000_000,
            succeeded: succeeded
        )
    }

    func makeCoordinator(
        media: CanvasSurfaceSlots<any CanvasMediaStreaming>,
        videoSink: any CanvasVideoSending = FakeVideoSink(),
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        flowReportSeconds: Double = MediaFlowMonitor.defaultReportInterval,
        onEvent: (@Sendable (String) -> Void)? = nil
    ) -> HostSessionCoordinator {
        HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                privateDesktopOffered: { true }
            ),
            media: media,
            videoSink: videoSink,
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            latencyRecorder: latencyRecorder,
            streamScaleSettleSeconds: 0.05,
            flowReportSeconds: flowReportSeconds,
            onEvent: onEvent
        )
    }

    // Sustained encoder pressure gives up frame rate, one step at a time
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // The first tick only reads the counters a later tick takes its
        // deltas against, and the three after it are the controller's
        // warm-up. What is left is two ticks of losing frames before the
        // class is named, one pressured tick per step, and the two-second
        // floor between two visible changes.
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.appliedFramesPerSecond == [45, 30],
            "sustained encoder pressure walks the frame rate down one step at a time, got \(media.appliedFramesPerSecond)"
        )
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 30
                && coordinator.appliedQualityScale(for: surfaceZero) == 1.0,
            "frame rate is spent before encoder quality: the picture is still full quality at 30 fps"
        )
        expect(
            coordinator.fidelityLimitReason(for: surfaceZero) == FidelityLimitReason.encoder,
            "the viewer is told which stage held the picture back, as the token it can branch on"
        )
        let fidelityLines = events.messages.filter { $0.hasPrefix("fidelity now") }
        expect(
            fidelityLines.count == 2,
            "exactly one line per applied change, never one per lever moved, got \(fidelityLines)"
        )
        expect(
            fidelityLines.last == "fidelity now 30 fps, quality 100%, 1.00x on canvas 0 (limited by the encoder)",
            "the line names the whole applied fidelity and what is holding it back, got \(fidelityLines.last ?? "nothing")"
        )

        var builder = HostTelemetrySnapshotBuilder()
        let samples = builder.snapshot(
            metrics: { _ in SessionMetrics() },
            frameCounts: { $0 == surfaceZero ? media.frameCounts : HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0) },
            sendQueueDropped: { _ in 0 },
            appliedStreamScale: { coordinator.appliedStreamScale(for: $0) },
            sustainableScaleCeiling: { coordinator.sustainableScaleCeiling(for: $0) },
            clampedFromUserChoice: { coordinator.clampedStreamScaleFromUserChoice(for: $0) },
            appliedFramesPerSecond: { coordinator.appliedFramesPerSecond(for: $0) },
            qualityScale: { coordinator.appliedQualityScale(for: $0) },
            fidelityLimitReason: { coordinator.fidelityLimitReason(for: $0) },
            atNanoseconds: 1_000_000_000
        )
        expect(
            samples.count == 1 && samples[0].appliedFramesPerSecond == 30
                && samples[0].qualityScale == 1.0
                && samples[0].fidelityLimitReason == FidelityLimitReason.encoder
                && samples[0].sustainableScaleCeiling == nil,
            "the telemetry tick reports the fidelity actually applied, with no scale ceiling invented before any resolution was spent"
        )
    }
    print("PASS: sustained encoder pressure steps the frame rate down one step at a time and the telemetry sample reports it")

    // A fidelity change names the viewer's own numbers behind it
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // A viewer keeping up comfortably, so the encoder alone is what moves
        // the ladder and the line under test is the same one the scenario
        // above writes.
        _ = try! await coordinator.handleWritingResponse(
            .viewerTelemetry(
                ViewerTelemetrySample(
                    surfaceID: 0,
                    endToEnd: nil,
                    receive: nil,
                    decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 4_250_000),
                    presentedFramesPerSecond: 59.6,
                    decodedFramesPerSecond: 60,
                    receivedBitsPerSecond: nil
                )
            )
        )
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let fidelityLines = events.messages.filter { $0.hasPrefix("fidelity now") }
        expect(
            fidelityLines.last
                == "fidelity now 30 fps, quality 100%, 1.00x on canvas 0 (limited by the encoder)"
                + "; viewer decode p95 4.2ms, decoded 60 fps, presented 60 fps",
            "the line carries the viewer's decode p95 and both of its frame rates, got \(fidelityLines.last ?? "nothing")"
        )
    }
    print("PASS: a fidelity change line carries the viewer's own decode time and frame rates when it has reported them")

    // The viewer's decode budget is judged on its decoder's own time when it reports one
    do {
        /// A viewer whose receipt-to-decoded p95 is over a 60 fps budget
        /// while its decoder alone, when reported, is well inside it: the
        /// wait ahead of the decoder is not decode time.
        func limitReason(decoderOnly: StageLatencySample?) async -> String? {
            let media = FakeScalableCanvasMedia()
            let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media))
            _ = try! await coordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            for tick in 0...8 {
                _ = try! await coordinator.handleWritingResponse(
                    .viewerTelemetry(
                        ViewerTelemetrySample(
                            surfaceID: 0,
                            endToEnd: nil,
                            receive: nil,
                            decode: StageLatencySample(p50Nanoseconds: 20_000_000, p95Nanoseconds: 35_000_000),
                            presentedFramesPerSecond: 60,
                            decodedFramesPerSecond: 60,
                            receivedBitsPerSecond: nil,
                            decodesInHardware: decoderOnly == nil ? nil : true,
                            decoderOnly: decoderOnly
                        )
                    )
                )
                media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 0)
                await coordinator.tickFidelity(atSeconds: Double(tick))
            }
            return coordinator.fidelityLimitReason(for: surfaceZero)
        }

        let withoutSplit = await limitReason(decoderOnly: nil)
        expect(
            withoutSplit == FidelityLimitReason.viewer,
            "a viewer reporting only its receipt-to-decoded time is still judged on it, got \(String(describing: withoutSplit))"
        )
        let withSplit = await limitReason(
            decoderOnly: StageLatencySample(p50Nanoseconds: 4_000_000, p95Nanoseconds: 5_000_000)
        )
        expect(
            withSplit == nil,
            "a viewer whose decoder takes 5 ms is not behind at 60 fps, however long frames waited for it, got \(String(describing: withSplit))"
        )
    }
    print("PASS: the viewer's decode budget is judged on its decoder's own time when the viewer reports it")

    // Frames the viewer replaced on time count as kept up with
    do {
        /// A viewer that decoded 50 frames a second and showed 33 of them,
        /// with an idle encoder, so only the viewer rule can limit the stream.
        func limitReason(supersededOnTime: Double?) async -> String? {
            let media = FakeScalableCanvasMedia()
            let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media))
            _ = try! await coordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            for tick in 0...8 {
                _ = try! await coordinator.handleWritingResponse(
                    .viewerTelemetry(
                        ViewerTelemetrySample(
                            surfaceID: 0,
                            endToEnd: nil,
                            receive: nil,
                            decode: nil,
                            presentedFramesPerSecond: 33,
                            decodedFramesPerSecond: 50,
                            receivedBitsPerSecond: nil,
                            supersededOnTimeFramesPerSecond: supersededOnTime
                        )
                    )
                )
                media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 0)
                await coordinator.tickFidelity(atSeconds: Double(tick))
            }
            return coordinator.fidelityLimitReason(for: surfaceZero)
        }

        let withoutOnTime = await limitReason(supersededOnTime: nil)
        expect(
            withoutOnTime == FidelityLimitReason.viewer,
            "a viewer showing 33 of 50 decoded frames and reporting no on-time figure is behind, got \(String(describing: withoutOnTime))"
        )
        let withOnTime = await limitReason(supersededOnTime: 15)
        expect(
            withOnTime == nil,
            "the same viewer replacing 15 frames a second on time is keeping up, got \(String(describing: withOnTime))"
        )
    }
    print("PASS: frames the viewer replaced on time count as kept up with in the stream's frame rate decision")

    // A fidelity change names the viewer's decoder and its decode time split
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(
            .viewerTelemetry(
                ViewerTelemetrySample(
                    surfaceID: 0,
                    endToEnd: nil,
                    receive: nil,
                    decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 4_250_000),
                    presentedFramesPerSecond: 59.6,
                    decodedFramesPerSecond: 60,
                    receivedBitsPerSecond: nil,
                    decodesInHardware: true,
                    decoderOnly: StageLatencySample(p50Nanoseconds: 2_500_000, p95Nanoseconds: 3_400_000),
                    decodeQueueWait: StageLatencySample(p50Nanoseconds: 300_000, p95Nanoseconds: 800_000)
                )
            )
        )
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let fidelityLines = events.messages.filter { $0.hasPrefix("fidelity now") }
        expect(
            fidelityLines.last
                == "fidelity now 30 fps, quality 100%, 1.00x on canvas 0 (limited by the encoder)"
                + "; viewer decode p95 4.2ms, decoded 60 fps, presented 60 fps"
                + ", hardware decoder, decoder p50 2.5ms p95 3.4ms, queue wait p95 0.8ms",
            "the line names the decoder and splits its time from the wait ahead of it, got \(fidelityLines.last ?? "nothing")"
        )
    }
    print("PASS: a fidelity change line names the viewer's decoder and splits the decoder's own time from the wait ahead of it")

    // A fidelity change names the viewer's whole-path and receive delay
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(
            .viewerTelemetry(
                ViewerTelemetrySample(
                    surfaceID: 0,
                    endToEnd: StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_500_000),
                    receive: StageLatencySample(p50Nanoseconds: 9_000_000, p95Nanoseconds: 12_250_000),
                    decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 4_250_000),
                    presentedFramesPerSecond: 59.6,
                    decodedFramesPerSecond: 60,
                    receivedBitsPerSecond: nil
                )
            )
        )
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let fidelityLines = events.messages.filter { $0.hasPrefix("fidelity now") }
        expect(
            fidelityLines.last
                == "fidelity now 30 fps, quality 100%, 1.00x on canvas 0 (limited by the encoder)"
                + "; viewer end to end p50 21.0ms p95 34.5ms, receive p50 9.0ms p95 12.2ms"
                + ", decode p95 4.2ms, decoded 60 fps, presented 60 fps",
            "the line leads with the viewer's end-to-end and receive delay, got \(fidelityLines.last ?? "nothing")"
        )
    }
    print("PASS: a fidelity change line carries the viewer's end-to-end and receive delay when it has reported them")

    // The viewer's decoder is named once per surface it streams
    do {
        let surfaceOne = CanvasSurfaceID.allCases[1]
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            media: CanvasSurfaceSlots(surface0: FakeScalableCanvasMedia(), surface1: FakeScalableCanvasMedia()),
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        func report(surfaceID: UInt32, decodesInHardware: Bool?) async {
            _ = try! await coordinator.handleWritingResponse(
                .viewerTelemetry(
                    ViewerTelemetrySample(
                        surfaceID: surfaceID,
                        endToEnd: nil,
                        receive: nil,
                        decode: nil,
                        presentedFramesPerSecond: 60,
                        decodedFramesPerSecond: 60,
                        receivedBitsPerSecond: nil,
                        decodesInHardware: decodesInHardware
                    )
                )
            )
        }
        func decoderLines() -> [String] {
            events.messages.filter { $0.contains("decodes in") }
        }

        await report(surfaceID: 0, decodesInHardware: nil)
        expect(decoderLines().isEmpty, "a report that does not say which decoder runs names none, got \(decoderLines())")

        await report(surfaceID: 0, decodesInHardware: true)
        await report(surfaceID: 0, decodesInHardware: true)
        await report(surfaceID: 0, decodesInHardware: false)
        await report(surfaceID: surfaceOne.wireValue, decodesInHardware: false)
        expect(
            decoderLines() == [
                "the viewer decodes in hardware on canvas 0",
                "the viewer decodes in software on canvas 1",
            ],
            "the first report that names the decoder is logged once per surface, got \(decoderLines())"
        )

        _ = try! await coordinator.handleWritingResponse(.displayCount(1))
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        await report(surfaceID: surfaceOne.wireValue, decodesInHardware: false)
        expect(
            decoderLines().count == 3 && decoderLines().last == "the viewer decodes in software on canvas 1",
            "a surface that stopped and came back names its decoder again, got \(decoderLines())"
        )
    }
    print("PASS: the viewer's decoder is logged once per surface, the first time the viewer names it")

    // A screen nobody is changing gets its quality back at once
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // Three steps down: 45 fps, 30 fps, then the first quality step.
        for tick in 0...10 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.appliedQualityScales == [0.75],
            "the third step is the first quality step, got \(media.appliedQualityScales)"
        )

        // The screen stops changing: the counters stop moving with it, which
        // is what "still" means here -- host capture, not a viewer's report.
        let still = media.frameCounts
        for tick in 11...12 {
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.appliedQualityScales == [0.75, 1.0],
            "a still screen costs nothing to send sharply, so quality returns to full without waiting out a recovery, got \(media.appliedQualityScales)"
        )
        expect(
            media.keyFrameRequestCount == 1,
            "the lift asks for a key frame, or the sharper picture is invisible until the interval next comes around"
        )
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 30
                && coordinator.appliedQualityScale(for: surfaceZero) == 1.0,
            "only quality is lifted: the frame rate the ladder chose still applies the moment the screen moves again"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.last
                == "fidelity now 30 fps, quality 100%, 1.00x on canvas 0 (limited by the encoder)",
            "the lift is one line like any other applied change, and still names what the picture was given up to"
        )
    }
    print("PASS: a still screen lifts encoder quality back to full immediately and asks for the key frame that makes it visible")

    // Every counter a tick reads is the difference between two of them
    do {
        let media = FakeScalableCanvasMedia()
        let sink = FakeVideoSink()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            videoSink: sink,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // One recorded run, as the host actually holds it: running totals that
        // never come back down. The opening burst loses a fifth of the first
        // tick's frames and the ticks after it lose one and then none -- so
        // every tick after the first is inside the admission share, and the
        // encoder is never named. Read as totals instead of as differences,
        // the same numbers are over that share on every tick and would cost
        // this surface its frame rate within seconds.
        let recorded: [(captured: Int, dropped: Int)] = [
            (100, 20), (248, 21), (432, 21), (436, 21), (437, 21), (497, 21),
            (557, 21), (617, 21), (677, 21), (737, 21), (797, 21), (857, 21)
        ]
        for (tick, total) in recorded.enumerated() {
            media.frameCounts = HostFrameCounts(
                captured: total.captured,
                encoded: total.captured - total.dropped,
                encodeSubmissionFailures: 0,
                encoderInputDropped: total.dropped
            )
            sink.droppedVideoFrameCount = total.dropped
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 60
                && coordinator.appliedQualityScale(for: surfaceZero) == 1.0,
            "an opening burst is one bad tick, not a pipeline that cannot keep up, got "
                + "\(coordinator.appliedFramesPerSecond(for: surfaceZero)) fps"
        )
        expect(
            coordinator.fidelityLimitReason(for: surfaceZero) == nil
                && events.messages.filter { $0.hasPrefix("fidelity now") }.isEmpty,
            "so nothing is given up and nothing is reported as holding the picture back, got \(events.messages)"
        )
    }
    print("PASS: a fidelity tick reads every counter as the difference between two readings, never as the session's total")

    // The periodic video line counts this interval's drops
    do {
        let media = FakeScalableCanvasMedia()
        let sink = FakeVideoSink()
        let events = DiagnosticsRecorder()
        // Reporting every interval however short, so the line under test is
        // written by the same code a five-second interval writes it with,
        // without the test waiting five seconds for each one.
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            videoSink: sink,
            flowReportSeconds: 0,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        func videoLines() -> [String] {
            events.messages.filter { $0.hasPrefix("video ") }
        }
        func packet(_ sequence: UInt64) -> EncodedVideoFramePacket {
            EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence * 1_000_000,
                isKeyFrame: false,
                codecConfiguration: nil,
                payload: Data([UInt8(sequence & 0xFF)])
            )
        }

        // The opening burst: twenty frames the transport could not carry,
        // and then a stream that never loses another.
        sink.droppedVideoFrameCount = 20
        media.emit(packet(1))
        sink.droppedVideoFrameCount = 21
        media.emit(packet(2))
        media.emit(packet(3))
        media.emit(packet(4))
        expect(
            videoLines().count == 4,
            "one line per interval, got \(videoLines())"
        )
        expect(
            videoLines().dropFirst().map { $0.contains("1 dropped to keep up") } == [true, false, false],
            "each line counts the frames that interval lost, not every one the session has ever lost, "
                + "got \(videoLines())"
        )
        expect(
            videoLines().last?.contains("0 dropped to keep up") == true,
            "an interval that lost nothing says nothing was lost, got \(videoLines().last ?? "no line")"
        )
    }
    print("PASS: the periodic video line reports the frames this interval dropped, not the session's running total")

    // The periodic video line carries the viewer's latest delay report
    do {
        let media = FakeScalableCanvasMedia()
        let sink = FakeVideoSink()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            videoSink: sink,
            flowReportSeconds: 0,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        func lastVideoLine() -> String? {
            events.messages.last { $0.hasPrefix("video ") }
        }
        func packet(_ sequence: UInt64) -> EncodedVideoFramePacket {
            EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence * 1_000_000,
                isKeyFrame: false,
                codecConfiguration: nil,
                payload: Data([UInt8(sequence & 0xFF)])
            )
        }

        media.emit(packet(1))
        expect(
            lastVideoLine()?.hasSuffix("0 dropped to keep up") == true,
            "before the viewer reports anything the line ends where it always did, got \(lastVideoLine() ?? "no line")"
        )

        _ = try! await coordinator.handleWritingResponse(
            .viewerTelemetry(
                ViewerTelemetrySample(
                    surfaceID: 0,
                    endToEnd: StageLatencySample(p50Nanoseconds: 41_000_000, p95Nanoseconds: 63_000_000),
                    receive: StageLatencySample(p50Nanoseconds: 18_000_000, p95Nanoseconds: 30_000_000),
                    decode: nil,
                    presentedFramesPerSecond: 60,
                    decodedFramesPerSecond: 60,
                    receivedBitsPerSecond: nil
                )
            )
        )
        media.emit(packet(2))
        expect(
            lastVideoLine()?.hasSuffix(
                "0 dropped to keep up; viewer end to end p50 41.0ms p95 63.0ms, receive p50 18.0ms p95 30.0ms"
            ) == true,
            "the line carries the viewer's end-to-end and receive delay, got \(lastVideoLine() ?? "no line")"
        )
    }
    print("PASS: the periodic video line carries the viewer's end-to-end and receive delay when it has reported them")

    // Both lines say why the viewer's draws showed nothing, only when they did
    do {
        func sample(_ report: ViewerDrawReport?) -> ViewerTelemetrySample {
            ViewerTelemetrySample(
                surfaceID: 0,
                endToEnd: nil,
                receive: nil,
                decode: nil,
                presentedFramesPerSecond: 5,
                decodedFramesPerSecond: 20,
                receivedBitsPerSecond: nil,
                drawReport: report
            )
        }
        func packet(_ sequence: UInt64) -> EncodedVideoFramePacket {
            EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence * 1_000_000,
                isKeyFrame: false,
                codecConfiguration: nil,
                payload: Data([UInt8(sequence & 0xFF)])
            )
        }
        let media = FakeScalableCanvasMedia()
        let sink = FakeVideoSink()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            videoSink: sink,
            flowReportSeconds: 0,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        func lastVideoLine() -> String? {
            events.messages.last { $0.hasPrefix("video ") }
        }

        _ = try! await coordinator.handleWritingResponse(.viewerTelemetry(sample(ViewerDrawReport(
            drawsPerSecond: 60, noDrawablePerSecond: 0, noCommandBufferPerSecond: 0,
            emptyDestinationPerSecond: 0, renderFailurePerSecond: 0
        ))))
        media.emit(packet(1))
        expect(
            lastVideoLine()?.hasSuffix("0 dropped to keep up") == true,
            "draws that all showed their frame add nothing to the video line, got \(lastVideoLine() ?? "no line")"
        )

        _ = try! await coordinator.handleWritingResponse(.viewerTelemetry(sample(ViewerDrawReport(
            drawsPerSecond: 60, noDrawablePerSecond: 14, noCommandBufferPerSecond: 0,
            emptyDestinationPerSecond: 0, renderFailurePerSecond: 0
        ))))
        media.emit(packet(2))
        expect(
            lastVideoLine()?.hasSuffix(
                "0 dropped to keep up; viewer draws 60/s, not shown 14/s (no drawable 14)"
            ) == true,
            "the video line says how many draws showed nothing and why, got \(lastVideoLine() ?? "no line")"
        )

        _ = try! await coordinator.handleWritingResponse(.viewerTelemetry(sample(ViewerDrawReport(
            drawsPerSecond: 0, noDrawablePerSecond: 0, noCommandBufferPerSecond: 0,
            emptyDestinationPerSecond: 0, renderFailurePerSecond: 0
        ))))
        media.emit(packet(3))
        expect(
            lastVideoLine()?.hasSuffix("0 dropped to keep up; viewer draws 0/s") == true,
            "a viewer asked to draw less often than it decodes is named even when no draw failed, got "
                + (lastVideoLine() ?? "no line")
        )

        _ = try! await coordinator.handleWritingResponse(.viewerTelemetry(sample(ViewerDrawReport(
            drawsPerSecond: 58, noDrawablePerSecond: 10, noCommandBufferPerSecond: 1,
            emptyDestinationPerSecond: 2, renderFailurePerSecond: 4
        ))))
        media.emit(packet(4))
        expect(
            lastVideoLine()?.hasSuffix(
                "; viewer draws 58/s, not shown 17/s"
                    + " (no drawable 10, no command buffer 1, zero-size destination 2, render failure 4)"
            ) == true,
            "every reason that occurred is named, in a fixed order, got \(lastVideoLine() ?? "no line")"
        )

        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let fidelityLine = events.messages.last { $0.hasPrefix("fidelity now") }
        expect(
            fidelityLine?.contains("; viewer draws 58/s, not shown 17/s (no drawable 10, no command buffer 1,") == true,
            "the fidelity line carries the same words, got \(fidelityLine ?? "no line")"
        )
    }
    print("PASS: the video and fidelity lines say why the viewer's draws showed nothing, only when some did")

    // A still screen is sent one good frame of the picture it holds
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let recorder = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            latencyRecorder: recorder,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.stillRefreshCount == 0,
            "a moving screen is never sent an extra frame, got \(media.stillRefreshCount)"
        )

        // The screen stops changing. The picture the viewer is left holding
        // was encoded as a delta on a moving screen, so it is sent again
        // whole -- once, however long the screen stays still.
        let still = media.frameCounts
        for tick in 9...16 {
            let refreshesBefore = media.stillRefreshCount
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
            if media.stillRefreshCount > refreshesBefore {
                expect(
                    !events.messages.contains { $0.hasPrefix("still-screen refresh sent") },
                    "a refresh handed to the transport is not yet a refresh sent, got \(events.messages)"
                )
                sendRefresh(recorder, atSeconds: Double(tick), taking: 40)
            }
        }
        expect(
            media.stillRefreshCount == 1,
            "the still picture is refreshed exactly once, got \(media.stillRefreshCount)"
        )
        expect(
            await waitUntil(timeoutSeconds: 2) {
                events.messages.contains("still-screen refresh sent on canvas 0 (1.9 MB key frame, 40 ms to send)")
            },
            "once its write ends, the refresh is a line in the log naming how large the picture it sent was "
                + "and how long it took to send, got \(events.messages)"
        )
        expect(
            events.messages.filter { $0.hasPrefix("still-screen refresh") }.count == 1,
            "and that one line is all a refresh that sent quickly writes, got \(events.messages)"
        )

        // The screen moves and goes quiet again: a new picture, and its own
        // refresh.
        var moving = still
        for tick in 17...19 {
            moving = HostFrameCounts(
                captured: moving.captured + 60,
                encoded: moving.encoded + 60,
                encodeSubmissionFailures: 0,
                encoderInputDropped: moving.encoderInputDropped
            )
            media.frameCounts = moving
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        for tick in 20...24 {
            media.frameCounts = moving
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.stillRefreshCount == 2,
            "a screen that moved and stopped again is a new picture to refresh, got \(media.stillRefreshCount)"
        )
    }
    print("PASS: a still screen is sent one whole frame of the picture it is holding, once per still period")

    // A refresh slow to send holds the next one off, for longer each time
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let recorder = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            latencyRecorder: recorder,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        var counts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
        var now = 0.0
        func tick(moving: Bool) async {
            if moving {
                counts = HostFrameCounts(
                    captured: counts.captured + 60,
                    encoded: counts.encoded + 60,
                    encodeSubmissionFailures: 0
                )
            }
            media.frameCounts = counts
            await coordinator.tickFidelity(atSeconds: now)
            now += 1
        }
        /// Something moves, then nothing does until the picture is refreshed
        /// or `limit` is reached. Answers when the refresh went out.
        func moveThenWaitForRefresh(until limit: Double) async -> Double? {
            await tick(moving: true)
            let refreshesBefore = media.stillRefreshCount
            while now < limit {
                let tickedAt = now
                await tick(moving: false)
                if media.stillRefreshCount > refreshesBefore {
                    return tickedAt
                }
            }
            return nil
        }
        func refreshLines() -> [String] {
            events.messages.filter { $0.hasPrefix("still-screen refresh") }
        }

        // The first reading and the warm-up.
        for _ in 0...3 {
            await tick(moving: true)
        }
        let first = await moveThenWaitForRefresh(until: 20) ?? -1
        expect(first >= 0, "a still screen is refreshed")
        sendRefresh(recorder, atSeconds: first, taking: 640)
        expect(
            await waitUntil(timeoutSeconds: 2) { refreshLines().count == 2 },
            "a slow refresh writes its own line and then the hold-off it starts, got \(refreshLines())"
        )
        expect(
            refreshLines() == [
                "still-screen refresh sent on canvas 0 (1.9 MB key frame, 640 ms to send)",
                "still-screen refresh on canvas 0 took 640 ms to send; next one no sooner than 30 s"
            ],
            "the lines name the send time and how long the next refresh waits, got \(refreshLines())"
        )

        let firstHoldOffEnds = first + 0.64 + 30
        expect(
            await moveThenWaitForRefresh(until: firstHoldOffEnds.rounded(.down)) == nil,
            "a new still picture inside the hold-off is not refreshed, got \(media.stillRefreshCount) refreshes"
        )
        let second = await moveThenWaitForRefresh(until: firstHoldOffEnds + 20) ?? -1
        expect(
            second >= firstHoldOffEnds && second < firstHoldOffEnds + 4,
            "the next still picture after the hold-off is refreshed, got \(second) against \(firstHoldOffEnds)"
        )
        sendRefresh(recorder, atSeconds: second, taking: 300)
        expect(
            await waitUntil(timeoutSeconds: 2) { refreshLines().count == 4 },
            "a second slow refresh writes both lines again, got \(refreshLines())"
        )
        expect(
            refreshLines().suffix(2) == [
                "still-screen refresh sent on canvas 0 (1.9 MB key frame, 300 ms to send)",
                "still-screen refresh on canvas 0 took 300 ms to send; next one no sooner than 60 s"
            ],
            "and the hold-off doubles, got \(refreshLines())"
        )

        let secondHoldOffEnds = second + 0.3 + 60
        expect(
            await moveThenWaitForRefresh(until: secondHoldOffEnds.rounded(.down)) == nil,
            "the longer hold-off is waited out in full, got \(media.stillRefreshCount) refreshes"
        )
        let third = await moveThenWaitForRefresh(until: secondHoldOffEnds + 20) ?? -1
        expect(third >= secondHoldOffEnds, "and then a still picture is refreshed again, got \(third)")
        sendRefresh(recorder, atSeconds: third, taking: 40)
        expect(
            await waitUntil(timeoutSeconds: 2) { refreshLines().count == 5 },
            "a fast refresh writes one line, got \(refreshLines())"
        )
        expect(
            refreshLines().last == "still-screen refresh sent on canvas 0 (1.9 MB key frame, 40 ms to send)",
            "naming its send time and nothing about a hold-off, got \(refreshLines())"
        )
        let fourth = await moveThenWaitForRefresh(until: now + 10) ?? -1
        expect(
            fourth >= 0 && fourth - third < 5,
            "and ends the hold-off, so the very next still picture is refreshed, got \(fourth) after \(third)"
        )
    }
    print("PASS: a still-screen refresh slow to send holds the next one off for longer each time, and the log says how long")

    // One surface's slow refresh holds off only that surface's next one
    do {
        let surfaceOne = CanvasSurfaceID.allCases[1]
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let recorder = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            latencyRecorder: recorder,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        var captured = 0
        var now = 0.0
        func tick(moving: Bool) async {
            if moving {
                captured += 60
            }
            let counts = HostFrameCounts(captured: captured, encoded: captured, encodeSubmissionFailures: 0)
            mediaZero.frameCounts = counts
            mediaOne.frameCounts = counts
            await coordinator.tickFidelity(atSeconds: now)
            now += 1
        }

        for _ in 0...4 {
            await tick(moving: true)
        }
        while mediaOne.stillRefreshCount == 0 && now < 20 {
            await tick(moving: false)
        }
        let refreshedAt = now - 1
        expect(
            mediaZero.stillRefreshCount == 1 && mediaOne.stillRefreshCount == 1,
            "both still screens are refreshed, got \(mediaZero.stillRefreshCount) and \(mediaOne.stillRefreshCount)"
        )
        sendRefresh(recorder, on: surfaceZero, atSeconds: refreshedAt, taking: 640)
        sendRefresh(recorder, on: surfaceOne, atSeconds: refreshedAt, taking: 40)
        expect(
            await waitUntil(timeoutSeconds: 2) {
                events.messages.contains("still-screen refresh on canvas 0 took 640 ms to send; next one no sooner than 30 s")
                    && events.messages.contains("still-screen refresh sent on canvas 1 (1.9 MB key frame, 40 ms to send)")
            },
            "each surface's refresh is logged on its own surface, got \(events.messages)"
        )
        expect(
            !events.messages.contains { $0.hasPrefix("still-screen refresh on canvas 1") },
            "and only the slow one holds anything off, got \(events.messages)"
        )

        await tick(moving: true)
        let movedAt = now
        while mediaOne.stillRefreshCount == 1 && now < movedAt + 10 {
            await tick(moving: false)
        }
        expect(
            mediaOne.stillRefreshCount == 2,
            "the surface whose refresh sent quickly refreshes its next still picture, got \(mediaOne.stillRefreshCount)"
        )
        expect(
            mediaZero.stillRefreshCount == 1,
            "while the surface whose refresh was slow waits out its own hold-off, got \(mediaZero.stillRefreshCount)"
        )
    }
    print("PASS: one surface's slow still-screen refresh holds off only that surface's next one")

    // A surface that stops and comes back starts with no hold-off
    do {
        let surfaceOne = CanvasSurfaceID.allCases[1]
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let recorder = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            latencyRecorder: recorder,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        var captured = 0
        var now = 0.0
        func tick(moving: Bool) async {
            if moving {
                captured += 60
            }
            let counts = HostFrameCounts(captured: captured, encoded: captured, encodeSubmissionFailures: 0)
            mediaZero.frameCounts = counts
            mediaOne.frameCounts = counts
            await coordinator.tickFidelity(atSeconds: now)
            now += 1
        }
        /// Something moves, then nothing does until canvas 1 is refreshed or
        /// `seconds` pass. Answers when the refresh went out.
        func moveThenWaitForRefresh(within seconds: Double) async -> Double? {
            await tick(moving: true)
            let refreshesBefore = mediaOne.stillRefreshCount
            let limit = now + seconds
            while now < limit {
                let tickedAt = now
                await tick(moving: false)
                if mediaOne.stillRefreshCount > refreshesBefore {
                    return tickedAt
                }
            }
            return nil
        }
        /// Canvas 1 goes away and is asked for again, which is a new session
        /// on that surface: the first reading and the warm-up come first.
        func restartCanvasOne() async {
            _ = try! await coordinator.handleWritingResponse(.displayCount(1))
            _ = try! await coordinator.handleWritingResponse(.displayCount(2))
            for _ in 0...3 {
                await tick(moving: true)
            }
        }

        for _ in 0...3 {
            await tick(moving: true)
        }
        let first = await moveThenWaitForRefresh(within: 10) ?? -1
        expect(first >= 0, "canvas 1's still screen is refreshed")
        sendRefresh(recorder, on: surfaceOne, atSeconds: first, taking: 640)
        expect(
            await waitUntil(timeoutSeconds: 2) {
                events.messages.contains("still-screen refresh on canvas 1 took 640 ms to send; next one no sooner than 30 s")
            },
            "its slow send holds the next refresh off, got \(events.messages)"
        )

        await restartCanvasOne()
        let second = await moveThenWaitForRefresh(within: 10) ?? -1
        expect(
            second >= 0 && second < first + 30,
            "the session that replaced it starts with no hold-off, got \(second) after \(first)"
        )

        // That refresh is handed over, and the canvas goes away before its
        // write ends.
        let handedOffAt = Int64(second * 1_000_000_000)
        recorder.recordHostRequestedFrameHandOff(
            surface: surfaceOne,
            presentationTimeNanoseconds: handedOffAt,
            atNanoseconds: handedOffAt
        )
        await restartCanvasOne()
        recorder.recordSendCompleted(
            surface: surfaceOne,
            presentationTimeNanoseconds: handedOffAt,
            atNanoseconds: handedOffAt + 640_000_000
        )
        try? await Task.sleep(for: .milliseconds(100))
        let slowSendLines = events.messages.filter { $0.contains("canvas 1") && $0.contains("640 ms") }
        expect(
            slowSendLines.count == 2,
            "a write that ends after its canvas went away belongs to a session that is over, and writes nothing, "
                + "got \(slowSendLines)"
        )
        let third = await moveThenWaitForRefresh(within: 10) ?? -1
        expect(third >= 0, "and holds nothing off in the session after it, got \(mediaOne.stillRefreshCount) refreshes")
    }
    print("PASS: a surface that stops and comes back starts with no still-screen refresh held off")

    // A refresh that did not go out is never logged as one that did
    do {
        for (outcome, expectedLine) in [
            (
                Result<Int?, any Error>.failure(StillFrameEncoderError.frameExceedsTransportLimit(bytes: 5_436_367)),
                "still-screen refresh skipped on canvas 0: 5.4 MB exceeds the transport limit"
            ),
            (
                Result<Int?, any Error>.failure(HostMediaPipelineError.stillRefreshNotDelivered),
                "still-screen refresh not sent on canvas 0. The frame was encoded, and the link would not take it."
            )
        ] {
            let media = FakeScalableCanvasMedia()
            media.stillRefreshOutcome = outcome
            let events = DiagnosticsRecorder()
            let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
            _ = try! await coordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            for tick in 0...8 {
                media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
                await coordinator.tickFidelity(atSeconds: Double(tick))
            }
            let still = media.frameCounts
            for tick in 9...16 {
                media.frameCounts = still
                await coordinator.tickFidelity(atSeconds: Double(tick))
            }
            expect(media.stillRefreshCount == 1, "the refresh was attempted once, got \(media.stillRefreshCount)")
            expect(
                events.messages.contains(expectedLine),
                "a refresh that did not go out says so, and says why, got \(events.messages)"
            )
            expect(
                !events.messages.contains { $0.hasPrefix("still-screen refresh sent") },
                "and is never also logged as a picture that went out, got \(events.messages)"
            )
        }
    }
    print("PASS: a still-screen refresh that was skipped or refused is logged as such, never as one that was sent")

    // A refresh whose write failed is not logged as sent, and still counts
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let recorder = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: onlyOnSurfaceZero(media),
            latencyRecorder: recorder,
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        for tick in 0...8 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let still = media.frameCounts
        for tick in 9...16 {
            let refreshesBefore = media.stillRefreshCount
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
            if media.stillRefreshCount > refreshesBefore {
                sendRefresh(recorder, atSeconds: Double(tick), taking: 640, succeeded: false)
            }
        }
        expect(media.stillRefreshCount == 1, "the refresh was handed over once, got \(media.stillRefreshCount)")
        let refreshLines = { events.messages.filter { $0.hasPrefix("still-screen refresh") } }
        expect(
            await waitUntil(timeoutSeconds: 2) { refreshLines().count == 2 },
            "a write that failed is still reported, got \(refreshLines())"
        )
        expect(
            refreshLines() == [
                "still-screen refresh not sent on canvas 0. The write failed after 640 ms.",
                "still-screen refresh on canvas 0 took 640 ms to send; next one no sooner than 30 s"
            ],
            "as a refresh that did not go out, whose time on the link still holds the next one off, "
                + "got \(refreshLines())"
        )
    }
    print("PASS: a still-screen refresh whose write failed is logged as not sent, and its time on the link still counts")

    // The controller lowers even a scale a person chose outright
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )

        // The frame rate goes first, down to 30 fps, and a pressured surface
        // that is still behind there is given a smaller picture.
        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.appliedFramesPerSecond == [45, 30],
            "the frame rate is given up before any resolution, got \(media.appliedFramesPerSecond)"
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "a smaller picture reaches the encoder through the same reconfigure path a viewer resize uses, got "
                + "\(media.reconfiguredScales)"
        )
        expect(
            coordinator.appliedStreamScale(for: surfaceZero) == 1.75
                && coordinator.sustainableScaleCeiling(for: surfaceZero) == 1.75,
            "a measured limit lowers a fixed choice: the ceiling is what the surface is actually streaming"
        )
        expect(
            coordinator.clampedStreamScaleFromUserChoice(for: surfaceZero) == 2.0,
            "the choice the ceiling held back is reported rather than silently overridden"
        )
        func holdLines() -> [String] {
            events.messages.filter { $0.hasPrefix("stream scale 2.00x requested but") }
        }
        expect(
            holdLines() == [
                "stream scale 2.00x requested but held to 1.75x by the fidelity controller (limited by the encoder)"
            ],
            "the hold names what decided it and which stage it measured, got \(holdLines())"
        )
        // The viewer re-asks for its geometry scale every time its window
        // settles. The hold has not moved, so it is not reported again.
        for _ in 0..<2 {
            _ = try! await coordinator.handleWritingResponse(
                .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)
            )
        }
        expect(
            holdLines().count == 1,
            "a hold is reported once per change, not once per request that runs into it, got \(holdLines())"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.last
                == "fidelity now 30 fps, quality 100%, 1.75x on canvas 0 (limited by the encoder)",
            "the line reports the scale actually streamed, at the frame rate given up before it, got "
                + "\(events.messages.filter { $0.hasPrefix("fidelity now") }.last ?? "nothing")"
        )
    }
    print("PASS: the controller lowers the applied scale through the existing reconfigure path even when a person chose a fixed scale")

    // A still screen is streamed at the scale the viewer asked for
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )
        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "the surface gives up the frame rate and then resolution, got \(media.reconfiguredScales)"
        )

        // The screen stops changing. The rebuild the smaller picture caused has
        // to be warmed up again first, and no encode was measured while the
        // screen was quiet, so nothing here could have taken resolution back the
        // ordinary way: what hands the resolution back is the still screen
        // itself.
        let still = media.frameCounts
        for tick in 10...35 {
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 3 }
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 2.0],
            "a screen nobody is changing is streamed at the scale that was asked for, got \(media.reconfiguredScales)"
        )
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 60
                && coordinator.sustainableScaleCeiling(for: surfaceZero) == nil,
            "at the full frame rate, with nothing measured holding the scale below the ask any more"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.last
                == "fidelity now 60 fps, quality 100%, 2.00x on canvas 0 (no limit)",
            "and the line says nothing is holding the picture back, got "
                + "\(events.messages.filter { $0.hasPrefix("fidelity now") }.last ?? "nothing")"
        )
    }
    print("PASS: a still screen is handed back the resolution the viewer asked for, and the host log says why")

    // A still screen that moves again is streamed at the size it can hold
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )
        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "the surface gives up the frame rate and then resolution, got \(media.reconfiguredScales)"
        )
        let still = media.frameCounts
        for tick in 10...35 {
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 3 }
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 2.0],
            "the still screen is handed the scale it asked for, got \(media.reconfiguredScales)"
        )

        // The screen starts changing again and cannot keep up at that size,
        // so what the still screen was given goes back the way it was first
        // given up: the frame rate, and then the resolution.
        var moving = still
        for tick in 36...43 {
            moving = HostFrameCounts(
                captured: moving.captured + 60,
                encoded: moving.encoded + 54,
                encodeSubmissionFailures: 0,
                encoderInputDropped: moving.encoderInputDropped + 6
            )
            media.frameCounts = moving
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 4 }
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 2.0, 1.75],
            "the screen moving again is streamed at the size it can hold, got \(media.reconfiguredScales)"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.last
                == "fidelity now 30 fps, quality 100%, 1.75x on canvas 0 (limited by the encoder)",
            "and the log names the stage that is holding it there, got "
                + "\(events.messages.filter { $0.hasPrefix("fidelity now") }.last ?? "nothing")"
        )
    }
    print("PASS: a still screen that starts changing again gives back the frame rate and then the resolution")

    // The frame a still screen is sent again is not the screen changing
    do {
        let media = FakeScalableCanvasMedia()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media))
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )
        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "the surface gives up the frame rate and then resolution, got \(media.reconfiguredScales)"
        )

        // A screen at rest is not a screen that produces nothing at all: a
        // cursor blink is one frame, and the whole frame the host sends of the
        // picture the screen is holding is another. Together they are two
        // frames a tick, one more than the limit that names a screen still.
        var counts = media.frameCounts
        for tick in 10...35 {
            counts = HostFrameCounts(
                captured: counts.captured + 2,
                encoded: counts.encoded + 2,
                encodeSubmissionFailures: 0,
                encoderInputDropped: counts.encoderInputDropped,
                hostRequested: counts.hostRequested + 1
            )
            media.frameCounts = counts
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 3 }
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 2.0],
            "the frame the host asked for is not the screen changing, so the screen is still still, got "
                + "\(media.reconfiguredScales)"
        )
    }
    print("PASS: the frame a still screen is sent again is counted, but not as the screen changing")

    // A resolution the rebuild refused leaves the controller where the stream is
    do {
        let media = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )
        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "the surface gives up the frame rate and then resolution, got \(media.reconfiguredScales)"
        )

        // From here the encoder cannot be rebuilt at any other scale: the
        // stream survives at the one it is already running.
        media.reconfigurationFailure = CanvasMediaReconfigurationError.recoveredToPreviousScale(1.75)
        let still = media.frameCounts
        for tick in 10...40 {
            media.frameCounts = still
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 3 }
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 2.0],
            "the still screen asks for its resolution back once, got \(media.reconfiguredScales)"
        )
        expect(
            events.messages.contains("stream scale 2.00x could not be applied; recovered and still streaming at 1.75x"),
            "the refusal is reported, got \(events.messages)"
        )
        expect(
            coordinator.appliedStreamScale(for: surfaceZero) == 1.75
                && coordinator.sustainableScaleCeiling(for: surfaceZero) == 1.75,
            "the controller goes back to the scale the stream is really running at, so the viewer is told what it is "
                + "looking at rather than what was attempted, got ceiling "
                + "\(String(describing: coordinator.sustainableScaleCeiling(for: surfaceZero)))"
        )
        expect(
            coordinator.fidelityLimitReason(for: surfaceZero) == FidelityLimitReason.encoder,
            "and the stage that took that resolution is still what is holding the picture back"
        )
    }
    print("PASS: a resolution the encoder refused leaves the controller at the scale the stream is really running")

    // Every scale step is counted from what the viewer asked for
    do {
        let media = FakeScalableCanvasMedia()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media))
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // A fixed choice handed back to automatic, with no resize ever
        // reported: the scale in force is the only record of what is wanted.
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(2.0), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the person's own choice is honoured exactly before anything is measured, got \(media.reconfiguredScales)"
        )
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.automatic, surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0] },
            "the scale already in force is what automatic keeps serving, got \(media.reconfiguredScales)"
        )

        for tick in 0...9 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [2.0, 1.75] },
            "the first scale step is one below what the viewer asked for, got \(media.reconfiguredScales)"
        )

        // The rebuild the first scale step caused warms the controller up
        // again, so the second step costs a fresh warm-up and more
        // pressured ticks on top of it. Ticked until it lands rather than a
        // fixed number of times, and each tick gives the debounced rebuild
        // the moment it needs to reach the media: how many ticks that takes
        // is not what this scenario is about, and the scale it lands on is.
        var tick = 10
        while media.reconfiguredScales.count < 3, tick < 60 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
            _ = await waitUntil(timeoutSeconds: 0.2) { media.reconfiguredScales.count == 3 }
            tick += 1
        }
        expect(
            media.reconfiguredScales == [2.0, 1.75, 1.5],
            "the second step is two below the ask, not one below what the first step left streaming, got \(media.reconfiguredScales)"
        )
    }
    print("PASS: successive scale steps are counted from the scale the viewer asked for, never from the one already lowered")

    // A lever that refuses to move leaves the picture where it was
    do {
        let media = FakeScalableCanvasMedia()
        media.fidelityFailure = CanvasMediaReconfigurationError.recoveredToPreviousScale(1.0)
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(media: onlyOnSurfaceZero(media), onEvent: { events.record($0) })
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        for tick in 0...6 {
            media.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            media.appliedFramesPerSecond == [45],
            "the step was attempted exactly once, got \(media.appliedFramesPerSecond)"
        )
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 60,
            "a refused lever leaves the picture where it was: the reported fidelity is what is being encoded, never what was attempted"
        )
        expect(
            coordinator.fidelityLimitReason(for: surfaceZero) == nil,
            "nothing was given up, so nothing is reported as holding the picture back"
        )
        expect(
            events.messages.filter { $0.hasPrefix("fidelity now") }.isEmpty,
            "a change that never took effect is never reported as one"
        )
        expect(
            events.messages.filter { $0.contains("fidelity change could not be applied") }.count == 1,
            "the refusal is reported once, loudly, got \(events.messages)"
        )
    }
    print("PASS: a fidelity lever the media refuses leaves the controller at what the surface is really encoding")

    // A surface stopping clears every surviving surface's lever hold-off
    do {
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        // A real recorder, fed a cheap median encode every tick: taking a
        // frame rate back needs measured evidence that it fits,
        // and a surface nobody measured never gets one back.
        let latency = HostMediaLatencyRecorder()
        let coordinator = makeCoordinator(
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            latencyRecorder: latency
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))

        var captured = 0
        var dropped = 0
        var presentationTime: Int64 = 0
        /// One tick of surface 0 either losing frames before the encoder or
        /// keeping up perfectly, with surface 1 quietly streaming throughout.
        func tick(atSeconds seconds: Double, pressured: Bool) async {
            captured += 60
            dropped += pressured ? 6 : 0
            // One more than the sustainability minimum: the sample right
            // after a checkpoint reset is the opening key frame and is
            // skipped, so a tick that follows a fidelity change still has
            // enough left to decide on.
            for _ in 0...EncodeSustainabilityPolicy.minimumSampleCount {
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
            mediaZero.frameCounts = HostFrameCounts(
                captured: captured,
                encoded: captured - dropped,
                encodeSubmissionFailures: 0,
                encoderInputDropped: dropped
            )
            // Surface 1 is quiet, which is not the same as silent: a stream
            // delivering nothing whatsoever is a dead one, and this one is
            // delivering the same picture again while nobody changes it.
            mediaOne.frameCounts = HostFrameCounts(
                captured: 0,
                encoded: 0,
                encodeSubmissionFailures: 0,
                unchangedFrames: captured
            )
            await coordinator.tickFidelity(atSeconds: seconds)
        }

        for seconds in 0...6 {
            await tick(atSeconds: Double(seconds), pressured: true)
        }
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 45,
            "the frame rate is given up, so there is something for a recovery to take back"
        )
        // Six unpressured ticks earn the frame rate back, and the probe is watched:
        // pressure inside its probation hands it straight back and holds that
        // lever off for a minute.
        for seconds in 7...12 {
            await tick(atSeconds: Double(seconds), pressured: false)
        }
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 60,
            "six unpressured ticks take the frame rate back"
        )
        for seconds in 13...14 {
            await tick(atSeconds: Double(seconds), pressured: true)
        }
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 45,
            "pressure inside the probation reverses the probe at once, without waiting out the two-second floor"
        )
        for seconds in 15...24 {
            await tick(atSeconds: Double(seconds), pressured: false)
        }
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 45,
            "a lever a probe just failed into is held off, so more good ticks alone do not take it back"
        )

        // The other canvas going away changes what this one can afford:
        // machine-wide encoder capacity is part of what the hold-off measured.
        _ = try! await coordinator.handleWritingResponse(.displayCount(1))
        expect(mediaOne.stopCount == 1, "the second canvas actually stopped")
        await tick(atSeconds: 25, pressured: false)
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceZero) == 60,
            "a surface stopping clears every surviving surface's hold-off, so the next good tick can take the frame rate back"
        )
    }
    print("PASS: a surface stopping clears the lever hold-offs every other surface learned while it was streaming")

    // A surface that stops and comes back starts from the full picture
    do {
        let surfaceOne = CanvasSurfaceID.allCases[1]
        let mediaZero = FakeScalableCanvasMedia()
        let mediaOne = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let coordinator = makeCoordinator(
            media: CanvasSurfaceSlots(surface0: mediaZero, surface1: mediaOne),
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        _ = try! await coordinator.handleWritingResponse(
            .streamScalePreference(.fixed(2.0), surfaceID: surfaceOne.wireValue)
        )
        func holdLines() -> [String] {
            events.messages.filter { $0.contains("held to") }
        }

        // All the way down to the first scale step, so this surface has a
        // lower frame rate, a smaller picture and a reported hold to carry
        // across the gap if anything does.
        for tick in 0...9 {
            mediaOne.frameCounts = counts(afterTicks: tick + 1, droppingPerTick: 6)
            mediaZero.frameCounts = quietCounts(afterTicks: tick + 1)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            await waitUntil(timeoutSeconds: 2) { mediaOne.reconfiguredScales.last == 1.75 },
            "the surface is streaming a step below what was asked for, got \(mediaOne.reconfiguredScales)"
        )
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceOne) == 30
                && coordinator.sustainableScaleCeiling(for: surfaceOne) == 1.75,
            "the surface really has given up its frame rate and then resolution before it is taken away"
        )
        expect(holdLines().count == 1, "the hold it reached was reported once, got \(holdLines())")

        _ = try! await coordinator.handleWritingResponse(.displayCount(1))
        expect(mediaOne.stopCount == 1, "the second canvas actually stopped")
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceOne) == 60
                && coordinator.appliedQualityScale(for: surfaceOne) == 1.0
                && coordinator.sustainableScaleCeiling(for: surfaceOne) == nil
                && coordinator.fidelityLimitReason(for: surfaceOne) == nil,
            "a stopped surface keeps nothing: what it measured was the cost of a pipeline that no longer exists"
        )

        // A tick while it is down, the way the telemetry loop keeps running,
        // and then the same canvas is asked for again.
        mediaZero.frameCounts = quietCounts(afterTicks: 18)
        await coordinator.tickFidelity(atSeconds: 17)
        _ = try! await coordinator.handleWritingResponse(.displayCount(2))
        _ = try! await coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: surfaceOne.wireValue, maximumScale: nil)
        )
        expect(
            holdLines().count == 1,
            "the surface that came back is holding nothing back, so nothing is reported as held, got \(holdLines())"
        )

        // The first tick reads the counters the next one takes its delta
        // against, the three after it are the warm-up, and one more is not
        // yet frames lost twice running.
        for tick in 18...22 {
            mediaOne.frameCounts = counts(afterTicks: tick - 17, droppingPerTick: 6)
            mediaZero.frameCounts = quietCounts(afterTicks: tick + 1)
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        expect(
            coordinator.sustainableScaleCeiling(for: surfaceOne) == nil
                && coordinator.appliedFramesPerSecond(for: surfaceOne) == 60,
            "the pipeline that came back is warmed up before anything it reports is acted on"
        )
        mediaOne.frameCounts = counts(afterTicks: 6, droppingPerTick: 6)
        mediaZero.frameCounts = quietCounts(afterTicks: 25)
        await coordinator.tickFidelity(atSeconds: 23)
        expect(
            coordinator.appliedFramesPerSecond(for: surfaceOne) == 45
                && coordinator.sustainableScaleCeiling(for: surfaceOne) == nil,
            "and once the warm-up is behind it, it gives ground exactly as any other surface does, frame rate "
                + "first, got \(coordinator.appliedFramesPerSecond(for: surfaceOne)) fps and ceiling "
                + "\(String(describing: coordinator.sustainableScaleCeiling(for: surfaceOne)))"
        )
    }
    print("PASS: a surface that stops and comes back starts at what the viewer asked for, warmed up, with nothing held back")
}
