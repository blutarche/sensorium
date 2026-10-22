import Foundation
import SensoriumCore
import SensoriumHost

/// A fidelity change waits on the encoder, and an encoder can stall for
/// minutes. A tick that arrives while an earlier one is still waiting must
/// not pile another change in behind it: it is skipped, and the tick after
/// the stall ends judges the stream afresh.

/// Canvas media whose first frame-rate change does not return until the test
/// lets it go, as a change waiting on a stalled encoder does. Counts every
/// reading of its counters, which is the first thing a tick does.
@MainActor
private final class StallingFidelityMedia: CanvasMediaStreaming {
    private(set) var appliedFramesPerSecond: [Int] = []
    private(set) var frameCountReadings = 0
    private(set) var isApplyStalled = false
    private var stalledApply: CheckedContinuation<Void, Never>?
    private var hasStalled = false
    var counts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
    var currentStreamScale: Double = StreamScalePolicy.defaultScale
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0

    var frameCounts: HostFrameCounts {
        frameCountReadings += 1
        return counts
    }

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {}

    func stop() async {}

    func reconfigure(streamScale: Double) async throws {
        currentStreamScale = streamScale
    }

    func apply(framesPerSecond: Int) async throws {
        appliedFramesPerSecond.append(framesPerSecond)
        if !hasStalled {
            hasStalled = true
            isApplyStalled = true
            await withCheckedContinuation { stalledApply = $0 }
            isApplyStalled = false
        }
        currentFramesPerSecond = framesPerSecond
    }

    func apply(qualityScale: Double) async throws {
        currentQualityScale = qualityScale
    }

    func requestKeyFrame() async {}

    func refreshStillPicture() async throws -> Int? { nil }

    func letStalledApplyGo() {
        stalledApply?.resume()
        stalledApply = nil
    }
}

@MainActor
private final class TickFinished {
    var value = false
}

@MainActor
func runFidelityTickOverlapTests() async {
    let surface = CanvasSurfaceID.allCases[0]
    let media = StallingFidelityMedia()
    let coordinator = HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        ),
        media: onlyOnSurfaceZero(media),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        streamScaleSettleSeconds: 0.05
    )
    _ = try! await coordinator.handleWritingResponse(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    )

    // Six of every sixty captures lost before the encoder is sustained
    // encoder pressure: after the warm-up, a tick steps the frame rate down.
    var stalledTick: Task<Void, Never>?
    var stalledAt = 0
    for tick in 0...8 {
        media.counts = HostFrameCounts(
            captured: 60 * (tick + 1),
            encoded: 54 * (tick + 1),
            encodeSubmissionFailures: 0,
            encoderInputDropped: 6 * (tick + 1)
        )
        let ticking = Task { @MainActor in
            await coordinator.tickFidelity(atSeconds: Double(tick))
        }
        let finished = TickFinished()
        Task { @MainActor in
            await ticking.value
            finished.value = true
        }
        _ = await waitUntil(timeoutSeconds: 5) { finished.value || media.isApplyStalled }
        if media.isApplyStalled {
            stalledTick = ticking
            stalledAt = tick
            break
        }
    }
    guard let stalledTick else {
        expect(false, "sustained encoder pressure reaches a frame-rate change for the stall to hold up")
        return
    }

    let readingsBefore = media.frameCountReadings
    let overlappingTickReturned = TickFinished()
    let overlapping = Task { @MainActor in
        await coordinator.tickFidelity(atSeconds: Double(stalledAt + 1))
        overlappingTickReturned.value = true
    }
    _ = await waitUntil(timeoutSeconds: 5) { overlappingTickReturned.value }
    expect(overlappingTickReturned.value, "a tick arriving while a fidelity change is stalled returns at once")
    expect(
        media.frameCountReadings == readingsBefore && media.appliedFramesPerSecond == [45],
        "a tick arriving while a fidelity change is stalled is skipped, not run behind it: read the counters "
            + "\(media.frameCountReadings - readingsBefore) times, frame rates asked for \(media.appliedFramesPerSecond)"
    )

    media.letStalledApplyGo()
    await stalledTick.value
    await overlapping.value
    expect(
        coordinator.appliedFramesPerSecond(for: surface) == 45,
        "the stalled change completes once it is let go, got \(coordinator.appliedFramesPerSecond(for: surface)) fps"
    )

    let readingsAfterStall = media.frameCountReadings
    await coordinator.tickFidelity(atSeconds: Double(stalledAt + 2))
    expect(
        media.frameCountReadings > readingsAfterStall,
        "the first tick after the stall ends runs normally"
    )

    print("PASS: a fidelity tick that arrives while an earlier one waits on a stalled change is skipped, and ticking resumes after")
}
