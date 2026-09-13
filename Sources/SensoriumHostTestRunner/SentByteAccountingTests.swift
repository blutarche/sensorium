import Foundation
import SensoriumCore
import SensoriumHost

/// A video sink whose sent-byte count a test sets directly, independent of
/// what it was actually handed through `send`. Used only to prove that a
/// fidelity tick reads its sent-bitrate figure from the sink's own count,
/// never from what the coordinator tracked as produced -- `HostNetworkSession`
/// already covers whether that count itself is right.
final class FakeCountingVideoSink: CanvasVideoSending, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [Int](repeating: 0, count: CanvasSurfaceID.capacity)

    func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool { true }

    func setSentVideoByteCount(_ bytes: Int, for surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        counts[surface.index] = bytes
    }

    func sentVideoByteCount(for surface: CanvasSurfaceID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return counts[surface.index]
    }
}

/// Review findings: a failed write counted as sent, the host and viewer
/// counting sent/received bytes on different bases, and no coverage proving
/// a fidelity tick reads sent bytes from the sink rather than from what the
/// coordinator tracked as produced.
@MainActor
func runSentByteAccountingTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    func packet(
        payloadCount: Int,
        codecConfigurationCount: Int? = nil,
        sequence: UInt64 = 1
    ) -> EncodedVideoFramePacket {
        EncodedVideoFramePacket(
            sequence: sequence,
            presentationTimeNanoseconds: sequence * 1_000_000,
            isKeyFrame: codecConfigurationCount != nil,
            codecConfiguration: codecConfigurationCount.map { Data(repeating: 0xC0, count: $0) },
            payload: Data(repeating: 0xAB, count: payloadCount)
        )
    }

    // A write the channel refused must count nothing as sent: the property's
    // own doc says "bytes actually written", and nothing left this machine.
    do {
        let channel = FakeHostByteChannel(scriptedMessages: [])
        channel.sendBytesError = HostNetworkSessionError.closed
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.start()
        try! await Task.sleep(for: .milliseconds(50))
        session.send(packet(payloadCount: 40), surface: surfaceZero, priority: .normal)
        try! await Task.sleep(for: .milliseconds(100))
        expect(
            session.sentVideoByteCount(for: surfaceZero) == 0,
            "a send the channel refused counts nothing as sent, got "
                + "\(session.sentVideoByteCount(for: surfaceZero) as Any)"
        )
    }

    // A key frame's codec configuration is counted alongside its payload,
    // matching the basis the viewer counts received bytes on.
    do {
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.start()
        try! await Task.sleep(for: .milliseconds(50))
        session.send(
            packet(payloadCount: 100, codecConfigurationCount: 12),
            surface: surfaceZero,
            priority: .normal
        )
        try! await Task.sleep(for: .milliseconds(100))
        expect(
            session.sentVideoByteCount(for: surfaceZero) == 112,
            "a key frame's sent-byte count includes its codec configuration, got "
                + "\(session.sentVideoByteCount(for: surfaceZero) as Any)"
        )
    }

    // The coordinator-level wiring: a fidelity tick's sent-bitrate figure
    // comes from the sink's own `sentVideoByteCount` delta, not from what the
    // coordinator itself tracked as produced. A link starved only when judged
    // against produced bytes must not be blamed once the two are told apart.
    do {
        func telemetry(receivedBitsPerSecond: Double) -> ViewerTelemetrySample {
            ViewerTelemetrySample(
                surfaceID: surfaceZero.wireValue,
                endToEnd: StageLatencySample(p50Nanoseconds: 20_000_000, p95Nanoseconds: 30_000_000),
                receive: StageLatencySample(p50Nanoseconds: 8_000_000, p95Nanoseconds: 12_000_000),
                decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 4_000_000),
                presentedFramesPerSecond: 60,
                decodedFramesPerSecond: 60,
                receivedBitsPerSecond: receivedBitsPerSecond
            )
        }

        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let media = FakeCanvasMedia()
        let sink = FakeCountingVideoSink()
        let events = DiagnosticsRecorder()
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(media),
            videoSink: sink,
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace()),
            onEvent: { events.record($0) }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )

        // A real link carrying this session's small, correctly-counted sent
        // bytes just fine: comfortably above `deliveredFraction` of what the
        // sink actually reports sent, while the coordinator's own produced
        // count -- from the large frames emitted below -- is over a hundred
        // times bigger. Using produced in place of sent would read this same
        // received figure as a link losing most of what left the host.
        _ = try! controller.handle(.viewerTelemetry(telemetry(receivedBitsPerSecond: 3_000)))

        for tick in 1...12 {
            media.frameCounts = HostFrameCounts(
                captured: 60 * tick,
                encoded: 60 * tick,
                encodeSubmissionFailures: 0
            )
            for _ in 0..<6 {
                media.emit(packet(payloadCount: 100_000, sequence: UInt64(tick)))
            }
            sink.setSentVideoByteCount(1_000 * tick, for: surfaceZero)
            await coordinator.tickFidelity(atSeconds: Double(tick) * 2)
        }

        expect(
            !events.messages.contains { $0.hasPrefix("fidelity now") },
            "a link the sink reports as healthy is never stepped down, got \(events.messages)"
        )
        expect(
            coordinator.appliedQualityScale(for: surfaceZero) == 1.0,
            "quality stays at full once the sent figure comes from the sink rather than from what was "
                + "produced, got \(coordinator.appliedQualityScale(for: surfaceZero))"
        )
    }

    print("PASS: sent-byte accounting only counts what actually left the host, on the viewer's own basis, "
        + "and a fidelity tick reads it from the sink rather than from what was produced")
}
