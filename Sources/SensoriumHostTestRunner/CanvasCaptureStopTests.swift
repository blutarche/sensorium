import Foundation
import SensoriumCore
import SensoriumHost

@MainActor
private func canvasCaptureStopCoordinator(
    media: FakeScalableCanvasMedia,
    unrecoverable: DiagnosticsRecorder
) async -> HostSessionCoordinator {
    let coordinator = HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        ),
        media: onlyOnSurfaceZero(media),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        streamScaleSettleSeconds: 0.05,
        flowReportSeconds: 1,
        onStreamUnrecoverable: { unrecoverable.record($0) }
    )
    _ = try! await coordinator.handleWritingResponse(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    )
    return coordinator
}

/// A session canvas whose capture stops on its own is built again once. If
/// that fails, or the rebuilt capture stops too, the session ends with
/// `captureUnavailable` rather than leaving the viewer on a frozen picture.
@MainActor
func runCanvasCaptureStopTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    do {
        let media = FakeScalableCanvasMedia()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = await canvasCaptureStopCoordinator(media: media, unrecoverable: unrecoverable)
        let scale = coordinator.appliedStreamScale(for: surfaceZero)

        media.simulateCaptureStoppedOnItsOwn()
        try! await Task.sleep(for: .milliseconds(100))
        expect(
            media.reconfiguredScales == [scale],
            "the first stop rebuilds the capture once, at the scale it was streaming, got \(media.reconfiguredScales)"
        )
        expect(!coordinator.hasEnded, "a rebuilt capture keeps the session")

        media.simulateCaptureStoppedOnItsOwn()
        try! await Task.sleep(for: .milliseconds(100))
        expect(media.reconfiguredScales.count == 1, "a second stop is not rebuilt again, got \(media.reconfiguredScales)")
        expect(coordinator.hasEnded, "a second stop ends the session")
        expect(
            unrecoverable.messages == [GoodbyeReason.captureUnavailable],
            "the session ends as captureUnavailable, got \(unrecoverable.messages)"
        )
    }

    print("PASS: a canvas capture that stops on its own is rebuilt once, and a second stop ends the session")

    do {
        let media = FakeScalableCanvasMedia()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = await canvasCaptureStopCoordinator(media: media, unrecoverable: unrecoverable)
        media.reconfigurationFailure = FakeMediaFailure.captureUnavailable

        media.simulateCaptureStoppedOnItsOwn()
        try! await Task.sleep(for: .milliseconds(100))
        expect(coordinator.hasEnded, "a rebuild that fails ends the session")
        expect(
            unrecoverable.messages == [GoodbyeReason.captureUnavailable],
            "a failed rebuild ends the session as captureUnavailable, got \(unrecoverable.messages)"
        )
    }

    print("PASS: a canvas capture rebuild that fails ends the session as captureUnavailable")

    do {
        let media = FakeScalableCanvasMedia()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = await canvasCaptureStopCoordinator(media: media, unrecoverable: unrecoverable)
        media.reconfigurationFailure = CanvasMediaReconfigurationError.recoveredToPreviousScale(1)

        media.simulateCaptureStoppedOnItsOwn()
        try! await Task.sleep(for: .milliseconds(100))
        expect(!coordinator.hasEnded, "a rebuild that recovers at the previous scale still streams, so the session stays")
        expect(unrecoverable.messages.isEmpty, "nothing is reported unrecoverable, got \(unrecoverable.messages)")
    }

    print("PASS: a canvas capture rebuild that recovers at the previous scale keeps the session")

    do {
        let media = FakeScalableCanvasMedia()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = await canvasCaptureStopCoordinator(media: media, unrecoverable: unrecoverable)
        await coordinator.sessionDidEnd(reason: "transport-closed")

        media.simulateCaptureStoppedOnItsOwn()
        try! await Task.sleep(for: .milliseconds(100))
        expect(media.reconfiguredScales.isEmpty, "a stop after the session ended rebuilds nothing, got \(media.reconfiguredScales)")
        expect(unrecoverable.messages.isEmpty, "and reports nothing, got \(unrecoverable.messages)")
    }

    print("PASS: a canvas capture stop after the session ended is ignored")
}
