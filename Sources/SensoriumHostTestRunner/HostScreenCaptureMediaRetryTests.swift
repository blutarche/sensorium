import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Records, in one shared order, when each pipeline starts and stops, so a
/// test can say which happened first.
@MainActor
private final class PipelineEventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// A pipeline double for `HostScreenCaptureMedia`'s injected factory. Real
/// `HostMediaPipeline` needs a granted, on-screen ScreenCaptureKit session,
/// which nothing in this repository has.
@available(macOS 13.0, *)
@MainActor
private final class RecordingPipeline: CanvasMediaPipelining {
    let id: Int
    let startError: Error?
    let events: PipelineEventLog
    private(set) var stopCallCount = 0

    init(id: Int, startError: Error?, events: PipelineEventLog) {
        self.id = id
        self.startError = startError
        self.events = events
    }

    func start() async throws {
        events.record("start \(id)")
        if let startError {
            throw startError
        }
    }

    func stop() async throws {
        stopCallCount += 1
        events.record("stop \(id)")
    }

    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) async throws {}
    func apply(keyFrameIntervalSeconds: Double) async throws {}
    func requestKeyFrame() {}
    func refreshStillPicture() async throws -> Int? { id }
}

/// `HostScreenCaptureMedia.startPipeline` stops a bring-up that failed
/// before the retry builds its replacement: the failed attempt installed its
/// pipeline before starting it, so a start that failed part-way leaves a
/// capture stream the host still owns.
@available(macOS 13.0, *)
@MainActor
func runHostScreenCaptureMediaRetryTests() async {
    let log = DiagnosticsRecorder()
    let events = PipelineEventLog()
    var pipelines: [RecordingPipeline] = []
    let media = HostScreenCaptureMedia(
        configuration: .remoteDefault,
        admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
        ),
        log: { log.record($0) },
        contentFilterProvider: { _ in SCContentFilter() },
        pipelineFactory: { _, _, _, _, _, _, _, _, _, _, _ in
            let pipeline = RecordingPipeline(
                id: pipelines.count,
                startError: pipelines.isEmpty ? FakeMediaFailure.captureUnavailable : nil,
                events: events
            )
            pipelines.append(pipeline)
            return pipeline
        }
    )

    try! await media.start(canvasDisplayID: 42, onPacket: { _ in true })

    expect(
        pipelines.count == 2,
        "a host-screen bring-up that fails once is retried exactly once, got \(pipelines.count) pipelines built"
    )
    expect(
        pipelines.first?.stopCallCount == 1,
        "the pipeline that failed to start is stopped, got \(String(describing: pipelines.first?.stopCallCount))"
    )
    expect(
        pipelines.last?.stopCallCount == 0,
        "the pipeline that started is left running, not stopped"
    )
    expect(
        events.events == ["start 0", "stop 0", "start 1"],
        "the failed pipeline is stopped before the retry's pipeline starts, got \(events.events)"
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

    print("PASS: a host-screen pipeline that fails to start is stopped before the retry replaces it")
}
