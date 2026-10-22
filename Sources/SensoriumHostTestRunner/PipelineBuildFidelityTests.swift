import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Building a pipeline waits on the encoder service, for minutes when the
/// hardware encoder is stuck, and the main actor goes on meanwhile. A
/// fidelity change that arrives during that wait has no pipeline to reach
/// yet, so the media only records it. The pipeline being built was given the
/// values from before the change, and once it is installed it must still end
/// up running the values most recently applied: the fidelity tick sees its
/// own level already in force and would never send them again.

/// Holds the `heldBuild`-th pipeline build, counting from one, until
/// `release`. Every other build passes straight through.
@MainActor
private final class PipelineBuildHold {
    private let heldBuild: Int
    private var builds = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isHolding = false

    init(heldBuild: Int) {
        self.heldBuild = heldBuild
    }

    func build() async {
        builds += 1
        guard builds == heldBuild, !isReleased else {
            return
        }
        isHolding = true
        await withCheckedContinuation { waiting = $0 }
        isHolding = false
    }

    func release() {
        isReleased = true
        waiting?.resume()
        waiting = nil
    }
}

/// Runs at the fidelity it was built with until a change is applied to it.
@MainActor
private final class FidelityTrackingPipeline: CanvasMediaPipelining {
    private(set) var framesPerSecond: Int
    private(set) var qualityScale: Double
    private(set) var keyFrameIntervalSeconds: Double

    init(builtWith configuration: VideoEncoderConfiguration) {
        framesPerSecond = configuration.framesPerSecond
        qualityScale = configuration.qualityScale
        keyFrameIntervalSeconds = configuration.keyFrameIntervalSeconds
    }

    func start() async throws {}
    func stop() async throws {}
    func apply(framesPerSecond: Int) async throws { self.framesPerSecond = framesPerSecond }
    func apply(qualityScale: Double) async throws { self.qualityScale = qualityScale }
    func apply(keyFrameIntervalSeconds: Double) async throws { self.keyFrameIntervalSeconds = keyFrameIntervalSeconds }
    func requestKeyFrame() {}
    func refreshStillPicture() async throws -> Int? { nil }
}

/// What the tests build and inspect: one media, the pipelines it built in
/// order, and the hold on the build the fidelity change arrives during.
@MainActor
private final class HeldBuildFixture {
    let hold: PipelineBuildHold
    private(set) var pipelines: [FidelityTrackingPipeline] = []

    init(heldBuild: Int) {
        hold = PipelineBuildHold(heldBuild: heldBuild)
    }

    var factory: HostMediaPipelineFactory {
        { [self] _, _, configuration, _, _, _, _, _, _, _, _ in
            await hold.build()
            let pipeline = FidelityTrackingPipeline(builtWith: configuration)
            pipelines.append(pipeline)
            return pipeline
        }
    }
}

private let appliedFramesPerSecond = 30
private let appliedQualityScale = 0.5
private let appliedKeyFrameIntervalSeconds = VideoEncoderConfiguration.viewerRecoveryKeyFrameIntervalSeconds

/// Waits for `operation` to reach the held build, applies all three levers
/// to `media` while it waits, then lets the build finish.
@MainActor
private func applyFidelity(
    to media: any CanvasMediaStreaming,
    whileHeldBy hold: PipelineBuildHold,
    during operation: @escaping @MainActor () async throws -> Void
) async -> Result<Void, any Error> {
    let task = Task { @MainActor in
        try await operation()
    }
    let reached = await waitUntil(timeoutSeconds: 10) { hold.isHolding }
    expect(reached, "the pipeline build is held while the fidelity change arrives")
    try? await media.apply(framesPerSecond: appliedFramesPerSecond)
    try? await media.apply(qualityScale: appliedQualityScale)
    try? await media.apply(keyFrameIntervalSeconds: appliedKeyFrameIntervalSeconds)
    hold.release()
    return await task.result
}

@MainActor
private func expectTheInstalledPipelineRunsTheAppliedFidelity(
    _ fixture: HeldBuildFixture,
    media: any CanvasMediaStreaming,
    builds: Int,
    _ what: String
) async {
    expect(
        fixture.pipelines.count == builds,
        "\(what): \(builds) pipelines are built, got \(fixture.pipelines.count)"
    )
    guard let pipeline = fixture.pipelines.last else {
        return
    }
    expect(
        pipeline.framesPerSecond == appliedFramesPerSecond,
        "\(what): the installed pipeline runs the frame rate applied during its build, got \(pipeline.framesPerSecond)"
    )
    expect(
        pipeline.qualityScale == appliedQualityScale,
        "\(what): the installed pipeline runs the quality applied during its build, got \(pipeline.qualityScale)"
    )
    expect(
        pipeline.keyFrameIntervalSeconds == appliedKeyFrameIntervalSeconds,
        "\(what): the installed pipeline runs the key-frame interval applied during its build, got \(pipeline.keyFrameIntervalSeconds)"
    )
    let reportedFramesPerSecond = await media.currentFramesPerSecond
    let reportedQualityScale = await media.currentQualityScale
    expect(
        reportedFramesPerSecond == appliedFramesPerSecond && reportedQualityScale == appliedQualityScale,
        "\(what): the media reports the fidelity its pipeline runs, got \(reportedFramesPerSecond) fps at quality \(reportedQualityScale)"
    )
}

@MainActor
private func expectAChangeDuringTheFirstBuildReachesThePipeline(
    _ what: String,
    makeMedia: (HeldBuildFixture) -> any CanvasMediaStreaming
) async {
    let fixture = HeldBuildFixture(heldBuild: 1)
    let media = makeMedia(fixture)
    let outcome = await applyFidelity(to: media, whileHeldBy: fixture.hold) {
        try await media.start(canvasDisplayID: 42, onPacket: { _ in true })
    }
    if case .failure(let error) = outcome {
        expect(false, "\(what) starts once its build is let go, got \(error)")
    }
    await expectTheInstalledPipelineRunsTheAppliedFidelity(fixture, media: media, builds: 1, what)
    await media.stop()
}

@MainActor
private func expectAChangeDuringAResolutionRebuildReachesThePipeline(
    _ what: String,
    makeMedia: (HeldBuildFixture) -> any CanvasMediaStreaming
) async {
    let fixture = HeldBuildFixture(heldBuild: 2)
    let media = makeMedia(fixture)
    do {
        try await media.start(canvasDisplayID: 42, onPacket: { _ in true })
    } catch {
        expect(false, "\(what) starts, got \(error)")
        return
    }
    let outcome = await applyFidelity(to: media, whileHeldBy: fixture.hold) {
        try await media.reconfigure(streamScale: 0.5)
    }
    if case .failure(let error) = outcome {
        expect(false, "\(what) rebuilds at the new resolution once its build is let go, got \(error)")
    }
    await expectTheInstalledPipelineRunsTheAppliedFidelity(fixture, media: media, builds: 2, what)
    let reportedScale = await media.currentStreamScale
    expect(reportedScale == 0.5, "\(what): the rebuild still moves to the new resolution, got \(reportedScale)")
    await media.stop()
}

@available(macOS 13.0, *)
@MainActor
private func makeHostScreenMedia(_ fixture: HeldBuildFixture) -> any CanvasMediaStreaming {
    HostScreenCaptureMedia(
        configuration: .remoteDefault,
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        contentFilterProvider: { _ in SCContentFilter() },
        pipelineFactory: fixture.factory
    )
}

@available(macOS 13.0, *)
@MainActor
private func makeCanvasMedia(_ fixture: HeldBuildFixture) -> any CanvasMediaStreaming {
    ScreenCaptureCanvasMedia(
        surface: CanvasSurfaceID.allCases[0],
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        pipelineFactory: fixture.factory,
        contentFilterProvider: { _ in SCContentFilter() }
    )
}

@available(macOS 13.0, *)
@MainActor
func runPipelineBuildFidelityTests() async {
    await expectAChangeDuringTheFirstBuildReachesThePipeline("a host-screen capture", makeMedia: makeHostScreenMedia)
    await expectAChangeDuringTheFirstBuildReachesThePipeline("a canvas capture", makeMedia: makeCanvasMedia)
    await expectAChangeDuringAResolutionRebuildReachesThePipeline("a host-screen capture", makeMedia: makeHostScreenMedia)
    await expectAChangeDuringAResolutionRebuildReachesThePipeline("a canvas capture", makeMedia: makeCanvasMedia)
    print("PASS: a fidelity change applied while a pipeline is built reaches that pipeline once it is installed")
}
