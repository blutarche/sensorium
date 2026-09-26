import Foundation
import SensoriumCore
import SensoriumHost

/// What this process does once this machine has stopped giving it any picture
/// at all: every later canvas request is refused in words the viewer can
/// branch on, the person at this machine is told the one thing that fixes it,
/// and neither is said twice.
@MainActor
func runCaptureUnavailableTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    do {
        let availability = HostCaptureAvailability()
        let log = DiagnosticsRecorder()
        expect(!availability.isUnavailable, "a process that has streamed nothing yet has nothing to report")
        availability.markUnavailable(log: { log.record($0) })
        availability.markUnavailable(log: { log.record($0) })
        expect(availability.isUnavailable, "the state survives the call that set it")
        expect(
            log.messages == [
                "capture on this machine delivers nothing; Sensorium Host needs to be quit and opened again"
            ],
            "the line naming the only remedy is written once however many times the state is set, got \(log.messages)"
        )
    }

    print("PASS: a host process that cannot capture records it once and says what fixes it")

    do {
        let availability = HostCaptureAvailability()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            captureAvailability: availability,
            privateDesktopOffered: { true }
        )
        availability.markUnavailable(log: { _ in })
        let response = try? controller.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(
            response == .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable, surfaceID: 0),
            "a canvas nothing on this machine can capture is refused in words, not answered with a black window, got \(String(describing: response))"
        )
        expect(
            CanvasRefusalReason.canvasUnavailable == "canvas-unavailable",
            "the token a viewer branches on is stable"
        )
    }

    print("PASS: every canvas request after capture stopped working is refused with a reason the viewer can read")

    do {
        // Observed on a real host: every stream in the process started
        // without error and delivered nothing at all -- no screen change, no
        // unchanged frame, no no-change notice, no other delivery -- for the
        // whole of a session. The workspace window guarantees a first frame
        // and the first-frame gate forces it to count, so a stream that has
        // delivered none of any kind is not a quiet screen. It is a dead one.
        let media = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let events = DiagnosticsRecorder()
        let ended = DiagnosticsRecorder()
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
            onEvent: { events.record($0) },
            onSessionEnded: { ended.record("ended") },
            captureAvailability: availability
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // The first tick is the reading the next one is measured against.
        await coordinator.tickFidelity(atSeconds: 0)
        await coordinator.tickFidelity(atSeconds: 1)
        expect(
            media.reconfiguredScales.isEmpty,
            "one report with nothing delivered is not yet a dead stream, got \(media.reconfiguredScales)"
        )
        await coordinator.tickFidelity(atSeconds: 2)
        expect(
            media.reconfiguredScales == [coordinator.appliedStreamScale(for: surfaceZero)],
            "a second report with nothing delivered rebuilds the pipeline once, at the scale it was already streaming, got \(media.reconfiguredScales)"
        )
        expect(
            !coordinator.hasEnded && !availability.isUnavailable,
            "a rebuild is tried before anything is given up on"
        )
        await coordinator.tickFidelity(atSeconds: 3)
        await coordinator.tickFidelity(atSeconds: 4)
        expect(
            media.reconfiguredScales.count == 1,
            "the rebuild is tried once, not once per silent report, got \(media.reconfiguredScales)"
        )
        expect(
            coordinator.hasEnded && ended.messages == ["ended"],
            "a rebuilt stream that is still silent ends the session rather than leaving the viewer a window that never updates"
        )
        expect(
            availability.isUnavailable,
            "and records that this process cannot capture on this machine at all"
        )
        expect(
            events.messages.filter { $0 == HostCaptureAvailability.operatorLogLine }.count == 1,
            "the remedy is in the host log exactly once, got \(events.messages)"
        )
    }

    print("PASS: a capture stream that delivers nothing is rebuilt once, then gives up on this process's capture")

    do {
        // The other half of the same machine state: every canvas identity
        // this process released stays refused for as long as it runs. A
        // refusal before this process has released anything is a different
        // thing entirely -- a leftover canvas from an earlier run, or a
        // machine with no virtual-display runtime -- and neither is fixed by
        // opening the host again.
        let availability = HostCaptureAvailability()
        let creator = FakeVirtualDisplayCreator()
        let log = DiagnosticsRecorder()
        let surface = CanvasSurfaceID.allCases[0]
        let adapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surface,
            creator: creator,
            captureAvailability: availability,
            log: { log.record($0) }
        )
        let everyIdentity = CanvasIdentityFallback.identities(for: surface, purpose: .session)
        creator.refusedSerials = Set(everyIdentity.map(\.serialNumber))
        _ = try? adapter.acquire(configuration: VirtualCanvasConfiguration.remoteDefault)
        expect(
            !availability.isUnavailable,
            "a process that has released no canvas of its own has broken nothing, whatever refused it"
        )

        creator.refusedSerials = []
        let handle = try! adapter.acquire(configuration: VirtualCanvasConfiguration.remoteDefault)
        adapter.release(handle)
        creator.refusedSerials = Set(everyIdentity.map(\.serialNumber))
        _ = try? adapter.acquire(configuration: VirtualCanvasConfiguration.remoteDefault)
        expect(
            availability.isUnavailable,
            "an identity this process released and cannot take back is machine state only quitting clears"
        )
        expect(
            log.messages.filter { $0 == HostCaptureAvailability.operatorLogLine }.count == 1,
            "and the remedy reaches the same log the release lines do, once, got \(log.messages)"
        )
    }

    print("PASS: a canvas identity this process released and can no longer acquire is capture stopping working")

    do {
        let store = HostOperatorStatusStore(
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        )
        store.beginHosting(address: "100.64.0.1")
        store.recordCaptureUnavailable()
        let presentation = store.status.presentation(now: Date())
        expect(
            presentation.headline == "Quit Sensorium Host and open it again",
            "the host window says the one thing that fixes it, got \(presentation.headline)"
        )
        expect(
            presentation.detail.contains("machine"),
            "and calls this a machine, got \(presentation.detail)"
        )
        expect(
            presentation.indicator == .attention,
            "a host that cannot capture is not a host quietly waiting"
        )
    }

    print("PASS: the host window tells the person at this machine to quit and open the host again")
}
