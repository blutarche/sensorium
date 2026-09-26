import Foundation
import SensoriumCore
import SensoriumHost

/// What the host log has to say about the displays it creates and gives back.
///
/// A canvas that is never released outlives the process that made it: no
/// public API removes another process's virtual display, so the only cure is
/// a restart. The host therefore has to make every release, and every release
/// it could not account for, readable from the log alone.
@MainActor
func runCanvasReleaseAccountingTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    do {
        let creator = FakeVirtualDisplayCreator()
        var log: [String] = []
        let adapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            creator: creator,
            log: { log.append($0) }
        )
        let handle = try! adapter.acquire(configuration: .remoteDefault)
        adapter.release(handle)
        expect(creator.destroyedHandles == [handle], "the display the adapter created is the one destroyed")
        expect(
            log.count == 1
                && log[0].contains("session canvas")
                && log[0].contains("display \(handle.rawValue)")
                && log[0].contains("identity 1"),
            "a released canvas leaves one line naming the display it gave back and the identity that is free again"
        )

        // The release path the bridge answers with silence: a display ID this
        // adapter never created. Nothing downstream can notice it, so the log
        // is the only place it can be seen at all.
        var strayLog: [String] = []
        let strayAdapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            creator: FakeVirtualDisplayCreator(),
            log: { strayLog.append($0) }
        )
        strayAdapter.release(VirtualDisplayHandle(rawValue: 404))
        expect(
            strayLog.count == 1 && strayLog[0].contains("404") && strayLog[0].contains("defect"),
            "releasing a display this host never created is reported as the defect it is, naming the display ID"
        )
    }

    print("PASS: every canvas release is logged, and releasing a display this host never created reads as a defect")

    do {
        // A capture stream can end on its own -- ScreenCaptureKit stops one
        // whose content is gone -- and a stop this host asked for can fail.
        // Neither produces a packet, a frame count, or any other trace, so a
        // session that goes silent is only explicable if both are said out
        // loud, and only useful if the line names the display it happened on.
        struct CaptureEnded: Error, CustomStringConvertible {
            var description: String { "the shareable content is gone" }
        }
        let stopped = ScreenCaptureStopReport.streamStopped(displayID: 81, error: CaptureEnded())
        expect(
            stopped.contains("81")
                && stopped.contains("stopped")
                && stopped.contains("the shareable content is gone"),
            "a stream that stopped by itself names the display it was capturing and what ended it"
        )
        let failed = ScreenCaptureStopReport.stopFailed(displayID: 81, error: CaptureEnded())
        expect(
            failed.contains("81")
                && failed.contains("the shareable content is gone")
                && failed != stopped,
            "a stop this host asked for and did not get is a different line, naming the same display"
        )
        // The pipeline is brought up a second time with a freshly resolved
        // filter when the first attempt fails, and the second attempt is the
        // one whose error reaches the caller. Unsaid, the attempt that failed
        // leaves no trace at all, and a machine whose capture has started
        // failing looks in the log exactly like one whose capture never
        // faltered.
        let startFailed = ScreenCaptureStopReport.startFailed(displayID: 81, error: CaptureEnded())
        expect(
            startFailed.contains("81")
                && startFailed.contains("the shareable content is gone")
                && startFailed != stopped
                && startFailed != failed,
            "a capture that would not start first time is its own line, naming the same display"
        )
    }

    print("PASS: a capture stream that stops by itself, and a stop that fails, both have words for the host log")

    do {
        // Every identity refused, which is what a machine carrying canvases
        // an earlier host left behind looks like. The request fails inside
        // the controller, before the coordinator's own bring-up, and the
        // client is told; the host log records why, so a person at the
        // machine does not just see a connection arrive, do nothing, and
        // leave.
        let refusing = FakeVirtualDisplayCreator()
        refusing.refusedSerials = Set(
            CanvasIdentityFallback.identities(for: surfaceZero).map(\.serialNumber)
        )
        let refusedSession = VirtualDisplaySession(
            adapter: CoreGraphicsVirtualDisplayAdapter(surface: surfaceZero, creator: refusing)
        )
        let events = DiagnosticsRecorder()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(refusedSession),
                keyConfinement: .unconfined,
                privateDesktopOffered: { true }
            ),
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace()),
            onEvent: { events.record($0) }
        )
        var refused = false
        do {
            _ = try await coordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
        } catch {
            refused = true
        }
        expect(refused, "a canvas that could not be created still ends the request")
        expect(
            events.messages.contains { $0.contains("canvas request failed") && $0.contains("creationFailed") },
            "and the host log names the failure rather than closing the connection in silence"
        )
        expect(!refusedSession.isActive, "no canvas is left claimed by a request that failed")

        // The same catch sees every other message the controller refuses, and
        // a line calling one of those a canvas request would send whoever
        // reads it looking for a display that was never asked for.
        let inputEvents = DiagnosticsRecorder()
        let inputCoordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            ),
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace()),
            onEvent: { inputEvents.record($0) }
        )
        var inputRefused = false
        do {
            _ = try await inputCoordinator.handleWritingResponse(
                .input(.pointerMoved(x: 10, y: 20), surfaceID: 9)
            )
        } catch {
            inputRefused = true
        }
        expect(inputRefused, "an input event naming a surface that cannot exist is still refused")
        expect(
            inputEvents.messages.contains { $0.contains("input failed") },
            "and the line names the message that failed"
        )
        expect(
            inputEvents.messages.allSatisfy { !$0.contains("canvas request") },
            "never a canvas request, which is not what arrived"
        )
    }

    print("PASS: a canvas request that fails inside the controller reaches the host log before the connection closes")

    do {
        // What a quit and a termination signal both have to run before the
        // process ends. A canvas this process does not release outlives it:
        // no public API removes another process's virtual display, so it
        // holds its identity until the machine restarts.
        let shutdown = CanvasShutdown()
        let creator = FakeVirtualDisplayCreator()
        let sessionAdapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            creator: creator,
            shutdown: shutdown
        )
        let probeAdapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            purpose: .capabilityProbe,
            creator: creator,
            shutdown: shutdown
        )
        let sessionCanvas = try! sessionAdapter.acquire(configuration: .remoteDefault)
        let probeCanvas = try! probeAdapter.acquire(configuration: .remoteDefault)
        expect(shutdown.liveCanvasCount == 2, "every canvas this process created is on the list")
        shutdown.releaseEverything()
        expect(
            Set(creator.destroyedHandles) == Set([sessionCanvas, probeCanvas]),
            "shutting down releases every canvas that was still held, the probe's included"
        )
        expect(shutdown.liveCanvasCount == 0, "and nothing is left on the list afterwards")
        shutdown.releaseEverything()
        expect(
            creator.destroyedHandles.count == 2,
            "a second shutdown releases nothing twice: the quit path and a termination signal can both run"
        )

        // A session that ended on its own has already given its canvas back,
        // and shutdown must not ask for it again.
        let reacquired = try! sessionAdapter.acquire(configuration: .remoteDefault)
        sessionAdapter.release(reacquired)
        expect(shutdown.liveCanvasCount == 0, "a canvas released the ordinary way leaves the list with it")
        shutdown.releaseEverything()
        expect(creator.destroyedHandles.count == 3, "and is not released a second time at shutdown")
    }

    print("PASS: shutting down releases every canvas this process still holds, once, however often it is asked")
}
