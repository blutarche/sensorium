import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// See `expectRunLoopPumpCanDispatchQueuedWork` for why these two tests in
/// particular must run before anything else in the suite.
@MainActor
func runLifecycleAndGateTests() async {
        // These two tests come first, and have to: each models
        // `NativeCanvasWorkspace`'s readiness wait by pumping the run loop,
        // and a nested pump can only dispatch queued `@MainActor` work while
        // no run loop is yet running on this thread. See
        // `expectRunLoopPumpCanDispatchQueuedWork`, which each of them
        // asserts before it pumps.

        // A second connection's canvas request arriving while another's canvas
        // creation is still in flight must be a clean, logged rejection that
        // never tears down state this connection never owned — releasing or
        // replacing a canvas another still in-flight connection owns is exactly
        // the interleaving that corrupts the display-ID allocator.
        //
        // The rejection is produced the only way a shipped host can produce
        // one. Both connections' display sessions and workspaces share a single
        // `CanvasCreationGate`, as `sensoriumd` wires them, so the second
        // connection is rejected inside `HostSessionController.handle`'s
        // `VirtualDisplaySession.start` — before its own workspace is ever
        // asked to start. Its request is dispatched from inside the first
        // connection's placement by the same run-loop pump
        // `NativeCanvasWorkspace`'s readiness wait runs.
        do {
            expectRunLoopPumpCanDispatchQueuedWork("the shared single-flight gate rejection test")
            let busyGate = CanvasCreationGate()
            let busyAdapter = FakeVirtualDisplayAdapter()
            let busySession = VirtualDisplaySession(adapter: busyAdapter, creationGate: busyGate)
            // One set of display sessions shared by both connections, exactly
            // as `sensoriumd`'s single `HostConnectionSessionFactory` shares it.
            let busyFactory = HostConnectionSessionFactory(
                sessions: surfaceZeroOnly(busySession), keyConfinement: .unconfined, privateDesktopOffered: { true }
            )
            let placingWorkspace = InterleavingCanvasWorkspace(gate: busyGate)
            let placingCoordinator = HostSessionCoordinator(
                controller: busyFactory.makeController(),
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(placingWorkspace))

            let busyMedia = FakeCanvasMedia()
            let busyWorkspace = FakeCanvasWorkspace()
            let busyEvents = DiagnosticsRecorder()
            let busyCoordinator = HostSessionCoordinator(
                controller: busyFactory.makeController(),
                media: onlyOnSurfaceZero(busyMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(busyWorkspace),
                onEvent: { busyEvents.record($0) }
            )
            let busyOutcome = DiagnosticsRecorder()
            placingWorkspace.pump = {
                let rejected = Task { @MainActor in
                    do {
                        _ = try await busyCoordinator.handleWritingResponse(
                            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
                        )
                        busyOutcome.record("accepted")
                    } catch let error as CanvasCreationGateError {
                        busyOutcome.record("rejected: \(error)")
                    } catch {
                        busyOutcome.record("failed: \(error)")
                    }
                }
                // Pumping the run loop is what production's readiness wait
                // does, and what lets this second connection's queued handler
                // run while this placement still holds the gate.
                var pumps = 0
                while busyOutcome.messages.isEmpty, pumps < 300 {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    pumps += 1
                }
                // Separate from the outcome assertion below, which reads what
                // the second connection was told: this one says the pump never
                // got to tell it anything, so a starved pump is never reported
                // as the gate having answered wrongly.
                expect(
                    !busyOutcome.messages.isEmpty,
                    "the run-loop pump dispatched the second connection's queued canvas request within \(pumps) pumps"
                )
                _ = rejected
            }

            _ = try! await placingCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )

            expect(
                busyOutcome.messages == ["rejected: creationInProgress"],
                "a canvas request arriving while another connection's creation is in flight is rejected by the shared single-flight gate"
            )
            expect(
                busyWorkspace.startedDisplayIDs.isEmpty,
                "the rejection happens at the display session, before the rejected connection's workspace is ever asked to start"
            )
            expect(
                busyEvents.messages.contains { $0 == HostOperatorLog.describe(CanvasCreationGateError.creationInProgress) },
                "the rejection that actually fires is logged in the words the operator reads, not silently swallowed"
            )
            expect(
                busyWorkspace.stopCount == 0,
                "a rejected request never tears down the workspace: it never started one, and another connection's may still be in flight"
            )
            expect(
                busySession.isActive && busyAdapter.releasedHandles.isEmpty,
                "a rejected request never releases the canvas another connection's in-flight creation still needs"
            )
            expect(
                placingWorkspace.startedDisplayIDs.count == 1,
                "the in-flight placement the rejection interrupted still completes"
            )
            await busyCoordinator.sessionDidEnd(reason: "transport-closed")
            expect(
                busyWorkspace.stopCount == 0,
                "the transport-level teardown that follows a rejected request also must not stop a workspace this connection never started"
            )
            expect(
                busySession.isActive && busyAdapter.releasedHandles.isEmpty,
                "nor release the canvas the connection that actually owns it is still streaming"
            )
            await placingCoordinator.sessionDidEnd(reason: "test-teardown")
            expect(
                busyAdapter.releasedHandles.count == 1,
                "exactly one release, by the connection that actually owns the canvas"
            )
        }

        // A gate rejection reaches `HostNetworkSession` as a `CanvasCreationGateError`,
        // not a `HostSessionControllerError` — it must take the same non-fatal
        // path as a refused control message, not fall through to the transport's
        // "genuinely broken" catch-all that cancels the connection. Driven
        // through the same shared gate, so the error originates where a shipped
        // host originates it rather than being injected at the workspace.
        do {
            expectRunLoopPumpCanDispatchQueuedWork("the transport-level gate rejection test")
            let transportGate = CanvasCreationGate()
            let transportAdapter = FakeVirtualDisplayAdapter()
            let transportCanvasSession = VirtualDisplaySession(adapter: transportAdapter, creationGate: transportGate)
            let transportFactory = HostConnectionSessionFactory(
                sessions: surfaceZeroOnly(transportCanvasSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
            )
            let transportPlacingWorkspace = InterleavingCanvasWorkspace(gate: transportGate)
            let transportPlacingCoordinator = HostSessionCoordinator(
                controller: transportFactory.makeController(),
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(transportPlacingWorkspace))

            let transportController = transportFactory.makeController()
            let transportWorkspace = FakeCanvasWorkspace()
            let transportEvents = DiagnosticsRecorder()
            let transportChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
                .timeSyncRequest(clientTimeNanoseconds: 99),
            ])
            let transportNetworkSession = HostNetworkSession(
                connection: transportChannel,
                controller: transportController,
                onEvent: { transportEvents.record($0) }
            )
            transportNetworkSession.attach(coordinator: HostSessionCoordinator(
                controller: transportController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(transportWorkspace),
                onEvent: { transportEvents.record($0) }
            ))
            transportPlacingWorkspace.pump = {
                // The connection starts reading only once this placement
                // already holds the gate, so its canvasRequest is handled
                // during the in-flight creation rather than after it.
                transportNetworkSession.start()
                let answered = {
                    transportChannel.sentPackets.contains {
                        if case let .control(.timeSyncReply(client, _)) = $0 { return client == 99 }
                        return false
                    }
                }
                var pumps = 0
                while !answered(), pumps < 300 {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    pumps += 1
                }
                expect(
                    answered(),
                    "the run-loop pump ran this connection's scripted messages within \(pumps) pumps"
                )
            }

            _ = try! await transportPlacingCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )

            expect(
                transportChannel.cancelCount == 0,
                "a rejected canvas creation must not cancel the connection"
            )
            expect(
                transportChannel.sentPackets.contains {
                    if case let .control(.timeSyncReply(client, _)) = $0 { return client == 99 }
                    return false
                },
                "the session keeps handling messages after a gate rejection and answers them normally"
            )
            expect(
                transportWorkspace.startedDisplayIDs.isEmpty,
                "the transport's connection was rejected at the display session, before its workspace was asked to start"
            )
            expect(
                transportEvents.messages.contains { $0 == HostOperatorLog.describe(CanvasCreationGateError.creationInProgress) },
                "the rejection is still logged in the words the operator reads"
            )
            expect(
                transportChannel.sentPackets.contains {
                    if case let .control(.canvasRefused(reason, surfaceID)) = $0 {
                        return surfaceID == nil && !reason.isEmpty
                    }
                    return false
                },
                "a refused canvas request is answered with an explicit refusal carrying a reason, not with silence"
            )
            expect(
                transportWorkspace.stopCount == 0,
                "a gate rejection at the transport must not stop a workspace this connection never started"
            )
            expect(
                transportCanvasSession.isActive,
                "a gate rejection at the transport must not release a canvas another connection's in-flight creation still needs"
            )
            transportNetworkSession.stop()
            await transportPlacingCoordinator.sessionDidEnd(reason: "test-teardown")
        }

        // Every identity refused -- macOS would not create a session canvas
        // under any of them. The request reaches the transport as a
        // `CoreGraphicsVirtualDisplayError`, and the client has to be told
        // why: without a reply it sees only a connection that closed, calls
        // that unreachable, and redials a host that will refuse the next
        // canvas exactly as it refused this one.
        do {
            let unavailableAdapter = FakeVirtualDisplayAdapter()
            unavailableAdapter.acquireError = CoreGraphicsVirtualDisplayError.creationFailed
            let unavailableController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: unavailableAdapter)),
                keyConfinement: .unconfined,
                privateDesktopOffered: { true }
            )
            let unavailableEvents = DiagnosticsRecorder()
            let unavailableChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            ])
            let unavailableNetworkSession = HostNetworkSession(
                connection: unavailableChannel,
                controller: unavailableController,
                onEvent: { unavailableEvents.record($0) }
            )
            unavailableNetworkSession.attach(coordinator: HostSessionCoordinator(
                controller: unavailableController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace()),
                onEvent: { unavailableEvents.record($0) }
            ))
            unavailableNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(200))

            expect(
                unavailableChannel.sentPackets.contains {
                    $0 == .control(.canvasRefused(reason: CanvasRefusalReason.canvasUnavailable, surfaceID: nil))
                },
                "a canvas macOS refused under every identity is answered with its own refusal reason, not with silence, got \(unavailableChannel.sentPackets)"
            )
            expect(
                unavailableEvents.messages.contains { $0.contains("canvas request failed") && $0.contains("creationFailed") },
                "and the host log still names the failure for whoever is at the machine"
            )
            expect(
                unavailableChannel.cancelCount == 1,
                "the connection still ends -- this session has no canvas to stream"
            )
            unavailableNetworkSession.stop()
        }

        print("PASS: a canvas macOS would not create under any identity is refused on the wire before the connection closes")
}
