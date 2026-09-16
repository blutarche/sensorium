import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Declares the naked fixtures the rest of this suite shares and mirrors
/// each into `fixtures` as it is created, so the later parts can read them
/// back under the same names.
@MainActor
func runCoreSessionTestsPart1(_ fixtures: CoreSessionSharedFixtures) async {
        let surfaceZero = CanvasSurfaceID.allCases[0]
        fixtures.surfaceZero = surfaceZero
        let surfaceOne = CanvasSurfaceID.allCases[1]
        fixtures.surfaceOne = surfaceOne
        let packetizer = VideoPacketSequencer()
        let codecConfiguration = try! H264CodecConfigurationCodec.encode(H264CodecConfiguration(
            sequenceParameterSet: Data([0x67, 0x42, 0x00, 0x1F]),
            pictureParameterSet: Data([0x68, 0xCE, 0x06, 0xE2])
        ))
        let keyFrame = packetizer.packet(
            presentationTimeNanoseconds: 1,
            isKeyFrame: true,
            codecConfiguration: codecConfiguration,
            payload: Data([1])
        )
        let interFrame = packetizer.packet(
            presentationTimeNanoseconds: 2,
            isKeyFrame: false,
            codecConfiguration: codecConfiguration,
            payload: Data([2])
        )
        guard keyFrame.sequence == 0,
              keyFrame.codecConfiguration == codecConfiguration,
              interFrame.sequence == 1,
              interFrame.codecConfiguration == nil else {
            print("FAIL: video packet sequencer did not number frames or isolate recovery configuration")
            Foundation.exit(1)
        }
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)

        let directOwner = CanvasOwnerToken()
        let firstHandle = try! session.start(owner: directOwner, configuration: .remoteDefault)
        let secondHandle = try! session.start(owner: directOwner, configuration: .remoteDefault)
        let configurations = adapter.acquiredConfigurations

        expect(firstHandle == secondHandle, "starting twice reuses one display handle")
        expect(configurations == [.remoteDefault], "session requests 1920x1200 scale-2 canvas")

        session.stop()
        session.stop()
        let releasedHandles = adapter.releasedHandles
        expect(releasedHandles == [firstHandle], "stopping twice releases exactly once")
        expect(session.isActive == false, "stopped session is inactive")
        expectThrows(
            CaptureSelectionError.physicalDisplayCaptureRejected,
            { _ = try CaptureSelectionGuard.validate(requestedDisplayID: 1, ownedHandle: firstHandle) },
            "capture rejects a display that is not session-owned"
        )
        expect(
            try! CaptureSelectionGuard.validate(requestedDisplayID: firstHandle.rawValue, ownedHandle: firstHandle) == firstHandle,
            "capture accepts the session-owned display"
        )
        let workspacePlacement = try! CanvasWorkspacePlacement.resolve(
            ownedHandle: firstHandle,
            display: CanvasWorkspaceDisplay(
                id: firstHandle.rawValue,
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                isBuiltin: false,
                isOnline: true
            ),
            physicalDisplayIDs: []
        )
        expect(
            workspacePlacement.displayID == firstHandle.rawValue,
            "the workspace is placed only on the current owned virtual canvas"
        )
        expectThrows(
            CanvasWorkspacePlacementError.physicalDisplayRejected,
            {
                _ = try CanvasWorkspacePlacement.resolve(
                    ownedHandle: firstHandle,
                    display: CanvasWorkspaceDisplay(
                        id: firstHandle.rawValue,
                        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                        isBuiltin: false,
                        isOnline: true
                    ),
                    physicalDisplayIDs: [firstHandle.rawValue]
                )
            },
            "the product workspace refuses an external physical display even if its identifier is presented as owned"
        )
        expectThrows(
            CanvasWorkspacePlacementError.physicalDisplayRejected,
            {
                _ = try CanvasWorkspacePlacement.resolve(
                    ownedHandle: firstHandle,
                    display: CanvasWorkspaceDisplay(
                        id: firstHandle.rawValue,
                        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                        isBuiltin: true,
                        isOnline: true
                    ),
                    physicalDisplayIDs: []
                )
            },
            "a real pre-existing built-in display with genuine non-zero bounds is still rejected as a physical display"
        )
        expectThrows(
            CanvasWorkspacePlacementError.unregisteredCanvas,
            {
                _ = try CanvasWorkspacePlacement.resolve(
                    ownedHandle: firstHandle,
                    display: CanvasWorkspaceDisplay(
                        id: firstHandle.rawValue,
                        bounds: .zero,
                        isBuiltin: true,
                        isOnline: true
                    ),
                    physicalDisplayIDs: []
                )
            },
            "a display whose bounds are (0,0,0,0) is an unregistered canvas, not a misreported physical display"
        )
        // `resolve` runs once, at install time. The window it placed is pinned
        // there (`isMovable = false`), but a display reconfiguration can still
        // relocate it, and a window standing on a physical monitor must not be
        // fronted and typed into.
        expect(
            CanvasWorkspacePlacement.isOnOwnedCanvas(
                canvasDisplayID: firstHandle.rawValue,
                windowScreenDisplayID: firstHandle.rawValue
            ),
            "a window still standing on its own canvas may be fronted"
        )
        expect(
            CanvasWorkspacePlacement.isOnOwnedCanvas(
                canvasDisplayID: firstHandle.rawValue,
                windowScreenDisplayID: firstHandle.rawValue &+ 1
            ) == false,
            "a window that has ended up on another display may not"
        )
        expect(
            CanvasWorkspacePlacement.isOnOwnedCanvas(
                canvasDisplayID: firstHandle.rawValue,
                windowScreenDisplayID: nil
            ),
            "a window AppKit names no screen for is a display mid-reconfiguration, not evidence of a physical one"
        )

        // The readiness poller is the seam that lets `NativeCanvasWorkspace`
        // wait for a freshly created virtual display to actually register with
        // AppKit, instead of assuming it is present the instant it is created.
        do {
            var probeCalls = 0
            var pumpCalls = 0
            let result = CanvasDisplayReadiness.awaitReady(
                expectedWidth: 1920,
                expectedHeight: 1200,
                maxAttempts: 5,
                probe: {
                    probeCalls += 1
                    return CanvasDisplayReadinessSample(
                        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                        isRegisteredInScreens: true
                    )
                },
                pump: { pumpCalls += 1 }
            )
            expect(result.sample.isRegisteredInScreens, "a display that is ready on the first probe reports ready")
            expect(probeCalls == 1, "a display ready on the first probe is polled exactly once")
            expect(pumpCalls == 0, "a display ready on the first probe never pumps the run loop")
            expect(result.attempts == 1, "a display ready on the first probe reports exactly one attempt")
            expect(result.isReady, "a display ready on the first probe reports isReady true")
        }

        do {
            var probeCalls = 0
            var pumpCalls = 0
            let result = CanvasDisplayReadiness.awaitReady(
                expectedWidth: 1920,
                expectedHeight: 1200,
                maxAttempts: 5,
                probe: {
                    probeCalls += 1
                    return CanvasDisplayReadinessSample(
                        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                        isRegisteredInScreens: probeCalls >= 3
                    )
                },
                pump: { pumpCalls += 1 }
            )
            expect(result.sample.isRegisteredInScreens, "a display that registers on its third probe is eventually reported ready")
            expect(probeCalls == 3, "polling stops as soon as the display becomes ready")
            expect(pumpCalls == 2, "the run loop is pumped only between unready probes")
            expect(result.attempts == 3, "the reported attempt count matches the probe that actually became ready")
        }

        do {
            var probeCalls = 0
            var pumpCalls = 0
            let maxAttempts = 4
            let result = CanvasDisplayReadiness.awaitReady(
                expectedWidth: 1920,
                expectedHeight: 1200,
                maxAttempts: maxAttempts,
                probe: {
                    probeCalls += 1
                    return CanvasDisplayReadinessSample(bounds: .zero, isRegisteredInScreens: false)
                },
                pump: { pumpCalls += 1 }
            )
            expect(!result.sample.isRegisteredInScreens, "a display that never registers times out still unready")
            expect(probeCalls == 4, "polling stops at the bounded attempt limit rather than continuing forever")
            expect(pumpCalls == 3, "the run loop is pumped only between attempts, never after the final one")
            expect(result.attempts == maxAttempts, "a probe that never becomes ready reports exactly maxAttempts")
            expect(!result.isReady, "a probe that never becomes ready reports isReady false")
        }

        do {
            var probeCalls = 0
            let result = CanvasDisplayReadiness.awaitReady(
                expectedWidth: 1920,
                expectedHeight: 1200,
                maxAttempts: 4,
                probe: {
                    probeCalls += 1
                    return CanvasDisplayReadinessSample(
                        bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                        isRegisteredInScreens: true
                    )
                },
                pump: {}
            )
            expect(!result.sample.isRegisteredInScreens == false, "a wrong-size display is registered in screens but still not ready")
            expect(
                Int(result.sample.bounds.width) != 1920 || Int(result.sample.bounds.height) != 1200,
                "a display registered at the wrong size never reports as ready"
            )
            expect(probeCalls == 4, "a wrong-size display is polled until the attempt limit, not accepted early")
            expect(result.attempts == 4, "a wrong-size display that never becomes ready reports exactly maxAttempts")
            expect(!result.isReady, "a wrong-size display that never becomes ready reports isReady false")
        }

        do {
            // Distinguishes `isReady` from "attempts hit the ceiling": here the
            // display becomes ready on precisely the last allowed attempt, so an
            // implementation that infers readiness from `attempts == maxAttempts`
            // would agree by coincidence on the previous case but disagree here.
            var probeCalls = 0
            let maxAttempts = 4
            let result = CanvasDisplayReadiness.awaitReady(
                expectedWidth: 1920,
                expectedHeight: 1200,
                maxAttempts: maxAttempts,
                probe: {
                    probeCalls += 1
                    return CanvasDisplayReadinessSample(
                        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                        isRegisteredInScreens: probeCalls >= maxAttempts
                    )
                },
                pump: {}
            )
            expect(probeCalls == maxAttempts, "a display that registers on the final allowed attempt is polled exactly maxAttempts times")
            expect(result.attempts == maxAttempts, "a display ready on the final allowed attempt reports attempts == maxAttempts")
            expect(result.isReady, "a display ready on the final allowed attempt still reports isReady true")
        }

        // `CanvasCreationGate` is the seam that makes `NativeCanvasWorkspace`
        // single-flight: the readiness wait above pumps the real run loop,
        // which lets a second, unrelated canvas-creation request begin
        // executing on the main actor before the first has finished. These
        // tests drive that interleaving directly, by having the first call's
        // own work reenter the gate, rather than calling it twice in sequence.
        do {
            let gate = CanvasCreationGate()
            var reentrantRan = false
            var reentrantError: Error?
            let outerResult = try! gate.run { () -> Int in
                do {
                    try gate.run { reentrantRan = true }
                } catch {
                    reentrantError = error
                }
                return 1
            }
            expect(outerResult == 1, "the in-flight canvas creation still completes")
            expect(!reentrantRan, "a canvas creation that arrives while another is in flight never runs its work")
            expect(
                (reentrantError as? CanvasCreationGateError) == .creationInProgress,
                "a canvas creation that arrives while another is in flight is rejected with a specific reason"
            )
            var laterRan = false
            try! gate.run { laterRan = true }
            expect(laterRan, "once the in-flight creation finishes, a later request is admitted normally")
        }

        do {
            // Mirrors the actual production shape: the gate wraps the
            // readiness wait, and the readiness wait's `pump` closure is
            // exactly where a second connection's canvas request can be
            // dispatched while the first is still waiting for its display to
            // register.
            let gate = CanvasCreationGate()
            var pumpCalls = 0
            var reentrantError: Error?
            let result = try! gate.run { () -> CanvasDisplayReadinessResult in
                CanvasDisplayReadiness.awaitReady(
                    expectedWidth: 1920,
                    expectedHeight: 1200,
                    maxAttempts: 3,
                    probe: {
                        CanvasDisplayReadinessSample(
                            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                            isRegisteredInScreens: pumpCalls >= 1
                        )
                    },
                    pump: {
                        pumpCalls += 1
                        do {
                            try gate.run {}
                        } catch {
                            reentrantError = error
                        }
                    }
                )
            }
            expect(result.sample.isRegisteredInScreens, "the in-flight creation still completes readiness once its own probe succeeds")
            expect(
                (reentrantError as? CanvasCreationGateError) == .creationInProgress,
                "a second canvas request that arrives mid-readiness-wait is rejected, not silently queued or dropped"
            )
        }

        // Regression: the single-flight gate above only ever guarded
        // workspace *placement*. `VirtualDisplaySession.start(owner:)` runs
        // earlier in the chain, unconditionally transferring ownership — so a
        // second connection's `.canvasRequest`, dispatched during the first
        // connection's readiness-wait pump, could still take over the live
        // canvas before that gate ever saw it. That second connection then
        // tears down and releases the canvas the first connection is still
        // creating. This drives the real interleaving through
        // `HostSessionController.handle(.canvasRequest)` and
        // `HostSessionCoordinator.handle`, the same entry points production
        // code uses, sharing one `CanvasCreationGate` the way `sensoriumd`
        // wires `VirtualDisplaySession` and `NativeCanvasWorkspace` together.
        do {
            let interleavedAdapter = FakeVirtualDisplayAdapter()
            let sharedGate = CanvasCreationGate()
            let interleavedSession = VirtualDisplaySession(adapter: interleavedAdapter, creationGate: sharedGate)
            let interleavedWorkspace = InterleavingCanvasWorkspace(gate: sharedGate)
            let interleavedFactory = HostConnectionSessionFactory(
                sessions: surfaceZeroOnly(interleavedSession),
                inputInjectorFactory: FakeInputInjectorFactory(),
                keyConfinement: .unconfined
            )
            let controllerA = interleavedFactory.makeController()
            let coordinatorA = HostSessionCoordinator(
                controller: controllerA,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(interleavedWorkspace))

            var bCanvasRequestError: Error?
            interleavedWorkspace.pump = {
                // B's own canvasRequest, dispatched while A's canvas
                // creation is still inside the gate below — exactly the
                // interleaving `NativeCanvasWorkspace`'s readiness wait
                // creates in production.
                let controllerB = interleavedFactory.makeController()
                do {
                    _ = try controllerB.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
                } catch {
                    bCanvasRequestError = error
                }
                // B's connection tears down immediately, exactly as
                // `HostSessionCoordinator.sessionDidEnd` does for a
                // transport that closed without a goodbye.
                _ = try? controllerB.handle(.goodbye(reason: "transport-closed"))
            }

            _ = try! await coordinatorA.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))

            expect(
                (bCanvasRequestError as? CanvasCreationGateError) == .creationInProgress,
                "a second connection's canvasRequest cannot take ownership while the first canvas creation is still in flight"
            )
            expect(interleavedSession.isActive, "A's in-flight canvas survives B's rejected request and teardown")
            expect(interleavedAdapter.releasedHandles.isEmpty, "B's teardown must not release the canvas A is still creating")
            expect(interleavedWorkspace.startedDisplayIDs.count == 1, "A's own workspace placement still completes")

            await coordinatorA.sessionDidEnd(reason: "test-teardown")
            expect(!interleavedSession.isActive, "A can still release the canvas it actually created, once its own creation finished")
            expect(interleavedAdapter.releasedHandles.count == 1, "exactly one release, by the connection that actually owns the canvas")
        }

        // `stop` and `stop(owner:)` must respect `creationGate` just as
        // `start` does: a release landing while this same shared gate holds
        // a creation in flight (as it does for the whole span of
        // `NativeCanvasWorkspace.start`'s readiness-wait pump) would
        // otherwise corrupt the display-ID allocator, from the release side
        // instead of the creation side. Two sessions share one gate here,
        // mirroring how `VirtualDisplaySession` and `NativeCanvasWorkspace`
        // share the same `CanvasCreationGate` instance in production:
        // `adapterB.acquire` reentrantly releases A's canvas on the same
        // thread, exactly where a run-loop pump would dispatch a queued
        // teardown mid-placement.
        do {
            let sharedGate = CanvasCreationGate()
            let adapterA = FakeVirtualDisplayAdapter()
            let sessionA = VirtualDisplaySession(adapter: adapterA, creationGate: sharedGate)
            let ownerA = CanvasOwnerToken()
            let handleA = try! sessionA.start(owner: ownerA, configuration: .remoteDefault)

            let adapterB = FakeVirtualDisplayAdapter()
            let sessionB = VirtualDisplaySession(adapter: adapterB, creationGate: sharedGate)
            let ownerB = CanvasOwnerToken()

            var releasedDuringAcquire: [VirtualDisplayHandle] = []
            adapterB.onAcquire = {
                sessionA.stop(owner: ownerA)
                releasedDuringAcquire = adapterA.releasedHandles
            }

            _ = try! sessionB.start(owner: ownerB, configuration: .remoteDefault)

            expect(
                releasedDuringAcquire.isEmpty,
                "a release requested while another creation is in flight on the shared gate does not call adapter.release concurrently with that in-flight acquire"
            )
            expect(
                adapterA.releasedHandles == [handleA],
                "the deferred release still runs once the in-flight creation finishes, so the canvas is not leaked"
            )
            expect(!sessionA.isActive, "handle/owner end up consistent with the release that actually happened")

            // Existing behaviour, unchanged by the gating above.
            let strayOwner = CanvasOwnerToken()
            sessionB.stop(owner: strayOwner)
            expect(sessionB.isActive, "stop(owner:) with a non-owning token still does nothing")
        }

        // `AnimatedMeasurementWorkspace` is test-only and never shipped in
        // the default `serve` path, but it still places a session canvas,
        // and until now did so without sharing `CanvasCreationGate` -- a
        // still-reachable path to the same display-ID allocator corruption
        // `NativeCanvasWorkspace` and `VirtualDisplaySession` already guard
        // against. This proves the wiring the same way the bare-gate
        // reentrancy test above does: a canvas request that arrives while
        // the gate is already busy is rejected before it ever reaches
        // `stop()`/AppKit, so this is safe to run headlessly.
        do {
            let gate = CanvasCreationGate()
            let workspace = AnimatedMeasurementWorkspace(physicalDisplayIDs: [], creationGate: gate)
            var reentrantError: Error?
            let outerResult = try! gate.run { () -> Int in
                do {
                    try workspace.start(canvasDisplayID: 999, owner: CanvasOwnerToken())
                } catch {
                    reentrantError = error
                }
                return 1
            }
            expect(outerResult == 1, "the in-flight creation still completes")
            expect(
                (reentrantError as? CanvasCreationGateError) == .creationInProgress,
                "AnimatedMeasurementWorkspace now shares the single-flight gate: a canvas request that arrives while another creation is in flight is rejected, exactly like NativeCanvasWorkspace, instead of racing real AppKit/display state"
            )
        }

        expect(VideoEncoderConfiguration.remoteDefault.width == 1920, "encoder defaults to 1920 width")
        expect(VideoEncoderConfiguration.remoteDefault.height == 1200, "encoder defaults to 1200 height")
        expect(VideoEncoderConfiguration.remoteDefault.framesPerSecond == 60, "encoder defaults to 60 fps")
        expect(VideoEncoderConfiguration.remoteDefault.codec == .h264, "encoder defaults to H.264 compatibility mode")
        expect(
            VideoEncoderConfiguration.remoteDefault.maxQueueDepth == 3,
            "capture holds three frames: one in flight, one waiting, and one a still-screen refresh may be "
                + "holding, so a refresh never starves the frame after it, "
                + "got \(VideoEncoderConfiguration.remoteDefault.maxQueueDepth)"
        )
        // Capturing at 3840x2400 while encoding at 1920x1200 forced
        // VideoToolbox to downscale a 4x-larger buffer on every frame, which
        // measurably slowed the encode stage (p50 8.5ms -> 6.8ms once capture
        // matched encode resolution) and reduced sustained throughput under
        // continuously changing content (578 -> 588 frames per 10s). The
        // viewer surface is 1920x1200 backing pixels, so capturing more
        // never bought additional visible detail.
        expect(VideoEncoderConfiguration.remoteDefault.captureWidth == 1920, "capture resolution matches encode resolution: capturing 4x the pixels only cost throughput and encode latency")
        expect(VideoEncoderConfiguration.remoteDefault.captureHeight == 1200, "capture resolution matches encode resolution: capturing 4x the pixels only cost throughput and encode latency")
        expect(VideoEncoderConfiguration.remoteDefault.encodeWidth == 1920, "encode resolution remains an explicit field, independent of capture resolution")
        expect(VideoEncoderConfiguration.remoteDefault.encodeHeight == 1200, "encode resolution remains an explicit field, independent of capture resolution")
        expect(VideoEncoderConfiguration.remoteDefault.averageBitRate == 12_000_000, "encoder sets an explicit average bitrate instead of running unconstrained")
        expect(VideoEncoderConfiguration.remoteDefault.dataRateLimitBytes == 15_000_000, "encoder caps burst output with an explicit data-rate limit")
        expect(VideoEncoderConfiguration.remoteDefault.dataRateLimitSeconds == 1.0, "encoder's data-rate limit window is explicit")
        expect(VideoEncoderConfiguration.remoteDefault.maxFrameDelayCount == 0, "encoder disables frame buffering for interactive latency")
        expect(VideoEncoderConfiguration.remoteDefault.profileLevel == .mainAutoLevel, "encoder selects an explicit profile/level")
        expect(VideoEncoderConfiguration.remoteDefault.requiresHardwareAcceleration == true, "encoder requires hardware acceleration instead of silently falling back to software")
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        let ready = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            ready == .canvasReady(
                displayID: firstHandle.rawValue,
                logicalWidth: 1920,
                logicalHeight: 1200,
                hostSignature: nil,
                surfaceID: nil,
                hostName: Host.current().localizedName
            ),
            "canvas request returns the owned canvas, naming this machine"
        )
        _ = try! controller.handle(.goodbye(reason: "client-disconnected"))
        expect(session.isActive == false, "goodbye releases the session canvas")

        // surfaceID routes: a request naming surface 1 gets surface 1's own
        // canvas, and the reply echoes the surfaceID it answers. The cap is
        // two canvases, keyed 0 and 1 -- 0, 1, and absent are the only values
        // a request can carry.
        let suppliedSurfaceAdapter = FakeVirtualDisplayAdapter()
        suppliedSurfaceAdapter.handleValuesToVend = [7, 8]
        let suppliedSurfaceController = HostSessionController(
            sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: suppliedSurfaceAdapter) },
            keyConfinement: .unconfined
        )
        let suppliedSurfaceReady = try! suppliedSurfaceController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1))
        expect(
            suppliedSurfaceReady == .canvasReady(
                displayID: 7,
                logicalWidth: 1920,
                logicalHeight: 1200,
                hostSignature: nil,
                surfaceID: 1,
                hostName: Host.current().localizedName
            ),
            "a canvasRequest's in-range surfaceID echoes back identical in canvasReady"
        )

        let omittedSurfaceAdapter = FakeVirtualDisplayAdapter()
        let omittedSurfaceSession = VirtualDisplaySession(adapter: omittedSurfaceAdapter)
        let omittedSurfaceController = HostSessionController(sessions: surfaceZeroOnly(omittedSurfaceSession), keyConfinement: .unconfined)
        let omittedSurfaceReady = try! omittedSurfaceController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            omittedSurfaceReady == .canvasReady(
                displayID: 7,
                logicalWidth: 1920,
                logicalHeight: 1200,
                hostSignature: nil,
                surfaceID: nil,
                hostName: Host.current().localizedName
            ),
            "a canvasRequest that omits surfaceID gets back a canvasReady that omits it too, not an invented value"
        )

        // A surfaceID outside the two-canvas cap must be refused, not echoed:
        // once the host keys real per-surface state by this value, echoing
        // whatever a client sends would let a buggy or hostile paired client
        // grow that state without bound.
        for outOfRange: UInt32 in [2, 3, 999] {
            let rejectedAdapter = FakeVirtualDisplayAdapter()
            let rejectedSession = VirtualDisplaySession(adapter: rejectedAdapter)
            let rejectedController = HostSessionController(sessions: surfaceZeroOnly(rejectedSession), keyConfinement: .unconfined)
            expectThrows(
                HostSessionControllerError.invalidCanvasRequest,
                { _ = try rejectedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: outOfRange)) },
                "a canvasRequest's surfaceID \(outOfRange) is rejected: the cap is exactly two canvases"
            )
            expect(!rejectedSession.isActive, "a canvasRequest rejected for its surfaceID never claims the canvas")
        }

        let surfaceValidationAdapter = FakeVirtualDisplayAdapter()
        let surfaceValidationSession = VirtualDisplaySession(adapter: surfaceValidationAdapter)
        let surfaceValidationInjector = FakeInputInjector()
        let surfaceValidationController = HostSessionController(
            sessions: surfaceZeroOnly(surfaceValidationSession),
            inputInjector: surfaceValidationInjector,
            keyConfinement: .unconfined
        )
        _ = try! surfaceValidationController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        // An absent surfaceID and an explicit 0 name the same canvas.
        for validSurfaceID: UInt32? in [nil, 0] {
            _ = try! surfaceValidationController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: validSurfaceID))
            _ = try! surfaceValidationController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: validSurfaceID, maximumScale: nil))
        }
        // Surface 1 is in range but has no canvas on this connection. Input
        // for it has nowhere to go, and must say so rather than land on
        // surface 0's canvas.
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            { _ = try surfaceValidationController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: 1)) },
            "input for a surface this connection never created is refused, never redirected to the other canvas"
        )
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            { _ = try surfaceValidationController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: 1, maximumScale: nil)) },
            "a viewer drawable size for a surface that has no canvas is refused, never applied to the other canvas"
        )
        for invalidSurfaceID: UInt32 in [2, 42] {
            expectThrows(
                HostSessionControllerError.invalidInput,
                { _ = try surfaceValidationController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: invalidSurfaceID)) },
                "an input event's surfaceID \(invalidSurfaceID) is rejected: the cap is exactly two canvases"
            )
            expectThrows(
                HostSessionControllerError.invalidViewerDrawableSize,
                { _ = try surfaceValidationController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: invalidSurfaceID, maximumScale: nil)) },
                "a viewerDrawableSize's surfaceID \(invalidSurfaceID) is rejected: the cap is exactly two canvases"
            )
        }

        let authenticatedAdapter = FakeVirtualDisplayAdapter()
        let authenticatedSession = VirtualDisplaySession(adapter: authenticatedAdapter)
        let inputInjector = FakeInputInjector()
        let identity = try! DeviceIdentity.generate()
        let authenticatedController = HostSessionController(
            sessions: surfaceZeroOnly(authenticatedSession),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjector: inputInjector,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try authenticatedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)) },
            "authenticated host rejects canvas requests before hello"
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try authenticatedController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil)) },
            "authenticated host rejects input before hello"
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: identity.publicKey
        )
        _ = try! authenticatedController.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: identity.publicKey,
            signature: try! identity.sign(transcript)
        ))
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            { _ = try authenticatedController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil)) },
            "host rejects input before the session canvas is ready"
        )
        let authenticatedReady = try! authenticatedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            authenticatedReady == .canvasReady(
                displayID: 7,
                logicalWidth: 1920,
                logicalHeight: 1200,
                hostSignature: nil,
                surfaceID: nil,
                hostName: Host.current().localizedName
            ),
            "valid signed hello unlocks canvas creation"
        )
        expectThrows(
            HostSessionControllerError.invalidInput,
            { _ = try authenticatedController.handle(.input(.pointerMoved(x: 1921, y: 20), surfaceID: nil)) },
            "host rejects input outside the owned canvas"
        )
        _ = try! authenticatedController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil))
        expect(inputInjector.events == [.pointerMoved(x: 10, y: 20)], "host injects input only into an authenticated active session")

        let factoryAdapter = FakeVirtualDisplayAdapter()
        let factorySession = VirtualDisplaySession(adapter: factoryAdapter)
        let factory = FakeInputInjectorFactory()
        let factoryController = HostSessionController(
            sessions: surfaceZeroOnly(factorySession),
            inputInjectorFactory: factory,
            keyConfinement: .unconfined
        )
        _ = try! factoryController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            factory.requestedDisplayIDs == [7],
            "the input injector is created only after the owned canvas exists and receives its display ID"
        )
        _ = try! factoryController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil))
        expect(
            factory.injector.events == [.pointerMoved(x: 10, y: 20)],
            "input reaches only the injector constructed for the owned canvas"
        )
        _ = try! factoryController.handle(.goodbye(reason: "client-disconnected"))

        // An unrecognized message type -- what an old build sees from a
        // newer peer's future message kind -- must be a silent no-op, not a
        // fatal error, and must not disturb a session already in progress.
        let unrecognizedAdapter = FakeVirtualDisplayAdapter()
        let unrecognizedSession = VirtualDisplaySession(adapter: unrecognizedAdapter)
        let unrecognizedInjector = FakeInputInjector()
        let unrecognizedController = HostSessionController(
            sessions: surfaceZeroOnly(unrecognizedSession),
            inputInjector: unrecognizedInjector,
            keyConfinement: .unconfined
        )
        _ = try! unrecognizedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let unrecognizedResponse = try! unrecognizedController.handle(.unrecognized(type: "futureFocusSignal"))
        expect(unrecognizedResponse == nil, "an unrecognized message type gets no response")
        expect(unrecognizedSession.isActive, "an unrecognized message type does not end the session")
        _ = try! unrecognizedController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil))
        expect(
            unrecognizedInjector.events == [.pointerMoved(x: 10, y: 20)],
            "a normal message handled after an unrecognized one still gets its normal effect"
        )

        let permissionChecker = FakeAccessibilityPermissionChecker()
        let permissionGate = AccessibilityPermissionGate(checker: permissionChecker)
        expect(
            permissionGate.currentStatus == .approvalRequired,
            "an untrusted host reports Accessibility approval is required"
        )
        expect(
            permissionChecker.promptRequests == [false],
            "checking Accessibility status never requests a system prompt"
        )
        permissionChecker.isTrusted = true
        expect(
            permissionGate.requestApproval() == .granted,
            "an explicit approval request reports granted when macOS trusts the host"
        )
        expect(
            permissionChecker.promptRequests == [false, true],
            "only the explicit approval request asks macOS to display its prompt"
        )

        let screenCaptureChecker = FakeScreenCapturePermissionChecker()
        let screenCaptureGate = ScreenCapturePermissionGate(checker: screenCaptureChecker)
        expect(
            screenCaptureGate.currentStatus == .approvalRequired,
            "an unapproved host reports Screen Recording approval is required"
        )
        expect(
            screenCaptureChecker.promptRequests == [false],
            "checking Screen Recording status never requests a system prompt"
        )
        screenCaptureChecker.isAuthorized = true
        expect(
            screenCaptureGate.requestApproval() == .granted,
            "an explicit Screen Recording request reports granted when macOS authorizes the host"
        )
        expect(
            screenCaptureChecker.promptRequests == [false, true],
            "only the explicit Screen Recording request asks macOS to display its prompt"
        )

        let requestScreenCaptureChecker = FakeScreenCapturePermissionChecker()
        requestScreenCaptureChecker.isAuthorized = true
        let requestAccessibilityChecker = FakeAccessibilityPermissionChecker()
        requestAccessibilityChecker.isTrusted = true
        let permissionRequest = HostPermissionRequester.request(
            screenCapture: ScreenCapturePermissionGate(checker: requestScreenCaptureChecker),
            accessibility: AccessibilityPermissionGate(checker: requestAccessibilityChecker)
        )
        expect(
            permissionRequest.isReadyForViewerControl,
            "an explicit host permission request is ready only when both user-controlled capabilities are granted"
        )
        expect(
            requestScreenCaptureChecker.promptRequests == [true]
                && requestAccessibilityChecker.promptRequests == [true],
            "the explicit host permission request asks for exactly Screen Recording and Accessibility"
        )

        var permissionTransitions: [HostPermissionTransition] = []
        let monitorScreenCaptureChecker = FakeScreenCapturePermissionChecker()
        monitorScreenCaptureChecker.isAuthorized = true
        let monitorAccessibilityChecker = FakeAccessibilityPermissionChecker()
        monitorAccessibilityChecker.isTrusted = true
        let permissionMonitor = HostPermissionMonitor(
            screenCapture: ScreenCapturePermissionGate(checker: monitorScreenCaptureChecker),
            accessibility: AccessibilityPermissionGate(checker: monitorAccessibilityChecker),
            onTransition: { permissionTransitions.append($0) }
        )
        permissionMonitor.poll()
        expect(
            permissionTransitions.isEmpty,
            "a monitor whose granted permissions have not changed since construction reports nothing"
        )

        monitorScreenCaptureChecker.isAuthorized = false
        permissionMonitor.poll()
        expect(
            permissionTransitions == [.lost(.screenRecording)],
            "Screen Recording being revoked while the host is running is detected and reported"
        )
        permissionMonitor.poll()
        permissionMonitor.poll()
        expect(
            permissionTransitions == [.lost(.screenRecording)],
            "an unchanged lost status is reported exactly once, not on every subsequent poll"
        )

        monitorScreenCaptureChecker.isAuthorized = true
        permissionMonitor.poll()
        expect(
            permissionTransitions == [.lost(.screenRecording), .recovered(.screenRecording)],
            "Screen Recording being re-approved while the host is running is reported as recovered exactly once"
        )

        monitorAccessibilityChecker.isTrusted = false
        permissionMonitor.poll()
        expect(
            permissionTransitions == [
                .lost(.screenRecording),
                .recovered(.screenRecording),
                .lost(.accessibility)
            ],
            "Accessibility is polled and reported independently of Screen Recording"
        )
        monitorAccessibilityChecker.isTrusted = true
        permissionMonitor.poll()
        expect(
            permissionTransitions.last == .recovered(.accessibility),
            "Accessibility recovering after Screen Recording already recovered is still reported"
        )
        expect(
            HostPermissionTransition.lost(.accessibility).logLine.contains("Accessibility")
                && HostPermissionTransition.lost(.accessibility).logLine.contains("System Settings"),
            "a lost-permission log line names exactly which permission and what the user must do"
        )
        expect(
            HostPermissionTransition.lost(.screenRecording).logLine.contains("Screen Recording")
                && !HostPermissionTransition.lost(.screenRecording).logLine.contains("Accessibility"),
            "a lost-permission log line never names a permission other than the one that changed"
        )

        let terminalReportLines = HostPermissionReport.lines(
            result: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted),
            launchContext: .terminalAttached
        )
        expect(
            terminalReportLines.contains { $0.contains("attached to a terminal") },
            "request-permissions warns explicitly when it detects it is running as a child of a terminal"
        )
        expect(
            terminalReportLines.contains { $0.contains("the terminal\u{2019}s own approval") },
            "the terminal-launch warning uses a curly apostrophe, not a straight one, like the rest of the app's copy"
        )
        let launchServicesReportLines = HostPermissionReport.lines(
            result: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted),
            launchContext: .notTerminalAttached
        )
        expect(
            !launchServicesReportLines.contains(where: { $0.contains("WARNING") }),
            "request-permissions does not raise the terminal-launch warning when none was detected"
        )
        expect(
            terminalReportLines.contains { $0.contains("Remote Desktop") }
                && launchServicesReportLines.contains { $0.contains("Remote Desktop") },
            "request-permissions always states that Remote Desktop cannot be checked programmatically"
        )
        expect(
            terminalReportLines.contains { $0.contains("Screen Recording: granted") }
                && terminalReportLines.contains { $0.contains("Accessibility: granted") },
            "request-permissions still reports the honest per-permission status alongside the caveats"
        )
        // Both bundles ship in the same kit. `Sensorium.app` is the viewer,
        // and an operator told to open it on the Mini opens the wrong one.
        expect(
            terminalReportLines.contains { $0.contains("Sensorium Host.app") }
                && !terminalReportLines.contains { $0.contains("Sensorium.app") },
            "the report names the host bundle the operator has to launch, never the viewer's"
        )
        // `CFBundleName` is "Sensorium Host", so that is the row in System
        // Settings. Being told to look for "sensoriumd" is being sent to a
        // row that is not there.
        expect(
            [HostPermissionTransition.lost(.accessibility), .lost(.screenRecording)].allSatisfy {
                $0.logLine.contains("Sensorium Host")
            },
            "a lost-permission line names the row as System Settings writes it"
        )

        // The terminal on the Mini is the record of what happened while nobody
        // was watching it, so every line in it is written for a reader, never
        // a Swift case name like `physicalDisplayRejected`,
        // `unexpectedCanvasDimensions`, or `authenticationRequired`.
        let placementErrors: [CanvasWorkspacePlacementError] = [
            .unownedCanvas, .unregisteredCanvas, .physicalDisplayRejected,
            .offlineCanvas, .unexpectedCanvasDimensions
        ]
        let controllerErrors: [HostSessionControllerError] = [
            .invalidCanvasRequest, .unexpectedMessage, .invalidAuthentication, .authenticationRequired,
            .inputSessionUnavailable, .inputInjectionUnavailable, .invalidInput, .deviceNotPaired,
            .invalidViewerDrawableSize, .invalidViewerFocus, .pairingConnectionFailuresExceeded
        ]
        let operatorLines = placementErrors.map(\.operatorLogLine)
            + controllerErrors.map(\.operatorLogLine)
            + [
                HostOperatorLog.describe(CanvasCreationGateError.creationInProgress),
                HostOperatorLog.sourceRefused(address: "192.168.1.40")
            ]
        let hostCaseNames = [
            "unownedCanvas", "unregisteredCanvas", "physicalDisplayRejected", "offlineCanvas",
            "unexpectedCanvasDimensions", "invalidCanvasRequest", "unexpectedMessage",
            "invalidAuthentication", "authenticationRequired", "inputSessionUnavailable",
            "inputInjectionUnavailable", "invalidInput", "deviceNotPaired",
            "invalidViewerDrawableSize", "invalidViewerFocus", "pairingConnectionFailuresExceeded",
            "creationInProgress", "Error", "Optional("
        ]
        expect(
            operatorLines.allSatisfy { line in hostCaseNames.allSatisfy { !line.contains($0) } },
            "no line the operator reads is a Swift case name or an interpolated error value"
        )
        expect(
            operatorLines.allSatisfy { !$0.contains("'") && $0.hasSuffix(".") && $0.contains(" ") },
            "every operator line is a sentence, with typographic apostrophes"
        )
        expect(
            Set(placementErrors.map(\.operatorLogLine)).count == placementErrors.count
                && Set(controllerErrors.map(\.operatorLogLine)).count == controllerErrors.count,
            "each refusal gets its own words; two identical ones would mean guessing at a cause"
        )
        expect(
            HostSessionControllerError.authenticationRequired.operatorLogLine.contains("pair"),
            "a request from an unauthenticated client says what pairing state would let it in — a never-paired machine refused every client without ever saying so"
        )
        expect(
            CanvasWorkspacePlacementError.physicalDisplayRejected.operatorLogLine.contains("own display"),
            "a rejected physical display says the one thing that matters: this machine's own display is never shown"
        )
        expect(
            HostOperatorLog.sourceRefused(address: "192.168.1.40").contains("192.168.1.40"),
            "a connection refused by address names the address, so a wrong-network client is not mistaken for a dead network"
        )
        expect(
            HostOperatorLog.describe(CanvasWorkspacePlacementError.offlineCanvas)
                == CanvasWorkspacePlacementError.offlineCanvas.operatorLogLine,
            "the one entry point every failing stage logs through knows the errors this host actually throws"
        )

        var peerLog = HostPeerActivityLog()
        expect(
            peerLog.line(for: .closed(reason: nil)) == nil,
            "a connection that never identified itself ends no session, and inventing one in the log would be a lie"
        )
        let connectedLine = peerLog.line(for: .identified(deviceName: "Kestrel’s Laptop"))
        let endedLine = peerLog.line(for: .closed(reason: nil))
        expect(
            connectedLine?.contains("Kestrel’s Laptop") == true && endedLine?.contains("Kestrel’s Laptop") == true,
            "the terminal records who connected and who left, by the name that arrived on the wire"
        )
        // A connection is not yet a target: the same hello precedes a session
        // canvas and a host screen alike, and the log lines that follow name
        // which one it became. Promising one of them here writes a false
        // record of every host-screen session there has ever been.
        expect(
            connectedLine == "Kestrel’s Laptop is connected.",
            "the connect line claims nothing about what the connected machine can see -- got \(connectedLine ?? "nothing")"
        )
        expect(
            peerLog.line(for: .closed(reason: nil)) == nil,
            "a session ends once; a second teardown of the same connection says nothing"
        )

        var droppedPeerLog = HostPeerActivityLog()
        _ = droppedPeerLog.line(for: .identified(deviceName: "Kestrel\u{2019}s Laptop"))
        let droppedLine = droppedPeerLog.line(for: .closed(reason: "macOS reported: The network connection was lost"))
        expect(
            droppedLine == "Kestrel\u{2019}s Laptop is no longer connected (macOS reported: The network connection was lost). "
                + "Nothing on this machine is being shared now.",
            "a connection that ended for a reason this host learned says the reason where it says the ending, so a drop mid-session is not a mystery in the log -- got \(droppedLine ?? "nothing")"
        )
        expect(
            HostOperatorLog.closeReason(for: HostNetworkSessionError.closed) == nil,
            "and an ending this host learned nothing about carries no reason at all, rather than a shrug dressed up as one"
        )

        expectThrows(
            HostSessionControllerError.invalidInput,
            { _ = try authenticatedController.handle(.input(.pointerButton(button: .left, isDown: true, x: -1, y: 20), surfaceID: nil)) },
            "host rejects a button press outside the owned canvas"
        )
        expectThrows(
            HostSessionControllerError.invalidInput,
            { _ = try authenticatedController.handle(.input(.scrolled(deltaX: 0, deltaY: 100_000, x: 10, y: 10, phase: nil, momentumPhase: nil), surfaceID: nil)) },
            "host rejects an unbounded scroll delta"
        )
        _ = try! authenticatedController.handle(.input(.pointerButton(button: .left, isDown: true, x: 10, y: 20), surfaceID: nil))
        _ = try! authenticatedController.handle(.input(.scrolled(deltaX: -2, deltaY: 3, x: 10, y: 20, phase: nil, momentumPhase: nil), surfaceID: nil))
        _ = try! authenticatedController.handle(.input(.key(keyCode: 55, isDown: true, modifiers: [.command]), surfaceID: nil))
        expect(
            inputInjector.events == [
                .pointerMoved(x: 10, y: 20),
                .pointerButton(button: .left, isDown: true, x: 10, y: 20),
                .scrolled(deltaX: -2, deltaY: 3, x: 10, y: 20, phase: nil, momentumPhase: nil),
                .key(keyCode: 55, isDown: true, modifiers: [.command])
            ],
            "host injects valid button, scroll, and key input"
        )

        expectThrows(
            HostSessionControllerError.invalidInput,
            { _ = try authenticatedController.handle(.input(.pointerMovedRelative(deltaX: 0, deltaY: 100_000), surfaceID: nil)) },
            "host rejects an unbounded relative pointer delta"
        )
        _ = try! authenticatedController.handle(.input(.pointerCaptureChanged(isCaptured: true), surfaceID: nil))
        _ = try! authenticatedController.handle(.input(.pointerMovedRelative(deltaX: -3, deltaY: 5), surfaceID: nil))
        expect(
            inputInjector.events.suffix(2) == [
                .pointerCaptureChanged(isCaptured: true),
                .pointerMovedRelative(deltaX: -3, deltaY: 5)
            ],
            "captured-mode toggling and the relative motion it gates are injected as ordinary events"
        )
        _ = try! authenticatedController.handle(.input(.pointerCaptureChanged(isCaptured: false), surfaceID: nil))

        _ = try! authenticatedController.handle(.goodbye(reason: "client-disconnected"))
        expect(
            inputInjector.events.suffix(2) == [
                .pointerButton(button: .left, isDown: false, x: 10, y: 20),
                .key(keyCode: 55, isDown: false, modifiers: [])
            ],
            "session end releases every held button and key exactly once"
        )
        expect(authenticatedSession.isActive == false, "goodbye still releases the authenticated session canvas")

        let releaseAllAdapter = FakeVirtualDisplayAdapter()
        let releaseAllSession = VirtualDisplaySession(adapter: releaseAllAdapter)
        let releaseAllInjector = FakeInputInjector()
        let releaseAllController = HostSessionController(sessions: surfaceZeroOnly(releaseAllSession), inputInjector: releaseAllInjector, keyConfinement: .unconfined)
        _ = try! releaseAllController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))

        _ = try! releaseAllController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            releaseAllInjector.events.isEmpty,
            "an explicit releaseAllInput with nothing held posts no event"
        )

        _ = try! releaseAllController.handle(.input(.pointerButton(button: .left, isDown: true, x: 30, y: 40), surfaceID: nil))
        _ = try! releaseAllController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: [.shift]), surfaceID: nil))
        expect(
            releaseAllInjector.events.count == 2,
            "the held button and key were injected as ordinary presses before release"
        )

        _ = try! releaseAllController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            releaseAllInjector.events == [
                .pointerButton(button: .left, isDown: true, x: 30, y: 40),
                .key(keyCode: 12, isDown: true, modifiers: [.shift]),
                .pointerButton(button: .left, isDown: false, x: 30, y: 40),
                .key(keyCode: 12, isDown: false, modifiers: [])
            ],
            "an explicit releaseAllInput posts a real mouse-up and key-up for everything held, not the opaque wire case itself"
        )

        _ = try! releaseAllController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            releaseAllInjector.events.count == 4,
            "a second releaseAllInput after state was already cleared is idempotent and posts nothing new"
        )

        // A release that genuinely fails must not be recorded as if it had
        // succeeded: the button/key must stay held so a later retry still
        // attempts it, and the failure must be counted.
        let flakyAdapter = FakeVirtualDisplayAdapter()
        let flakySession = VirtualDisplaySession(adapter: flakyAdapter)
        let flakyInjector = FakeInputInjector()
        let flakyController = HostSessionController(sessions: surfaceZeroOnly(flakySession), inputInjector: flakyInjector, keyConfinement: .unconfined)
        _ = try! flakyController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! flakyController.handle(.input(.pointerButton(button: .left, isDown: true, x: 30, y: 40), surfaceID: nil))
        _ = try! flakyController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: [.shift]), surfaceID: nil))

        flakyInjector.failingEvents = [
            .pointerButton(button: .left, isDown: false, x: 30, y: 40),
            .key(keyCode: 12, isDown: false, modifiers: [])
        ]
        _ = try! flakyController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            flakyController.heldInputReleaseFailureCount == 2,
            "a release whose injection throws is counted as a failure, not silently treated as success"
        )
        expect(
            flakyInjector.events.count == 2,
            "a release whose injection throws posts nothing, so events still holds only the original two presses"
        )

        flakyInjector.failingEvents = []
        _ = try! flakyController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            flakyInjector.events == [
                .pointerButton(button: .left, isDown: true, x: 30, y: 40),
                .key(keyCode: 12, isDown: true, modifiers: [.shift]),
                .pointerButton(button: .left, isDown: false, x: 30, y: 40),
                .key(keyCode: 12, isDown: false, modifiers: [])
            ],
            "a held button/key is retried on the next release once injection recovers, instead of the failed release having discarded it"
        )

        // A session that drops while captured must not leave the Mini's
        // cursor permanently hidden and disassociated: teardown uncaptures it
        // exactly as it releases a held button or key.
        let capturedAdapter = FakeVirtualDisplayAdapter()
        let capturedSession = VirtualDisplaySession(adapter: capturedAdapter)
        let capturedInjector = FakeInputInjector()
        let capturedController = HostSessionController(sessions: surfaceZeroOnly(capturedSession), inputInjector: capturedInjector, keyConfinement: .unconfined)
        _ = try! capturedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! capturedController.handle(.input(.pointerCaptureChanged(isCaptured: true), surfaceID: nil))
        _ = try! capturedController.handle(.goodbye(reason: "client-disconnected"))
        expect(
            capturedInjector.events.last == .pointerCaptureChanged(isCaptured: false),
            "session teardown releases a still-active pointer capture, the same way it releases a held button or key"
        )

        let neverCapturedInjector = FakeInputInjector()
        let neverCapturedController = HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), inputInjector: neverCapturedInjector, keyConfinement: .unconfined)
        _ = try! neverCapturedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! neverCapturedController.handle(.goodbye(reason: "client-disconnected"))
        expect(
            !neverCapturedInjector.events.contains(where: { if case .pointerCaptureChanged = $0 { true } else { false } }),
            "teardown that never entered capture posts no capture-release event"
        )

        // What that failure is allowed to say. These are the only host log
        // lines that see held input at all, and a key code is keystroke
        // material -- the count and the outcome are what a reader needs.
        let releaseLog = DiagnosticsRecorder()
        let loggingInjector = FakeInputInjector()
        let loggingController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: loggingInjector,
            keyConfinement: .unconfined,
            log: { releaseLog.record($0) }
        )
        _ = try! loggingController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! loggingController.handle(.input(.pointerButton(button: .left, isDown: true, x: 30, y: 40), surfaceID: nil))
        _ = try! loggingController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: [.shift]), surfaceID: nil))
        loggingInjector.failingEvents = [
            .pointerButton(button: .left, isDown: false, x: 30, y: 40),
            .key(keyCode: 4242, isDown: false, modifiers: [])
        ]
        _ = try! loggingController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            releaseLog.messages.contains { $0.contains("buttons=1") && $0.contains("keys=1") },
            "a failed release is reported as how many failed and that they failed"
        )
        expect(
            releaseLog.messages.allSatisfy { !$0.contains("4242") && !$0.contains("left") },
            "and never as which key or which button was held"
        )
        loggingInjector.failingEvents = []
        let messagesAfterFailure = releaseLog.messages.count
        _ = try! loggingController.handle(.input(.releaseAllInput, surfaceID: nil))
        expect(
            releaseLog.messages.count == messagesAfterFailure,
            "a release that succeeds says nothing at all"
        )

        let tailnetSources = ["100.100.0.1", "100.100.0.2", "100.100.0.3", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::9"]
        for source in tailnetSources {
            expect(SourceAddressPolicy.isTailnetSource(source), "tailnet source \(source) is accepted")
        }
        let rejectedSources = ["100.63.255.255", "100.128.0.1", "192.0.2.45", "10.0.0.1", "127.0.0.1", "8.8.8.8", "fd7a:115c:a1e1::1", "fe80::1", "::1", "not-an-address", ""]
        for source in rejectedSources {
            expect(!SourceAddressPolicy.isTailnetSource(source), "non-tailnet source \(source) is rejected")
        }

        expect(
            HostConnectionAdmission.admits(endpoint: .hostPort(host: "100.100.0.2", port: 7777), transport: .quic),
            "tailnet endpoint is admitted"
        )
        expect(
            HostConnectionAdmission.admits(endpoint: .hostPort(host: "fd7a:115c:a1e0::1", port: 7777), transport: .quic),
            "tailnet IPv6 endpoint is admitted"
        )
        expect(
            !HostConnectionAdmission.admits(endpoint: .hostPort(host: "192.0.2.45", port: 7777), transport: .quic),
            "LAN endpoint is refused"
        )
        expect(
            !HostConnectionAdmission.admits(endpoint: .hostPort(host: "127.0.0.1", port: 7777), transport: .quic),
            "loopback endpoint is refused"
        )
        expect(
            !HostConnectionAdmission.admits(endpoint: .unix(path: "/tmp/socket"), transport: .quic),
            "a non-IP endpoint is refused"
        )

        let pairingAdapter = FakeVirtualDisplayAdapter()
        let pairingSession = VirtualDisplaySession(adapter: pairingAdapter)
        let hostIdentity = try! DeviceIdentity.generate()
        let newDevice = try! DeviceIdentity.generate()
        let pairingService = HostPairingService(hostIdentity: hostIdentity)
        let issuedCode = pairingService.issueCode(code: "424242")
        expect(issuedCode == "424242", "the host displays the code it issued")
        let pairingController = HostSessionController(
            sessions: surfaceZeroOnly(pairingSession),
            requireAuthentication: true,
            pairing: pairingService,
            keyConfinement: .unconfined
        )

        let newDeviceTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "NewLaptop",
            publicKey: newDevice.publicKey
        )
        let newDeviceHello = SensoriumMessage.authenticatedHello(
            protocolVersion: 1,
            deviceName: "NewLaptop",
            publicKey: newDevice.publicKey,
            signature: try! newDevice.sign(newDeviceTranscript)
        )
        expectThrows(
            HostSessionControllerError.deviceNotPaired,
            { _ = try pairingController.handle(newDeviceHello) },
            "an unpaired device cannot open a session"
        )

        let wrongCode = try! pairingController.handle(.pairRequest(
            deviceName: "NewLaptop",
            publicKey: newDevice.publicKey,
            code: "999999"
        ))
        expect(wrongCode == .pairRejected(reason: "invalid-code"), "a wrong pairing code is rejected")
        expectThrows(
            HostSessionControllerError.deviceNotPaired,
            { _ = try pairingController.handle(newDeviceHello) },
            "a rejected pairing does not approve the device"
        )

        let approval = try! pairingController.handle(.pairRequest(
            deviceName: "NewLaptop",
            publicKey: newDevice.publicKey,
            code: "424242"
        ))
        guard case let .pairApproved(approvedHostKey, tlsCertificateHash, signature?) = approval else {
            expect(false, "pairing approval contains a host signature")
            return
        }
        expect(approvedHostKey == hostIdentity.publicKey && tlsCertificateHash == nil, "TCP pairing returns the host key and explicitly has no TLS certificate pin")
        expect(
            DeviceIdentity.verify(
                signature: signature,
                message: SensoriumFrameCodec.pairApprovalTranscript(
                    deviceName: "NewLaptop",
                    clientPublicKey: newDevice.publicKey,
                    tlsCertificateHash: nil
                ),
                publicKey: hostIdentity.publicKey
            ),
            "the host signs the exact pairing approval transcript"
        )
        expect(try! pairingController.handle(newDeviceHello) == nil, "a paired device opens a session")

        let replay = try! pairingController.handle(.pairRequest(
            deviceName: "Attacker",
            publicKey: try! DeviceIdentity.generate().publicKey,
            code: "424242"
        ))
        expect(replay == .pairRejected(reason: "code-already-consumed"), "a pairing code cannot be replayed")

        // Guessing is bounded by a budget that belongs to the issued code
        // rather than to a connection: redialling resumes the same count
        // instead of resetting it, so ten wrong guesses retire the code
        // however many connections spent them.
        let budgetLog = DiagnosticsRecorder()
        let budgetDevice = try! DeviceIdentity.generate()
        let budgetPairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        budgetPairing.issueCode(code: "424242")
        // One controller per connection sharing the host's one pairing
        // service, exactly as `sensoriumd serve` builds them.
        func budgetConnection() -> HostSessionController {
            HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                requireAuthentication: true,
                pairing: budgetPairing,
                keyConfinement: .unconfined,
                log: { budgetLog.record($0) }
            )
        }
        for attempt in 1...PairingAuthority.maximumFailedAttempts {
            let guess = try! budgetConnection().handle(.pairRequest(
                deviceName: "NewLaptop",
                publicKey: budgetDevice.publicKey,
                code: String(format: "%06d", attempt)
            ))
            expect(
                guess == .pairRejected(reason: "invalid-code"),
                "wrong guess \(attempt), each on its own connection, is rejected"
            )
        }
        let spentBudget = try! budgetConnection().handle(.pairRequest(
            deviceName: "NewLaptop",
            publicKey: budgetDevice.publicKey,
            code: "424242"
        ))
        expect(
            spentBudget == .pairRejected(reason: "code-attempts-exhausted"),
            "a code whose failure budget is spent no longer pairs, even for the correct guess"
        )
        expect(
            !budgetPairing.isApproved(budgetDevice.publicKey),
            "an exhausted ceremony approves nothing"
        )
        expect(
            budgetLog.messages.allSatisfy { message in
                (3...6).allSatisfy { !message.contains("424242".prefix($0)) }
            },
            "no host log line carries the pairing code or a prefix of it"
        )

        // Ten is a bound on an attacker, not on a person mistyping six digits
        // read off the Mini: the tenth attempt still pairs.
        let nearMissDevice = try! DeviceIdentity.generate()
        let nearMissPairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        nearMissPairing.issueCode(code: "135790")
        let nearMissController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: nearMissPairing,
            keyConfinement: .unconfined
        )
        for attempt in 1..<PairingAuthority.maximumFailedAttempts {
            _ = try! nearMissController.handle(.pairRequest(
                deviceName: "NewLaptop",
                publicKey: nearMissDevice.publicKey,
                code: String(format: "%06d", attempt)
            ))
        }
        let nearMissApproval = try! nearMissController.handle(.pairRequest(
            deviceName: "NewLaptop",
            publicKey: nearMissDevice.publicKey,
            code: "135790"
        ))
        guard case .pairApproved = nearMissApproval else {
            expect(false, "nine wrong codes still leave the correct one able to pair")
            return
        }
        expect(
            nearMissPairing.isApproved(nearMissDevice.publicKey),
            "the pairing that survived nine wrong codes approved the device"
        )

        let signedAdapter = FakeVirtualDisplayAdapter()
        let signedSession = VirtualDisplaySession(adapter: signedAdapter)
        let signingHostIdentity = try! DeviceIdentity.generate()
        let signedClient = try! DeviceIdentity.generate()
        let signedPairing = HostPairingService(
            hostIdentity: signingHostIdentity,
            approvedPublicKeys: [signedClient.publicKey]
        )
        let signingController = HostSessionController(
            sessions: surfaceZeroOnly(signedSession),
            requireAuthentication: true,
            pairing: signedPairing,
            keyConfinement: .unconfined
        )
        let signedTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: signedClient.publicKey
        )
        _ = try! signingController.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: signedClient.publicKey,
            signature: try! signedClient.sign(signedTranscript)
        ))
        let signedReady = try! signingController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard case let .canvasReady(displayID, width, height, hostSignature, _, _) = signedReady else {
            expect(false, "canvas readiness carries a host signature")
            return
        }
        expect(
            DeviceIdentity.verify(
                signature: hostSignature ?? Data(),
                message: SensoriumFrameCodec.canvasReadyTranscript(
                    displayID: displayID,
                    logicalWidth: width,
                    logicalHeight: height,
                    clientPublicKey: signedClient.publicKey, surfaceID: nil
                ),
                publicKey: signingHostIdentity.publicKey
            ),
            "the host proves its identity over the canvas it just created"
        )

        expect(
            CoreGraphicsInputTranslation.motionType(heldButton: nil) == .mouseMoved,
            "motion with no button held is a plain move"
        )
        expect(
            CoreGraphicsInputTranslation.motionType(heldButton: .left) == .leftMouseDragged,
            "motion while the left button is held is a drag"
        )
        expect(
            CoreGraphicsInputTranslation.motionType(heldButton: .right) == .rightMouseDragged,
            "motion while the right button is held is a right drag"
        )
        expect(
            CoreGraphicsInputTranslation.buttonType(.middle, isDown: true) == .otherMouseDown,
            "the middle button maps to the other-button event"
        )
        expect(
            CoreGraphicsInputTranslation.flags([.command, .shift]) == [.maskCommand, .maskShift],
            "modifiers translate to the matching event flags"
        )
        expect(
            CoreGraphicsInputTranslation.flags([]) == [],
            "no modifiers means no event flags"
        )

        // Two virtual canvases share one system cursor. A CGEvent scroll
        // carries no location of its own, so it lands wherever that one
        // cursor is standing: scrolling in the second canvas's window after
        // last moving the pointer in the first one scrolls the first canvas.
        // The wire message already carries the position the scroll happened
        // at, so the injector puts the cursor there first.
        expect(
            CoreGraphicsInputTranslation.cursorPositioning(
                for: .scrolled(deltaX: 1, deltaY: 2, x: 100, y: 200, phase: nil, momentumPhase: nil)
            ) == CGPoint(x: 100, y: 200),
            "a scroll is positioned at its own canvas coordinates before it is posted"
        )
        expect(
            CoreGraphicsInputTranslation.cursorPositioning(for: .pointerMoved(x: 5, y: 6)) == nil,
            "pointer motion already carries its own position and is never repositioned twice"
        )
        expect(
            CoreGraphicsInputTranslation.cursorPositioning(
                for: .pointerButton(button: .left, isDown: true, x: 5, y: 6)
            ) == nil,
            "a button press already carries its own position"
        )
        // The unfixable half, recorded as a decision rather than an
        // oversight: a key event carries no position, and macOS routes it by
        // process-wide keyboard focus, which both canvases share. Positioning
        // the cursor does not move keyboard focus, so there is nothing here
        // for this seam to return.
        expect(
            CoreGraphicsInputTranslation.cursorPositioning(
                for: .key(keyCode: 0, isDown: true, modifiers: [])
            ) == nil,
            "a key event carries no position, so the injector has nothing to position it by"
        )
        expect(
            CoreGraphicsInputTranslation.cursorPositioning(for: .releaseAllInput) == nil,
            "release-all is turned into positioned releases by the controller before it reaches the injector"
        )

        // A trackpad's own per-event deltas are routinely well under one
        // pixel. `CGEvent(scrollWheelEvent2Source:...)`'s integer wheel
        // fields floor a delta like this to zero -- that truncation is the
        // scroll-precision bug -- so the fix must be provable on the exact
        // fields CoreGraphics defines for fractional scrolling, independent
        // of ever posting the event.
        guard let scrollSource = CGEventSource(stateID: .hidSystemState) else {
            expect(false, "a HID-state event source can be created for this translation check")
            return
        }
        guard let subPixelScroll = CoreGraphicsInputTranslation.scrollEvent(
            source: scrollSource,
            deltaX: 0,
            deltaY: 0.4,
            phase: nil,
            momentumPhase: nil
        ) else {
            expect(false, "a scroll event is created for a sub-pixel delta")
            return
        }
        expect(
            subPixelScroll.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) != 0,
            "a sub-pixel scroll delta is not truncated to zero on the axis that carries precise motion"
        )
        expect(
            abs(subPixelScroll.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) - 0.4) < 0.001,
            "the fixed-point delta field carries the exact fractional value, not a rounded one"
        )

        guard let phasedScroll = CoreGraphicsInputTranslation.scrollEvent(
            source: scrollSource,
            deltaX: -2,
            deltaY: 6,
            phase: .began,
            momentumPhase: nil
        ) else {
            expect(false, "a scroll event is created when a phase is present")
            return
        }
        expect(
            phasedScroll.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.began.rawValue),
            "a trackpad gesture's began phase is written onto the injected scroll event"
        )
        expect(
            CoreGraphicsInputTranslation.scrollEvent(
                source: scrollSource,
                deltaX: 0,
                deltaY: 1,
                phase: nil,
                momentumPhase: nil
            )?.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
            "an ordinary scroll-wheel mouse, which reports no phase, leaves the phase field untouched"
        )

        guard let momentumScroll = CoreGraphicsInputTranslation.scrollEvent(
            source: scrollSource,
            deltaX: 0,
            deltaY: 3,
            phase: nil,
            momentumPhase: .continue
        ) else {
            expect(false, "a scroll event is created when a momentum phase is present")
            return
        }
        expect(
            momentumScroll.getIntegerValueField(.scrollWheelEventMomentumPhase)
                == Int64(CoreGraphicsInputTranslation.cgMomentumScrollPhase(.continue).rawValue),
            "a trackpad flick's momentum-continue phase is written onto the injected scroll event"
        )

        let mediaAdapter = FakeVirtualDisplayAdapter()
        let mediaSession = VirtualDisplaySession(adapter: mediaAdapter)
        let media = FakeCanvasMedia()
        let workspace = FakeCanvasWorkspace()
        let videoSink = FakeVideoSink()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(mediaSession), keyConfinement: .unconfined),
            media: onlyOnSurfaceZero(media),
            videoSink: videoSink,
            workspaces: onlyOnSurfaceZero(workspace))

        expect(media.startedDisplayIDs.isEmpty, "no capture starts before a canvas exists")
        let coordinatorReady = try! await coordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard case .canvasReady = coordinatorReady else {
            expect(false, "the coordinator forwards canvas readiness to the client")
            return
        }
        expect(
            media.startedDisplayIDs == [7],
            "capture starts exactly once, on the display the session owns"
        )
        expect(
            workspace.startedDisplayIDs == [7],
            "a product workspace starts on the exact session-owned canvas before video begins"
        )

        let streamedPacket = EncodedVideoFramePacket(
            sequence: 5,
            presentationTimeNanoseconds: 50,
            isKeyFrame: true,
            payload: Data([9])
        )
        media.emit(streamedPacket)
        expect(videoSink.packets == [streamedPacket], "encoded canvas frames reach the client transport")

        _ = try! await coordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))
        expect(media.stopCount == 1, "capture stops when the session ends")
        expect(workspace.stopCount == 1, "the product workspace stops when the session ends")
        expect(!mediaSession.isActive, "the canvas is released when the session ends")
        media.emit(streamedPacket)
        expect(videoSink.packets.count == 1, "no frame is sent after the session ends")

        // A dropped connection's late teardown must never close the workspace
        // window the connection that took the surface over is streaming.
        // `CanvasOwnerToken` has always protected the canvas display from this
        // exact race; the workspaces are shared across connections in the same
        // way (`sensoriumd` builds them once, outside `serveChannel`), so a
        // teardown that stopped one regardless left the live connection with a
        // live canvas, a live stream and no window on it, silently.
        do {
            let reconnectAdapter = FakeVirtualDisplayAdapter()
            let reconnectSession = VirtualDisplaySession(adapter: reconnectAdapter)
            let reconnectFactory = HostConnectionSessionFactory(sessions: surfaceZeroOnly(reconnectSession), keyConfinement: .unconfined)
            let sharedWorkspace = FakeCanvasWorkspace()
            var reconnectOrder: [String] = []
            sharedWorkspace.onStop = { reconnectOrder.append("workspace") }
            reconnectAdapter.onRelease = { _ in reconnectOrder.append("display") }
            let mediaA = FakeCanvasMedia()
            let mediaB = FakeCanvasMedia()
            let endedA = DiagnosticsRecorder()
            let endedB = DiagnosticsRecorder()
            let coordinatorA = HostSessionCoordinator(
                controller: reconnectFactory.makeController(),
                media: onlyOnSurfaceZero(mediaA),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(sharedWorkspace),
                onSessionEnded: { endedA.record("ended") }
            )
            let coordinatorB = HostSessionCoordinator(
                controller: reconnectFactory.makeController(),
                media: onlyOnSurfaceZero(mediaB),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(sharedWorkspace),
                onSessionEnded: { endedB.record("ended") }
            )

            _ = try! await coordinatorA.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            expect(sharedWorkspace.startedDisplayIDs == [7], "the first connection's workspace is placed on its canvas")

            // A's socket is already dead; the host's blocked read has not
            // noticed yet. B redials, is handed the live canvas and installs
            // its own window over A's.
            _ = try! await coordinatorB.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            expect(
                sharedWorkspace.startedDisplayIDs == [7, 7],
                "the reconnecting connection takes the surface over with its own window on the same canvas"
            )

            // A's read finally fails, long after B owns the surface.
            await coordinatorA.sessionDidEnd(reason: "transport-closed")
            expect(
                sharedWorkspace.stopCount == 0,
                "the dead connection's teardown does not close the window the reconnected connection is streaming"
            )
            expect(
                sharedWorkspace.declinedStopCount == 1,
                "the workspace declines it for want of ownership, exactly as the canvas release already did"
            )
            expect(
                reconnectSession.isActive && reconnectAdapter.releasedHandles.isEmpty,
                "and the canvas the reconnected connection owns is not released either"
            )
            expect(
                mediaA.stopCount == 1 && mediaB.stopCount == 0,
                "the dead connection stops only its own capture"
            )
            expect(endedA.messages == ["ended"], "the dead connection signals session end exactly once")
            expect(endedB.messages.isEmpty, "and never on behalf of the live connection")

            // B's own teardown still closes the window it does own, workspace
            // before display.
            await coordinatorB.sessionDidEnd(reason: "client-disconnected")
            expect(
                sharedWorkspace.stopCount == 1,
                "the connection that owns the workspace still closes it when its own session ends"
            )
            expect(!reconnectSession.isActive, "and releases the canvas it owns")
            expect(
                reconnectOrder == ["workspace", "display"],
                "the surviving connection's window still disappears before the canvas display it sits on is released"
            )
            expect(endedB.messages == ["ended"], "the surviving connection signals session end exactly once")
        }

}
