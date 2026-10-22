import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A viewer that asks for its own key frames is sent the periodic one every
/// 10 seconds instead of every second. Both of the encoder's key-frame bounds
/// follow the one interval, a frame-rate change keeps them together, and a
/// rebuilt encoder keeps the interval its stream had. A viewer that never said
/// so keeps the one-second key frame that bounds its wait.
@MainActor
func runViewerKeyFrameIntervalTests() async {
    expectTheConfigurationDerivesBothBoundsFromOneInterval()
    await expectTheEncoderSessionHoldsBothBounds()
    await expectTheCanvasMediaCarriesTheIntervalIntoEveryPipeline()
    await expectACanvasStretchesItsIntervalOnlyOnceTheViewerDeclared()
    await expectAHostScreenStretchesItsIntervalOnlyOnceTheViewerDeclared()
    print("PASS: a viewer that asks for its own key frames gets the periodic one every 10 seconds, and any other viewer every second")
}

private func expectTheConfigurationDerivesBothBoundsFromOneInterval() {
    expect(
        VideoEncoderConfiguration.standardKeyFrameIntervalSeconds == 1
            && VideoEncoderConfiguration.viewerRecoveryKeyFrameIntervalSeconds == 10,
        "the standard interval is one second and the one for a viewer that asks is ten"
    )
    let standard = VideoEncoderConfiguration.remoteDefault
    expect(
        standard.keyFrameIntervalSeconds == 1 && standard.maxKeyFrameIntervalFrames == 60,
        "a configuration opens at one second, which is 60 frames at 60 fps, got "
            + "\(standard.keyFrameIntervalSeconds) s and \(standard.maxKeyFrameIntervalFrames) frames"
    )
    let stretched = standard.with(keyFrameIntervalSeconds: 10)
    expect(
        stretched.keyFrameIntervalSeconds == 10 && stretched.maxKeyFrameIntervalFrames == 600,
        "ten seconds at 60 fps is 600 frames, got \(stretched.maxKeyFrameIntervalFrames)"
    )
    let slower = stretched.with(framesPerSecond: 30)
    expect(
        slower.keyFrameIntervalSeconds == 10 && slower.maxKeyFrameIntervalFrames == 300,
        "a frame-rate change keeps the interval and moves the frame count with it, got "
            + "\(slower.keyFrameIntervalSeconds) s and \(slower.maxKeyFrameIntervalFrames) frames"
    )
    let carried = [
        stretched.scaled(toStreamScale: 1.5),
        stretched.with(qualityScale: 0.5),
        stretched.with(profileLevel: .mainAutoLevel),
        VideoEncoderConfiguration.fullHiDPI.with(keyFrameIntervalSeconds: 10)
    ]
    expect(
        carried.allSatisfy { $0.keyFrameIntervalSeconds == 10 && $0.maxKeyFrameIntervalFrames == 600 },
        "a rebuild at another scale, quality or profile keeps the interval, got \(carried.map(\.keyFrameIntervalSeconds))"
    )
}

/// Read back from VideoToolbox, so what is checked is what the session holds
/// rather than what this encoder meant to give it. A machine with no hardware
/// H.264 encoder skips it, as the other real-encoder tests do.
private func expectTheEncoderSessionHoldsBothBounds() async {
    guard let standard = try? VideoToolboxEncoder(configuration: .remoteDefault, frameOutcomeHandler: { _ in }) else {
        print("SKIP: this machine has no hardware H.264 encoder, so there are no key-frame bounds to read back")
        return
    }
    let opening = standard.sessionKeyFrameIntervalBounds()
    expect(
        opening?.frames == 60 && opening?.seconds == 1,
        "a standard encoder opens with a key frame at least every 60 frames and every second, got \(String(describing: opening))"
    )
    do {
        try await standard.apply(keyFrameIntervalSeconds: 10)
    } catch {
        expect(false, "the running session takes a ten-second interval, got \(error)")
    }
    let stretched = standard.sessionKeyFrameIntervalBounds()
    expect(
        stretched?.frames == 600 && stretched?.seconds == 10,
        "a live change sets both bounds, got \(String(describing: stretched))"
    )
    do {
        try await standard.apply(framesPerSecond: 30)
    } catch {
        expect(false, "the running session takes 30 fps, got \(error)")
    }
    let slower = standard.sessionKeyFrameIntervalBounds()
    expect(
        slower?.frames == 300 && slower?.seconds == 10,
        "a frame-rate change keeps the frame bound at the frame rate times the interval in force, got \(String(describing: slower))"
    )

    guard let built = try? VideoToolboxEncoder(
        configuration: VideoEncoderConfiguration.remoteDefault.with(keyFrameIntervalSeconds: 10),
        frameOutcomeHandler: { _ in }
    ) else {
        expect(false, "an encoder opens at a ten-second interval on a machine that opened one at one second")
        return
    }
    let builtBounds = built.sessionKeyFrameIntervalBounds()
    expect(
        builtBounds?.frames == 600 && builtBounds?.seconds == 10,
        "an encoder built at ten seconds opens with both bounds at it, got \(String(describing: builtBounds))"
    )
}

@MainActor
private final class IntervalRecordingPipeline: CanvasMediaPipelining {
    private(set) var appliedKeyFrameIntervals: [Double] = []

    func start() async throws {}
    func stop() async throws {}
    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) async throws {}
    func apply(keyFrameIntervalSeconds: Double) async throws {
        appliedKeyFrameIntervals.append(keyFrameIntervalSeconds)
    }
    func requestKeyFrame() {}
    func refreshStillPicture() async throws -> Int? { nil }
}

/// Recorded before `start` and applied live after it, and in both cases every
/// pipeline the media builds from then on, a rebuild at a new scale included,
/// opens at it.
@MainActor
private func expectTheCanvasMediaCarriesTheIntervalIntoEveryPipeline() async {
    var configurations: [VideoEncoderConfiguration] = []
    var pipelines: [IntervalRecordingPipeline] = []
    let media = ScreenCaptureCanvasMedia(
        surface: CanvasSurfaceID.allCases[0],
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        pipelineFactory: { _, _, configuration, _, _, _, _, _, _, _, _ in
            configurations.append(configuration)
            let pipeline = IntervalRecordingPipeline()
            pipelines.append(pipeline)
            return pipeline
        },
        contentFilterProvider: { _ in SCContentFilter() }
    )
    try! await media.apply(keyFrameIntervalSeconds: 10)
    try! await media.start(canvasDisplayID: 42, onPacket: { _ in true })
    try? await media.reconfigure(streamScale: 1.5)
    expect(
        configurations.count == 2 && configurations.allSatisfy { $0.keyFrameIntervalSeconds == 10 },
        "an interval recorded before start reaches the first pipeline and the rebuilt one, got "
            + "\(configurations.map(\.keyFrameIntervalSeconds))"
    )

    try! await media.apply(keyFrameIntervalSeconds: 1)
    expect(
        pipelines.last?.appliedKeyFrameIntervals == [1],
        "an interval applied while streaming reaches the running pipeline, got "
            + "\(String(describing: pipelines.last?.appliedKeyFrameIntervals))"
    )
    try? await media.reconfigure(streamScale: 1)
    expect(
        configurations.last?.keyFrameIntervalSeconds == 1,
        "and the next rebuild opens at it, got \(String(describing: configurations.last?.keyFrameIntervalSeconds))"
    )
}

private let canvasStretchedLine = "key frames every 10 s on canvas 0: the viewer asks for one when it needs it"

@MainActor
private func makeCanvasIntervalFixture(
    media: FakeCanvasMedia
) -> (coordinator: HostSessionCoordinator, events: DiagnosticsRecorder) {
    let events = DiagnosticsRecorder()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        keyConfinement: .unconfined,
        privateDesktopOffered: { true }
    )
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(media),
        videoSink: FakeVideoSink(),
        onEvent: { events.record($0) }
    )
    return (coordinator, events)
}

private let canvasRequest = SensoriumMessage.canvasRequest(
    logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0
)

@MainActor
private func expectACanvasStretchesItsIntervalOnlyOnceTheViewerDeclared() async {
    do {
        let media = FakeCanvasMedia()
        let fixture = makeCanvasIntervalFixture(media: media)
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        expect(media.appliedKeyFrameIntervals.isEmpty, "nothing is streaming yet, so nothing is told yet")
        _ = try! await fixture.coordinator.handleWritingResponse(canvasRequest)
        expect(
            media.appliedKeyFrameIntervals.map(\.seconds) == [10]
                && media.appliedKeyFrameIntervals.allSatisfy { $0.startsBefore == 1 },
            "a canvas started after the declaration is moved to ten seconds as it starts, got \(media.appliedKeyFrameIntervals)"
        )
        expect(
            fixture.events.messages.filter { $0 == canvasStretchedLine }.count == 1,
            "and the host says so once, got \(fixture.events.messages)"
        )
    }

    do {
        let media = FakeCanvasMedia()
        let fixture = makeCanvasIntervalFixture(media: media)
        _ = try! await fixture.coordinator.handleWritingResponse(canvasRequest)
        expect(media.appliedKeyFrameIntervals.isEmpty, "a canvas streams at the standard interval before any declaration")
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        expect(
            media.appliedKeyFrameIntervals.map(\.seconds) == [10],
            "a declaration made while the canvas streams moves it to ten seconds live, got \(media.appliedKeyFrameIntervals)"
        )
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        expect(
            fixture.events.messages.filter { $0 == canvasStretchedLine }.count == 1,
            "the host says so once for the surface, however often it is told, got \(fixture.events.messages)"
        )
    }

    do {
        let media = FakeCanvasMedia()
        let fixture = makeCanvasIntervalFixture(media: media)
        _ = try! await fixture.coordinator.handleWritingResponse(canvasRequest)
        expect(
            media.appliedKeyFrameIntervals.isEmpty
                && !fixture.events.messages.contains { $0.hasPrefix("key frames every") },
            "a viewer that never declared keeps the one-second key frame, got \(media.appliedKeyFrameIntervals)"
        )
    }

    do {
        let media = FakeCanvasMedia()
        media.keyFrameIntervalFailure = VideoEncoderError.propertyUpdateFailed(-12900)
        let fixture = makeCanvasIntervalFixture(media: media)
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        _ = try! await fixture.coordinator.handleWritingResponse(canvasRequest)
        let refusals = fixture.events.messages.filter {
            $0.hasPrefix("key frames stay every 1 s on canvas 0: the encoder refused 10 s")
        }
        expect(
            refusals.count == 1 && !fixture.events.messages.contains(canvasStretchedLine),
            "an encoder that refuses the change keeps one second and the host says that instead, got \(fixture.events.messages)"
        )
    }
}

private let hostScreenStretchedLine =
    "key frames every 10 s on host-screen display 7: the viewer asks for one when it needs it"

@MainActor
private func expectAHostScreenStretchesItsIntervalOnlyOnceTheViewerDeclared() async {
    do {
        let events = DiagnosticsRecorder()
        var configuration: VideoEncoderConfiguration?
        let fixture = makeHostScreenPreferenceFixture(onEvent: { events.record($0) }) { built, _ in
            configuration = built
            return FakeScalableCanvasMedia()
        }
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenRequest(token: hostScreenPreferenceToken(fixture.controller), resumeTicket: nil)
        )
        expect(
            configuration?.keyFrameIntervalSeconds == 10,
            "a host-screen encoder is built at ten seconds for a viewer that declared first, got "
                + "\(String(describing: configuration?.keyFrameIntervalSeconds))"
        )
        expect(
            events.messages.filter { $0 == hostScreenStretchedLine }.count == 1,
            "and the host says so once, naming the display, got \(events.messages)"
        )
    }

    do {
        let events = DiagnosticsRecorder()
        var configuration: VideoEncoderConfiguration?
        let media = FakeScalableCanvasMedia()
        let fixture = makeHostScreenPreferenceFixture(onEvent: { events.record($0) }) { built, _ in
            configuration = built
            return media
        }
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenRequest(token: hostScreenPreferenceToken(fixture.controller), resumeTicket: nil)
        )
        expect(
            configuration?.keyFrameIntervalSeconds == 1 && media.appliedKeyFrameIntervals.isEmpty,
            "a host screen streams at one second before any declaration, got "
                + "\(String(describing: configuration?.keyFrameIntervalSeconds)) and \(media.appliedKeyFrameIntervals)"
        )
        _ = try! await fixture.coordinator.handleWritingResponse(.viewerKeyFrameRecovery)
        expect(
            media.appliedKeyFrameIntervals == [10],
            "a declaration made while the host screen streams moves it to ten seconds live, got \(media.appliedKeyFrameIntervals)"
        )
        expect(
            events.messages.filter { $0 == hostScreenStretchedLine }.count == 1,
            "and the host says so once, got \(events.messages)"
        )
    }
}
