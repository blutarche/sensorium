import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A pipeline double for `ScreenCaptureCanvasMedia`'s injected factory. Real
/// `HostMediaPipeline` cannot run here: it requires a granted, on-screen
/// ScreenCaptureKit session, which nothing in this repository has.
@available(macOS 13.0, *)
@MainActor
private final class FakeMediaPipeline: CanvasMediaPipelining {
    let id: Int
    let startError: Error?
    private(set) var stopCallCount = 0

    init(id: Int, startError: Error?) {
        self.id = id
        self.startError = startError
    }

    func start() async throws {
        if let startError {
            throw startError
        }
    }

    func stop() async throws {
        stopCallCount += 1
    }

    func apply(framesPerSecond: Int) async throws {}

    func apply(qualityScale: Double) throws {}

    func requestKeyFrame() {}

    func refreshStillPicture() async throws -> Int? { id }
}

/// `ScreenCaptureCanvasMedia.startPipeline` stops a bring-up that failed
/// before building the retry's pipeline -- see the commit that made it do so.
/// Nothing in this repository can run real ScreenCaptureKit, so this drives
/// the class through the injected pipeline factory and content-filter
/// provider instead.
@available(macOS 13.0, *)
@MainActor
func runScreenCaptureCanvasMediaRetryTests() async {
    let surface = CanvasSurfaceID.allCases[0]
    let log = DiagnosticsRecorder()
    var pipelines: [FakeMediaPipeline] = []
    let media = ScreenCaptureCanvasMedia(
        surface: surface,
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        log: { log.record($0) },
        pipelineFactory: { _, _, _, _, _, _, _, _, _, _ in
            let pipeline = FakeMediaPipeline(
                id: pipelines.count,
                startError: pipelines.isEmpty ? FakeMediaFailure.captureUnavailable : nil
            )
            pipelines.append(pipeline)
            return pipeline
        },
        contentFilterProvider: { _ in SCContentFilter() }
    )

    try! await media.start(canvasDisplayID: 42, onPacket: { _ in true })

    expect(
        pipelines.count == 2,
        "a bring-up that fails once is retried exactly once, got \(pipelines.count) pipelines built"
    )
    expect(
        pipelines.first?.stopCallCount == 1,
        "the pipeline that failed to start is stopped before the retry builds its replacement, got \(String(describing: pipelines.first?.stopCallCount))"
    )
    expect(
        pipelines.last?.stopCallCount == 0,
        "the pipeline that started is left running, not stopped"
    )
    expect(
        log.messages == [ScreenCaptureStopReport.startFailed(displayID: 42, error: FakeMediaFailure.captureUnavailable)],
        "the first bring-up's failure is logged exactly once, got \(log.messages)"
    )
    let liveRefresh = try! await media.refreshStillPicture()
    expect(
        liveRefresh == pipelines.last?.id,
        "the pipeline that started is the one the media now streams through, got \(String(describing: liveRefresh))"
    )

    print("PASS: a canvas pipeline that fails to start is stopped before the retry replaces it")
}
