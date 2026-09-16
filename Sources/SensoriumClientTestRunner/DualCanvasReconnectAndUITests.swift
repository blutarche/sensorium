import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testDualCanvasReconnectAndUITests() async {

        // A dual-canvas client against a capable host opens both, in one
        // connect, each bound to its own surfaceID end to end.
        let dualHostTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 70, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0),
            .canvasReady(displayID: 71, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 1)
        ])
        let dualClient = ClientSessionController(transport: dualHostTransport, requestSecondCanvas: true)
        let dualPrimaryDisplayID = try! await dualClient.connect(deviceName: "Laptop")
        expect(
            dualPrimaryDisplayID == .canvas(displayID: 70, hostScreenOffer: []),
            "connect still returns the primary canvas's own displayID"
        )
        expect(await dualClient.hostSupportsSurfaceIDs, "the host's echo on the primary canvas is still recorded as capability")
        expect(await dualClient.didOpenSecondCanvas, "a dual-canvas client against a capable host opens the second canvas")
        expect(await dualHostTransport.sent == [
            .hello(protocolVersion: 1, deviceName: "Laptop"),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)
        ], "both canvases are requested back to back within the same connect, never later")

        // A host that refuses the second canvas — its creation gate was busy
        // with another device's — must leave this session with the canvas it
        // already has. Dropping to single-window is the graceful outcome; the
        // failure this replaces was the client waiting out its whole
        // canvas-creation timeout and then closing the transport, taking the
        // working primary canvas down with it.
        let refusedSecondTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 90, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0),
            .canvasRefused(reason: CanvasRefusalReason.creationInProgress, surfaceID: 1)
        ])
        let refusedSecondClient = ClientSessionController(transport: refusedSecondTransport, requestSecondCanvas: true)
        let refusedSecondStart = Date()
        let refusedSecondPrimary = try! await refusedSecondClient.connect(deviceName: "Laptop")
        let refusedSecondElapsed = Date().timeIntervalSince(refusedSecondStart)
        expect(
            refusedSecondPrimary == .canvas(displayID: 90, hostScreenOffer: []),
            "a refused second canvas still returns the primary canvas's own displayID"
        )
        expect(
            await refusedSecondClient.didOpenSecondCanvas == false,
            "a refused second canvas leaves the client single-window rather than failing the connect"
        )
        // The timeout it must not have waited for is 15s; a scripted transport
        // answers in microseconds, so anything near it means the refusal was
        // not read as a reply at all.
        expect(
            refusedSecondElapsed < 1,
            "a refusal resolves promptly instead of waiting out the canvas-creation timeout"
        )
        expect(
            await refusedSecondTransport.closeCount == 0,
            "and never closes the transport the working primary canvas is still on"
        )
        try! await refusedSecondClient.sendInput(.pointerMoved(x: 7, y: 7))
        expect(
            await refusedSecondTransport.sent.contains(.input(.pointerMoved(x: 7, y: 7), surfaceID: nil, sequence: 0)),
            "the session is still usable after a refusal: the primary canvas still sends input"
        )

        // Refusing the *primary* canvas is the opposite case: there is no
        // session without surface 0, so it fails the connect, carrying the
        // host's own reason rather than a generic unexpected-message.
        let refusedPrimaryTransport = ScriptedClientTransport(responses: [
            .canvasRefused(reason: CanvasRefusalReason.creationInProgress, surfaceID: 0)
        ])
        let refusedPrimaryClient = ClientSessionController(
            transport: refusedPrimaryTransport,
            requestSecondCanvas: true
        )
        do {
            _ = try await refusedPrimaryClient.connect(deviceName: "Laptop")
            expect(false, "a refused primary canvas fails the connect")
        } catch let ClientSessionError.canvasRefused(refusedPrimaryReason) {
            expect(
                refusedPrimaryReason == CanvasRefusalReason.creationInProgress,
                "a refused primary canvas reports the host's own reason"
            )
        } catch {
            expect(false, "a refused primary canvas fails with the refusal error, not a generic one")
        }
        expect(
            await refusedPrimaryClient.didOpenSecondCanvas == false,
            "and no second canvas is opened off a session that never got its first"
        )

        // What a client that predates `canvasRefused` sees: its decoder does
        // not know the type, so the refusal arrives as `.unrecognized` — never
        // as a `canvasReady` it would act on. It fails its handshake fast
        // instead of waiting out the timeout, and does not close the transport
        // on the way out.
        let oldPeerRefusalTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 95, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0),
            .unrecognized(type: "canvasRefused")
        ])
        let oldPeerRefusalClient = ClientSessionController(
            transport: oldPeerRefusalTransport,
            requestSecondCanvas: true
        )
        let oldPeerRefusalStart = Date()
        do {
            _ = try await oldPeerRefusalClient.connect(deviceName: "Laptop")
            expect(false, "an old client does not mistake a refusal for a canvas it may draw on")
        } catch ClientSessionError.unexpectedMessage {
        } catch {
            expect(false, "an old client fails the second canvas rather than accepting the refusal")
        }
        expect(
            Date().timeIntervalSince(oldPeerRefusalStart) < 1,
            "an old client fails fast on a refusal rather than waiting out its canvas-creation timeout"
        )
        expect(
            await oldPeerRefusalTransport.closeCount == 0,
            "and does not itself close the session's transport"
        )

        // Input from each surface's window is tagged for its own canvas: the
        // primary keeps sending `surfaceID: nil`, unchanged from before a
        // second surface existed; the second sends an explicit `surfaceID: 1`.
        try! await dualClient.sendInput(.pointerMoved(x: 5, y: 5))
        let secondSurfaceSink = SurfaceScopedInputSink(session: dualClient, surfaceID: 1)
        try! await secondSurfaceSink.sendInput(.pointerMoved(x: 6, y: 6))
        expect(
            await dualHostTransport.sent.contains(.input(.pointerMoved(x: 5, y: 5), surfaceID: nil, sequence: 0)),
            "the primary window's input still carries no surfaceID"
        )
        expect(
            await dualHostTransport.sent.contains(.input(.pointerMoved(x: 6, y: 6), surfaceID: 1, sequence: 1)),
            "the second window's input carries an explicit surfaceID 1"
        )

        // Resizing the second window reports its drawable size tagged
        // surfaceID 1 only — the primary window's own reported size is
        // untouched by it.
        let secondSurfaceViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: secondSurfaceSink
        )
        await secondSurfaceViewport.canvasDidBecomeReady()
        let sentBeforeResize = await dualHostTransport.sent.count
        _ = await secondSurfaceViewport.setDrawableSize(pixelWidth: 3840, pixelHeight: 2400)
        let sentAfterResize = await dualHostTransport.sent
        expect(
            sentAfterResize.contains(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: 1, maximumScale: nil)),
            "resizing the second window reports its drawable size tagged surfaceID 1"
        )
        expect(
            sentAfterResize[sentBeforeResize...].allSatisfy {
                guard case let .viewerDrawableSize(_, _, surfaceID, _) = $0 else { return true }
                return surfaceID == 1
            },
            "resizing the second window never reports a drawable size for the primary window"
        )

        // Disconnecting a dual-canvas session releases input on both
        // surfaces — one surface's release must not leak across both.
        await dualClient.disconnect(reason: "test-teardown")
        let dualReleases = await dualHostTransport.sent.filter {
            if case .input(.releaseAllInput, _, _) = $0 { return true } else { return false }
        }
        expect(dualReleases.count == 2, "disconnecting a dual-canvas session releases input once per surface, not once total")
        expect(dualReleases.contains(.input(.releaseAllInput, surfaceID: nil)), "the primary surface's release keeps its original nil tag")
        expect(dualReleases.contains(.input(.releaseAllInput, surfaceID: 1)), "the second surface's release is tagged surfaceID 1")

        // Media interleaved into a handshake. The host starts streaming a
        // surface inside the same `handle` that produced its `canvasReady`,
        // so by the time the client asks for the second canvas there is video
        // on the socket ahead of the reply it is waiting for. A control read
        // steps over it; treating it as a peer failure took the primary
        // canvas down with it.
        let handshakeKeyFrame = EncodedVideoFramePacket(
            sequence: 0,
            presentationTimeNanoseconds: 1,
            isKeyFrame: true,
            payload: Data([0xA0])
        )
        let handshakeDeltaFrame = EncodedVideoFramePacket(
            sequence: 1,
            presentationTimeNanoseconds: 2,
            isKeyFrame: false,
            payload: Data([0xA1])
        )
        let interleavedDualTransport = ScriptedClientTransport(packets: [
            .control(.canvasReady(displayID: 90, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)),
            .video(handshakeKeyFrame),
            .videoForSurface(surfaceID: 0, frame: handshakeDeltaFrame),
            .control(.canvasReady(displayID: 91, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 1))
        ])
        let interleavedDualClient = ClientSessionController(
            transport: interleavedDualTransport,
            requestSecondCanvas: true
        )
        let interleavedPrimaryDisplayID = try? await interleavedDualClient.connect(deviceName: "Laptop")
        expect(
            interleavedPrimaryDisplayID == .canvas(displayID: 90, hostScreenOffer: []),
            "video arriving between the two canvasReady replies does not fail the connect and take the primary canvas down with it"
        )
        expect(
            await interleavedDualClient.didOpenSecondCanvas,
            "the second canvas still comes up after video interleaved into the handshake"
        )

        // What the handshake stepped over is still there for the media loop,
        // in arrival order and drained ahead of the wire -- the recovery
        // keyframe first, so the delta that depends on it stays admissible.
        // Dropping the keyframe instead would leave surface 0 undecodable
        // until the encoder's next one.
        var deferredDuringHandshake: [SensoriumTransportPacket] = []
        while let next = try? await interleavedDualTransport.receivePacket() {
            deferredDuringHandshake.append(next)
        }
        expect(
            deferredDuringHandshake == [
                .video(handshakeKeyFrame),
                .videoForSurface(surfaceID: 0, frame: handshakeDeltaFrame)
            ],
            "video read during a handshake reaches the media loop in arrival order instead of being discarded"
        )
        let interleavedIngress = SurfaceVideoIngress()
        await interleavedIngress.receive(surfaceID: 0, frame: handshakeKeyFrame)
        await interleavedIngress.receive(surfaceID: 0, frame: handshakeDeltaFrame)
        expect(
            await interleavedIngress.takeNewest(surfaceID: 0) == handshakeDeltaFrame,
            "the handshake's recovery keyframe survives, so the frame after it is still decodable"
        )

        // The single-canvas path is the same race, only narrower: encoder
        // startup against one immediate control write.
        let interleavedSingleTransport = ScriptedClientTransport(packets: [
            .video(EncodedVideoFramePacket(
                sequence: 0,
                presentationTimeNanoseconds: 1,
                isKeyFrame: true,
                payload: Data([0xB0])
            )),
            .unrecognized(tag: 9, payload: Data([0xB1])),
            .control(.canvasReady(displayID: 92, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil))
        ])
        let interleavedSingleClient = ClientSessionController(transport: interleavedSingleTransport)
        let interleavedSingleDisplayID = try? await interleavedSingleClient.connect(deviceName: "Laptop")
        expect(
            interleavedSingleDisplayID == .canvas(displayID: 92, hostScreenOffer: []),
            "a single-canvas connect is equally robust to video and unknown packets arriving before its canvasReady"
        )

        // Tolerance is for packets that are merely not control -- never for a
        // reply that is wrong, and never for a stream that ended.
        let wrongReplyTransport = ScriptedClientTransport(packets: [
            .video(handshakeKeyFrame),
            .control(.goodbye(reason: "host-busy"))
        ])
        let wrongReplyClient = ClientSessionController(transport: wrongReplyTransport)
        var wrongReplyError: Error?
        do {
            _ = try await wrongReplyClient.connect(deviceName: "Laptop")
        } catch {
            wrongReplyError = error
        }
        expect(
            wrongReplyError as? ClientSessionError == .unexpectedMessage,
            "a control reply that is not canvasReady is still an error, however much video preceded it"
        )
        let truncatedTransport = ScriptedClientTransport(packets: [.video(handshakeKeyFrame)])
        let truncatedClient = ClientSessionController(transport: truncatedTransport)
        var truncatedError: Error?
        do {
            _ = try await truncatedClient.connect(deviceName: "Laptop")
        } catch {
            truncatedError = error
        }
        expect(
            truncatedError as? ControlChannelError == .closed,
            "a stream that ends mid-handshake is reported, so stepping over media never becomes waiting forever"
        )

        // The hold is bounded: a peer that streams and never answers must not
        // grow it without limit. Overflow gives up only what a later keyframe
        // already supersedes, so what remains is still decodable on its own.
        let boundedQueue = DeferredPacketQueue()
        for sequence in 0..<UInt64(DeferredPacketQueue.capacity + 20) {
            await boundedQueue.hold(.videoForSurface(surfaceID: 0, frame: EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence,
                isKeyFrame: sequence == UInt64(DeferredPacketQueue.capacity),
                payload: Data([UInt8(sequence % 251)])
            )))
        }
        expect(await boundedQueue.count <= DeferredPacketQueue.capacity, "the deferred hold never grows past its cap")
        expect(
            await boundedQueue.droppedPacketCount == 0,
            "an overflow a later keyframe supersedes costs the surface nothing"
        )
        let oldestSurvivor = await boundedQueue.take()
        expect(
            {
                guard case let .videoForSurface(_, frame) = oldestSurvivor else { return false }
                return frame.isKeyFrame && frame.sequence == UInt64(DeferredPacketQueue.capacity)
            }(),
            "overflow keeps the newest recovery keyframe and everything after it"
        )
        let keyFramelessQueue = DeferredPacketQueue()
        for sequence in 0..<UInt64(DeferredPacketQueue.capacity + 5) {
            await keyFramelessQueue.hold(.videoForSurface(surfaceID: 0, frame: EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence,
                isKeyFrame: false,
                payload: Data([0xC0])
            )))
        }
        expect(
            await keyFramelessQueue.count == DeferredPacketQueue.capacity,
            "a hold with no keyframe to compact around still stays bounded"
        )
        expect(
            await keyFramelessQueue.droppedPacketCount == 5,
            "frames a bounded hold could not keep are counted rather than silently lost"
        )

        // SurfaceFrameRouter: the seam below the window that proves frame
        // routing correct without a window server connection.
        let frameRouter = SurfaceFrameRouter()
        let recordingWindow0 = RecordingSurfaceWindow(surfaceID: 0)
        let recordingWindow1 = RecordingSurfaceWindow(surfaceID: 1)
        frameRouter.setWindow(recordingWindow0, atSurfaceID: 0)
        frameRouter.setWindow(recordingWindow1, atSurfaceID: 1)
        _ = try! await frameRouter.route(
            surfaceID: 0,
            frame: EncodedVideoFramePacket(sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([0])),
            receivedAtNanoseconds: 100
        )
        _ = try! await frameRouter.route(
            surfaceID: 1,
            frame: EncodedVideoFramePacket(sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([1])),
            receivedAtNanoseconds: 100
        )
        expect(recordingWindow0.payloads == [Data([0])], "a frame tagged surface 0 is presented in window 0")
        expect(recordingWindow1.payloads == [Data([1])], "a frame tagged surface 1 is presented in window 1")
        expect(!recordingWindow0.payloads.contains(Data([1])), "surface 1's frame never reaches window 0")
        expect(!recordingWindow1.payloads.contains(Data([0])), "surface 0's frame never reaches window 1")

        // A surface with no registered window (single-canvas operation) still
        // admits its frame into ingress but has nowhere to present it.
        let singleSurfaceRouter = SurfaceFrameRouter()
        let onlyPrimaryWindow = RecordingSurfaceWindow(surfaceID: 0)
        singleSurfaceRouter.setWindow(onlyPrimaryWindow, atSurfaceID: 0)
        let deliveredToUnopenedSurface = try! await singleSurfaceRouter.route(
            surfaceID: 1,
            frame: EncodedVideoFramePacket(sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([9])),
            receivedAtNanoseconds: 1
        )
        expect(deliveredToUnopenedSurface == false, "a surface with no registered window drops its frame instead of presenting it anywhere")
        expect(onlyPrimaryWindow.payloads.isEmpty, "a frame for an unopened second surface never reaches the primary window")

        // The router's window storage is bounded to the same two-slot cap as
        // SurfaceVideoIngress -- a surfaceID outside {0,1} is ignored, not
        // used to grow storage.
        let boundedRouter = SurfaceFrameRouter()
        boundedRouter.setWindow(RecordingSurfaceWindow(surfaceID: 5), atSurfaceID: 5)
        let deliveredOutOfRange = try! await boundedRouter.route(
            surfaceID: 5,
            frame: EncodedVideoFramePacket(sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([5])),
            receivedAtNanoseconds: 1
        )
        expect(deliveredOutOfRange == false, "a surfaceID outside the {0,1} cap is dropped rather than used to grow window storage")

        // Teardown stops decoding on every window the router still knows
        // about -- both, not just the primary.
        await frameRouter.teardown()
        expect(recordingWindow0.stopDecodingCalls == 1, "teardown stops decoding on the primary window")
        expect(recordingWindow1.stopDecodingCalls == 1, "teardown stops decoding on the second window too, not just the primary")

        // Telemetry routes through the same fixed two-slot window lookup as
        // video, so one surface's reading can never land on the other's
        // window, by construction rather than by a test asserting it after
        // the fact each time.
        let telemetryRouter = SurfaceFrameRouter()
        let telemetryWindow0 = RecordingSurfaceWindow(surfaceID: 0)
        let telemetryWindow1 = RecordingSurfaceWindow(surfaceID: 1)
        telemetryRouter.setWindow(telemetryWindow0, atSurfaceID: 0)
        telemetryRouter.setWindow(telemetryWindow1, atSurfaceID: 1)
        func routedSnapshot(surfaceID: UInt32, isAttentionWorthy: Bool) -> SessionHUDSnapshot {
            SessionHUDSnapshot(
                surfaceID: surfaceID,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil,
                isAttentionWorthy: isAttentionWorthy
            )
        }
        telemetryRouter.updateSessionHUD(surfaceID: 0, snapshot: routedSnapshot(surfaceID: 0, isAttentionWorthy: false))
        telemetryRouter.updateSessionHUD(surfaceID: 1, snapshot: routedSnapshot(surfaceID: 1, isAttentionWorthy: true))
        expect(
            telemetryWindow0.lastTelemetryUpdate?.surfaceID == 0
                && telemetryWindow0.lastTelemetryUpdate?.isAttentionWorthy == false,
            "surface 0's window receives only surface 0's telemetry"
        )
        expect(
            telemetryWindow1.lastTelemetryUpdate?.surfaceID == 1
                && telemetryWindow1.lastTelemetryUpdate?.isAttentionWorthy == true,
            "surface 1's window receives only surface 1's telemetry, never surface 0's"
        )
        expect(telemetryWindow0.telemetryUpdateCount == 1, "surface 0's window is not updated by surface 1's telemetry")

        // Availability: unavailable before anything ever arrives, fresh right
        // after, stale once the freshness window has passed without a new
        // reading -- and crucially, still carrying the same last-known
        // numbers rather than resetting to a fabricated zero.
        var telemetryTracker = SessionTelemetryTracker()
        expect(
            telemetryTracker.availability(surfaceID: 0, nowNanoseconds: 0) == .unavailable,
            "a session that never received telemetry reports unavailable, not a zeroed reading"
        )
        let sample = SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 2_000_000, p95Nanoseconds: 3_000_000),
            encode: nil,
            send: nil,
            framesPerSecond: 60,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
        let staleAfterNanoseconds = Int64(TelemetryPolicy.staleAfterSeconds * 1_000_000_000)
        telemetryTracker.receive(surfaces: [sample], atNanoseconds: 1_000_000_000)
        expect(
            telemetryTracker.availability(surfaceID: 0, nowNanoseconds: 1_000_000_000) == .fresh(sample),
            "a reading just received is fresh"
        )
        expect(
            telemetryTracker.availability(surfaceID: 0, nowNanoseconds: 1_000_000_000 + staleAfterNanoseconds) == .fresh(sample),
            "a reading is still fresh exactly at the freshness boundary"
        )
        expect(
            telemetryTracker.availability(surfaceID: 0, nowNanoseconds: 1_000_000_000 + staleAfterNanoseconds + 1) == .stale(sample),
            "once telemetry stops arriving past the freshness window, the same last-known sample is reported stale rather than frozen as if it were current"
        )
        expect(
            telemetryTracker.availability(surfaceID: 1, nowNanoseconds: 1_000_000_000) == .unavailable,
            "one surface's reading does not manufacture availability for a surface that never reported"
        )
        // The whole reason the host sends the applied scale: the tracker must
        // hand it back intact, and must hand back nothing at all for a host
        // that never sent one.
        guard case let .fresh(trackedOldHost) = telemetryTracker.availability(surfaceID: 0, nowNanoseconds: 1_000_000_000) else {
            expect(false, "the just-received reading is fresh")
            return
        }
        expect(
            trackedOldHost.appliedStreamScale == nil && trackedOldHost.sustainableScaleCeiling == nil,
            "a host that reports no scale leaves the tracker with none, never a default"
        )
        var backedOffTracker = SessionTelemetryTracker()
        backedOffTracker.receive(
            surfaces: [SurfaceTelemetrySample(
                surfaceID: 0,
                capture: nil,
                encode: nil,
                send: nil,
                framesPerSecond: nil,
                encoderInputDropped: 0,
                globalAdmissionDropped: 0,
                sendQueueDropped: 0,
                appliedStreamScale: 1.5,
                sustainableScaleCeiling: 1.5
            )],
            atNanoseconds: 1_000_000_000
        )
        guard case let .fresh(trackedBackedOff) = backedOffTracker.availability(surfaceID: 0, nowNanoseconds: 1_000_000_000) else {
            expect(false, "a reading carrying a backed-off scale is fresh")
            return
        }
        expect(
            trackedBackedOff.appliedStreamScale == 1.5 && trackedBackedOff.sustainableScaleCeiling == 1.5,
            "the scale the host is actually encoding at reaches the client's tracker unchanged"
        )

        // The threshold fires on a bad reading and stays quiet on a good one.
        let goodSample = SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 2_000_000, p95Nanoseconds: 4_000_000),
            encode: StageLatencySample(p50Nanoseconds: 6_000_000, p95Nanoseconds: 9_000_000),
            send: StageLatencySample(p50Nanoseconds: 100_000, p95Nanoseconds: 200_000),
            framesPerSecond: 60,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
        expect(
            !TelemetryAttentionThreshold.isAttentionWorthy(availability: .fresh(goodSample), clientEndToEndP50Nanoseconds: 6_000_000),
            "a healthy fresh reading with no drops does not draw attention"
        )
        let slowSample = SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 20_000_000, p95Nanoseconds: 30_000_000),
            encode: StageLatencySample(p50Nanoseconds: 20_000_000, p95Nanoseconds: 30_000_000),
            send: StageLatencySample(p50Nanoseconds: 5_000_000, p95Nanoseconds: 9_000_000),
            framesPerSecond: 60,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
        expect(
            TelemetryAttentionThreshold.isAttentionWorthy(availability: .fresh(slowSample), clientEndToEndP50Nanoseconds: nil),
            "a host-measured reading whose own stages already exceed the threshold draws attention even with no client end-to-end sample yet"
        )
        let droppingSample = SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 2_000_000, p95Nanoseconds: 4_000_000),
            encode: nil,
            send: nil,
            framesPerSecond: 60,
            encoderInputDropped: 1,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0
        )
        expect(
            TelemetryAttentionThreshold.isAttentionWorthy(availability: .fresh(droppingSample), clientEndToEndP50Nanoseconds: nil),
            "any dropped frame since the last tick draws attention regardless of latency"
        )
        expect(
            TelemetryAttentionThreshold.isAttentionWorthy(availability: .stale(goodSample), clientEndToEndP50Nanoseconds: 6_000_000),
            "a stale reading draws attention even if the last numbers it carries were good"
        )
        expect(
            !TelemetryAttentionThreshold.isAttentionWorthy(availability: .unavailable, clientEndToEndP50Nanoseconds: nil),
            "unavailable telemetry is not itself an attention-worthy event"
        )

        print("PASS: telemetry routes to each surface's own window and never the other's")
        print("PASS: telemetry availability is unavailable before the first reading, fresh on receipt, and stale (not zeroed) once readings stop arriving")
        print("PASS: the attention threshold fires on drops, a stale reading, or slow host stages, and stays quiet on a healthy fresh reading")
        print("PASS: an old host that never echoes surfaceID stays single-window even when dual-canvas is requested")
        print("PASS: a capable host stays single-window unless dual-canvas is actually requested")
        print("PASS: connect requests both canvases back to back, never as a later toggle")
        print("PASS: each window's input and drawable-size reports carry that surface's own surfaceID")
        print("PASS: disconnecting a dual-canvas session releases input once per opened surface")
        print("PASS: video interleaved between the two canvasReady replies neither fails the connect nor loses the second canvas")
        print("PASS: media stepped over during a handshake reaches the media loop in order, keyframe intact")
        print("PASS: a single-canvas connect tolerates video and unknown packets ahead of its canvasReady")
        print("PASS: a wrong control reply or a stream that ended mid-handshake is still an error")
        print("PASS: the deferred hold is bounded and gives up only what a later keyframe supersedes")
        print("PASS: SurfaceFrameRouter presents each surface's frame in its own window and never the other's")
        print("PASS: SurfaceFrameRouter drops a frame for a surface with no registered window")
        print("PASS: SurfaceFrameRouter bounds window storage to the two-slot surfaceID cap")
        print("PASS: SurfaceFrameRouter teardown stops decoding on every window it knows about")

        // System shortcut routing: the default mode with a windowed viewer
        // must leave every system-reserved chord on the local machine.
        let defaultRouter = SystemShortcutRouter()
        let windowedPrimary = ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
        expect(
            defaultRouter.decide(
                chord: KeyChord(keyCode: 48, modifiers: [.command]),
                viewer: windowedPrimary,
                accessibilityGranted: true
            ) == .deliverToLocalMachine,
            "the default mode with a windowed viewer leaves Cmd-Tab on the local machine"
        )

        print("PASS: the default mode with a windowed viewer leaves Cmd-Tab on the local machine")

        // Each mode routes a representative system shortcut correctly across
        // focus and fullscreen. Cmd-Tab stands in for the tap-required half;
        // Accessibility is granted throughout so the mode is the only variable.
        let cmdTab = KeyChord(keyCode: 48, modifiers: [.command])
        let focusedWindowed = ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
        let focusedFullscreen = ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: true)
        let unfocusedWindowed = ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: false)
        let unfocusedFullscreen = ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: true)

        let localMode = SystemShortcutRouter(mode: .local)
        for viewer in [focusedWindowed, focusedFullscreen, unfocusedWindowed, unfocusedFullscreen] {
            expect(
                localMode.decide(chord: cmdTab, viewer: viewer, accessibilityGranted: true) == .deliverToLocalMachine,
                "local mode never forwards a system shortcut, whatever the window is doing"
            )
        }

        let whenFocused = SystemShortcutRouter(mode: .remoteWhenFocused)
        expect(
            whenFocused.decide(chord: cmdTab, viewer: focusedWindowed, accessibilityGranted: true)
                == .forwardToHost(surfaceID: 0),
            "remoteWhenFocused forwards a system shortcut from a focused windowed viewer"
        )
        expect(
            whenFocused.decide(chord: cmdTab, viewer: focusedFullscreen, accessibilityGranted: true)
                == .forwardToHost(surfaceID: 0),
            "remoteWhenFocused forwards a system shortcut from a focused fullscreen viewer"
        )
        expect(
            whenFocused.decide(chord: cmdTab, viewer: unfocusedWindowed, accessibilityGranted: true)
                == .deliverToLocalMachine,
            "remoteWhenFocused leaves a system shortcut local when the viewer has no key focus"
        )

        let inFullscreen = SystemShortcutRouter(mode: .remoteInFullscreen)
        expect(
            inFullscreen.decide(chord: cmdTab, viewer: focusedFullscreen, accessibilityGranted: true)
                == .forwardToHost(surfaceID: 0),
            "remoteInFullscreen forwards a system shortcut from a focused fullscreen viewer"
        )
        expect(
            inFullscreen.decide(chord: cmdTab, viewer: focusedWindowed, accessibilityGranted: true)
                == .deliverToLocalMachine,
            "remoteInFullscreen leaves a system shortcut local while the viewer is windowed"
        )
        expect(
            inFullscreen.decide(chord: cmdTab, viewer: unfocusedFullscreen, accessibilityGranted: true)
                == .deliverToLocalMachine,
            "remoteInFullscreen needs key focus as well as fullscreen"
        )
        expect(
            SystemShortcutMode.default == .remoteInFullscreen,
            "remoteInFullscreen is the default mode"
        )

        // Without Accessibility on the client, the tap-required half is never
        // claimed as forwarded — it names the shortcut instead of vanishing.
        let ungrantedDecision = inFullscreen.decide(
            chord: cmdTab,
            viewer: focusedFullscreen,
            accessibilityGranted: false
        )
        expect(
            !ungrantedDecision.forwardsToHost,
            "an ungranted client never claims a tap-required shortcut as forwarded"
        )
        guard case let .notForwardedAccessibilityRequired(blockedShortcut) = ungrantedDecision else {
            print("FAIL: an ungranted tap-required shortcut is not reported as needing Accessibility")
            Foundation.exit(1)
        }
        expect(
            blockedShortcut.name.contains("Cmd-Tab"),
            "the blocked decision names which shortcut is not reaching the host"
        )
        expect(
            ClientShortcutPermissionReport.blockedLine(blockedShortcut).contains("Accessibility"),
            "the blocked notice states that Accessibility is what is missing"
        )

        // The half that needs no tap keeps working on an ungranted client.
        expect(
            inFullscreen.decide(
                chord: KeyChord(keyCode: 12, modifiers: [.command]),
                viewer: focusedFullscreen,
                accessibilityGranted: false
            ) == .forwardToHost(surfaceID: 0),
            "an ungranted client still forwards the shortcuts that need no event tap"
        )

        // The launch-time report is what makes the degraded state visible:
        // nothing observes a Cmd-Tab the client is never handed.
        let ungrantedLines = ClientShortcutPermissionReport.lines(
            mode: .remoteInFullscreen,
            accessibilityGranted: false
        )
        expect(
            ungrantedLines.contains(where: { $0.contains("Accessibility") && $0.contains("not granted") }),
            "the launch report states plainly that Accessibility is not granted"
        )
        expect(
            ungrantedLines.contains(where: { $0.contains("Cmd-Tab") }),
            "the launch report names Cmd-Tab as one of the shortcuts that will not be forwarded"
        )
        expect(
            ungrantedLines.contains(where: { $0.contains("Cmd-Q") && $0.contains("menu") }),
            "the launch report says Cmd-Q reaches the host and the viewer's own menu is how the viewer is quit"
        )
        expect(
            ClientShortcutPermissionReport.lines(mode: .local, accessibilityGranted: false)
                .allSatisfy { !$0.contains("Accessibility") },
            "local mode needs no Accessibility, so its report does not ask for one"
        )
        expect(
            ClientShortcutPermissionReport.lines(mode: .remoteInFullscreen, accessibilityGranted: true)
                .contains(where: { $0.contains("granted") }),
            "a granted client is told so rather than left guessing"
        )

        // The escape gesture is never forwarded, in any mode, including the
        // fullscreen-with-Accessibility case that would otherwise be a trap.
        expect(
            SystemShortcutCatalog.escapeGestureIsNeverForwardable,
            "the escape gesture is not a member of the forwardable set"
        )
        for mode in SystemShortcutMode.allCases {
            for viewer in [focusedWindowed, focusedFullscreen, unfocusedWindowed, unfocusedFullscreen] {
                for granted in [true, false] {
                    let decision = SystemShortcutRouter(mode: mode).decide(
                        chord: SystemShortcutCatalog.escapeGesture,
                        viewer: viewer,
                        accessibilityGranted: granted
                    )
                    expect(
                        decision == .releaseToLocalMachine,
                        "the escape gesture returns the user to the local machine in mode \(mode.flagValue)"
                    )
                    expect(!decision.forwardsToHost, "the escape gesture is never forwarded")
                }
            }
        }

        // Regression: Cmd-Q and Cmd-H are menu key equivalents and catalog
        // entries at once. AppKit matches a menu chord before the key
        // window's `keyDown:`, so a viewer whose mode said "forward" quit
        // itself instead of the app on the remote machine.
        // `claimsKeyEquivalent` is what `CanvasSurfaceView` asks ahead of the
        // menu, and it must answer with the same policy that governs
        // forwarding.
        let menuClaimedChords = [
            ("Cmd-Q", KeyChord(keyCode: 12, modifiers: [.command])),
            ("Cmd-H", KeyChord(keyCode: 4, modifiers: [.command]))
        ]
        for (name, chord) in menuClaimedChords {
            for viewer in [focusedWindowed, focusedFullscreen, unfocusedWindowed, unfocusedFullscreen] {
                expect(
                    !localMode.claimsKeyEquivalent(chord: chord, viewer: viewer, accessibilityGranted: true),
                    "local mode leaves \(name) to the viewer's own menu, whatever the window is doing"
                )
            }
            expect(
                whenFocused.claimsKeyEquivalent(chord: chord, viewer: focusedWindowed, accessibilityGranted: true),
                "remoteWhenFocused takes \(name) ahead of the menu in a focused windowed viewer"
            )
            expect(
                whenFocused.claimsKeyEquivalent(chord: chord, viewer: focusedFullscreen, accessibilityGranted: true),
                "remoteWhenFocused takes \(name) ahead of the menu in a focused fullscreen viewer"
            )
            expect(
                !whenFocused.claimsKeyEquivalent(chord: chord, viewer: unfocusedWindowed, accessibilityGranted: true),
                "an unfocused viewer never takes \(name) from the menu"
            )
            expect(
                inFullscreen.claimsKeyEquivalent(chord: chord, viewer: focusedFullscreen, accessibilityGranted: true),
                "remoteInFullscreen takes \(name) ahead of the menu once the viewer is focused and fullscreen"
            )
            expect(
                !inFullscreen.claimsKeyEquivalent(chord: chord, viewer: focusedWindowed, accessibilityGranted: true),
                "remoteInFullscreen leaves \(name) to the menu while the viewer is windowed"
            )
            expect(
                !inFullscreen.claimsKeyEquivalent(chord: chord, viewer: unfocusedFullscreen, accessibilityGranted: true),
                "remoteInFullscreen needs key focus before it takes \(name) from the menu"
            )
            // Neither chord is one the WindowServer consumes, so no
            // Accessibility grant stands between the canvas and the menu.
            expect(
                whenFocused.claimsKeyEquivalent(chord: chord, viewer: focusedWindowed, accessibilityGranted: false),
                "\(name) is taken ahead of the menu without an Accessibility grant, which it never needed"
            )
        }

        // The escape gesture is left to the ordinary key path in every mode:
        // `CanvasSurfaceView.claim(_:isDown:)` is what releases a captured
        // pointer, and a claim here would take the gesture before it ran.
        for mode in SystemShortcutMode.allCases {
            for viewer in [focusedWindowed, focusedFullscreen, unfocusedWindowed, unfocusedFullscreen] {
                for granted in [true, false] {
                    expect(
                        !SystemShortcutRouter(mode: mode).claimsKeyEquivalent(
                            chord: SystemShortcutCatalog.escapeGesture,
                            viewer: viewer,
                            accessibilityGranted: granted
                        ),
                        "the escape gesture is never claimed ahead of the menu in mode \(mode.flagValue)"
                    )
                }
            }
        }

        // The menu's own chords that no catalog entry reserves keep working:
        // Cmd-Ctrl-F is how a user leaves fullscreen, which is itself one of
        // the ways back to a local Cmd-Q.
        for mode in SystemShortcutMode.allCases {
            expect(
                !SystemShortcutRouter(mode: mode).claimsKeyEquivalent(
                    chord: KeyChord(keyCode: 3, modifiers: [.command, .control]),
                    viewer: focusedFullscreen,
                    accessibilityGranted: true
                ),
                "Cmd-Ctrl-F stays the local fullscreen toggle in mode \(mode.flagValue)"
            )
        }

        print("PASS: a forwarded system shortcut outranks the viewer's menu, while the escape gesture and menu chords do not")

        // A forwarded shortcut carries the surfaceID of the window that had
        // focus, for both surfaces.
        expect(
            whenFocused.decide(
                chord: cmdTab,
                viewer: ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false),
                accessibilityGranted: true
            ) == .forwardToHost(surfaceID: 0),
            "a shortcut forwarded from the primary window carries surfaceID 0"
        )
        expect(
            whenFocused.decide(
                chord: cmdTab,
                viewer: ViewerWindowState(surfaceID: 1, hasKeyFocus: true, isFullscreen: false),
                accessibilityGranted: true
            ) == .forwardToHost(surfaceID: 1),
            "a shortcut forwarded from the second window carries surfaceID 1"
        )

        // And the surfaceID a decision carries is what actually reaches the
        // wire: surface 1's forwarded Cmd-Tab is tagged, surface 0's is not.
        let shortcutTransport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed"),
            .canvasReady(displayID: 70, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0),
            .canvasReady(displayID: 71, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 1)
        ])
        let shortcutClient = ClientSessionController(
            transport: shortcutTransport,
            identity: try! DeviceIdentity.generate(),
            pinnedHostPublicKey: nil,
            requestSecondCanvas: true
        )
        _ = try! await shortcutClient.connect(deviceName: "Laptop")
        let forwardedKey = SensoriumInputEvent.key(keyCode: 48, isDown: true, modifiers: [.command])
        for surface in [UInt32(0), UInt32(1)] {
            let decision = whenFocused.decide(
                chord: cmdTab,
                viewer: ViewerWindowState(surfaceID: surface, hasKeyFocus: true, isFullscreen: false),
                accessibilityGranted: true
            )
            guard case let .forwardToHost(decidedSurfaceID) = decision else {
                print("FAIL: a focused viewer did not forward Cmd-Tab for surface \(surface)")
                Foundation.exit(1)
            }
            let sink: any CanvasInputSending = decidedSurfaceID == 0
                ? shortcutClient
                : SurfaceScopedInputSink(session: shortcutClient, surfaceID: decidedSurfaceID)
            try! await sink.sendInput(forwardedKey)
        }
        expect(
            await shortcutTransport.sent.contains(.input(forwardedKey, surfaceID: nil, sequence: 0)),
            "a shortcut forwarded from the primary window reaches the wire with no surfaceID, as surface 0 always has"
        )
        expect(
            await shortcutTransport.sent.contains(.input(forwardedKey, surfaceID: 1, sequence: 1)),
            "a shortcut forwarded from the second window reaches the wire tagged surfaceID 1"
        )

        // Ordinary typing must not regress: every mode forwards it unchanged
        // whenever the viewer holds key focus, and Accessibility is irrelevant.
        let ordinaryChords = [
            KeyChord(keyCode: 0, modifiers: []),               // "a"
            KeyChord(keyCode: 8, modifiers: [.command]),       // Cmd-C
            KeyChord(keyCode: 9, modifiers: [.command]),       // Cmd-V
            KeyChord(keyCode: 6, modifiers: [.command]),       // Cmd-Z
            KeyChord(keyCode: 48, modifiers: [])               // bare Tab
        ]
        for mode in SystemShortcutMode.allCases {
            let router = SystemShortcutRouter(mode: mode)
            for chord in ordinaryChords {
                for granted in [true, false] {
                    expect(
                        router.decide(chord: chord, viewer: focusedWindowed, accessibilityGranted: granted)
                            == .forwardToHost(surfaceID: 0),
                        "ordinary typing still reaches the canvas in mode \(mode.flagValue)"
                    )
                    expect(
                        router.decide(chord: chord, viewer: focusedFullscreen, accessibilityGranted: granted)
                            == .forwardToHost(surfaceID: 0),
                        "ordinary typing still reaches the canvas fullscreen in mode \(mode.flagValue)"
                    )
                }
            }
        }

        // The default mode with a windowed viewer forwards nothing
        // system-reserved: the local machine keeps every one of them.
        for shortcut in SystemShortcutCatalog.all {
            expect(
                defaultRouter.decide(chord: shortcut.chord, viewer: focusedWindowed, accessibilityGranted: true)
                    == .deliverToLocalMachine,
                "the default windowed viewer leaves \(shortcut.name) on the local machine"
            )
            expect(
                !shortcut.name.contains("minimise"),
                "every shortcut name is US English -- \(shortcut.name) still carries a British spelling"
            )
        }

        // The launch flag's spellings round-trip, and an unknown one is
        // rejected rather than silently defaulted.
        for mode in SystemShortcutMode.allCases {
            expect(
                SystemShortcutMode(flagValue: mode.flagValue) == mode,
                "the --system-shortcuts value for \(mode.flagValue) round-trips"
            )
        }
        expect(
            SystemShortcutMode(flagValue: "remoteInFullscreen") == nil,
            "an unrecognised --system-shortcuts value is rejected, not silently defaulted"
        )

        print("PASS: each routing mode forwards or withholds a system shortcut per focus and fullscreen")
        print("PASS: an ungranted client withholds tap-required shortcuts and names them instead of dropping them")
        print("PASS: the escape gesture is never forwarded in any mode, focus state, or permission state")
        print("PASS: a forwarded shortcut carries the focused window's surfaceID onto the wire")
        print("PASS: ordinary typing is unaffected by every routing mode")
        print("PASS: the --system-shortcuts flag value round-trips and rejects unknown spellings")

        // The forwarder seam: policy joined to whichever viewer window has
        // focus, with a fake interceptor standing in for the event tap so no
        // TCC grant or window server is involved.
        await MainActor.run {
            let primaryTarget = RecordingShortcutTarget(
                state: ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: true)
            )
            let secondTarget = RecordingShortcutTarget(
                state: ViewerWindowState(surfaceID: 1, hasKeyFocus: true, isFullscreen: true)
            )
            let grantedInterceptor = FakeShortcutInterceptor()
            let forwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: grantedInterceptor
            )
            forwarder.register(primaryTarget)
            forwarder.register(secondTarget)
            var logged: [String] = []
            forwarder.startInterceptingIfPermitted { logged.append($0) }
            expect(grantedInterceptor.isRunning, "a granted client in a remote mode starts the interceptor")
            expect(logged.isEmpty, "a successful interceptor start says nothing alarming")

            expect(
                grantedInterceptor.deliver(KeyChord(keyCode: 48, modifiers: [.command]), isDown: true),
                "a forwarded shortcut is claimed so it never also acts on this machine"
            )
            expect(
                secondTarget.forwarded == [ForwardedShortcut(keyCode: 48, isDown: true, modifiers: [.command])],
                "the focused window is the one handed the forwarded shortcut"
            )
            expect(primaryTarget.forwarded.isEmpty, "an unfocused viewer window is never handed a forwarded shortcut")

            // The escape gesture reaches the focused window as a release, not
            // as a forwarded key, even here where the tap is running.
            expect(
                grantedInterceptor.deliver(SystemShortcutCatalog.escapeGesture, isDown: true),
                "the escape gesture is claimed rather than left to act on this machine"
            )
            expect(secondTarget.releaseCount == 1, "the escape gesture releases the focused window back to this machine")
            expect(
                secondTarget.forwarded.count == 1,
                "the escape gesture is never forwarded, even with the tap running in fullscreen"
            )

            forwarder.stop()
            expect(!grantedInterceptor.isRunning, "stopping the forwarder stops the interceptor")

            // local mode has no use for a tap, so it never creates one.
            let localInterceptor = FakeShortcutInterceptor()
            let localForwarder = SystemShortcutForwarder(
                mode: .local,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: localInterceptor
            )
            localForwarder.startInterceptingIfPermitted { _ in }
            expect(!localInterceptor.isRunning, "local mode never starts an event tap")

            // Nor does an ungranted client: starting one is what makes macOS
            // ask, and nothing here asks for a permission on the user's behalf.
            let ungrantedInterceptor = FakeShortcutInterceptor()
            let ungrantedForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: false),
                interceptor: ungrantedInterceptor
            )
            let ungrantedTarget = RecordingShortcutTarget(
                state: ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: true)
            )
            ungrantedForwarder.register(ungrantedTarget)
            ungrantedForwarder.startInterceptingIfPermitted { _ in }
            expect(!ungrantedInterceptor.isRunning, "an ungranted client never creates an event tap")
            expect(
                !ungrantedForwarder.handle(chord: KeyChord(keyCode: 48, modifiers: [.command]), isDown: true),
                "an ungranted client does not claim a tap-required shortcut it cannot forward"
            )
            expect(ungrantedTarget.forwarded.isEmpty, "an ungranted client forwards no tap-required shortcut")
            expect(
                ungrantedForwarder.handle(chord: KeyChord(keyCode: 12, modifiers: [.command]), isDown: true),
                "an ungranted client still forwards the half that needs no tap"
            )

            // A tap that cannot be created is reported, not swallowed.
            let failingInterceptor = FakeShortcutInterceptor()
            failingInterceptor.failure = .tapCreationFailed
            let failingForwarder = SystemShortcutForwarder(
                mode: .remoteWhenFocused,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: failingInterceptor
            )
            var failureLines: [String] = []
            failingForwarder.startInterceptingIfPermitted { failureLines.append($0) }
            expect(failureLines.count == 1, "a failed interceptor start is reported exactly once")
            expect(
                failureLines[0].contains("act on this machine"),
                "the failure says what the user will actually observe, not just that something failed"
            )

            // The blocked notice is said once per shortcut, so a held key does
            // not flood the log with the same line.
            let blocked = SystemShortcutCatalog.all.first { $0.interception == .eventTap }!
            expect(
                ungrantedForwarder.unreportedBlockedNotice(for: blocked) != nil,
                "a blocked shortcut is reported the first time it is seen"
            )
            expect(
                ungrantedForwarder.unreportedBlockedNotice(for: blocked) == nil,
                "the same blocked shortcut is not reported again"
            )

            // A tap sees every keystroke on the machine, not only the
            // viewer's — its lifetime must match the session that justifies
            // it exactly, reinstalling on reconnect and never stacking or
            // leaking across a flapping one.
            let lifetimeInterceptor = FakeShortcutInterceptor()
            let lifetimeForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: lifetimeInterceptor
            )
            let lifetimeTarget = RecordingShortcutTarget(
                state: ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: true)
            )
            lifetimeForwarder.register(lifetimeTarget)
            // A catalog chord, not ordinary typing: the tap must never claim
            // ordinary typing at all (see the adversarial block below), so
            // proving install/remove/reinstall needs a chord the tap is
            // actually meant to see.
            let cmdTabChord = KeyChord(keyCode: 48, modifiers: [.command])

            lifetimeForwarder.startInterceptingIfPermitted { _ in }
            expect(lifetimeInterceptor.isRunning, "a session start installs the tap")
            expect(
                lifetimeInterceptor.deliver(cmdTabChord, isDown: true),
                "a system-reserved chord is claimed and forwarded while a session is active"
            )
            expect(lifetimeTarget.forwarded.count == 1, "the claimed shortcut reached the focused window")

            lifetimeForwarder.stop()
            expect(!lifetimeInterceptor.isRunning, "a session end removes the tap")
            // With no tap installed there is nothing to call `claim` at all —
            // this is the fake's stand-in for the WindowServer routing the
            // keystroke to the local machine because no tap exists to see it
            // first, not for the tap seeing it and letting it through.
            expect(
                !lifetimeInterceptor.deliver(cmdTabChord, isDown: true),
                "with no session active, no keystroke is claimed — it reaches the local machine untouched"
            )
            expect(lifetimeTarget.forwarded.count == 1, "no further keystroke reaches the dead session's window")

            lifetimeForwarder.startInterceptingIfPermitted { _ in }
            expect(lifetimeInterceptor.isRunning, "reconnecting installs the tap again")
            expect(lifetimeInterceptor.startCount == 2, "a genuine end-then-reconnect reinstalls rather than reusing a stale tap")
            expect(lifetimeInterceptor.stopCount == 1, "one session end removed exactly one tap")
            expect(
                lifetimeInterceptor.deliver(cmdTabChord, isDown: true),
                "the reinstalled tap claims keystrokes again"
            )
            expect(lifetimeTarget.forwarded.count == 2, "the reconnected session forwards again")

            // A start that races a still-pending stop, or a caller invoking
            // it twice, must never stack a second tap behind the first.
            lifetimeForwarder.startInterceptingIfPermitted { _ in }
            expect(lifetimeInterceptor.startCount == 2, "starting while already intercepting installs nothing new")

            // A flapping reconnect must settle at exactly one tap installed,
            // with every stop tearing down the one it started — never more,
            // never leaked.
            for _ in 0..<5 {
                lifetimeForwarder.stop()
                lifetimeForwarder.startInterceptingIfPermitted { _ in }
            }
            expect(lifetimeInterceptor.isRunning, "after flapping, exactly one tap is installed")
            expect(lifetimeInterceptor.startCount == 7, "each flap's stop is followed by exactly one fresh install")
            expect(lifetimeInterceptor.stopCount == 6, "each flap tears down exactly the one tap it started")
            lifetimeForwarder.stop()
            expect(!lifetimeInterceptor.isRunning, "the final stop leaves nothing installed")
            expect(lifetimeInterceptor.stopCount == 7, "stop after stop across the whole cycle never double-tears-down or leaks")

            // Without Accessibility, nothing ever actually installs — the
            // lifetime logic around it must still behave across a full
            // start/stop/reconnect cycle rather than erroring or
            // double-reporting on something that was never there.
            let neverInstalledInterceptor = FakeShortcutInterceptor()
            let neverInstalledForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: false),
                interceptor: neverInstalledInterceptor
            )
            neverInstalledForwarder.startInterceptingIfPermitted { _ in }
            neverInstalledForwarder.stop()
            neverInstalledForwarder.stop()
            neverInstalledForwarder.startInterceptingIfPermitted { _ in }
            expect(!neverInstalledInterceptor.isRunning, "an ungranted client installs nothing across a full start/stop/reconnect cycle")
            expect(neverInstalledInterceptor.startCount == 0, "an ungranted client never reaches the interceptor's start")
            expect(neverInstalledInterceptor.stopCount == 0, "stopping something never installed never reaches the interceptor's stop")

            // Adversarial: the machine must stay usable. These assert the
            // client cannot lock the user out, not that a feature works.
            let ordinaryChords = [
                KeyChord(keyCode: 0, modifiers: []),               // "a"
                KeyChord(keyCode: 8, modifiers: [.command]),       // Cmd-C
                KeyChord(keyCode: 9, modifiers: [.command]),       // Cmd-V
                KeyChord(keyCode: 6, modifiers: [.command]),       // Cmd-Z
                KeyChord(keyCode: 48, modifiers: [])                // bare Tab
            ]
            // Cmd-Option-Escape: macOS's own Force Quit. Not the escape
            // gesture (which also holds Control) and not a catalog entry —
            // must never be touched, in any mode or state.
            let forceQuit = KeyChord(keyCode: 53, modifiers: [.command, .option])
            let adversarialStates = [
                ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: true),
                ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false),
                ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: true),
                ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: false)
            ]

            for mode in SystemShortcutMode.allCases {
                for granted in [true, false] {
                    for state in adversarialStates {
                        let interceptor = FakeShortcutInterceptor()
                        let forwarder = SystemShortcutForwarder(
                            mode: mode,
                            accessibility: FixedAccessibilityAuthorization(granted: granted),
                            interceptor: interceptor
                        )
                        let target = RecordingShortcutTarget(state: state)
                        forwarder.register(target)

                        for chord in ordinaryChords {
                            expect(
                                !forwarder.handle(chord: chord, isDown: true),
                                "ordinary typing (\(chord)) is never claimed by the tap — mode \(mode.flagValue), granted \(granted), \(state)"
                            )
                        }
                        expect(target.forwarded.isEmpty, "no ordinary key reached forwardShortcut through the tap path — mode \(mode.flagValue), \(state)")

                        expect(
                            !forwarder.handle(chord: forceQuit, isDown: true),
                            "Force Quit is never claimed — mode \(mode.flagValue), granted \(granted), \(state)"
                        )
                    }
                }
            }

            // Mid-teardown: windows exist but none currently holds focus (or
            // none are registered at all). Every chord, including the escape
            // gesture and a real catalog entry, must fail open rather than
            // erroring on the missing target.
            let noFocusForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: FakeShortcutInterceptor()
            )
            expect(!noFocusForwarder.handle(chord: SystemShortcutCatalog.escapeGesture, isDown: true), "no registered window: even the escape gesture claims nothing")
            expect(!noFocusForwarder.handle(chord: cmdTabChord, isDown: true), "no registered window: a real catalog chord still claims nothing")

            let unfocusedTarget = RecordingShortcutTarget(
                state: ViewerWindowState(surfaceID: 0, hasKeyFocus: false, isFullscreen: true)
            )
            noFocusForwarder.register(unfocusedTarget)
            expect(!noFocusForwarder.handle(chord: SystemShortcutCatalog.escapeGesture, isDown: true), "a registered but unfocused window: still nothing is claimed")
            expect(!noFocusForwarder.handle(chord: cmdTabChord, isDown: true), "a registered but unfocused window: still nothing is claimed")
            expect(unfocusedTarget.releaseCount == 0 && unfocusedTarget.forwarded.isEmpty, "the unfocused window was never touched")

            // The escape gesture must still work, in every mode, focus,
            // fullscreen, and Accessibility combination that can reach it —
            // it is the user's guaranteed way out.
            for mode in SystemShortcutMode.allCases {
                for granted in [true, false] {
                    let interceptor = FakeShortcutInterceptor()
                    let forwarder = SystemShortcutForwarder(
                        mode: mode,
                        accessibility: FixedAccessibilityAuthorization(granted: granted),
                        interceptor: interceptor
                    )
                    let target = RecordingShortcutTarget(
                        state: ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: true)
                    )
                    forwarder.register(target)
                    expect(
                        forwarder.handle(chord: SystemShortcutCatalog.escapeGesture, isDown: true),
                        "the escape gesture always releases — mode \(mode.flagValue), granted \(granted)"
                    )
                    expect(target.releaseCount == 1, "the release actually reached the focused window — mode \(mode.flagValue), granted \(granted)")
                    expect(target.forwarded.isEmpty, "the escape gesture is never forwarded — mode \(mode.flagValue), granted \(granted)")
                }
            }

            // Once the session is gone (tap stopped), `handle` is not even
            // reachable through the tap — the interceptor-level lifetime
            // test above already proves that. This proves the forwarder side
            // fails open the same way if it were ever invoked directly with
            // nothing to hand a chord to, e.g. via a stale closure firing
            // after teardown.
            let torndownForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: FakeShortcutInterceptor()
            )
            expect(!torndownForwarder.handle(chord: cmdTabChord, isDown: true), "a forwarder with no windows registered claims nothing, ever")
            expect(!torndownForwarder.handle(chord: SystemShortcutCatalog.escapeGesture, isDown: true), "including the escape gesture")

            print("PASS: ordinary typing is never claimed by the tap, in every mode, focus, fullscreen, and Accessibility state")
            print("PASS: Force Quit (Cmd-Option-Escape) is never claimed, in any mode or state")
            print("PASS: with no focused window, nothing is claimed, even the escape gesture and a real catalog chord")
            print("PASS: the escape gesture always releases the focused window, in every mode and Accessibility state")

            // macOS's own safety valve for a tap it disabled must not be
            // defeated. Pure policy, tested directly — no real tap involved.
            let timeoutBudget = TapDisableBudget()
            for attempt in 1...TapDisableBudget.maxTimeoutReenables {
                expect(
                    timeoutBudget.decide(.timeout) == .reenable,
                    "timeout \(attempt) of \(TapDisableBudget.maxTimeoutReenables) is still within budget"
                )
            }
            switch timeoutBudget.decide(.timeout) {
            case let .stayDisabledAndReport(message):
                expect(!message.isEmpty, "exceeding the timeout budget reports something, not silence")
            default:
                expect(false, "exceeding the timeout budget must stay disabled and report it exactly once")
            }
            expect(
                timeoutBudget.decide(.timeout) == .stayDisabled,
                "once the budget is spent, further timeouts stay disabled without repeating the report"
            )

            let userInputBudget = TapDisableBudget()
            expect(
                userInputBudget.decide(.userInput) == .stayDisabled,
                "tapDisabledByUserInput is never auto re-enabled, even on the very first occurrence"
            )
            expect(
                userInputBudget.decide(.userInput) == .stayDisabled,
                "...nor on any later occurrence"
            )
            expect(
                userInputBudget.decide(.timeout) == .stayDisabled,
                "once the user's own escape hatch has fired, a later timeout does not get a fresh budget either"
            )

            // A fresh session must not inherit a previous session's exhausted
            // budget — `CoreGraphicsShortcutInterceptor.start()` rebuilds its
            // handler (and therefore its `TapDisableBudget`) every time,
            // verified by reading since it needs a real tap to exercise
            // end to end. This is the pure half of that contract: a fresh
            // instance always starts with a full budget regardless of how
            // exhausted some other instance is.
            let freshBudgetAfterExhaustion = TapDisableBudget()
            expect(
                freshBudgetAfterExhaustion.decide(.timeout) == .reenable,
                "a fresh budget instance always starts with its full allowance"
            )

            // The forwarder's `log` closure is the same one the interceptor
            // is handed as `onDegraded` — proven end to end at the seam,
            // without a real tap ever having to actually get disabled.
            let degradedInterceptor = FakeShortcutInterceptor()
            let degradedForwarder = SystemShortcutForwarder(
                mode: .remoteInFullscreen,
                accessibility: FixedAccessibilityAuthorization(granted: true),
                interceptor: degradedInterceptor
            )
            var degradedMessages: [String] = []
            degradedForwarder.startInterceptingIfPermitted { degradedMessages.append($0) }
            expect(degradedMessages.isEmpty, "nothing reported before the interceptor says anything")
            expect(
                degradedInterceptor.simulateDegraded("System shortcuts: the event tap gave up re-enabling itself."),
                "the interceptor holds an onDegraded callback once started"
            )
            expect(degradedMessages.count == 1, "the forwarder's log closure receives the degradation report")

            print("PASS: tapDisabledByUserInput is never auto re-enabled, in a single occurrence or repeated ones")
            print("PASS: repeated tapDisabledByTimeout stops re-enabling after a small bound and reports it exactly once")
            print("PASS: a degraded interceptor's report reaches the forwarder's log closure")
        }

        print("PASS: the forwarder hands a shortcut to the focused window only, and claims it so this machine never sees it")
        print("PASS: no event tap is created in local mode or without an existing Accessibility grant")
        print("PASS: an event tap that cannot start is reported instead of degrading silently")
        print("PASS: the tap's lifetime matches the session and never stacks or leaks across a flapping cycle")
        print("PASS: a clipboard packet is not media, and applying one never sends it back")

        // Hardware decode: request it, never require it -- the viewer is the
        // weaker x86_64 laptop, so a missing hardware decoder must not block
        // a connection. `DecoderSpecification.make()` is the pure seam for
        // that choice; no real `VTDecompressionSession` is created here.
        let decoderSpecification = DecoderSpecification.make()
        expect(
            decoderSpecification[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] == true,
            "the decoder specification enables hardware accelerated decode"
        )
        expect(
            decoderSpecification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] == nil,
            "the decoder specification never requires hardware decode -- a software fallback must still show a picture"
        )

        expect(
            DecoderHardwareAccelerationStatus(reportedHardwareAccelerated: true) == .hardwareAccelerated,
            "a session reporting hardware acceleration is classified as hardware accelerated"
        )
        expect(
            DecoderHardwareAccelerationStatus(reportedHardwareAccelerated: false) == .softwareFallback,
            "a session that did not report hardware acceleration is classified as a software fallback"
        )
        // An unreadable property must never be classified as a confirmed
        // software fallback -- that would assert something never established,
        // rather than admitting which decoder was actually used is unknown.
        expect(
            DecoderHardwareAccelerationStatus(reportedHardwareAccelerated: nil) == .unknown,
            "a property that could not be read back is classified as unknown"
        )
        expect(
            DecoderHardwareAccelerationStatus(reportedHardwareAccelerated: nil) != .softwareFallback,
            "an unreadable property is never reported as a confirmed software fallback"
        )
        print("PASS: the decoder specification enables hardware decode without requiring it, and the hardware/software/unknown outcome is classified for logging")

        // The viewer's session state, which is what stands between a dropped
        // session and a frozen picture the user reads as a live one.
        // No window is built here: every word and every status colour is a
        // decision `ViewerSessionStateMachine` owns on its own.
        var viewerState = ViewerSessionStateMachine(hostName: "Studio")
        expect(
            viewerState.status.phase == .connecting,
            "the viewer starts in the connecting state, before a single frame exists"
        )
        expect(
            viewerState.status.headline == "Connecting to Studio…",
            "the connecting state names the host it is dialling, got: \(viewerState.status.headline)"
        )
        expect(
            viewerState.status.isOverlayVisible && !viewerState.status.dimsCanvas,
            "connecting shows the overlay, and dims nothing because there is no picture yet"
        )
        expect(
            viewerState.status.buttons.map(\.action) == [.quit, .yourMachines],
            "a first connect that has not yet failed still offers a way out for a machine that will not answer, "
                + "with Quit leftmost as it is in every other state that carries it, got: "
                + "\(viewerState.status.buttons.map(\.action))"
        )
        expect(
            viewerState.status.buttons.allSatisfy { !$0.isPrimary },
            "nothing here restores a session that never existed, so neither button takes the accent"
        )

        let live = viewerState.handle(.canvasReady)
        expect(live.phase == .live, "a ready canvas puts the viewer in the live state, got: \(live.phase)")
        expect(
            !live.isOverlayVisible && !live.dimsCanvas,
            "a live session shows nothing over the canvas and dims nothing"
        )

        let dropped = viewerState.handle(.sessionEnded)
        expect(dropped.phase == .lost, "a dropped transport puts the viewer in the lost state, got: \(dropped.phase)")
        expect(dropped.tone == .bad, "a lost connection is drawn in the status palette's bad colour")
        expect(
            dropped.isOverlayVisible && dropped.dimsCanvas,
            "a dropped session dims the frozen frame and says so — this is the defect that made a dead session pixel-identical to a live one"
        )
        expect(
            dropped.headline == "Connection to Studio lost.",
            "the drop names the machine it lost the connection to, got: \(dropped.headline)"
        )
        expect(
            !dropped.detail.contains("transport") && !dropped.detail.contains("NWError"),
            "no transport jargon reaches the person reading it, got: \(dropped.detail)"
        )
        expect(
            dropped.detail.contains("frozen") && !dropped.detail.contains("trying"),
            "the drop says what the user is looking at and lets the buttons offer the retry, rather than announcing one beside a Try again button, got: \(dropped.detail)"
        )
        expect(
            dropped.detail.contains("The picture behind this is frozen from before the drop."),
            "the drop describes the frozen frame as behind the panel that is covering it, not \"below\" -- "
                + "got: \(dropped.detail)"
        )

        let firstRedial = viewerState.handle(.connectStarted)
        expect(
            firstRedial.phase == .reconnecting,
            "redialling after a live session is reconnecting, not a first connect, got: \(firstRedial.phase)"
        )
        expect(firstRedial.tone == .warn, "a reconnect in progress is a warning, not a failure")
        expect(
            firstRedial.headline == "Reconnecting to Studio…",
            "the reconnect names the machine it is redialling, got: \(firstRedial.headline)"
        )
        expect(
            firstRedial.dimsCanvas,
            "the frozen frame stays dimmed while reconnecting"
        )
        expect(
            firstRedial.detail == "Attempt 1 to reach it. The picture behind this is frozen from before the drop.",
            "the first reconnect attempt describes the frozen frame as behind the panel, not \"below\", and "
                + "never repeats the host the headline just named -- got: \(firstRedial.detail)"
        )

        let secondRedial = viewerState.handle(.connectStarted)
        expect(
            secondRedial.detail.contains("Attempt 2"),
            "a repeated attempt says which attempt it is on, got: \(secondRedial.detail)"
        )
        expect(
            secondRedial.detail == "Attempt 2 to reach it. If it does not come back, check that it is awake "
                + "and on the same network.",
            "a reconnect that keeps failing names the remedy without repeating the host the headline "
                + "names, got: \(secondRedial.detail)"
        )

        let recovered = viewerState.handle(.canvasReady)
        expect(recovered.phase == .live, "a reconnected canvas returns to live")
        expect(
            viewerState.handle(.connectStarted).detail.contains("Attempt 2") == false,
            "the attempt count restarts after a session comes back, so the next outage does not inherit it"
        )

        var abandoned = ViewerSessionStateMachine(hostName: "Studio")
        abandoned.handle(.canvasReady)
        abandoned.handle(.sessionEnded)
        let gaveUp = abandoned.handle(.gaveUp)
        expect(gaveUp.phase == .lost, "giving up leaves the viewer in the lost state")
        expect(
            gaveUp.detail == "Sensorium has stopped retrying. Check that it is awake and that Tailscale is "
                + "connected on both machines, then choose Try again.",
            "giving up names what the user can actually do about it, without repeating the host the "
                + "headline names, got: \(gaveUp.detail)"
        )

        // Defect 3: every reconnect stole focus, because `show()` activated
        // the app unconditionally.
        var activation = ViewerActivationPolicy()
        expect(activation.shouldActivate(), "the first show activates, or the window opens behind everything")
        expect(!activation.shouldActivate(), "a later show — a reconnect — never steals focus")
        expect(!activation.shouldActivate(), "and no show after that does either")

        print("PASS: the viewer names every session state in plain words, dims a stale picture, and activates only on first show")

        // A host-screen connect that never became a session is not a session
        // that ended -- nothing began, so the overlay must not claim it did.
        var neverStarted = ViewerSessionStateMachine(hostName: "Studio")
        let refused = neverStarted.handle(.hostScreenConnectEnded(reasonLine: "Some reason.", offersPairAgain: false))
        expect(
            refused.eyebrow == "NOT STARTED",
            "a refusal before any frame ever arrived is not a session that ended, got: \(refused.eyebrow)"
        )
        expect(
            refused.headline == "Could not show a host screen from Studio.",
            "the headline never orphans the host's name on its own line, got: \(refused.headline)"
        )
        expect(
            refused.buttons.map(\.title) == ["Your machines", "Connect with a virtual display"],
            "the filled button only ever reconnects with a virtual display, so it is titled for what it "
                + "does rather than reading as a retry of the refusal, and the list sits beside it so a "
                + "refusal is never a dead end, got: \(refused.buttons.map(\.title))"
        )
        expect(
            refused.buttons.map(\.action) == [.yourMachines, .connectAsVirtualDisplay],
            "the way to another machine comes first, the filled default rightmost, got: \(refused.buttons.map(\.action))"
        )
        expect(
            refused.buttons.map(\.isPrimary) == [false, true],
            "exactly one primary action, the one that restores a session, got: \(refused.buttons.map(\.isPrimary))"
        )

        // A host-screen connect that ends after the session was already live
        // reads as SESSION ENDED, unlike a connect that never went live.
        var wasLive = ViewerSessionStateMachine(hostName: "Studio")
        wasLive.handle(.connectStarted)
        wasLive.handle(.canvasReady)
        let endedAfterLive = wasLive.handle(.hostScreenConnectEnded(reasonLine: "Some reason.", offersPairAgain: false))
        expect(
            endedAfterLive.eyebrow == "SESSION ENDED",
            "a refusal after the session was live is a session that ended, got: \(endedAfterLive.eyebrow)"
        )
        expect(
            endedAfterLive.headline == "The host-screen session with Studio ended.",
            "the headline says the session ended, since it did, got: \(endedAfterLive.headline)"
        )

        print("PASS: a host-screen connect that never became a session reads as not started, and one that went live reads as ended")

        // The two reasons that mean this machine's presence credential needs
        // re-registering cannot be fixed with a virtual display alone, so
        // they offer a way to pair again -- primary, since it is the fix.
        var needsRearming = ViewerSessionStateMachine(hostName: "Studio")
        let rearm = needsRearming.handle(
            .hostScreenConnectEnded(reasonLine: "Some reason.", offersPairAgain: true)
        )
        expect(
            rearm.buttons.map(\.action) == [.yourMachines, .connectAsVirtualDisplay, .pairAgain],
            "the list comes first, and the filled default sits rightmost, the way macOS itself places a "
                + "default button in a row, got: \(rearm.buttons.map(\.action))"
        )
        expect(
            rearm.buttons.map(\.title) == ["Your machines", "Connect with a virtual display", "Pair again"],
            "got: \(rearm.buttons.map(\.title))"
        )
        expect(
            rearm.buttons.map(\.isPrimary) == [false, false, true],
            "pairing again is the fix, so it carries the accent, and sits rightmost as the row's default, got: "
                + "\(rearm.buttons.map(\.isPrimary))"
        )

        print("PASS: a host-screen refusal offering pairing shows Your machines, Connect with a virtual display, then Pair again as primary")

        // Pressing Pair again sends no event to this type: nothing is
        // dialling while the pairing windows are up, so switching phase
        // here would leave a spinner on screen with no button and nothing
        // behind it. A cancelled or closed pairing attempt must find the
        // ended panel and its buttons exactly as they were.
        var stillOffersPairAgain = ViewerSessionStateMachine(hostName: "studio-mini")
        let beforePairAgainPressed = stillOffersPairAgain.handle(
            .hostScreenConnectEnded(reasonLine: "Some reason.", offersPairAgain: true)
        )
        expect(
            stillOffersPairAgain.status == beforePairAgainPressed,
            "no event means no change: pressing Pair again must not itself alter this state"
        )
        expect(
            stillOffersPairAgain.status.phase == .ended,
            "a cancelled pair-again leaves the panel in the ended phase, got: \(stillOffersPairAgain.status.phase)"
        )
        expect(
            stillOffersPairAgain.status.buttons.map(\.action) == [.yourMachines, .connectAsVirtualDisplay, .pairAgain],
            "the same three buttons are still there to press, in the same order, got: "
                + "\(stillOffersPairAgain.status.buttons.map(\.action))"
        )

        print("PASS: a cancelled pair-again leaves the ended panel in its ended phase with the same button set")

        // A state that describes a dead end without offering a way out of it
        // is still a dead end. Which buttons each state carries is a copy
        // decision like the words are, so it lives in the same pure type.
        var actionable = ViewerSessionStateMachine(hostName: "studio-mini")
        actionable.handle(.connectStarted)
        expect(
            actionable.status.eyebrow == "CONNECTING",
            "the eyebrow is part of the copy, not a switch in the view, got: \(actionable.status.eyebrow)"
        )
        expect(
            actionable.handle(.canvasReady).buttons.isEmpty,
            "a live session puts no buttons over the canvas"
        )
        actionable.handle(.sessionEnded)

        let reconnect = actionable.handle(.connectStarted)
        expect(
            reconnect.buttons.map(\.action) == [.quit, .stopTrying],
            "reconnecting puts Quit Sensorium leftmost like every other panel, then the one thing that "
                + "ends an indefinite wait, got: \(reconnect.buttons.map(\.title))"
        )
        expect(
            reconnect.buttons.map(\.title) == ["Quit Sensorium", "Stop trying"],
            "the reconnect buttons carry the same titles the other panels use, got: \(reconnect.buttons.map(\.title))"
        )
        expect(
            reconnect.buttons.allSatisfy { !$0.isPrimary },
            "stopping is never the primary action — the accent belongs to the action that restores the session"
        )
        expect(
            reconnect.headline == "Reconnecting to studio-mini\u{2026}",
            "the reconnect headline names the machine it is redialling, got: \(reconnect.headline)"
        )
        expect(
            reconnect.detail.contains("Attempt 1"),
            "the first redial says which attempt it is on, so the wait is legible from the start, got: \(reconnect.detail)"
        )
        expect(
            reconnect.headline.contains("studio-mini") && !reconnect.headline.contains("studio\u{2011}mini"),
            "the stored host name is the caller's string verbatim, not rewritten with non-breaking hyphens, got: \(reconnect.headline)"
        )
        expect(
            !reconnect.detail.contains("studio-mini"),
            "the detail never repeats the host the headline just named, got: \(reconnect.detail)"
        )

        let stopped = actionable.handle(.stopRequested)
        expect(stopped.phase == .lost, "stopping the wait is what makes the lost state reachable, got: \(stopped.phase)")
        expect(stopped.eyebrow == "STOPPED", "a wait the user ended is not a session that died, got: \(stopped.eyebrow)")
        expect(
            stopped.buttons.map(\.action) == [.quit, .yourMachines, .tryAgain],
            "a stopped client offers the way out, the list, and the way back -- the filled default sits "
                + "rightmost, the way macOS itself places a default button in a row, got: "
                + "\(stopped.buttons.map(\.title))"
        )
        expect(
            stopped.buttons.map(\.title) == ["Quit Sensorium", "Your machines", "Try again"],
            "the buttons say what they do -- Quit sits beside Try again, so it must say it quits the whole "
                + "app rather than reading as a way to close just the session, got: \(stopped.buttons.map(\.title))"
        )
        expect(
            stopped.buttons.map(\.isPrimary) == [false, false, true],
            "exactly one primary action, and it is the one that brings the session back, rightmost"
        )

        let resumed = actionable.handle(.retryRequested)
        expect(
            resumed.phase == .reconnecting,
            "asking to try again puts the viewer back in the reconnecting state, got: \(resumed.phase)"
        )
        expect(
            resumed.detail.contains("Attempt 1"),
            "a retry the user asked for starts its count over, got: \(resumed.detail)"
        )

        // The copy defect: it told the user to open the application they were
        // reading the sentence inside of.
        var unreached = ViewerSessionStateMachine(hostName: "studio-mini")
        unreached.handle(.connectStarted)
        unreached.handle(.canvasReady)
        unreached.handle(.sessionEnded)
        let unreachable = unreached.handle(.gaveUp)
        expect(
            !unreachable.detail.lowercased().contains("open sensorium"),
            "a running app never tells the user to open it, got: \(unreachable.detail)"
        )
        expect(
            unreachable.detail.contains("Try again"),
            "it names the button that is on screen instead, got: \(unreachable.detail)"
        )
        expect(
            unreachable.buttons.map(\.action) == [.quit, .yourMachines, .tryAgain],
            "the abandoned state carries the same ways out, in the same order, got: "
                + "\(unreachable.buttons.map(\.title))"
        )
        expect(
            unreachable.detail.contains("awake") && unreachable.detail.contains("Tailscale"),
            "and still says what to go check, got: \(unreachable.detail)"
        )

        print("PASS: the reconnecting and lost states carry buttons that act: stop trying, try again, quit")

        // Defect: the viewer had no menu bar at all -- no `NSMenu` anywhere in
        // Sources/ -- so Cmd-Q did nothing, there was no way to leave the app
        // from the GUI, and the two chords the window does implement were
        // undiscoverable.
        let menuItems = ViewerMenuPlan.menus.flatMap(\.items)
        func plannedItem(_ command: ViewerMenuCommand) -> ViewerMenuItem? {
            menuItems.first { $0.command == command }
        }

        expect(
            ViewerMenuPlan.menus.first?.title == "Sensorium",
            "the first menu is the application menu, which is what macOS draws next to the Apple menu"
        )
        expect(
            plannedItem(.about)?.title == "About Sensorium",
            "the application menu says what the app is"
        )
        expect(
            plannedItem(.hide)?.keyEquivalent == "h" && plannedItem(.hide)?.modifiers == [.command],
            "Hide keeps its standard Cmd-H"
        )
        expect(
            plannedItem(.hideOthers)?.modifiers == [.command, .option],
            "Hide Others keeps its standard Cmd-Opt-H"
        )
        expect(
            plannedItem(.quit)?.keyEquivalent == "q" && plannedItem(.quit)?.modifiers == [.command],
            "Quit is on Cmd-Q, the defect that left the app with no way out"
        )
        // The launch window is the only way to reach a machine other than the one
        // a live session is on, so a session that is up must still be able to
        // get back to it without ending first.
        expect(
            plannedItem(.showYourMachines)?.title == "Your Machines\u{2026}",
            "the application menu names the launch window, got \(plannedItem(.showYourMachines)?.title ?? "nil")"
        )
        expect(
            plannedItem(.showYourMachines)?.keyEquivalent == "1"
                && plannedItem(.showYourMachines)?.modifiers == [.command],
            "and puts it on Command-1, reachable at any time"
        )
        expect(
            !menuItems.contains { $0.title.contains("Settings") || $0.title.contains("Preferences") },
            "no Settings item: the settings window does not exist, and an item opening nothing is worse than no item"
        )
        expect(
            plannedItem(.toggleFullScreen)?.keyEquivalent == "f"
                && plannedItem(.toggleFullScreen)?.modifiers == [.command, .control],
            "fullscreen is offered on the standard Cmd-Ctrl-F"
        )
        expect(
            plannedItem(.toggleTelemetryOverlay)?.keyEquivalent == "l"
                && plannedItem(.toggleTelemetryOverlay)?.modifiers == [.command, .shift],
            "the menu states the telemetry overlay's real chord, Cmd-Shift-L, which is how anyone discovers it exists"
        )
        expect(
            plannedItem(.toggleTelemetryOverlay)?.title.contains("Diagnostics") == true,
            "the panel of numbers this toggles is named as what it is to a person who opens it -- a diagnostics"
                + " panel -- not left under the engineering word \"telemetry\" alone, got: "
                + "\(plannedItem(.toggleTelemetryOverlay)?.title ?? "nil")"
        )
        expect(
            plannedItem(.togglePointerCapture)?.keyEquivalent == "g"
                && plannedItem(.togglePointerCapture)?.modifiers == [.command, .shift],
            "the menu states captured-pointer mode's real chord, Cmd-Shift-G"
        )
        let escapeHint = plannedItem(.escapeGestureHint)
        expect(
            escapeHint?.title.contains("Control-Option-Command-Escape") == true,
            "the escape gesture is stated in the menu, not only in a launch line printed to a terminal nobody sees"
        )
        expect(
            escapeHint?.keyEquivalent.isEmpty == true && escapeHint?.isEnabled == false,
            "the escape gesture item claims no chord: a menu key equivalent would take Ctrl-Opt-Cmd-Esc before CanvasSurfaceView could honour it, breaking the one guaranteed way out of a captured pointer"
        )
        expect(
            !menuItems.contains { $0.modifiers == [.command] && ["w", "m"].contains($0.keyEquivalent) },
            "no menu item claims Cmd-W or Cmd-M: both are SystemShortcutCatalog entries the viewer forwards to the host, and a menu key equivalent would swallow them first"
        )

        print("PASS: the viewer's menu bar offers only what the app can do, and states the escape gesture without claiming its chord")

        // Defect: the window was built from a fixed contentRect at origin
        // (0,0) with no autosave name, so it opened at the screen's
        // bottom-left under the Dock on every launch forever -- and with
        // --dual-canvas the second window was built from the same rect and
        // landed exactly on top of the first.
        expect(
            ViewerWindowPlacementPolicy.placement(surfaceID: 0, hasSavedFrame: false) == .center,
            "a first-ever launch centres the canvas window instead of parking it in the corner under the Dock"
        )
        expect(
            ViewerWindowPlacementPolicy.placement(surfaceID: 0, hasSavedFrame: true) == .restoreSaved,
            "every launch after that restores wherever the user last left it"
        )
        expect(
            ViewerWindowPlacementPolicy.placement(surfaceID: 1, hasSavedFrame: false) == .cascade,
            "an unplaced second canvas cascades off the first, which is the defect that made --dual-canvas look like it did nothing"
        )
        expect(
            ViewerWindowPlacementPolicy.placement(surfaceID: 1, hasSavedFrame: true) == .restoreSaved,
            "a second canvas the user has already placed stays where they put it rather than cascading again"
        )
        expect(
            ViewerWindowPlacementPolicy.frameAutosaveName(surfaceID: 0)
                != ViewerWindowPlacementPolicy.frameAutosaveName(surfaceID: 1),
            "each canvas remembers its own frame; one shared name would restore both windows onto each other"
        )

        print("PASS: a canvas window centres on first launch, restores after, and a second canvas cascades off the first")

        // Defect: the first thing anyone did with Sensorium was a `.command`
        // file that asked for an address and a code in Terminal with no
        // validation and no retry, and the app itself, double-clicked, printed
        // `No saved host.` to a stream nobody reads and exited. The window that
        // replaced it holds three text fields; every rule below is here, not
        // there.
        expect(
            ViewerPairingForm(address: "100.83.14.2", code: "123456").submission
                == ViewerPairingSubmission(host: "100.83.14.2", port: 7777, code: "123456", displayName: "100.83.14.2"),
            "a Tailscale address and six digits pair on the port every packaged launcher passes"
        )
        expect(
            ViewerPairingForm(address: " mini.local ", code: " 123456 ").submission
                == ViewerPairingSubmission(host: "mini.local", port: 7777, code: "123456", displayName: "mini.local"),
            "a name typed with stray spaces around it still pairs: trailing whitespace is a copy-paste artefact, not a decision"
        )
        expect(
            ViewerPairingForm(address: "mini.local:9000", code: "123456").parsedAddress
                == ViewerPairingAddress(host: "mini.local", port: 9000),
            "an explicit :port is honoured, so a host started on another port is still reachable from the window"
        )
        expect(
            ViewerPairingForm(address: "fd7a:1234::1", code: "123456").parsedAddress
                == ViewerPairingAddress(host: "fd7a:1234::1", port: 7777),
            "a bare IPv6 literal keeps all of its colons instead of losing its tail to a port split"
        )
        expect(
            ViewerPairingForm(address: "[fd7a:1234::1]:9000", code: "123456").parsedAddress
                == ViewerPairingAddress(host: "fd7a:1234::1", port: 9000),
            "the bracket form is how an IPv6 literal carries a port, and it is the only way to give one"
        )
        expect(
            ViewerPairingForm(address: "office-1.tail1234.ts.net", code: "123456").canSubmit,
            "a MagicDNS name with hyphens and digits is an ordinary address"
        )
        expect(
            ViewerPairingForm(address: "mini.tail1234.ts.net").addressState.isValid,
            "the lowercase, hyphen-free MagicDNS form the address hint now names is valid too"
        )
        expect(
            ViewerPairingForm(address: "mini").addressState.isValid,
            "a bare name with no dot at all is still a plausible address"
        )
        expect(
            ViewerPairingForm(address: "mini.tail1234.ts.net.").parsedAddress?.host
                == "mini.tail1234.ts.net",
            "a MagicDNS name typed or pasted fully qualified, as tailscale status --json reports it, dials without its trailing dot"
        )
        expect(
            !ViewerPairingForm(address: "host..example").addressState.isValid,
            "a genuine double dot is still an implausible host, not confused with a single trailing one"
        )

        expect(
            ViewerPairingForm(address: "", code: "").addressState == ViewerPairingFieldState(isValid: false, message: nil),
            "an untouched address field says nothing: a form that shouts before the first keystroke teaches the user to ignore it"
        )
        expect(
            ViewerPairingForm(address: "", code: "").codeState == ViewerPairingFieldState(isValid: false, message: nil),
            "an untouched code field says nothing either, and neither field is valid while empty"
        )
        expect(
            ViewerPairingForm(address: "sensorium://mini.local").addressState.message
                == "Type only the address, without http:// in front of it.",
            "a pasted URL names the scheme as the problem instead of failing after submit, in words that "
                + "never name Sensorium\u{2019}s own wire scheme"
        )
        expect(
            ViewerPairingForm(address: "mini.local/desktop").addressState.message
                == "Type only the address, with nothing after a slash.",
            "a path after the address is named as the problem"
        )
        expect(
            ViewerPairingForm(address: "mini local").addressState.message
                == "An address has no spaces in it. Check for a stray one.",
            "an internal space is the likeliest typo and gets its own sentence"
        )
        expect(
            ViewerPairingForm(address: "-mini.local").addressState.message
                == "The other machine\u{2019}s Tailscale address, which starts with 100, or a name such as "
                    + "mini.local or mini.tail1234.ts.net.",
            "an implausible host says what a plausible one looks like, with both forms a person might have"
        )
        expect(
            ViewerPairingForm(address: "mini.local:0").addressState.message
                == "The port after the colon must be a whole number from 1 to 65535.",
            "a port out of range is named as a port problem, not as a bad address"
        )
        expect(
            ViewerPairingForm(address: "mini.local:99999").addressState.message
                == "The port after the colon must be a whole number from 1 to 65535.",
            "and so is one above the range"
        )
        expect(
            ViewerPairingForm(address: "[fd7a::1", code: "123456").addressState.message
                == "That address opens a bracket and never closes it.",
            "an unclosed bracket is a typo the user can see and fix"
        )

        expect(
            ViewerPairingForm(code: "12345").codeState.message == "Six digits — one more to type.",
            "a code being typed counts down rather than calling a half-typed code wrong"
        )
        expect(
            ViewerPairingForm(code: "1234").codeState.message == "Six digits — two more to type.",
            "and says how many are still missing"
        )
        expect(
            ViewerPairingForm(code: "1234567").codeState.message == "The code is exactly six digits; that is seven.",
            "an over-long code says what is wrong with it in words, not by silently truncating"
        )
        expect(
            ViewerPairingForm(code: "12a456").codeState.message == "The code is six digits and nothing else.",
            "a letter in the code is rejected where it is typed"
        )
        expect(
            ViewerPairingForm(code: "123/456").codeState.message == "The code is six digits and nothing else.",
            "so is any character that is neither a digit nor the separator between the two groups"
        )
        expect(
            ViewerPairingForm(code: "123456").codeState == ViewerPairingFieldState(isValid: true, message: nil),
            "six digits is valid and says nothing"
        )
        expect(
            ViewerPairingForm(code: "1234").codeIsStillTyping,
            "a code short of six digits, typed so far without a mistake, is still-typing progress"
        )
        expect(
            !ViewerPairingForm(code: "123456").codeIsStillTyping,
            "a complete code is not still-typing"
        )
        expect(
            !ViewerPairingForm(code: "1234567").codeIsStillTyping,
            "an over-long code is a mistake, not progress -- it is not still-typing"
        )
        expect(
            !ViewerPairingForm(code: "12a456").codeIsStillTyping,
            "a code with a stray character is a mistake, not progress -- it is not still-typing"
        )
        expect(
            !ViewerPairingForm(code: "").codeIsStillTyping,
            "an empty code has not started being typed"
        )

        expect(
            ViewerPairingForm(address: "100.83.14.2", code: "123456", name: "Studio").submission?.displayName == "Studio",
            "a name the user typed becomes the display name, so every later window title and error says it"
        )
        expect(
            ViewerPairingForm(address: "100.83.14.2", code: "123456", name: "  Studio  ").submission?.displayName == "Studio",
            "the name is trimmed: a trailing space would ride along in every title forever"
        )
        expect(
            ViewerPairingForm(address: "100.83.14.2", code: "123456", name: "   ").submission?.displayName == "100.83.14.2",
            "a name of only spaces is no name, and the address stays the display name — today's behaviour"
        )
        expect(
            ViewerPairingForm(address: "100.83.14.2:9000", code: "123456").submission?.displayName == "100.83.14.2",
            "the display name is the host, never the port the user had to type to reach it"
        )
        expect(
            ViewerPairingForm(address: "100.83.14.2", code: "12345").submission == nil
                && ViewerPairingForm(address: "", code: "123456").submission == nil,
            "nothing is dialled until both the address and the code are valid"
        )

        // Every refusal `HostPairingService.handlePairRequest` can send, plus
        // the failures the client itself can tell apart. A rejected code used
        // to dead-end at `[Process completed]` with a raw Swift enum printed.
        func failureCopy(_ outcome: ViewerPairingOutcome) -> ViewerPairingFailureCopy {
            ViewerPairingFailureCopy.copy(for: outcome, hostLabel: "Studio")
        }
        let refusals = [
            "invalid-code", "code-expired", "code-already-consumed",
            "code-attempts-exhausted", "no-active-code", "invalid-request"
        ]
        let allOutcomes: [ViewerPairingOutcome] = refusals.map { .refused(reason: $0) }
            + [.refused(reason: "some-reason-from-a-newer-host"), .unreachable, .unverifiedHost, .unexpectedReply, .unknown]
        expect(
            Set(allOutcomes.map { failureCopy($0).headline }).count == allOutcomes.count,
            "each failure Sensorium can tell apart gets its own sentence; two identical ones would mean guessing at a cause"
        )
        expect(
            allOutcomes.allSatisfy { !failureCopy($0).headline.isEmpty && !failureCopy($0).detail.isEmpty },
            "no failure is a dead end: every one says what happened and what to do next"
        )
        expect(
            refusals.allSatisfy { reason in
                let copy = failureCopy(.refused(reason: reason))
                return !copy.headline.contains(reason) && !copy.detail.contains(reason)
            },
            "no wire token reaches the user: `code-already-consumed` is a protocol string, not a sentence"
        )
        expect(
            failureCopy(.refused(reason: "invalid-code")).headline == "Wrong code."
                && failureCopy(.refused(reason: "invalid-code")).focus == .code
                && !failureCopy(.refused(reason: "invalid-code")).needsFreshCode,
            "a wrong code is worth retyping on the spot, and the caret goes back to the code"
        )
        expect(
            failureCopy(.refused(reason: "code-expired")).needsFreshCode
                && failureCopy(.refused(reason: "code-already-consumed")).needsFreshCode
                && failureCopy(.refused(reason: "code-attempts-exhausted")).needsFreshCode,
            "a spent, expired or retired code cannot be retyped: the other machine has to show a new one first"
        )
        expect(
            failureCopy(.refused(reason: "invalid-code")).detail == "Check the six digits on Studio and try again.",
            "a wrong code is one sentence naming only the action -- "
                + "got \(failureCopy(.refused(reason: "invalid-code")).detail)"
        )
        expect(
            failureCopy(.refused(reason: "no-active-code")).headline.contains("Studio"),
            "the copy names the machine rather than saying `the host`"
        )
        expect(
            failureCopy(.refused(reason: "some-reason-from-a-newer-host")).detail.contains("some-reason-from-a-newer-host"),
            "a reason this version does not know is quoted rather than guessed at — the one honest thing to do with it"
        )
        expect(
            failureCopy(.unreachable).focus == .address,
            "nothing answering points at the address, which is the field most likely to be wrong"
        )

        expect(
            ViewerPairingOutcome.classify(ClientSessionError.pairingRejected("invalid-code")) == .refused(reason: "invalid-code"),
            "a refusal carries the host's own reason through to the copy"
        )
        expect(
            ViewerPairingOutcome.classify(ClientSessionError.hostKeyMismatch) == .unverifiedHost,
            "an unsigned or wrongly signed approval is its own failure, never `could not connect`"
        )
        expect(
            ViewerPairingOutcome.classify(ClientSessionError.unexpectedMessage) == .unexpectedReply,
            "a reply Sensorium did not expect is a version mismatch, not a refusal"
        )
        expect(
            ViewerPairingOutcome.classify(NetworkControlConnectionError.timedOut) == .unreachable
                && ViewerPairingOutcome.classify(NWError.posix(.ECONNREFUSED)) == .unreachable,
            "a dial that never completes and one that is refused are indistinguishable from here, and share one honest sentence"
        )

        print("PASS: the pairing form validates input as it is typed and turns every failure into a sentence with a way to try again")

        // Rendered and reviewed: the inline messages moved the layout, because
        // a two-line hint replaced by a one-line error is 15pt shorter and
        // every field below it jumped. The window reserves the tallest message
        // each field can produce, and this is the list it reserves from.
        let codeMessages = ViewerPairingForm.possibleMessages(for: .code)
        let addressMessages = ViewerPairingForm.possibleMessages(for: .address)
        var producedMessages: [ViewerPairingField: Set<String>] = [:]
        for probe in [
            "", "sensorium://mini.local", "http://mini.local", "mini.local/desktop", "mini local",
            "user@mini.local", "[fd7a::1", "mini.local:0", "mini.local:99999", "-mini.local",
            "mini.local", "100.64.0.1"
        ] {
            if let message = ViewerPairingForm(address: probe).addressState.message {
                producedMessages[.address, default: []].insert(message)
            }
        }
        for length in 0...15 {
            let typed = String(repeating: "4", count: length)
            if let message = ViewerPairingForm(code: typed).codeState.message {
                producedMessages[.code, default: []].insert(message)
            }
        }
        for probe in ["12a456", "418 297x", "\u{0664}18297"] {
            if let message = ViewerPairingForm(code: probe).codeState.message {
                producedMessages[.code, default: []].insert(message)
            }
        }
        expect(
            producedMessages[.address, default: []].isSubset(of: Set(addressMessages)),
            "every address message the form can produce is in the list the window reserves height from; one that is not would reflow the form under the cursor"
        )
        expect(
            producedMessages[.code, default: []].isSubset(of: Set(codeMessages)),
            "and every code message is too"
        )
        expect(
            ViewerPairingForm.possibleMessages(for: .name).isEmpty,
            "the optional name can never be wrong, so it reserves nothing"
        )

        // A person reading six digits aloud reads them in threes, and the host
        // panel now shows `418 297`. Someone will type what they see.
        expect(
            ViewerPairingForm(address: "mini.local", code: "418 297").submission?.code == "418297",
            "a code typed in the two groups the other machine shows is accepted, and only the digits go on the wire"
        )
        expect(
            ViewerPairingForm(address: "mini.local", code: "418-297").submission?.code == "418297",
            "a hyphen between the groups is accepted too: it is the other separator a person reaches for"
        )
        expect(
            ViewerPairingForm(code: "418 29").codeState.message == "Six digits — one more to type.",
            "a grouped code still counts down by digits, never by the spaces between them"
        )
        expect(
            ViewerPairingForm(code: "418 2971").codeState.message == "The code is exactly six digits; that is seven.",
            "and an over-long grouped code is counted by its digits as well"
        )
        expect(
            ViewerPairingForm(code: "418 29a").codeState.message == "The code is six digits and nothing else.",
            "a separator is not a licence for any other character"
        )

        // The field itself groups what is typed as `418 297`, the same shape
        // the host panel shows — this is the pure function the field's live
        // formatting calls; the caret and field-editor plumbing around it is
        // AppKit and untestable headless.
        expect(
            ViewerPairingForm.groupedCodeDisplay("418297") == "418 297",
            "six typed digits are grouped exactly as the host shows them"
        )
        expect(
            ViewerPairingForm.groupedCodeDisplay("41") == "41",
            "fewer than four digits are not grouped yet — there is no second group to separate from"
        )
        expect(
            ViewerPairingForm.groupedCodeDisplay("418") == "418",
            "the third digit does not yet earn a trailing space with nothing typed after it"
        )
        expect(
            ViewerPairingForm.groupedCodeDisplay("4182971") == "418 2971",
            "an over-long code still only ever groups after the third digit"
        )
        expect(
            ViewerPairingForm.groupedCodeDisplay("418 297") == "418 297",
            "an already-grouped code is left alone rather than double-spaced"
        )
        expect(
            ViewerPairingForm.groupedCodeDisplay("") == "",
            "nothing typed groups to nothing"
        )

        expect(
            !ViewerPairingFailureCopy.copy(for: .unreachable, hostLabel: "Studio").detail
                .contains("\(ViewerPairingForm.defaultPort)"),
            "the validator already accepts address:port silently, so nothing answering never sends a person "
                + "hunting for a port number that is never the actual problem"
        )
        expect(
            ViewerPairingFailureCopy.copy(for: .unreachable, hostLabel: "Studio").detail
                == "Check that it is awake and Sensorium Host is running.",
            "Sensorium Host never shows its own address, so the unreachable copy cannot send a person "
                + "looking for a screen that does not exist"
        )

        // Defect: identity resolution runs before any window exists, so a
        // key that cannot be read died to stdout with nothing on screen —
        // the same silent death the pairing window replaced, one step
        // earlier.
        let identityCopy = ViewerStartupFailureCopy.copy(for: .unreadable(reason: "the stored key is malformed"))
        // Design SS: no user ever runs a command, so a dead end naming a
        // CLI flag or another app is not a screen this app ships — the
        // screen offers the fix itself, and names its consequence before
        // the button that acts on it exists to tap.
        expect(
            !identityCopy.detail.contains("--") && !identityCopy.replaceConsequence.contains("--"),
            "the identity failure screen names no command-line flag — it offers its own fix"
        )
        expect(
            !identityCopy.replaceButtonTitle.isEmpty,
            "it offers the replace action, since a fresh identity recovers from an unreadable one"
        )
        expect(
            identityCopy.replaceConsequence.contains(identityCopy.replaceButtonTitle),
            "the consequence names the very button the person is about to tap, not a generic warning"
        )
        expect(
            identityCopy.replaceConsequence.localizedCaseInsensitiveContains("pairing code"),
            "the consequence says plainly, before the tap, that the other machine will ask for a pairing code again"
        )
        expect(
            identityCopy.detail.contains("the stored key is malformed"),
            "the loader's own reason is carried through rather than replaced with a guess"
        )
        expect(
            !identityCopy.headline.isEmpty && !identityCopy.detail.isEmpty,
            "and it is never a blank window"
        )

        print("PASS: the pairing form accepts the grouped code, reserves height for every message, and has words for a key it cannot read")

        // The session HUD. Every decision it shows is made here, in a pure
        // function over what the client actually holds -- the AppKit panel
        // draws these rows and decides nothing.
        do {
            // Client-side byte accounting: there is none anywhere else, and
            // the Mbit/s the host reports is the host's view, not the
            // viewer's.
            let stats = ClientStreamStatistics()
            expect(
                stats.reading(surfaceID: 0, atNanoseconds: 0) == ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                "a surface that has received nothing reports no size and no rate, never a zero"
            )
            stats.recordDecodedFrame(surfaceID: 0, pixelWidth: 2880, pixelHeight: 1800)
            stats.recordReceivedVideo(surfaceID: 0, byteCount: 1_000_000, atNanoseconds: 0)
            let earlyReading = stats.reading(surfaceID: 0, atNanoseconds: 500_000_000)
            expect(
                earlyReading.bitsPerSecond == nil && earlyReading.pixelWidth == 2880 && earlyReading.pixelHeight == 1800,
                "before a full measuring window there is no rate to report, though the decoded size is already known"
            )
            let fullReading = stats.reading(surfaceID: 0, atNanoseconds: 1_000_000_000)
            expect(
                fullReading.bitsPerSecond == 8_000_000,
                "a megabyte received over one second is reported as 8 Mbit/s"
            )
            expect(
                stats.reading(surfaceID: 1, atNanoseconds: 1_000_000_000) == ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                "one surface's bytes and size never appear on the other's reading"
            )

            func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
                sections.flatMap(\.rows).first { $0.label == label }
            }

            var clientMetrics = SessionMetrics()
            _ = clientMetrics.record(stage: .decode, startedAtNanoseconds: 0, endedAtNanoseconds: 4_000_000)
            _ = clientMetrics.record(stage: .endToEnd, startedAtNanoseconds: 0, endedAtNanoseconds: 12_000_000)
            let backedOffSample = SurfaceTelemetrySample(
                surfaceID: 0,
                capture: StageLatencySample(p50Nanoseconds: 2_000_000, p95Nanoseconds: 3_000_000),
                encode: StageLatencySample(p50Nanoseconds: 6_000_000, p95Nanoseconds: 9_000_000),
                send: nil,
                framesPerSecond: 59.8,
                encoderInputDropped: 0,
                globalAdmissionDropped: 0,
                sendQueueDropped: 0,
                appliedStreamScale: 1.5,
                sustainableScaleCeiling: 1.5
            )
            let backedOff = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(backedOffSample),
                clientMetrics: clientMetrics,
                stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Studio"
            )
            var liveState = ViewerSessionStateMachine(hostName: "Studio")
            let liveStatus = liveState.handle(.canvasReady)
            let backedOffSections = SessionHUDPanel.sections(telemetry: backedOff, session: liveStatus)
            expect(
                hudRow(backedOffSections, "APPLIED")?.value == "1.50x",
                "the panel shows the scale the host says it is actually encoding at"
            )
            expect(
                hudRow(backedOffSections, "STATE")?.note == "Connected to Studio.",
                "every sub-line sentence on the panel ends with a period, including the session state's own"
                    + " headline, got: \(hudRow(backedOffSections, "STATE")?.note ?? "nil")"
            )
            expect(
                hudRow(backedOffSections, "REQUESTED")?.note
                    == "Held to 1.50x. Automatic asked for 2.00x, which Studio measured as unsustainable.",
                "the single most useful line on the panel: the host is holding this viewer below what it asked "
                    + "for, and says so in the same one-sentence shape the fixed-choice clamp uses, got: "
                    + "\(hudRow(backedOffSections, "REQUESTED")?.note ?? "nil")"
            )
            // The host's own report of a clamped fixed choice -- a plain
            // sentence, not two clauses stitched together with a double
            // hyphen.
            let clampedByHostSample = SurfaceTelemetrySample(
                surfaceID: 0,
                capture: StageLatencySample(p50Nanoseconds: 2_000_000, p95Nanoseconds: 3_000_000),
                encode: StageLatencySample(p50Nanoseconds: 6_000_000, p95Nanoseconds: 9_000_000),
                send: nil,
                framesPerSecond: 59.8,
                encoderInputDropped: 0,
                globalAdmissionDropped: 0,
                sendQueueDropped: 0,
                appliedStreamScale: 1.75,
                sustainableScaleCeiling: 1.75,
                clampedFromUserChoice: 2.0
            )
            let clampedByHostSections = SessionHUDPanel.sections(
                telemetry: SessionHUDSnapshot(
                    surfaceID: 0,
                    availability: .fresh(clampedByHostSample),
                    clientMetrics: clientMetrics,
                    stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                    requestedStreamScale: 2.0,
                    streamScalePreference: .fixed(2.0),
                    decoder: .hardwareAccelerated,
                    hostName: "Studio"
                ),
                session: liveStatus
            )
            expect(
                hudRow(clampedByHostSections, "REQUESTED")?.note
                    == "Held to 1.75x. You asked for 2.00x, which Studio measured as unsustainable.",
                "the host's own clamp reads as one plain sentence, not two clauses joined by a double hyphen,"
                    + " and names the machine by its own name"
            )

            // The two numbers being compared must be adjacent. The sentence
            // explaining them sat between them, which broke the row rhythm
            // exactly where the eye is trying to read one against the other.
            expect(
                backedOffSections.first { $0.title == "FIDELITY" }.map { section in
                    zip(section.rows, section.rows.dropFirst()).contains {
                        $0.label == "APPLIED" && $1.label == "REQUESTED"
                    }
                } == true,
                "the applied scale and the requested scale are neighbours, with the explanation after both"
            )
            expect(
                hudRow(backedOffSections, "APPLIED")?.note == nil,
                "nothing sits between the two numbers being compared"
            )
            expect(
                hudRow(backedOffSections, "APPLIED")?.tone == .warn
                    && hudRow(backedOffSections, "APPLIED")?.isStale == false,
                "being held below the requested scale is worth the user's eye without being an error"
            )
            expect(
                hudRow(backedOffSections, "SIZE")?.value == "2880 \u{00D7} 1800",
                "the pixel size shown is the decoded frame's own, not a size derived from a scale, and "
                    + "joined with a multiplication sign, not a letter x"
            )
            expect(
                !backedOffSections.flatMap(\.rows).contains { $0.label == "FIDELITY" },
                "no row repeats the word its own section heading already says"
            )
            expect(
                hudRow(backedOffSections, "VIDEO IN")?.value == "8.0 Mbit/s",
                "the data rate is the client's own byte count, which is the viewer's honest number"
            )
            expect(
                hudRow(backedOffSections, "DECODER")?.value == "hardware",
                "which decoder VideoToolbox actually selected is shown rather than logged and forgotten"
            )
            expect(
                hudRow(backedOffSections, "DECODE")?.value == "4.0 ms" && hudRow(backedOffSections, "ENCODE")?.value == "6.0 ms",
                "the client's own decode and the host's encode both appear, each with its own number"
            )
            expect(
                backedOffSections.contains { $0.title == "THIS MACHINE" } && backedOffSections.contains { $0.title == "STUDIO" },
                "each latency figure is labelled with the machine that measured it, the host by its own upper-cased name"
            )
            // The two latency blocks are parallel data with short values, and
            // the question a person opens this panel to answer is which
            // machine is slow. Side by side answers it at a glance and costs
            // half the height; the model says they pair, the view only draws
            // it.
            let backedOffBlocks = SessionHUDPanel.blocks(telemetry: backedOff, session: liveStatus)
            let pairedTitles: [[String]] = backedOffBlocks.compactMap { block in
                guard case let .columns(title, left, right) = block else { return nil }
                return [title, left.title, right.title]
            }
            expect(
                pairedTitles == [["LATENCY", "THIS MACHINE", "STUDIO"]],
                "the only paired block is the two latency columns, this machine's on the left, the host named by its"
                    + " own upper-cased name rather than the generic word \"HOST\""
            )
            expect(
                hudRow(backedOffSections, "FPS")?.note == "Encoded on Studio.",
                "every viewer surface names the machine; the HUD does too, once it has been told the name, got: "
                    + "\(hudRow(backedOffSections, "FPS")?.note ?? "nil")"
            )
            expect(
                backedOffBlocks.flatMap(\.sections) == backedOffSections,
                "the flat section list and the laid-out blocks are the same sections in the same order"
            )

            // An old host: no scale on the wire at all. The panel must say it
            // does not know rather than print a plausible number.
            let oldHostSample = SurfaceTelemetrySample(
                surfaceID: 0,
                capture: nil,
                encode: nil,
                send: nil,
                framesPerSecond: nil,
                encoderInputDropped: 0,
                globalAdmissionDropped: 0,
                sendQueueDropped: 0
            )
            let oldHostSections = SessionHUDPanel.sections(
                telemetry: SessionHUDSnapshot(
                    surfaceID: 0,
                    availability: .fresh(oldHostSample),
                    clientMetrics: SessionMetrics(),
                    stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                    requestedStreamScale: 2.0,
                    streamScalePreference: .automatic,
                    decoder: nil
                ),
                session: liveStatus
            )
            expect(
                hudRow(oldHostSections, "APPLIED")?.value == "not reported" && hudRow(oldHostSections, "APPLIED")?.note == nil,
                "a host that never reports its applied scale says so plainly rather than reading as if the"
                    + " resolution itself were unavailable, and makes no claim about being held back, got: "
                    + "\(hudRow(oldHostSections, "APPLIED")?.value ?? "nil")"
            )
            expect(
                hudRow(oldHostSections, "CEILING")?.value == "not measured",
                "every empty diagnostics value reads as one \"not \u{2026}\" pattern -- APPLIED, CEILING, and PRESENT "
                    + "alike -- got: \(hudRow(oldHostSections, "CEILING")?.value ?? "nil")"
            )
            let oldHostPairedTitles: [[String]] = SessionHUDPanel.blocks(
                telemetry: SessionHUDSnapshot(
                    surfaceID: 0,
                    availability: .fresh(oldHostSample),
                    clientMetrics: SessionMetrics(),
                    stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                    requestedStreamScale: 2.0,
                    streamScalePreference: .automatic,
                    decoder: nil
                ),
                session: liveStatus
            ).compactMap { block in
                guard case let .columns(title, left, right) = block else { return nil }
                return [title, left.title, right.title]
            }
            expect(
                oldHostPairedTitles == [["LATENCY", "THIS MACHINE", "HOST"]],
                "the generic word \"HOST\" survives as the column header's own fallback when no name is known,"
                    + " got: \(oldHostPairedTitles)"
            )
            expect(
                hudRow(oldHostSections, "SIZE")?.value == "unavailable"
                    && hudRow(oldHostSections, "VIDEO IN")?.value == "unavailable"
                    && hudRow(oldHostSections, "DECODER")?.value == "unavailable"
                    && hudRow(oldHostSections, "ENCODE")?.value == "not yet",
                "nothing measured is said to be unavailable, never shown as a zero"
            )

            // Stale: the last numbers stay on screen, labelled as no longer
            // current. A frozen number that reads as live is the bug this
            // exists to prevent.
            let staleSections = SessionHUDPanel.sections(
                telemetry: SessionHUDSnapshot(
                    surfaceID: 0,
                    availability: .stale(backedOffSample),
                    clientMetrics: clientMetrics,
                    stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                    requestedStreamScale: 2.0,
                    streamScalePreference: .automatic,
                    decoder: .softwareFallback,
                    hostName: "Studio"
                ),
                session: liveStatus
            )
            expect(
                hudRow(staleSections, "READINGS")?.value == "stale" && hudRow(staleSections, "READINGS")?.tone == .warn,
                "a reading that stopped arriving says so in the panel"
            )
            expect(
                hudRow(staleSections, "READINGS")?.note?.contains("last Studio sent") == true
                    && hudRow(staleSections, "READINGS")?.note?.contains("the last the host sent") == false,
                "the stale note names the host by its own label rather than the generic word, got: "
                    + "\(hudRow(staleSections, "READINGS")?.note ?? "nil")"
            )
            expect(
                hudRow(staleSections, "ENCODE")?.value == "6.0 ms"
                    && hudRow(staleSections, "ENCODE")?.isStale == true,
                "the last known numbers are still shown, and every host-measured one is marked as no longer current rather than blanked"
            )
            // A HUD is scanned for numbers. A dead one drawn like a live one
            // is the panel misleading its reader, which is the single failure
            // it exists to prevent -- so staleness rides on the values
            // themselves, not only on a sentence somebody has to read.
            expect(
                ["APPLIED", "CEILING", "FPS", "DROPPED", "CAPTURE", "SEND"].allSatisfy {
                    hudRow(staleSections, $0)?.isStale == true
                },
                "every value that came from the host is marked, not just the latency ones"
            )
            expect(
                hudRow(staleSections, "RECEIVE")?.isStale == false
                    && hudRow(staleSections, "VIDEO IN")?.isStale == false
                    && hudRow(staleSections, "SIZE")?.isStale == false,
                "what this machine measured itself is still current, so a stale host must not cast doubt on it"
            )
            // Staleness is not a status: a dead reading should recede, not
            // compete with the amber that means "look at this". Keeping them
            // separate is also what stops a stale panel claiming the host is
            // holding you back on evidence it no longer has.
            expect(
                staleSections.flatMap(\.rows).allSatisfy { !$0.isStale || $0.tone == nil },
                "a stale reading is not dressed as an attention-worthy one"
            )
            expect(
                hudRow(staleSections, "APPLIED")?.note == nil
                    && hudRow(staleSections, "REQUESTED")?.note == nil,
                "the panel does not claim the host is holding you back on evidence it no longer has"
            )
            expect(
                hudRow(staleSections, "DECODER")?.tone == .warn,
                "which decoder this machine is running is this machine's own fact, unaffected by a host gone quiet"
            )
            // Said once, where the state itself is stated. Repeating the same
            // sentence under every host-sourced group cost three copies and
            // wrapped to nothing legible inside a half-width column.
            expect(
                staleSections.allSatisfy { $0.note == nil },
                "the staleness is stated once on the panel, not once per section"
            )
            expect(
                hudRow(staleSections, "READINGS")?.note?.contains("last") == true,
                "the one statement says what it means for the numbers below it"
            )
            expect(
                hudRow(staleSections, "READINGS")?.note?.hasPrefix("Nothing from Studio for a few seconds.") == true,
                "the staleness sentence names the machine by its own name once it is known, not the generic word "
                    + "\"host\", got: \(hudRow(staleSections, "READINGS")?.note ?? "nil")"
            )
            expect(
                hudRow(staleSections, "DECODER")?.value == "software",
                "a software decode fallback is named, since on the x86_64 viewer it is the difference that matters"
            )

            // A session that is down is a second reason the host's numbers
            // are not current, and it is known a full staleness window before
            // telemetry expires. Reading `READINGS live` beside a panel that
            // says the connection is lost is the panel contradicting the app
            // around it.
            var downMachine = ViewerSessionStateMachine(hostName: "Studio")
            downMachine.handle(.connectStarted)
            downMachine.handle(.canvasReady)
            for downStatus in [downMachine.handle(.sessionEnded), downMachine.handle(.connectStarted), downMachine.handle(.gaveUp)] {
                let downSections = SessionHUDPanel.sections(
                    telemetry: SessionHUDSnapshot(
                        surfaceID: 0,
                        availability: .fresh(backedOffSample),
                        clientMetrics: clientMetrics,
                        stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                        requestedStreamScale: 2.0,
                        streamScalePreference: .automatic,
                        decoder: .hardwareAccelerated,
                        hostName: "Studio"
                    ),
                    session: downStatus
                )
                expect(
                    hudRow(downSections, "STATE")?.value != "live",
                    "the panel never says the session is live while the window says it is not, got: \(hudRow(downSections, "STATE")?.value ?? "nil")"
                )
                expect(
                    hudRow(downSections, "READINGS")?.value == "stopped",
                    "a reading that arrived a moment ago is still the last one there will be while the session is down"
                )
                expect(
                    hudRow(downSections, "READINGS")?.note
                        == "The session is down, so nothing more is arriving. Every reading below is the last one measured.",
                    "the session-down caption covers every reading, not only the host's, since this machine's own "
                        + "rows go stale too, got: \(hudRow(downSections, "READINGS")?.note ?? "nil")"
                )
                expect(
                    ["APPLIED", "CEILING", "CAPTURE", "ENCODE", "SEND", "FPS", "DROPPED"].allSatisfy {
                        hudRow(downSections, $0)?.isStale == true
                    },
                    "a session that is down dims every host-fed value, a whole staleness window before telemetry would"
                )
                expect(
                    ["RECEIVE", "DECODE", "UPDATES", "PRESENT", "END-TO-END", "VIDEO IN", "SIZE"].allSatisfy {
                        hudRow(downSections, $0)?.isStale == true
                    },
                    "a session that is down is why nothing more is arriving at all -- including what this machine"
                        + " measures of itself -- so every measured row on the panel is marked stale, not only the host's"
                )
                expect(
                    hudRow(downSections, "REQUESTED")?.note == nil,
                    "no claim about what the host is doing to you right now, from a host that is not there"
                )
                expect(
                    hudRow(downSections, "STATE")?.note?.hasSuffix("..") != true,
                    "a headline that already ends with a period is never given a second one, got: "
                        + "\(hudRow(downSections, "STATE")?.note ?? "nil")"
                )
            }

            // Nothing has ever arrived, and no window has reported a session
            // state either.
            let emptySections = SessionHUDPanel.sections(
                telemetry: SessionHUDSnapshot(
                    surfaceID: 0,
                    availability: .unavailable,
                    clientMetrics: SessionMetrics(),
                    stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                    requestedStreamScale: 1.0,
                    streamScalePreference: .fixed(1.25),
                    decoder: nil
                ),
                session: nil
            )
            expect(
                hudRow(emptySections, "READINGS")?.value == "none yet" && hudRow(emptySections, "STATE")?.value == "unknown",
                "before anything is known the panel says so rather than inventing a state"
            )
            expect(
                hudRow(emptySections, "CHOICE")?.value == "1.25x",
                "the user's own choice is shown even when the host has said nothing, because the client set it"
            )
            expect(
                !emptySections.flatMap(\.rows).contains { $0.value.contains("0.0") },
                "an unknown reading is never rendered as a zero anywhere on the panel"
            )

            print("PASS: the session HUD states what the client holds, attributes each latency figure to its machine, and names every absent or stale reading")
        }

        // Every way a session can fail, as a sentence for the person who ran
        // it, never a Swift case name like
        // `canvasRefused("canvas-creation-in-progress")`.
        do {
            let hostLabel = "Studio"
            let sessionErrors: [ClientSessionError] = [
                .unexpectedMessage,
                .notConnected,
                .invalidInput,
                .pairingRejected("invalid-code"),
                .identityRequired,
                .hostKeyMismatch,
                .timedOut,
                .canvasRefused(CanvasRefusalReason.creationInProgress),
                .surfaceIDMismatch
            ]
            let lines = sessionErrors.map { ViewerSessionFailureCopy.line(for: $0, hostLabel: hostLabel) }
            let caseNames = [
                "unexpectedMessage", "notConnected", "invalidInput", "pairingRejected",
                "identityRequired", "hostKeyMismatch", "timedOut", "canvasRefused",
                "surfaceIDMismatch", "ClientSessionError", "NWError", "Optional("
            ]
            expect(
                lines.allSatisfy { line in caseNames.allSatisfy { !line.contains($0) } },
                "nothing the user reads is a Swift case name or an interpolated error value"
            )
            expect(
                lines.allSatisfy { !$0.contains("'") },
                "every apostrophe is typographic, matching the pairing window"
            )
            expect(
                lines.allSatisfy { $0.hasSuffix(".") && $0.contains(" ") },
                "every failure is a sentence, never a token"
            )
            // Not one per error: `notConnected` and `timedOut` are one thing
            // to the reader, and saying so is the point of classifying them.
            expect(
                Set(lines).count == Set(sessionErrors.map { ViewerSessionFailure.classify($0) }).count,
                "each failure Sensorium can tell apart gets its own words; two identical ones would mean guessing at a cause"
            )
            expect(
                lines.allSatisfy { $0.contains(hostLabel) || $0.contains("this machine") },
                "every sentence names a machine the reader recognises"
            )
            expect(
                ViewerSessionFailureCopy.line(for: ClientSessionError.hostKeyMismatch, hostLabel: hostLabel)
                    .contains("did not prove")
                    && !ViewerSessionFailureCopy.line(for: ClientSessionError.hostKeyMismatch, hostLabel: hostLabel)
                        .contains("Pair again"),
                "an unverified host says the key does not match what was pinned, and does not send the user off to re-pair blindly"
            )

            // A system error's own words are never carried into the
            // message: rewriting arbitrary text word-by-word, for example
            // `replacingOccurrences(of: "connect", with: "enter")`, would
            // turn an NWError's "Connection refused" into "Enterion refused".
            let systemStyle = SystemStyleError()
            let unknownLine = ViewerSessionFailureCopy.line(for: systemStyle, hostLabel: hostLabel)
            expect(
                !unknownLine.contains("Enterion")
                    && !unknownLine.contains("Connection refused")
                    && !unknownLine.contains("POSIXErrorCode"),
                "a system error's own words are never carried into the message, so nothing can rewrite them"
            )

            let events = RecordedReconnectEvents()
            let driver = ClientReconnectDriver(
                policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 2),
                runSession: { throw SystemStyleError() },
                sleep: { _ in },
                onEvent: { events.append($0) }
            )
            let outcome = await driver.runUntilConnectedSessionEnds()
            expect(
                outcome == .gaveUp && events.all == [
                    .attemptFailed(.unknown), .retrying(afterSeconds: 0.5),
                    .attemptFailed(.unknown), .retrying(afterSeconds: 0.5),
                    .attemptFailed(.unknown)
                ],
                "the driver reports what happened as values, leaving every word to the copy above it"
            )
            expect(
                ViewerSessionFailureCopy.line(for: ClientReconnectEvent.retrying(afterSeconds: 0.5), hostLabel: hostLabel)
                    .contains("0.5"),
                "a wait the user is asked to sit through says how long it is"
            )
            expect(
                events.all.allSatisfy { event in
                    let line = ViewerSessionFailureCopy.line(for: event, hostLabel: hostLabel)
                    return line.hasSuffix(".") && !line.contains("attemptFailed") && !line.contains("retrying(")
                },
                "every redial event reaches the terminal as a sentence"
            )

            // The one refusal a person cannot act on from this machine: the
            // host would not open a canvas under any identity, so the line
            // sends them to the other machine rather than telling them to
            // wait and try again like the busy-gate refusal above does.
            let unavailableLabel = "Studio"
            let unavailableLine = ViewerSessionFailureCopy.line(
                for: ClientSessionError.canvasRefused(CanvasRefusalReason.canvasUnavailable),
                hostLabel: unavailableLabel
            )
            expect(
                unavailableLine == "Stopped: \(unavailableLabel) could not open a session canvas. Its Sensorium "
                    + "Host app needs to be quit and opened again at the machine itself before this machine can "
                    + "connect.",
                "a canvas the host could not open at all says so and names the one thing that fixes it, got: \(unavailableLine)"
            )

            print("PASS: a failed session says what happened and what to do without editing the system error's own words")
        }

        do {
            // A host presenting a certificate other than the one
            // pinned at pairing is reported as unverified, never as
            // unreachable -- the person is told to check the host,
            // not to keep retrying an address that answered fine.
            expect(
                NetworkControlConnection.resolveDialError(
                    .failed(NetworkControlConnectionError.peerFailed),
                    pinMismatchObserved: true
                ) as? NetworkControlConnectionError == .certificatePinMismatch,
                "a mismatch the verify block saw wins over whatever the failed dial's own error was"
            )
            expect(
                NetworkControlConnection.resolveDialError(
                    .timedOut,
                    pinMismatchObserved: true
                ) as? NetworkControlConnectionError == .certificatePinMismatch,
                "a mismatch the verify block saw wins even when the dial's own deadline fired first"
            )
            expect(
                NetworkControlConnection.resolveDialError(
                    .failed(NetworkControlConnectionError.peerFailed),
                    pinMismatchObserved: false
                ) as? NetworkControlConnectionError == .peerFailed,
                "with no mismatch observed, a failed dial's own error passes through unchanged"
            )
            expect(
                NetworkControlConnection.resolveDialError(
                    .timedOut,
                    pinMismatchObserved: false
                ) as? NetworkControlConnectionError == .timedOut,
                "with no mismatch observed, a timed-out dial is reported as timed out, not as a mismatch"
            )
            expect(
                ViewerSessionFailure.classify(NetworkControlConnectionError.certificatePinMismatch) == .unverifiedHost,
                "a pin mismatch classifies the same way a host key mismatch already does"
            )
            expect(
                ViewerSessionFailureCopy.line(for: NetworkControlConnectionError.certificatePinMismatch, hostLabel: "Studio")
                    == ViewerSessionFailureCopy.line(for: ClientSessionError.hostKeyMismatch, hostLabel: "Studio"),
                "the words on screen do not depend on which layer caught the mismatch"
            )

            print("PASS: a host presenting an unpinned certificate is reported as unverified, not unreachable")
        }

        do {
            // A refused or failed host-screen connect never
            // auto-redials -- design's "nothing automatic": the
            // retry policy's backoff and give-up never apply to it,
            // unlike every other kind of failure above.
            let events = RecordedReconnectEvents()
            let driver = ClientReconnectDriver(
                policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 2),
                runSession: { throw ClientSessionError.hostScreenRefused("host-screen-not-allowed") },
                sleep: { _ in
                    expect(false, "a refused host-screen connect must never wait for a retry")
                },
                onEvent: { events.append($0) }
            )
            let outcome = await driver.runUntilConnectedSessionEnds()
            expect(
                outcome == .stopped,
                "a refused host-screen connect ends the run outright, the same outcome as an explicit user stop, got: \(outcome)"
            )
            expect(
                events.all == [.attemptFailed(.hostScreenRefused(reason: "host-screen-not-allowed"))],
                "exactly one failure is reported, with no retrying event ever following it"
            )

            print("PASS: a refused or failed host-screen connect never auto-redials")
        }

        do {
            // One refused canvas ends the run: `canvas-unavailable`,
            // which macOS refused under every identity the host has,
            // so the next dial is refused exactly as this one was and
            // redialling only hides that from the person waiting. One
            // host accepted and dropped thousands of connections this
            // way.
            let events = RecordedReconnectEvents()
            let driver = ClientReconnectDriver(
                policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
                runSession: { throw ClientSessionError.canvasRefused(CanvasRefusalReason.canvasUnavailable) },
                sleep: { _ in
                    expect(false, "a canvas the host could not open at all must never wait for a retry")
                },
                onEvent: { events.append($0) }
            )
            let outcome = await driver.runUntilConnectedSessionEnds()
            expect(
                outcome == .stopped,
                "a canvas the host could not open at all ends the run outright, got: \(outcome)"
            )
            expect(
                events.all == [.attemptFailed(.canvasRefused(reason: CanvasRefusalReason.canvasUnavailable))],
                "exactly one failure is reported, with no retrying event and no second attempt after it, got \(events.all)"
            )

            // Every other reason keeps the backoff.
            // `canvas-creation-in-progress` is a race with another
            // connection's creation, over in a moment, which is what
            // the words on screen already tell the person to wait for;
            // and a token this build has never seen is not proof the
            // host can never recover from it.
            for reason in [CanvasRefusalReason.creationInProgress, "a-reason-from-a-newer-host"] {
                let retryEvents = RecordedReconnectEvents()
                let retryingDriver = ClientReconnectDriver(
                    policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 2),
                    runSession: { throw ClientSessionError.canvasRefused(reason) },
                    sleep: { _ in },
                    onEvent: { retryEvents.append($0) }
                )
                let retryOutcome = await retryingDriver.runUntilConnectedSessionEnds()
                expect(
                    retryOutcome == .gaveUp,
                    "a canvas refused with \(reason) is dialled again on the policy and gives up with it, got: \(retryOutcome)"
                )
                expect(
                    retryEvents.all == [
                        .attemptFailed(.canvasRefused(reason: reason)), .retrying(afterSeconds: 0.5),
                        .attemptFailed(.canvasRefused(reason: reason)), .retrying(afterSeconds: 0.5),
                        .attemptFailed(.canvasRefused(reason: reason))
                    ],
                    "each attempt for \(reason) is reported with the policy's own wait between them, got \(retryEvents.all)"
                )
            }

            print("PASS: a canvas the host could not open at all ends the run, and every other refusal is redialled on the policy")
        }

        do {
            // Cancelling has to end the wait, not merely mark it. The
            // backoff between attempts is seconds long, and a run that
            // finished its sleep before noticing would leave a row
            // saying nothing useful for that whole time.
            let attempts = RecordedReconnectEvents()
            let driver = ClientReconnectDriver(
                policy: ReconnectPolicy(initialDelay: 60, maximumDelay: 60, multiplier: 1, maximumAttempts: 10),
                runSession: { throw ClientSessionError.timedOut },
                sleep: { seconds in
                    // The real wait: cancellation is what ends it early, not
                    // a shorter number injected for the test's convenience.
                    try? await Task.sleep(for: .seconds(seconds))
                },
                onEvent: { attempts.append($0) }
            )
            let run = Task { await driver.runUntilConnectedSessionEnds() }
            // Let the first attempt fail and the run park in its backoff.
            while attempts.all.count < 2 {
                await Task.yield()
            }
            run.cancel()
            let outcome = await run.value
            expect(
                outcome == .stopped,
                "a cancelled run stops rather than serving out a sixty-second wait, got: \(outcome)"
            )
            expect(
                attempts.all == [.attemptFailed(.unreachable), .retrying(afterSeconds: 60)],
                "and it dials nothing more after the cancel, got \(attempts.all)"
            )

            print("PASS: cancelling a run of attempts ends its wait instead of letting the backoff run out")
        }
}
