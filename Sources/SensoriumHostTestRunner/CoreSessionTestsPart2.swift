import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Split out of main.swift, mechanically -- see docs/testing.md.
@MainActor
func runCoreSessionTestsPart2(_ fixtures: CoreSessionSharedFixtures) async {
    let surfaceZero = fixtures.surfaceZero!
    let surfaceOne = fixtures.surfaceOne!
        // Workspace ownership is per surface: a connection that lost one
        // surface to a reconnect still owns the other, and must take down
        // exactly the one it still owns.
        do {
            let splitAdapter = FakeVirtualDisplayAdapter()
            splitAdapter.handleValuesToVend = [7, 8]
            let splitSessions = CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: splitAdapter) }
            let splitFactory = HostConnectionSessionFactory(
                sessions: splitSessions, keyConfinement: .unconfined, privateDesktopOffered: { true }
            )
            let splitWorkspace0 = FakeCanvasWorkspace()
            let splitWorkspace1 = FakeCanvasWorkspace()
            var splitOrder: [String] = []
            splitWorkspace0.onStop = { splitOrder.append("workspace-0") }
            splitWorkspace1.onStop = { splitOrder.append("workspace-1") }
            splitAdapter.onRelease = { splitOrder.append("display-\($0.rawValue)") }
            let splitWorkspaces = CanvasSurfaceSlots(
                surface0: splitWorkspace0 as any CanvasWorkspacePresenting,
                surface1: splitWorkspace1 as any CanvasWorkspacePresenting
            )
            let splitCoordinatorA = HostSessionCoordinator(
                controller: splitFactory.makeController(),
                media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
                videoSink: FakeVideoSink(),
                workspaces: splitWorkspaces
            )
            let splitCoordinatorB = HostSessionCoordinator(
                controller: splitFactory.makeController(),
                media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
                videoSink: FakeVideoSink(),
                workspaces: splitWorkspaces
            )

            _ = try! await splitCoordinatorA.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            _ = try! await splitCoordinatorA.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)
            )
            // B reconnects onto surface 0 only, exactly as a client that has
            // reopened one of its two viewer windows does.
            _ = try! await splitCoordinatorB.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )

            await splitCoordinatorA.sessionDidEnd(reason: "transport-closed")
            expect(
                splitWorkspace0.stopCount == 0 && splitWorkspace0.declinedStopCount == 1,
                "the surface another connection took over is left alone"
            )
            expect(
                splitWorkspace1.stopCount == 1,
                "while the surface this connection still owns is closed by its own teardown"
            )
            expect(
                splitAdapter.releasedHandles == [VirtualDisplayHandle(rawValue: 8)],
                "and only that surface's canvas is released"
            )
            expect(
                splitOrder == ["workspace-1", "display-8"],
                "that surface's window still disappears before that surface's display is released"
            )

            await splitCoordinatorB.sessionDidEnd(reason: "client-disconnected")
            expect(
                splitWorkspace0.stopCount == 1 && splitWorkspace1.stopCount == 1,
                "the reconnected connection then closes the surface it took over, and neither surface is closed twice"
            )
            expect(
                splitOrder == ["workspace-1", "display-8", "workspace-0", "display-7"],
                "on both connections' paths the window comes down before the display it sits on is released"
            )
        }

        // A genuinely fatal error must still tear the connection down: the
        // fix above must not turn every thrown error non-fatal.
        let fatalController = HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined)
        let fatalChannel = FakeHostByteChannel(scriptedMessages: [
            // `.canvasReady` is a host-to-client message; receiving one from
            // the client is unconditionally `HostSessionControllerError.unexpectedMessage`,
            // which is session-fatal.
            .canvasReady(displayID: 1, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil),
        ])
        let fatalNetworkSession = HostNetworkSession(connection: fatalChannel, controller: fatalController)
        fatalNetworkSession.start()
        try! await Task.sleep(for: .milliseconds(200))
        expect(fatalChannel.cancelCount == 1, "a session-fatal error still cancels the connection")

        // A per-connection failure cap, on top of the per-code budget covered
        // earlier: without it, one socket could work through the whole
        // per-code budget by itself, since a rejected pairRequest leaves the
        // connection open. Instead the connection itself is dropped after
        // `HostSessionController.maximumPairingFailuresPerConnection` wrong
        // guesses, whatever budget the code still has left.
        let capUnderPairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        capUnderPairing.issueCode(code: "555555")
        let capUnderDevice = try! DeviceIdentity.generate()
        let capUnderLog = DiagnosticsRecorder()
        let capUnderController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            pairing: capUnderPairing,
            keyConfinement: .unconfined,
            log: { capUnderLog.record($0) }
        )
        let capUnderChannel = FakeHostByteChannel(scriptedMessages: (0..<(HostSessionController.maximumPairingFailuresPerConnection - 1)).map { _ in
            signedPairRequest(deviceName: "Attacker", identity: capUnderDevice, code: "111111")
        })
        let capUnderSession = HostNetworkSession(connection: capUnderChannel, controller: capUnderController)
        capUnderSession.start()
        try! await Task.sleep(for: .milliseconds(200))
        expect(
            capUnderChannel.cancelCount == 0,
            "wrong codes up to the per-connection cap are refused without dropping the connection"
        )
        expect(
            capUnderChannel.sentPackets.count == HostSessionController.maximumPairingFailuresPerConnection - 1
                && capUnderChannel.sentPackets.allSatisfy { $0 == .control(.pairRejected(reason: "invalid-code")) },
            "every guess under the cap still gets its own pairRejected reply"
        )

        let capAtPairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        capAtPairing.issueCode(code: "555555")
        let capAtDevice = try! DeviceIdentity.generate()
        let capAtLog = DiagnosticsRecorder()
        let capAtController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            pairing: capAtPairing,
            keyConfinement: .unconfined,
            log: { capAtLog.record($0) }
        )
        let capAtChannel = FakeHostByteChannel(scriptedMessages: (0..<HostSessionController.maximumPairingFailuresPerConnection).map { _ in
            signedPairRequest(deviceName: "Attacker", identity: capAtDevice, code: "111111")
        })
        let capAtSession = HostNetworkSession(connection: capAtChannel, controller: capAtController)
        capAtSession.start()
        try! await Task.sleep(for: .milliseconds(200))
        expect(
            capAtChannel.cancelCount == 1,
            "the guess that reaches the per-connection cap drops the connection, not merely errors"
        )
        expect(
            capAtChannel.sentPackets.count == HostSessionController.maximumPairingFailuresPerConnection
                && capAtChannel.sentPackets.last == .control(.pairRejected(reason: "invalid-code")),
            "the peer is told why (pairRejected) before the connection drops"
        )
        expect(
            capAtLog.messages.allSatisfy { message in
                (3...6).allSatisfy { !message.contains("555555".prefix($0)) && !message.contains("111111".prefix($0)) }
            },
            "the per-connection cap log line carries no pairing code material"
        )

        let capOkPairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        capOkPairing.issueCode(code: "555555")
        let capOkDevice = try! DeviceIdentity.generate()
        let capOkController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            pairing: capOkPairing,
            keyConfinement: .unconfined
        )
        var capOkMessages = (0..<(HostSessionController.maximumPairingFailuresPerConnection - 1)).map { _ in
            signedPairRequest(deviceName: "NewLaptop", identity: capOkDevice, code: "111111")
        }
        capOkMessages.append(signedPairRequest(deviceName: "NewLaptop", identity: capOkDevice, code: "555555"))
        let capOkChannel = FakeHostByteChannel(scriptedMessages: capOkMessages)
        let capOkSession = HostNetworkSession(connection: capOkChannel, controller: capOkController)
        capOkSession.start()
        try! await Task.sleep(for: .milliseconds(200))
        expect(
            capOkChannel.cancelCount == 0,
            "a successful pairing that lands within the cap does not drop the connection"
        )
        expect(
            capOkChannel.sentPackets.count == HostSessionController.maximumPairingFailuresPerConnection,
            "every request, including the approving one, still gets a reply"
        )
        if case .control(.pairApproved) = capOkChannel.sentPackets.last {
            // approved
        } else {
            expect(false, "the final, correct guess inside the cap still pairs")
        }

        // Ordinary session errors must not become fatal because of this: the
        // cap is scoped to `.pairRequest`'s own rejection, not to refused
        // messages in general.
        let ordinaryController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let ordinaryChannel = FakeHostByteChannel(scriptedMessages: (0..<HostSessionController.maximumPairingFailuresPerConnection).map { _ in
            // A canvas request with an unsupported geometry: refused
            // (`invalidCanvasRequest`), not fatal, and nothing to do with
            // pairing.
            SensoriumMessage.canvasRequest(logicalWidth: 1, logicalHeight: 1, scale: 1, surfaceID: nil)
        })
        let ordinarySession = HostNetworkSession(connection: ordinaryChannel, controller: ordinaryController)
        ordinarySession.start()
        try! await Task.sleep(for: .milliseconds(200))
        expect(
            ordinaryChannel.cancelCount == 0,
            "repeated non-pairing refusals never trip the per-connection pairing cap"
        )

        // The two caps compose: spread across connections that each stay
        // under the per-connection cap, the per-code budget still bounds the
        // total at `PairingAuthority.maximumFailedAttempts` guesses.
        let composeLog = DiagnosticsRecorder()
        let composePairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        composePairing.issueCode(code: "864213")
        let composeDevice = try! DeviceIdentity.generate()
        let guessesPerConnection = HostSessionController.maximumPairingFailuresPerConnection - 1
        var composeChannels: [FakeHostByteChannel] = []
        // `HostNetworkSession.run()` captures `[weak self]`, so a session with
        // nothing else retaining it never gets to process its script -- these
        // arrays are what keep each connection (and the controller it drives)
        // alive for the length of the loop below, not just its channel.
        var composeSessions: [HostNetworkSession] = []
        var composeControllers: [HostSessionController] = []
        var remainingGuesses = PairingAuthority.maximumFailedAttempts
        while remainingGuesses > 0 {
            let guessesThisConnection = min(guessesPerConnection, remainingGuesses)
            remainingGuesses -= guessesThisConnection
            let controller = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                pairing: composePairing,
                keyConfinement: .unconfined,
                log: { composeLog.record($0) }
            )
            let messages = (0..<guessesThisConnection).map { _ in
                signedPairRequest(deviceName: "Attacker", identity: composeDevice, code: "111111")
            }
            let channel = FakeHostByteChannel(scriptedMessages: messages)
            let session = HostNetworkSession(connection: channel, controller: controller)
            session.start()
            composeChannels.append(channel)
            composeSessions.append(session)
            composeControllers.append(controller)
        }
        // Ten connections' worth of scripted messages, each hopping through
        // the main actor in turn, can outlast a fixed sleep under load; poll
        // for every guess to have landed rather than racing it.
        var composePumps = 0
        while composeChannels.reduce(0, { $0 + $1.sentPackets.count }) < PairingAuthority.maximumFailedAttempts,
              composePumps < 300 {
            try! await Task.sleep(for: .milliseconds(10))
            composePumps += 1
        }
        expect(
            composeChannels.allSatisfy { $0.cancelCount == 0 },
            "none of the connections individually reaches its own per-connection cap"
        )
        expect(
            composeChannels.allSatisfy { channel in
                channel.sentPackets.allSatisfy { $0 == .control(.pairRejected(reason: "invalid-code")) }
            },
            "every guess across those connections is a plain wrong-code rejection, not an already-exhausted code"
        )
        let composeFreshController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            pairing: composePairing,
            keyConfinement: .unconfined
        )
        let composeExhausted = try! composeFreshController.handle(signedPairRequest(
            deviceName: "NewLaptop",
            identity: composeDevice,
            code: "864213"
        ))
        expect(
            composeExhausted == .pairRejected(reason: "code-attempts-exhausted"),
            "the per-code budget is spent across connections even though no single connection reached its own cap"
        )

        let lostAdapter = FakeVirtualDisplayAdapter()
        let lostSession = VirtualDisplaySession(adapter: lostAdapter)
        let lostMedia = FakeCanvasMedia()
        let lostInjector = FakeInputInjector()
        let lostCoordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(lostSession), inputInjector: lostInjector, keyConfinement: .unconfined,
                privateDesktopOffered: { true }
            ),
            media: onlyOnSurfaceZero(lostMedia),
            videoSink: FakeVideoSink()
        )
        _ = try! await lostCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! await lostCoordinator.handleWritingResponse(.input(.pointerButton(button: .left, isDown: true, x: 5, y: 5), surfaceID: nil))
        await lostCoordinator.sessionDidEnd(reason: "transport-closed")
        expect(!lostSession.isActive, "a transport that died without a goodbye still releases the canvas")
        expect(lostMedia.stopCount == 1, "a transport that died without a goodbye still stops capture")
        expect(
            lostInjector.events.last == .pointerButton(button: .left, isDown: false, x: 5, y: 5),
            "a transport that died without a goodbye still releases the held button"
        )
        await lostCoordinator.sessionDidEnd(reason: "transport-closed")
        expect(lostMedia.stopCount == 1, "repeated end-of-session cleanup stays idempotent")

        // `HostNetworkSession.stop()` must not bypass the coordinator's
        // ordered teardown: the workspace window has to disappear before the
        // canvas display it sits on is released, or AppKit may move it onto
        // a physical monitor.
        do {
            let stopOrderAdapter = FakeVirtualDisplayAdapter()
            let stopOrderSession = VirtualDisplaySession(adapter: stopOrderAdapter)
            let stopOrderMedia = FakeCanvasMedia()
            let stopOrderWorkspace = FakeCanvasWorkspace()
            var stopOrder: [String] = []
            stopOrderWorkspace.onStop = { stopOrder.append("workspace") }
            stopOrderAdapter.onRelease = { _ in stopOrder.append("display") }
            let stopOrderController = HostSessionController(sessions: surfaceZeroOnly(stopOrderSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            let stopOrderCoordinator = HostSessionCoordinator(
                controller: stopOrderController,
                media: onlyOnSurfaceZero(stopOrderMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(stopOrderWorkspace))
            let stopOrderChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            ])
            let stopOrderNetworkSession = HostNetworkSession(connection: stopOrderChannel, controller: stopOrderController)
            stopOrderNetworkSession.attach(coordinator: stopOrderCoordinator)
            stopOrderNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            expect(stopOrderWorkspace.startedDisplayIDs == [7], "the canvas is established before stop() is exercised")
            stopOrderNetworkSession.stop()
            try! await Task.sleep(for: .milliseconds(200))
            // Twice, not once: stop() cancels the transport directly, and
            // run()'s own background loop -- still waiting on receiveBytes
            // for whatever the peer might send next -- notices that
            // cancellation and runs its own catch-block cleanup, which
            // cancels the same connection again. A real NWConnection
            // tolerates a second cancel() as a harmless no-op, which is
            // exactly what this fixture's count reflects.
            expect(stopOrderChannel.cancelCount == 2, "stop() cancels the transport, and so does run()'s own cleanup once it notices")
            expect(stopOrderMedia.stopCount == 1, "stop() with a coordinator attached also stops streaming")
            expect(stopOrderWorkspace.stopCount == 1, "stop() with a coordinator attached stops the workspace")
            expect(!stopOrderSession.isActive, "stop() with a coordinator attached releases the canvas display")
            expect(
                stopOrder == ["workspace", "display"],
                "stop() tears the workspace down before releasing the canvas display it sits on, not after"
            )
        }

        // The host must not put a surface's video on the wire before it has
        // told the client that surface exists. Asserted through the real
        // transport wiring, because the ordering is a property of the
        // coordinator and the network session together: the coordinator
        // decides when capture starts, the session decides when the reply is
        // written.
        do {
            let orderAdapter = FakeVirtualDisplayAdapter()
            let orderSession = VirtualDisplaySession(adapter: orderAdapter)
            let orderController = HostSessionController(sessions: surfaceZeroOnly(orderSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            let orderChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
            ])
            let orderMedia = SendOrderRecordingCanvasMedia(channel: orderChannel)
            let orderNetworkSession = HostNetworkSession(connection: orderChannel, controller: orderController)
            orderNetworkSession.attach(coordinator: HostSessionCoordinator(
                controller: orderController,
                media: onlyOnSurfaceZero(orderMedia),
                videoSink: orderNetworkSession))
            orderNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            expect(orderMedia.startCount == 1, "capture starts once for the canvas the request created")
            expect(
                orderMedia.packetsSentBeforeStart.contains(where: isCanvasReadyPacket),
                "the canvasReady is on the wire before that surface's capture starts"
            )
            expect(
                orderChannel.sentPackets.filter(isCanvasReadyPacket).count == 1,
                "and is written exactly once, not once by the coordinator and again by the session"
            )
        }

        // Writing the reply first moves the capture-start failure to after the
        // client has already been told the canvas exists. The unwind must be
        // unchanged by that: the workspace window still goes before the
        // display it sits on, the session still ends exactly once, and the
        // transport still closes so the client stops waiting on a canvas that
        // will never produce a frame.
        do {
            let lateFailureAdapter = FakeVirtualDisplayAdapter()
            let lateFailureSession = VirtualDisplaySession(adapter: lateFailureAdapter)
            let lateFailureWorkspace = FakeCanvasWorkspace()
            var lateFailureOrder: [String] = []
            lateFailureWorkspace.onStop = { lateFailureOrder.append("workspace") }
            lateFailureAdapter.onRelease = { _ in lateFailureOrder.append("display") }
            let lateFailureSignals = DiagnosticsRecorder()
            let lateFailureController = HostSessionController(sessions: surfaceZeroOnly(lateFailureSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            let lateFailureChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
            ])
            let lateFailureNetworkSession = HostNetworkSession(
                connection: lateFailureChannel,
                controller: lateFailureController
            )
            let lateFailureCoordinator = HostSessionCoordinator(
                controller: lateFailureController,
                media: onlyOnSurfaceZero(FailingCanvasMedia()),
                videoSink: lateFailureNetworkSession,
                workspaces: onlyOnSurfaceZero(lateFailureWorkspace),
                onSessionEnded: { lateFailureSignals.record("ended") })
            lateFailureNetworkSession.attach(coordinator: lateFailureCoordinator)
            lateFailureNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            expect(
                lateFailureChannel.sentPackets.filter(isCanvasReadyPacket).count == 1,
                "the canvasReady written before capture is not retracted or repeated when capture then fails"
            )
            expect(
                lateFailureOrder == ["workspace", "display"],
                "the capture-failure teardown still stops the workspace before releasing the canvas it sits on"
            )
            expect(
                lateFailureSignals.messages == ["ended"],
                "and signals session end exactly once, despite the transport's own follow-on teardown"
            )
            expect(!lateFailureSession.isActive, "the canvas whose capture failed is released, not orphaned")
            expect(lateFailureChannel.cancelCount == 1, "and the transport is closed so the client stops waiting")
        }

        // No coordinator attached: stop() must still fall back to the bare
        // controller goodbye.
        do {
            let noCoordinatorAdapter = FakeVirtualDisplayAdapter()
            let noCoordinatorSession = VirtualDisplaySession(adapter: noCoordinatorAdapter)
            let noCoordinatorController = HostSessionController(sessions: surfaceZeroOnly(noCoordinatorSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            _ = try! noCoordinatorController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
            expect(noCoordinatorSession.isActive, "the canvas is established before the no-coordinator fallback is exercised")
            let noCoordinatorChannel = FakeHostByteChannel(scriptedMessages: [])
            let noCoordinatorNetworkSession = HostNetworkSession(connection: noCoordinatorChannel, controller: noCoordinatorController)
            noCoordinatorNetworkSession.stop()
            try! await Task.sleep(for: .milliseconds(200))
            expect(
                !noCoordinatorSession.isActive,
                "stop() with no coordinator attached still falls back to the bare controller goodbye"
            )
        }

        // Calling stop() twice must run the ordered teardown once.
        do {
            let doubleStopAdapter = FakeVirtualDisplayAdapter()
            let doubleStopSession = VirtualDisplaySession(adapter: doubleStopAdapter)
            let doubleStopMedia = FakeCanvasMedia()
            let doubleStopWorkspace = FakeCanvasWorkspace()
            let doubleStopEvents = DiagnosticsRecorder()
            let doubleStopController = HostSessionController(sessions: surfaceZeroOnly(doubleStopSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            let doubleStopCoordinator = HostSessionCoordinator(
                controller: doubleStopController,
                media: onlyOnSurfaceZero(doubleStopMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(doubleStopWorkspace),
                onSessionEnded: { doubleStopEvents.record("ended") }
            )
            let doubleStopChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            ])
            let doubleStopNetworkSession = HostNetworkSession(connection: doubleStopChannel, controller: doubleStopController)
            doubleStopNetworkSession.attach(coordinator: doubleStopCoordinator)
            doubleStopNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            doubleStopNetworkSession.stop()
            doubleStopNetworkSession.stop()
            try! await Task.sleep(for: .milliseconds(200))
            expect(doubleStopMedia.stopCount == 1, "calling stop() twice stops streaming exactly once")
            expect(doubleStopWorkspace.stopCount == 1, "calling stop() twice stops the workspace exactly once")
            expect(doubleStopEvents.messages == ["ended"], "calling stop() twice still fires onSessionEnded exactly once")
        }

        // stop() racing the run() loop's own error-path teardown (triggered
        // here by the transport reporting closed on its own, shortly after
        // the canvas is established) must still produce exactly one ordered
        // teardown, not two interleaved ones.
        do {
            let raceAdapter = FakeVirtualDisplayAdapter()
            let raceSession = VirtualDisplaySession(adapter: raceAdapter)
            let raceMedia = FakeCanvasMedia()
            let raceWorkspace = FakeCanvasWorkspace()
            var raceOrder: [String] = []
            raceWorkspace.onStop = { raceOrder.append("workspace") }
            raceAdapter.onRelease = { _ in raceOrder.append("display") }
            let raceEvents = DiagnosticsRecorder()
            let raceController = HostSessionController(sessions: surfaceZeroOnly(raceSession), keyConfinement: .unconfined, privateDesktopOffered: { true })
            let raceCoordinator = HostSessionCoordinator(
                controller: raceController,
                media: onlyOnSurfaceZero(raceMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(raceWorkspace),
                onSessionEnded: { raceEvents.record("ended") }
            )
            let raceChannel = FakeHostByteChannel(
                scriptedMessages: [
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
                ],
                closeAfterScriptDelay: .milliseconds(50)
            )
            let raceNetworkSession = HostNetworkSession(connection: raceChannel, controller: raceController)
            raceNetworkSession.attach(coordinator: raceCoordinator)
            raceNetworkSession.start()
            try! await Task.sleep(for: .milliseconds(100))
            expect(raceWorkspace.startedDisplayIDs == [7], "the canvas is established before the race is exercised")
            // The run() loop's own next receive is already in flight and will
            // report closed in another ~50ms, tearing the session down on its
            // own; calling stop() here overlaps that in-flight teardown.
            raceNetworkSession.stop()
            try! await Task.sleep(for: .milliseconds(300))
            expect(raceMedia.stopCount == 1, "a race between stop() and the run loop's own teardown stops streaming exactly once")
            expect(raceWorkspace.stopCount == 1, "a race between stop() and the run loop's own teardown stops the workspace exactly once")
            expect(!raceSession.isActive, "a race between stop() and the run loop's own teardown still releases the canvas")
            expect(raceEvents.messages == ["ended"], "a race between stop() and the run loop's own teardown fires onSessionEnded exactly once")
            expect(
                raceOrder == ["workspace", "display"],
                "even when torn down by a race, the workspace still disappears before the canvas display is released"
            )
        }

        func evidenceDisplay(id: UInt32, vendor: UInt32, model: UInt32) -> DisplaySnapshot {
            DisplaySnapshot(
                id: id,
                pixelWidth: 1920,
                pixelHeight: 1200,
                modeWidth: 1920,
                modeHeight: 1200,
                modePixelWidth: 3840,
                modePixelHeight: 2400,
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                online: true,
                builtin: false,
                main: false,
                vendorNumber: vendor,
                modelNumber: model
            )
        }
        let ownCanvas = evidenceDisplay(
            id: 1,
            vendor: CanvasDisplayIdentity.vendorID,
            model: CanvasDisplayIdentity.productID
        )
        let ownCanvasOfAnotherProduct = evidenceDisplay(
            id: 2,
            vendor: CanvasDisplayIdentity.vendorID,
            model: CanvasDisplayIdentity.productID + 1
        )
        let displayWeDidNotCreate = evidenceDisplay(id: 3, vendor: 0x0610, model: 0x9c6)

        expect(
            !PhysicalDisplayEvidence(displays: [ownCanvas, ownCanvasOfAnotherProduct]).hasPhysicalDisplay,
            "a baseline of nothing but displays carrying Sensorium's own vendor ID is not a physical baseline"
        )
        expect(
            PhysicalDisplayEvidence(displays: [displayWeDidNotCreate]).hasPhysicalDisplay,
            "a display Sensorium did not create is what makes a baseline physical"
        )
        expect(
            PhysicalDisplayEvidence(displays: [ownCanvas, displayWeDidNotCreate]).hasPhysicalDisplay,
            "a mixed baseline still holds a display that is not ours"
        )
        expect(
            !PhysicalDisplayEvidence(displays: []).hasPhysicalDisplay,
            "an empty baseline is evidence of nothing"
        )
        expect(
            !PhysicalDisplayEvidence(displays: [displayWeDidNotCreate]).isPreservationTestable,
            "preservation cannot be tested without a display left over to preserve"
        )
        expect(
            PhysicalDisplayEvidence(displays: [ownCanvas, displayWeDidNotCreate]).isPreservationTestable,
            "one physical display plus one other is enough to test preservation"
        )
        expect(
            !PhysicalDisplayEvidence(displays: [ownCanvas, ownCanvasOfAnotherProduct]).isPreservationTestable,
            "two of our own canvases are two displays and still not a testable baseline"
        )
        expect(
            !PhysicalDisplayEvidence(physicalDisplayCount: 1, activeDisplayCount: 1).isPreservationTestable,
            "a lone physical display is not a testable baseline: the canvas would be the only thing added"
        )
        expect(
            PhysicalDisplayEvidence(physicalDisplayCount: 1, activeDisplayCount: 2).isPreservationTestable,
            "one physical display alongside anything else is a testable baseline"
        )

        let tlsIdentity = try! HostTLSIdentity.generate(commonName: "Sensorium Host")
        fixtures.tlsIdentity = tlsIdentity
        let boundParameters = try! HostNetworkListener.parameters(
            boundToTailnetAddress: "100.100.0.4",
            tlsIdentity: tlsIdentity
        )
        // An address-pinned QUIC listener is a defect, not a defence: accepted
        // connections inherit `requiredLocalEndpoint`, re-bind the listener's
        // own address and port, and die with EADDRINUSE before the handshake —
        // for every client, remote ones included. The tailnet restriction is
        // carried by interface scoping plus the source-address policy instead.
        expect(
            boundParameters.requiredLocalEndpoint == nil,
            "the QUIC listener must not pin a local endpoint its accepted connections would re-bind"
        )
        expect(
            boundParameters.requiredInterface != nil || !TailnetInterfaceLocator.isAvailable(address: "100.100.0.4"),
            "the listener is scoped to the interface that owns the tailnet address when one exists"
        )
        expect(
            boundParameters.defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options,
            "the production host listener uses QUIC rather than a TCP fallback"
        )
        do {
            _ = try HostNetworkListener.parameters(
                boundToTailnetAddress: "192.0.2.45",
                tlsIdentity: tlsIdentity
            )
            expect(false, "scoping to a LAN address is refused")
        } catch HostNetworkListenerError.nonTailnetBindAddress {
        } catch {
            expect(false, "scoping to a LAN address reports the expected error")
        }
        do {
            _ = try HostNetworkListener.parameters(
                boundToTailnetAddress: "0.0.0.0",
                tlsIdentity: tlsIdentity
            )
            expect(false, "scoping to every interface is refused")
        } catch HostNetworkListenerError.nonTailnetBindAddress {
        } catch {
            expect(false, "scoping to every interface reports the expected error")
        }

        // Synthetic documentation-only fixtures exercise the tailnet admission
        // phase, kept as regression coverage against the ranges being wrong.
        expect(SourceAddressPolicy.isTailnetSource("100.100.0.4"), "a synthetic tailnet v4 address is admitted")
        expect(SourceAddressPolicy.isTailnetSource("fd7a:115c:a1e0:100::4"), "a synthetic tailnet v6 address is admitted")
        expect(SourceAddressPolicy.isTailnetSource("100.100.0.5"), "another synthetic tailnet address is admitted")
        expect(!SourceAddressPolicy.isTailnetSource("192.0.2.45"), "a synthetic non-tailnet address is refused")

        let failingMedia = FailingCanvasMedia()
        let diagnosticsAdapter = FakeVirtualDisplayAdapter()
        let diagnosticsSession = VirtualDisplaySession(adapter: diagnosticsAdapter)
        let events = DiagnosticsRecorder()
        let diagnosticsCoordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(diagnosticsSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
            ),
            media: onlyOnSurfaceZero(failingMedia),
            videoSink: FakeVideoSink(),
            onEvent: { events.record($0) }
        )
        _ = try? await diagnosticsCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            events.messages.contains { $0.contains("start capturing") },
            "a capture that cannot start is reported, not swallowed"
        )
        expect(
            !diagnosticsSession.isActive,
            "a canvas whose capture cannot start is released rather than left orphaned"
        )
        // One catch covers every step of bringing a canvas up -- placing the
        // workspace, writing the canvasReady, starting capture -- so the
        // failure it reports has to name the step that actually failed. A
        // workspace that will not place is not a capture failure.
        do {
            let placementSession = VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())
            let placementWorkspace = FakeCanvasWorkspace()
            placementWorkspace.startFailure = NativeCanvasWorkspaceError.screenUnavailable
            let placementMedia = FakeCanvasMedia()
            let placementEvents = DiagnosticsRecorder()
            let placementCoordinator = HostSessionCoordinator(
                controller: HostSessionController(
                    sessions: surfaceZeroOnly(placementSession),
                    keyConfinement: .unconfined,
                    privateDesktopOffered: { true }
                ),
                media: onlyOnSurfaceZero(placementMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(placementWorkspace),
                onEvent: { placementEvents.record($0) }
            )
            _ = try? await placementCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            expect(
                placementEvents.messages.contains { $0.contains("Could not open the workspace") },
                "a workspace that will not place is reported as the placement failure it is"
            )
            expect(
                placementEvents.messages.allSatisfy { !$0.contains("start capturing") },
                "and never as a capture failure, which is the one thing it is not"
            )
            expect(
                placementMedia.startedDisplayIDs.isEmpty && !placementSession.isActive,
                "capture never started, and the canvas nothing could stand on is released"
            )
        }

        // A socket that dies between the workspace going up and the reply
        // reaching the wire is not a capture failure either: capture is the
        // step after it and never ran.
        do {
            let writeSession = VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())
            let writeWorkspace = FakeCanvasWorkspace()
            let writeMedia = FakeCanvasMedia()
            let writeEvents = DiagnosticsRecorder()
            let writeCoordinator = HostSessionCoordinator(
                controller: HostSessionController(
                    sessions: surfaceZeroOnly(writeSession),
                    keyConfinement: .unconfined,
                    privateDesktopOffered: { true }
                ),
                media: onlyOnSurfaceZero(writeMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(writeWorkspace),
                onEvent: { writeEvents.record($0) }
            )
            do {
                _ = try await writeCoordinator.handle(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
                ) { _ in
                    throw FakeMediaFailure.captureUnavailable
                }
                print("FAIL: a canvasReady that could not be written ends the canvas request")
                Foundation.exit(1)
            } catch {}
            expect(
                writeEvents.messages.contains { $0.contains("Could not tell the other machine") },
                "a reply that never reached the wire is reported as the write that failed"
            )
            expect(
                writeEvents.messages.allSatisfy { !$0.contains("start capturing") },
                "and not as a capture failure"
            )
            expect(
                writeMedia.startedDisplayIDs.isEmpty && writeWorkspace.stopCount == 1 && !writeSession.isActive,
                "capture never started, and the workspace and canvas that did go up come back down"
            )
        }

        // A capture that could not start ends the session on the spot, so it
        // must set the same end-of-session guard `goodbye` and the
        // stream-failure path set. Without it the error this path throws
        // reaches `HostNetworkSession`, whose handler calls `sessionDidEnd`
        // and runs a second teardown and a second goodbye for a session that
        // already ended.
        do {
            let endedAdapter = FakeVirtualDisplayAdapter()
            let endedSession = VirtualDisplaySession(adapter: endedAdapter)
            let endedMedia = FailingCanvasMedia()
            let endedWorkspace = FakeCanvasWorkspace()
            var endedOrder: [String] = []
            endedWorkspace.onStop = { endedOrder.append("workspace") }
            endedAdapter.onRelease = { _ in endedOrder.append("display") }
            let endedSignals = DiagnosticsRecorder()
            let endedCoordinator = HostSessionCoordinator(
                controller: HostSessionController(
                    sessions: surfaceZeroOnly(endedSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
                ),
                media: onlyOnSurfaceZero(endedMedia),
                videoSink: FakeVideoSink(),
                workspaces: onlyOnSurfaceZero(endedWorkspace),
                onSessionEnded: { endedSignals.record("ended") }
            )
            do {
                _ = try await endedCoordinator.handleWritingResponse(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
                )
                expect(false, "a capture that cannot start fails the canvas request")
            } catch {
            }
            expect(
                endedCoordinator.hasEnded,
                "a capture that could not start marks the session ended, so the transport's own follow-on teardown is a no-op"
            )
            expect(
                endedOrder == ["workspace", "display"],
                "the capture-failure teardown still stops the workspace window before releasing the canvas it sits on"
            )
            expect(endedSignals.messages == ["ended"], "session end is signalled once on the capture-failure path")

            await endedCoordinator.sessionDidEnd(reason: "transport-closed")
            expect(
                endedMedia.stopCount == 1 && endedWorkspace.stopCount == 1,
                "the transport's follow-on sessionDidEnd does not re-run a teardown the capture failure already ran"
            )
            expect(
                endedOrder == ["workspace", "display"],
                "and issues no second goodbye, so nothing is torn down or released twice"
            )
            expect(endedSignals.messages == ["ended"], "nor signals session end a second time")
        }

        let approvedStore = InMemoryApprovedDeviceStore()
        let restartIdentity = try! DeviceIdentity.generate()
        let firstRun = HostPairingService(hostIdentity: restartIdentity, approvedStore: approvedStore)
        firstRun.issueCode(code: "314159")
        let pairedDevice = try! DeviceIdentity.generate()
        let restartApproval = firstRun.handlePairRequest(
            deviceName: "Laptop",
            publicKey: pairedDevice.publicKey,
            code: "314159",
            signature: try! pairedDevice.sign(SensoriumFrameCodec.pairRequestTranscript(
                deviceName: "Laptop",
                clientPublicKey: pairedDevice.publicKey,
                code: "314159"
            ))
        )
        guard case let .pairApproved(restartHostKey, restartTLSHash, restartSignature?) = restartApproval else {
            expect(false, "the restart ceremony returns a signed approval")
            return
        }
        expect(restartHostKey == restartIdentity.publicKey && restartTLSHash == nil, "the ceremony approves the device")
        expect(
            approvedStore.name(for: pairedDevice.publicKey) == "Laptop",
            "the name the device gave at pairing is recorded alongside its key, not just the key itself"
        )
        expect(
            DeviceIdentity.verify(
                signature: restartSignature,
                message: SensoriumFrameCodec.pairApprovalTranscript(
                    deviceName: "Laptop",
                    clientPublicKey: pairedDevice.publicKey,
                    tlsCertificateHash: nil
                ),
                publicKey: restartIdentity.publicKey
            ),
            "a restart pairing approval remains signed"
        )
        let afterRestart = HostPairingService(hostIdentity: restartIdentity, approvedStore: approvedStore)
        expect(
            afterRestart.isApproved(pairedDevice.publicKey),
            "a paired device survives a host restart instead of silently needing re-pairing"
        )
        expect(
            approvedStore.name(for: pairedDevice.publicKey) == "Laptop",
            "the recorded name survives a host restart too, the same way the approval itself does"
        )
        expect(
            !afterRestart.isApproved(try! DeviceIdentity.generate().publicKey),
            "an unknown device is still refused after a restart"
        )


        let timeSyncAdapter = FakeVirtualDisplayAdapter()
        let timeSyncSession = VirtualDisplaySession(adapter: timeSyncAdapter)
        let timeSyncIdentity = try! DeviceIdentity.generate()
        let timeSyncController = HostSessionController(
            sessions: surfaceZeroOnly(timeSyncSession),
            approvedPublicKeys: [timeSyncIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try timeSyncController.handle(.timeSyncRequest(clientTimeNanoseconds: 42)) },
            "an unauthenticated peer cannot read the host clock"
        )
        let timeSyncTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: timeSyncIdentity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! timeSyncController.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: timeSyncIdentity.publicKey,
            signature: try! timeSyncIdentity.sign(timeSyncTranscript)
        ))
        let before = MonotonicClock.nowNanoseconds()
        let syncReply = try! timeSyncController.handle(.timeSyncRequest(clientTimeNanoseconds: 42))
        let after = MonotonicClock.nowNanoseconds()
        guard case let .timeSyncReply(echoed, hostTime)?? = Optional(syncReply) else {
            print("FAIL: an authenticated time-sync request returns a reply")
            Foundation.exit(1)
        }
        expect(echoed == 42, "the reply echoes the client timestamp it was asked about")
        expect(before <= hostTime && hostTime <= after, "the reply carries the host clock read during the call")
        expectThrows(
            HostSessionControllerError.unexpectedMessage,
            { _ = try timeSyncController.handle(.timeSyncReply(clientTimeNanoseconds: 1, hostTimeNanoseconds: 2)) },
            "a host never accepts a time-sync reply"
        )


        // Criterion 6: reaching the port must never inherit another device's
        // authority. One controller shared across connections would hand the
        // second peer the first peer's authenticated session.
        let sharedAdapter = FakeVirtualDisplayAdapter()
        let sharedSession = VirtualDisplaySession(adapter: sharedAdapter)
        let pairedIdentity = try! DeviceIdentity.generate()
        let connectionFactory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(sharedSession),
            approvedPublicKeys: [pairedIdentity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let pairedHello = SensoriumMessage.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: pairedIdentity.publicKey,
            signature: try! pairedIdentity.sign(
                SensoriumFrameCodec.authenticatedHelloTranscript(
                    protocolVersion: 1,
                    deviceName: "Laptop",
                    publicKey: pairedIdentity.publicKey,
                    hostCertificateHash: nil
                )
            )
        )

        let firstConnection = connectionFactory.makeController()
        _ = try! firstConnection.handle(pairedHello)
        _ = try! firstConnection.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(sharedSession.isActive, "the authenticated connection owns the session canvas")

        let secondConnection = connectionFactory.makeController()
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try secondConnection.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)) },
            "a second connection does not inherit the first connection's authentication"
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try secondConnection.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil)) },
            "a second connection cannot inject input on the first connection's authority"
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try secondConnection.handle(.timeSyncRequest(clientTimeNanoseconds: 1)) },
            "a second connection cannot read the host clock on the first connection's authority"
        )
        expect(sharedSession.isActive, "the unauthenticated connection did not disturb the live canvas")

        // The approval set is genuinely shared, so a device paired during one
        // connection is recognised by the next without a host restart.
        let laterConnection = connectionFactory.makeController()
        _ = try! laterConnection.handle(pairedHello)
        _ = try! laterConnection.handle(.timeSyncRequest(clientTimeNanoseconds: 1))


        // A dropped client redials before the host's socket teardown has run.
        // The stale connection must not release the canvas the reconnected one
        // is already using.
        let raceAdapter = FakeVirtualDisplayAdapter()
        let raceSession = VirtualDisplaySession(adapter: raceAdapter)
        let staleOwner = CanvasOwnerToken()
        let freshOwner = CanvasOwnerToken()

        let staleHandle = try! raceSession.start(owner: staleOwner, configuration: .remoteDefault)
        expect(raceSession.isActive, "the first connection acquired the canvas")

        // The reconnected connection takes ownership of the same live canvas
        // rather than acquiring a second one.
        let freshHandle = try! raceSession.start(owner: freshOwner, configuration: .remoteDefault)
        expect(freshHandle == staleHandle, "a reconnect reuses the one session canvas")
        expect(raceAdapter.acquiredConfigurations.count == 1, "a reconnect does not create a second canvas")

        raceSession.stop(owner: staleOwner)
        expect(raceSession.isActive, "the stale connection's teardown did not release the live canvas")
        expect(raceAdapter.releasedHandles.isEmpty, "no release was issued on behalf of the stale connection")

        raceSession.stop(owner: freshOwner)
        expect(!raceSession.isActive, "the owning connection still releases the canvas")
        expect(raceAdapter.releasedHandles.count == 1, "the canvas was released exactly once")

        raceSession.stop(owner: freshOwner)
        expect(raceAdapter.releasedHandles.count == 1, "a repeated release from the owner stays idempotent")

        // Host shutdown releases whatever is live, without needing a token.
        _ = try! raceSession.start(owner: CanvasOwnerToken(), configuration: .remoteDefault)
        raceSession.stop()
        expect(!raceSession.isActive, "an unconditional stop releases the canvas at host shutdown")
        expect(raceAdapter.releasedHandles.count == 2, "the shutdown release happened exactly once")


        // A session must survive input it refuses. Treating every controller
        // error as fatal turns one stray coordinate into a dropped session.
        expect(
            !HostSessionControllerError.invalidInput.isSessionFatal,
            "refused input does not end the session"
        )
        expect(
            !HostSessionControllerError.inputSessionUnavailable.isSessionFatal,
            "input arriving before the canvas is ready does not end the session"
        )
        expect(
            !HostSessionControllerError.invalidCanvasRequest.isSessionFatal,
            "a canvas request for the wrong geometry is answered, not fatal"
        )
        expect(
            !HostSessionControllerError.inputInjectionUnavailable.isSessionFatal,
            "a session with no injector still streams video"
        )
        // Anything that says the peer is not who it claims ends the session.
        expect(
            HostSessionControllerError.authenticationRequired.isSessionFatal,
            "a peer acting without authentication ends the session"
        )
        expect(
            HostSessionControllerError.invalidAuthentication.isSessionFatal,
            "a bad signature ends the session"
        )
        expect(
            HostSessionControllerError.deviceNotPaired.isSessionFatal,
            "an unpaired device ends the session"
        )
        expect(
            HostSessionControllerError.unexpectedMessage.isSessionFatal,
            "a peer speaking the host's half of the protocol ends the session"
        )


        // A link slower than the encoder must cost freshness, not memory. The
        // queue keeps at most one frame waiting behind the one in flight.
        func videoFrame(_ sequence: UInt64, keyFrame: Bool = false) -> EncodedVideoFramePacket {
            EncodedVideoFramePacket(
                sequence: sequence,
                presentationTimeNanoseconds: sequence * 1_000_000,
                isKeyFrame: keyFrame,
                codecConfiguration: keyFrame ? Data([1, 2, 3]) : nil,
                payload: Data([UInt8(sequence & 0xFF)])
            )
        }

        var queue = VideoSendQueue()
        expect(queue.enqueue(videoFrame(1, keyFrame: true)) == .sendNow, "the first frame goes straight out")
        expect(queue.enqueue(videoFrame(2)) == .queued, "a frame arriving mid-send waits")
        expect(queue.enqueue(videoFrame(3)) == .replacedStaleFrame, "a newer delta supersedes the waiting one")
        expect(queue.droppedFrameCount == 1, "the superseded frame is counted as dropped")

        // A keyframe is the client's only way back after loss, so it is never
        // thrown away for a delta that cannot be decoded without it.
        expect(queue.enqueue(videoFrame(4, keyFrame: true)) == .replacedStaleFrame, "a keyframe supersedes a waiting delta")
        expect(queue.enqueue(videoFrame(5)) == .droppedIncoming, "a delta never displaces a waiting keyframe")
        expect(queue.droppedFrameCount == 3, "both the superseded delta and the refused delta are counted")

        guard let next = queue.completeSend() else {
            print("FAIL: completing a send releases the waiting frame")
            Foundation.exit(1)
        }
        expect(next.sequence == 4, "the waiting keyframe is what goes out next")
        expect(queue.completeSend() == nil, "an empty queue releases nothing")
        expect(queue.enqueue(videoFrame(6)) == .sendNow, "the queue accepts a new frame once it is idle")


        // The same bounded one-in-flight, one-waiting policy also gates the
        // encoder's own input, between capture and VTCompressionSessionEncode-
        // Frame, via the same generic `VideoFrameAdmissionQueue` `VideoSendQueue`
        // is a type alias of -- proven here against a frame type unrelated to
        // `EncodedVideoFramePacket`, so the reuse is real code sharing, not
        // just a similar-looking policy reimplemented twice.
        struct FakeAdmissibleFrame: VideoFrameAdmissible, Equatable {
            let id: Int
            let isKeyFrame: Bool
        }
        var admissionQueue = VideoFrameAdmissionQueue<FakeAdmissibleFrame>()
        expect(
            admissionQueue.enqueue(FakeAdmissibleFrame(id: 1, isKeyFrame: false)) == .sendNow,
            "the first frame is admitted immediately"
        )
        expect(
            admissionQueue.enqueue(FakeAdmissibleFrame(id: 2, isKeyFrame: false)) == .queued,
            "a frame arriving while the bound is reached waits"
        )
        expect(
            admissionQueue.enqueue(FakeAdmissibleFrame(id: 3, isKeyFrame: false)) == .replacedStaleFrame,
            "the newest frame wins over the stale waiting one"
        )
        expect(admissionQueue.droppedFrameCount == 1, "the superseded frame is dropped and counted")
        expect(
            admissionQueue.enqueue(FakeAdmissibleFrame(id: 4, isKeyFrame: true)) == .replacedStaleFrame,
            "a keyframe supersedes a waiting delta"
        )
        expect(
            admissionQueue.enqueue(FakeAdmissibleFrame(id: 5, isKeyFrame: false)) == .droppedIncoming,
            "a keyframe is never dropped in favour of a delta"
        )
        expect(admissionQueue.droppedFrameCount == 3, "both drops are counted")
        expect(
            admissionQueue.completeSend() == FakeAdmissibleFrame(id: 4, isKeyFrame: true),
            "the protected keyframe is what goes out next"
        )


        // Two canvases share one byte channel. With one queue between them,
        // keyframe protection is scoped to the wrong thing: surface 1's
        // keyframe evicts surface 0's still-waiting keyframe, after which
        // surface 0 decodes nothing until its next IDR, and surface 1's delta
        // is refused outright by a keyframe belonging to a stream it could
        // not damage. This block is the record of that failure; the
        // per-surface queues below are what prevent it.
        var sharedQueue = VideoSendQueue()
        expect(sharedQueue.enqueue(videoFrame(1, keyFrame: true)) == .sendNow, "surface 0's frame takes the idle wire")
        expect(sharedQueue.enqueue(videoFrame(2, keyFrame: true)) == .queued, "surface 0's next keyframe waits behind it")
        expect(
            sharedQueue.enqueue(videoFrame(3)) == .droppedIncoming,
            "one shared queue refuses surface 1's delta because a keyframe from a different stream is waiting"
        )
        expect(
            sharedQueue.enqueue(videoFrame(4, keyFrame: true)) == .replacedStaleFrame,
            "one shared queue evicts surface 0's waiting keyframe for surface 1's"
        )

        var surfaceQueues = SurfaceVideoSendQueues()
        expect(
            surfaceQueues.enqueue(videoFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal) == .sendNow,
            "the first frame takes the idle wire"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(2, keyFrame: true), surface: surfaceZero, priority: .normal) == .queued,
            "surface 0's second keyframe waits in surface 0's own queue"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(3), surface: surfaceOne, priority: .normal) == .queued,
            "surface 1's delta waits in surface 1's own queue instead of being refused by surface 0's keyframe"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(4, keyFrame: true), surface: surfaceOne, priority: .normal) == .replacedStaleFrame,
            "surface 1's keyframe supersedes surface 1's own waiting delta"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(5), surface: surfaceOne, priority: .normal) == .droppedIncoming,
            "a delta never displaces a waiting keyframe, per surface exactly as before"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(6), surface: surfaceZero, priority: .normal) == .droppedIncoming,
            "surface 0's own delta still cannot displace surface 0's own waiting keyframe"
        )
        expect(surfaceQueues.droppedFrameCount == 3, "every per-surface drop is counted across both queues")

        // Fair share: with both surfaces backlogged, the wire alternates. No
        // focus signal exists on the wire, so nothing may legitimately prefer
        // one canvas over the other.
        guard let firstOut = surfaceQueues.completeSend() else {
            expect(false, "a completed send releases the longest-waiting surface's frame")
            return
        }
        expect(
            firstOut.surface == surfaceZero && firstOut.frame.sequence == 2,
            "surface 0 waited first, so surface 0's protected keyframe goes next"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(7), surface: surfaceZero, priority: .normal) == .queued,
            "surface 0 re-queues immediately, taking its turn at the back of the line"
        )
        guard let secondOut = surfaceQueues.completeSend() else {
            expect(false, "the second completed send releases surface 1's waiting frame")
            return
        }
        expect(
            secondOut.surface == surfaceOne && secondOut.frame.sequence == 4,
            "an eager surface 0 cannot win two turns in a row: surface 1 goes next"
        )
        expect(
            surfaceQueues.enqueue(videoFrame(8), surface: surfaceOne, priority: .normal) == .queued,
            "surface 1 re-queues behind surface 0"
        )
        guard let thirdOut = surfaceQueues.completeSend() else {
            expect(false, "the third completed send releases surface 0's waiting frame")
            return
        }
        expect(
            thirdOut.surface == surfaceZero && thirdOut.frame.sequence == 7,
            "with both surfaces continuously backlogged the wire alternates and neither starves"
        )
        guard let fourthOut = surfaceQueues.completeSend() else {
            expect(false, "the fourth completed send releases surface 1's waiting frame")
            return
        }
        expect(fourthOut.surface == surfaceOne && fourthOut.frame.sequence == 8, "the alternation continues")
        expect(surfaceQueues.completeSend() == nil, "an empty pair of queues releases nothing")
        expect(
            surfaceQueues.enqueue(videoFrame(9), surface: surfaceOne, priority: .normal) == .sendNow,
            "the wire is idle again once nothing is waiting on either surface"
        )

        // A single-surface session behaves exactly as one `VideoSendQueue`
        // does today: same admissions, same drop count, in the same order.
        var singleSurfaceQueues = SurfaceVideoSendQueues()
        var singleQueue = VideoSendQueue()
        let singleSurfaceScript: [EncodedVideoFramePacket] = [
            videoFrame(1, keyFrame: true),
            videoFrame(2),
            videoFrame(3),
            videoFrame(4, keyFrame: true),
            videoFrame(5),
        ]
        for frame in singleSurfaceScript {
            expect(
                singleSurfaceQueues.enqueue(frame, surface: surfaceZero, priority: .normal) == singleQueue.enqueue(frame),
                "one surface's admissions are byte-for-byte the single-queue policy for frame \(frame.sequence)"
            )
        }
        expect(
            singleSurfaceQueues.droppedFrameCount == singleQueue.droppedFrameCount,
            "one surface drops exactly what a single queue drops"
        )
        expect(
            singleSurfaceQueues.completeSend()?.frame == singleQueue.completeSend(),
            "one surface releases the same protected keyframe a single queue does"
        )

        // The waiting slot and the fairness line move together: a surface is
        // listed exactly while it holds a waiting frame, so `completeSend`
        // releases that surface's own frame and answers `nil` only when
        // neither surface has anything waiting. A run that answered `nil`
        // with a frame still waiting would strand it for good -- the wire
        // goes idle and the next enqueue takes the in-flight slot instead.
        // Driven by a fixed pseudo-random interleaving, so the sequences are
        // wider than the hand-written ones above and identical on every run.
        do {
            var propertyQueues = SurfaceVideoSendQueues()
            var expectedWaiting = CanvasSurfaceSlots<EncodedVideoFramePacket?> { _ in nil }
            var isWireBusy = false
            var randomState: UInt64 = 0x5EED
            func nextRandom() -> UInt64 {
                randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return randomState >> 33
            }
            func waitingSurfaceCount() -> Int {
                CanvasSurfaceID.allCases.filter { expectedWaiting[$0] != nil }.count
            }
            for step in 0..<400 {
                if nextRandom() % 3 == 0 {
                    guard isWireBusy else { continue }
                    guard let released = propertyQueues.completeSend() else {
                        expect(
                            waitingSurfaceCount() == 0,
                            "completeSend released nothing while a frame was still waiting, at step \(step)"
                        )
                        isWireBusy = false
                        continue
                    }
                    expect(
                        expectedWaiting[released.surface] == released.frame,
                        "completeSend released the frame that surface was actually holding, at step \(step)"
                    )
                    expectedWaiting[released.surface] = nil
                } else {
                    let surface = CanvasSurfaceID.allCases[Int(nextRandom() % 2)]
                    let frame = videoFrame(UInt64(step), keyFrame: nextRandom() % 4 == 0)
                    let priority: VideoSendPriority = nextRandom() % 2 == 0 ? .elevated : .normal
                    switch propertyQueues.enqueue(frame, surface: surface, priority: priority) {
                    case .sendNow:
                        expect(!isWireBusy, "the idle wire was taken only while it was idle, at step \(step)")
                        isWireBusy = true
                    case .queued, .replacedStaleFrame:
                        expectedWaiting[surface] = frame
                    case .droppedIncoming:
                        break
                    }
                }
            }
            while isWireBusy {
                guard let released = propertyQueues.completeSend() else {
                    expect(waitingSurfaceCount() == 0, "the drain went idle with a frame still waiting")
                    isWireBusy = false
                    break
                }
                expect(
                    expectedWaiting[released.surface] == released.frame,
                    "the drain released each surface's own waiting frame"
                )
                expectedWaiting[released.surface] = nil
            }
            expect(waitingSurfaceCount() == 0, "every admitted frame was dispatched, none orphaned")
            expect(
                propertyQueues.enqueue(videoFrame(9999), surface: surfaceZero, priority: .normal) == .sendNow,
                "a fully drained pair of queues leaves the wire idle for the next frame"
            )
        }

        // With a focus signal on the wire, the focused surface's frames are
        // preferred -- but preference is not strict priority. The unfocused
        // window is still visible on the user's second monitor, and a frozen
        // background window is a worse bug than a slightly slower focused
        // one, so the focused surface may take at most
        // `maximumConsecutivePriorityWins` turns in a row while the other
        // surface has a frame waiting.
        do {
            var focusedQueues = SurfaceVideoSendQueues()
            expect(
                focusedQueues.enqueue(videoFrame(1), surface: surfaceZero, priority: .normal) == .sendNow,
                "the first frame takes the idle wire"
            )
            // Both surfaces backlogged from here on, with focus on surface 1.
            _ = focusedQueues.enqueue(videoFrame(2), surface: surfaceZero, priority: .normal)
            _ = focusedQueues.enqueue(videoFrame(3), surface: surfaceOne, priority: .elevated)

            var dispatched: [CanvasSurfaceID] = []
            var nextSequence: UInt64 = 4
            for _ in 0..<8 {
                guard let out = focusedQueues.completeSend() else {
                    expect(false, "both surfaces are backlogged, so every completed send releases a frame")
                    return
                }
                dispatched.append(out.surface)
                // Whoever just went re-queues immediately, so neither surface
                // ever runs out of work and the schedule is what is measured.
                _ = focusedQueues.enqueue(
                    videoFrame(nextSequence),
                    surface: out.surface,
                    priority: out.surface == surfaceOne ? .elevated : .normal
                )
                nextSequence += 1
            }

            expect(
                dispatched.prefix(SurfaceVideoSendQueues.maximumConsecutivePriorityWins).allSatisfy { $0 == surfaceOne },
                "the focused surface is preferred: it wins the contended turns first"
            )
            let backgroundTurns = dispatched.filter { $0 == surfaceZero }.count
            expect(
                backgroundTurns >= 2,
                "the unfocused surface is not starved: it gets at least one turn in every \(SurfaceVideoSendQueues.maximumConsecutivePriorityWins + 1), so 2 of 8, not 0"
            )
            var longestFocusedRun = 0
            var run = 0
            for surface in dispatched {
                run = surface == surfaceOne ? run + 1 : 0
                longestFocusedRun = max(longestFocusedRun, run)
            }
            expect(
                longestFocusedRun == SurfaceVideoSendQueues.maximumConsecutivePriorityWins,
                "the focused surface never takes more than the documented number of consecutive turns while the other waits"
            )

            // A waiting keyframe is the unfocused surface's only way back to a
            // picture at all -- the client gates on `hasRecoveryKeyFrame`, so
            // every delta behind it is undecodable wire time. An elevated
            // delta therefore does not outrank it.
            var keyFrameQueues = SurfaceVideoSendQueues()
            _ = keyFrameQueues.enqueue(videoFrame(1), surface: surfaceZero, priority: .normal)
            expect(
                keyFrameQueues.enqueue(videoFrame(2, keyFrame: true), surface: surfaceZero, priority: .normal) == .queued,
                "the unfocused surface's keyframe waits"
            )
            expect(
                keyFrameQueues.enqueue(videoFrame(3), surface: surfaceOne, priority: .elevated) == .queued,
                "the focused surface's delta waits too"
            )
            expect(
                keyFrameQueues.completeSend()?.surface == surfaceZero,
                "an elevated delta does not preempt the unfocused surface's waiting keyframe"
            )

            // Focus still decides between two keyframes: preference applies
            // among equals, and the rule above is about keyframe versus delta.
            var twoKeyFrameQueues = SurfaceVideoSendQueues()
            _ = twoKeyFrameQueues.enqueue(videoFrame(1), surface: surfaceZero, priority: .normal)
            _ = twoKeyFrameQueues.enqueue(videoFrame(2, keyFrame: true), surface: surfaceZero, priority: .normal)
            _ = twoKeyFrameQueues.enqueue(videoFrame(3, keyFrame: true), surface: surfaceOne, priority: .elevated)
            expect(
                twoKeyFrameQueues.completeSend()?.surface == surfaceOne,
                "with both surfaces holding a keyframe, the focused one goes first"
            )
        }

        // A session that never receives a focus report must schedule exactly
        // as it did before the signal existed: every call site passes
        // `.normal`, and the dispatch order is the plain fair share above.
        do {
            var unreportedQueues = SurfaceVideoSendQueues()
            var todayQueues = SurfaceVideoSendQueues()
            _ = unreportedQueues.enqueue(videoFrame(1), surface: surfaceZero, priority: .normal)
            _ = todayQueues.enqueue(videoFrame(1), surface: surfaceZero)
            var unreportedOrder: [UInt64] = []
            var todayOrder: [UInt64] = []
            for sequence in UInt64(2)...9 {
                let surface = sequence.isMultiple(of: 2) ? surfaceZero : surfaceOne
                _ = unreportedQueues.enqueue(videoFrame(sequence), surface: surface, priority: .normal)
                _ = todayQueues.enqueue(videoFrame(sequence), surface: surface)
                if let out = unreportedQueues.completeSend() {
                    unreportedOrder.append(out.frame.sequence)
                }
                if let out = todayQueues.completeSend() {
                    todayOrder.append(out.frame.sequence)
                }
            }
            expect(
                unreportedOrder == todayOrder && !unreportedOrder.isEmpty,
                "with no focus reported, the schedule is identical to the one a caller that never passes a priority gets"
            )
        }


        // Every frame the encoder-input gate drops must reach the host stage
        // summary, exactly like a transport-level drop, so a slow encoder can
        // never lose frames invisibly.
        let encoderInputRecorder = HostMediaLatencyRecorder()
        expect(
            encoderInputRecorder.frameCounts.encoderInputDropped == 0,
            "a recorder with no encoder-input drops reports zero"
        )
        encoderInputRecorder.recordEncoderInputDrop()
        encoderInputRecorder.recordEncoderInputDrop()
        expect(
            encoderInputRecorder.frameCounts.encoderInputDropped == 2,
            "encoder-input drops are counted rather than silently discarded"
        )
        var encoderInputMetrics = SessionMetrics()
        _ = encoderInputMetrics.record(stage: .capture, startedAtNanoseconds: 0, endedAtNanoseconds: 1_000_000)
        guard let encoderInputSummary = HostLatencySummary.line(
            metrics: encoderInputMetrics,
            droppedFrameCount: 3,
            frameCounts: encoderInputRecorder.frameCounts
        ) else {
            expect(false, "a session with samples and encoder-input drops still produces a summary line")
            return
        }
        expect(
            encoderInputSummary.contains("5 dropped to keep up"),
            "the summary's dropped count folds in encoder-input drops alongside transport drops"
        )
        expect(
            encoderInputSummary.contains("encoderInputDropped=2"),
            "the summary breaks out encoder-input drops explicitly"
        )

        // Every frame the *global* admission gate drops must reach the host
        // stage summary too, distinctly from a single pipeline's own local
        // drops, so contention between two canvases sharing the encoder
        // cannot vanish behind one pipeline's healthy-looking count.
        let globalAdmissionRecorder = HostMediaLatencyRecorder()
        expect(
            globalAdmissionRecorder.frameCounts.globalAdmissionDropped == 0,
            "a recorder with no global-admission drops reports zero"
        )
        globalAdmissionRecorder.recordGlobalEncoderInputDrop()
        expect(
            globalAdmissionRecorder.frameCounts.globalAdmissionDropped == 1,
            "global-admission drops are counted rather than silently discarded"
        )
        var globalAdmissionMetrics = SessionMetrics()
        _ = globalAdmissionMetrics.record(stage: .capture, startedAtNanoseconds: 0, endedAtNanoseconds: 1_000_000)
        guard let globalAdmissionSummary = HostLatencySummary.line(
            metrics: globalAdmissionMetrics,
            droppedFrameCount: 0,
            frameCounts: globalAdmissionRecorder.frameCounts
        ) else {
            expect(false, "a session with samples and global-admission drops still produces a summary line")
            return
        }
        expect(
            globalAdmissionSummary.contains("1 dropped to keep up"),
            "the summary's dropped count folds in global-admission drops alongside transport and local encoder-input drops"
        )
        expect(
            globalAdmissionSummary.contains("globalAdmissionDropped=1"),
            "the summary breaks out global-admission drops explicitly"
        )


        // `SharedEncodeAdmissionGate` bounds frames in flight toward the
        // encoder *across every pipeline*, not just within one -- the gap a
        // per-pipeline `EncodeAdmissionGate` cannot see, since two pipelines
        // each with their own gate are invisible to each other. These first
        // tests drive it directly and deterministically against a fake
        // `Frame` type, the same way `VideoFrameAdmissionQueue` is tested
        // above, decoupled from `CMSampleBuffer`/`VideoToolboxEncoder`, which
        // this repository's runners never touch.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let sourceA = gate.makeSource()
            let sourceB = gate.makeSource()
            nonisolated(unsafe) var admittedA: [Int] = []
            nonisolated(unsafe) var admittedB: [Int] = []
            expect(
                gate.request(source: sourceA, sampleBuffer: 1, submit: { admittedA.append($0) }) == .admittedNow,
                "the first request finds a free slot and runs immediately"
            )
            expect(admittedA == [1], "the admitted submit closure actually ran, synchronously")
            expect(
                gate.request(source: sourceB, sampleBuffer: 2, submit: { admittedB.append($0) }) == .pending,
                "a second source's request waits its turn while the only slot is held"
            )
            expect(admittedB.isEmpty, "a pending request has not run yet")
            gate.releaseSlot(source: sourceA)
            expect(admittedB == [2], "releasing the slot dispatches the waiting request")
            expect(gate.droppedFrameCount == 0, "no drop happened: the second request merely waited its turn")
        }

        // `EncodeAdmissionGate` never produces more than one outstanding
        // request per source, so this only fires as a defensive property of
        // the reusable gate itself -- mirrors exactly how
        // `VideoFrameAdmissionQueue` counts a stale waiting frame it had to
        // replace.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let sourceA = gate.makeSource()
            let sourceB = gate.makeSource()
            _ = gate.request(source: sourceA, sampleBuffer: 1, submit: { _ in })
            _ = gate.request(source: sourceB, sampleBuffer: 2, submit: { _ in })
            expect(gate.droppedFrameCount == 0, "a source's first pending request is not a drop")
            nonisolated(unsafe) var secondAdmitted: [Int] = []
            let secondResult = gate.request(source: sourceB, sampleBuffer: 3, submit: { secondAdmitted.append($0) })
            expect(
                secondResult == .replacedPendingRequest,
                "a second request from the same source before its first is dispatched replaces, rather than queues, the older one"
            )
            expect(gate.droppedFrameCount == 1, "the replaced request is counted as dropped")
            gate.releaseSlot(source: sourceA)
            expect(secondAdmitted == [3], "the newer request is what actually gets dispatched")
        }

        // A pipeline that stops while its frame is still waiting for a
        // global slot must not hold that fairness turn forever for output
        // that will now never exist.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let sourceA = gate.makeSource()
            let sourceB = gate.makeSource()
            _ = gate.request(source: sourceA, sampleBuffer: 1, submit: { _ in })
            _ = gate.request(source: sourceB, sampleBuffer: 2, submit: { _ in })
            expect(
                gate.unregisterSource(sourceB) == true,
                "a pipeline that stops while its frame is still pending drops that frame"
            )
            expect(gate.droppedFrameCount == 1, "the abandoned frame is counted, not silently forgotten")
            expect(
                gate.unregisterSource(sourceA) == false,
                "unregistering a source with nothing pending drops nothing"
            )
        }

        // A pipeline that stops while its frame is genuinely *in flight* --
        // submitted to the encoder, no terminal callback yet -- must give
        // that slot back too. Its callback may never arrive, and a slot no
        // live source holds is one the gate can never reclaim on its own.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let dying = gate.makeSource()
            let survivor = gate.makeSource()
            nonisolated(unsafe) var admitted: [Int] = []
            _ = gate.request(source: dying, sampleBuffer: 1, submit: { admitted.append($0) })
            gate.unregisterSource(dying)
            expect(gate.framesInFlight == 0, "a source that stops mid-encode releases the slot it was holding")
            expect(
                gate.request(source: survivor, sampleBuffer: 2, submit: { admitted.append($0) }) == .admittedNow,
                "the slot the stopped source gave back is usable by a source that outlived it"
            )
            expect(admitted == [1, 2], "both frames actually ran; the second was not stranded behind a leaked slot")
        }

        // Fairness: with no focus signal in the wire protocol, every request
        // today carries `.normal` priority, so a source that keeps
        // re-requesting faster than a sibling must never be able to win
        // every race for a freed slot merely by asking first -- a sibling
        // that has been waiting longer is served first. Driven with an
        // explicit, deterministic call order rather than real thread timing,
        // since this proves the scheduling *policy*, not thread safety.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let eager = gate.makeSource()
            let patient = gate.makeSource()
            nonisolated(unsafe) var eagerAdmissions: [Int] = []
            nonisolated(unsafe) var patientAdmissions: [Int] = []

            expect(
                gate.request(source: eager, sampleBuffer: 0, submit: { eagerAdmissions.append($0) }) == .admittedNow,
                "eager grabs the only slot first, arriving first"
            )
            expect(
                gate.request(source: patient, sampleBuffer: 100, submit: { patientAdmissions.append($0) }) == .pending,
                "patient is now waiting for the slot eager holds"
            )

            // eager's frame completes and it immediately re-requests before
            // patient is dispatched -- exactly the ordering
            // `EncodeAdmissionGate.encodeCompleted` produces: `releaseSlot`
            // runs first, then `submit` re-requests.
            gate.releaseSlot(source: eager)
            expect(
                patientAdmissions == [100],
                "patient, already waiting, is served before eager's new request -- eager cannot cut back in line"
            )
            let requeue = gate.request(source: eager, sampleBuffer: 1, submit: { eagerAdmissions.append($0) })
            expect(requeue == .pending, "eager's immediate re-request now waits behind patient instead of preempting it")

            gate.releaseSlot(source: patient)
            expect(eagerAdmissions == [0, 1], "once patient's frame completes, eager's queued request is finally served -- no source waits forever")
        }

        // `priority` is the seam a later focus signal attaches to: a source
        // that arrives second but at a higher priority is still served
        // first, ahead of an already-waiting normal-priority source. Every
        // real call site passes `.normal` today, so this exercises the seam
        // itself, not any caller Sensorium ships yet.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let holder = gate.makeSource()
            let low = gate.makeSource()
            let high = gate.makeSource()
            nonisolated(unsafe) var lowAdmissions: [Int] = []
            nonisolated(unsafe) var highAdmissions: [Int] = []

            _ = gate.request(source: holder, sampleBuffer: -1, submit: { _ in })
            _ = gate.request(source: low, sampleBuffer: 1, priority: .normal, submit: { lowAdmissions.append($0) })
            _ = gate.request(source: high, sampleBuffer: 2, priority: .elevated, submit: { highAdmissions.append($0) })
            gate.releaseSlot(source: holder)
            expect(highAdmissions == [2], "a higher-priority waiting source is served first, even though it asked second")
            expect(lowAdmissions.isEmpty, "the lower-priority source is still waiting")
        }

        // Preference at the encode gate is bounded the same way it is on the
        // send path: the focused canvas's frames go first, but a background
        // canvas that keeps requesting must still reach the encoder, or its
        // window freezes rather than merely running slower.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let focused = gate.makeSource()
            let background = gate.makeSource()
            nonisolated(unsafe) var dispatched: [String] = []
            func request(_ source: EncodeAdmissionSource, _ name: String, _ priority: EncodeAdmissionPriority) {
                _ = gate.request(source: source, sampleBuffer: 0, priority: priority) { _ in dispatched.append(name) }
            }

            request(focused, "focused", .elevated)
            dispatched.removeAll()
            // Both sources backlogged behind the one in-flight slot, the
            // background one waiting first.
            request(background, "background", .normal)
            request(focused, "focused", .elevated)
            // The slot moves between the two sources, and a release now names
            // the source that holds it, so the holder is tracked explicitly.
            var holder = focused
            for _ in 0..<8 {
                gate.releaseSlot(source: holder)
                guard let ran = dispatched.last else {
                    expect(false, "a released slot with two sources waiting always dispatches one of them")
                    return
                }
                if ran == "focused" {
                    holder = focused
                    request(focused, "focused", .elevated)
                } else {
                    holder = background
                    request(background, "background", .normal)
                }
            }

            let cap = SharedEncodeAdmissionGate<Int>.maximumConsecutivePriorityWins
            expect(
                dispatched.prefix(cap).allSatisfy { $0 == "focused" },
                "the focused pipeline's frames are preferred at the encode gate"
            )
            expect(
                dispatched.filter { $0 == "background" }.count >= 2,
                "the background pipeline still reaches the encoder: at least one turn in every \(cap + 1)"
            )
            var longestRun = 0
            var run = 0
            for name in dispatched {
                run = name == "focused" ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
            expect(
                longestRun == cap,
                "the focused pipeline never takes more than the documented number of consecutive slots while the other waits"
            )
        }

        // A host that never receives a focus report: every request carries
        // `.normal`, and the gate degrades to exactly the fair share it ran
        // before the signal existed.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let first = gate.makeSource()
            let second = gate.makeSource()
            nonisolated(unsafe) var dispatched: [String] = []
            _ = gate.request(source: first, sampleBuffer: 0, priority: .normal) { _ in }
            _ = gate.request(source: second, sampleBuffer: 1, priority: .normal) { _ in dispatched.append("second") }
            _ = gate.request(source: first, sampleBuffer: 2, priority: .normal) { _ in dispatched.append("first") }
            gate.releaseSlot(source: first)
            gate.releaseSlot(source: second)
            expect(
                dispatched == ["second", "first"],
                "with nothing focused, the longest-waiting source is served first, exactly as before"
            )
        }

}
