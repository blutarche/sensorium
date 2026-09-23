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
func runCoreSessionTestsPart4(_ fixtures: CoreSessionSharedFixtures) async {
    let surfaceZero = fixtures.surfaceZero!
    let surfaceOne = fixtures.surfaceOne!
    // Duplicated from `runCoreSessionTestsPart2`, which is where this part's
    // own local `videoFrame(...)` calls below need it from: a pure helper
    // with no captured state, so a second declaration is exact and safe,
    // unlike the stateful fixtures above.
    func videoFrame(_ sequence: UInt64, keyFrame: Bool = false) -> EncodedVideoFramePacket {
        EncodedVideoFramePacket(
            sequence: sequence,
            presentationTimeNanoseconds: sequence * 1_000_000,
            isKeyFrame: keyFrame,
            codecConfiguration: keyFrame ? Data([1, 2, 3]) : nil,
            payload: Data([UInt8(sequence & 0xFF)])
        )
    }

        // Each canvasReady is signed over its own surfaceID, so a client
        // cannot be handed surface 0's canvas under surface 1's name.
        do {
            let dualSignAdapter = FakeVirtualDisplayAdapter()
            dualSignAdapter.handleValuesToVend = [7, 8]
            let dualSignHost = try! DeviceIdentity.generate()
            let dualSignClient = try! DeviceIdentity.generate()
            let dualSignController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: dualSignAdapter) },
                requireAuthentication: true,
                pairing: HostPairingService(
                    hostIdentity: dualSignHost,
                    approvedPublicKeys: [dualSignClient.publicKey]
                ),
                keyConfinement: .unconfined
            )
            let dualSignTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: "Laptop",
                publicKey: dualSignClient.publicKey,
                hostCertificateHash: nil
            )
            _ = try! dualSignController.handle(.authenticatedHello(
                protocolVersion: 1,
                deviceName: "Laptop",
                publicKey: dualSignClient.publicKey,
                signature: try! dualSignClient.sign(dualSignTranscript)
            ))
            for surfaceID: UInt32 in [0, 1] {
                let ready = try! dualSignController.handle(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: surfaceID)
                )
                guard case let .canvasReady(displayID, _, _, hostSignature?, echoedSurfaceID, _) = ready else {
                    expect(false, "each canvas request is answered with a signed canvasReady")
                    return
                }
                expect(echoedSurfaceID == surfaceID, "the reply names the surface it answers")
                expect(
                    DeviceIdentity.verify(
                        signature: hostSignature,
                        message: SensoriumFrameCodec.canvasReadyTranscript(
                            displayID: displayID,
                            logicalWidth: 1920,
                            logicalHeight: 1200,
                            clientPublicKey: dualSignClient.publicKey,
                            surfaceID: surfaceID
                        ),
                        publicKey: dualSignHost.publicKey
                    ),
                    "surface \(surfaceID)'s canvasReady is signed over its own displayID and surfaceID"
                )
            }
            expect(
                dualSignAdapter.acquiredConfigurations.count == 2,
                "two surfaces means two displays, each acquired once"
            )
        }

        // The same two-canvas negotiation over the real transport loop: the
        // host handles one control message at a time, so the second creation
        // cannot begin before the first has finished.
        do {
            let dualWireAdapter = FakeVirtualDisplayAdapter()
            dualWireAdapter.handleValuesToVend = [7, 8]
            let dualWireGate = CanvasCreationGate()
            let dualWireController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in
                    VirtualDisplaySession(adapter: dualWireAdapter, creationGate: dualWireGate)
                },
                keyConfinement: .unconfined
            )
            let dualWireChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1),
            ])
            let dualWireSession = HostNetworkSession(
                connection: dualWireChannel,
                controller: dualWireController
            )
            dualWireSession.attach(coordinator: HostSessionCoordinator(
                controller: dualWireController,
                media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
                videoSink: FakeVideoSink(),
                workspaces: CanvasSurfaceSlots { _ in InterleavingCanvasWorkspace(gate: dualWireGate) }
            ))
            dualWireSession.start()
            try! await Task.sleep(for: .milliseconds(300))
            let readied: [(UInt32, UInt32?)] = dualWireChannel.sentPackets.compactMap {
                guard case let .control(.canvasReady(displayID, _, _, _, surfaceID, _)) = $0 else { return nil }
                return (displayID, surfaceID)
            }
            expect(readied.count == 2, "both canvas requests are answered over the wire")
            expect(
                readied.map(\.0) == [7, 8] && readied.map(\.1) == [0, 1],
                "each surface is readied on its own display, in the order requested"
            )
            expect(
                dualWireChannel.cancelCount == 0,
                "neither creation is rejected by the shared gate, so the connection survives both"
            )
        }

        // Surface-tagged video (tag 2) goes only to a peer that proved it
        // understands surfaces by supplying a surfaceID in `canvasRequest` and
        // receiving the echo. An older client that receives an unknown tag ends
        // its session, and its reconnect driver redials into the same
        // negotiation and dies again -- a reconnect loop, not a degraded
        // picture -- so this gate is a correctness requirement.
        func videoTags(_ channel: FakeHostByteChannel) -> [UInt8] {
            channel.sentFrames.map { $0[$0.startIndex] }.filter { $0 != 0 }
        }

        do {
            let legacyController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            )
            let legacyMedia = FakeCanvasMedia()
            let legacyChannel = FakeHostByteChannel(scriptedMessages: [
                // Exactly what an older client sends: no surfaceID at all.
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            ])
            let legacySession = HostNetworkSession(connection: legacyChannel, controller: legacyController)
            legacySession.attach(coordinator: HostSessionCoordinator(
                controller: legacyController,
                media: onlyOnSurfaceZero(legacyMedia),
                videoSink: legacySession,
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
            ))
            legacySession.start()
            try! await Task.sleep(for: .milliseconds(200))
            let legacyFrame = videoFrame(1, keyFrame: true)
            legacyMedia.emit(legacyFrame)
            try! await Task.sleep(for: .milliseconds(100))
            expect(videoTags(legacyChannel) == [1], "a client that never supplied a surfaceID receives tag 1")
            expect(
                legacyChannel.sentFrames.last == (try! SensoriumTransportPacketCodec.encode(.video(legacyFrame))),
                "the single-surface frame is byte-for-byte the framing this host has always written"
            )

            // Surface 1 cannot exist for this peer, but if it somehow produced
            // a frame it must be dropped rather than written as tag 1, which
            // would interleave a second sequence into surface 0's stream.
            legacySession.send(videoFrame(2, keyFrame: true), surface: surfaceOne, priority: .normal)
            try! await Task.sleep(for: .milliseconds(100))
            expect(videoTags(legacyChannel) == [1], "a surface 1 frame is never smuggled onto tag 1")

            // The error path: the transport dies, the session tears itself
            // down, and a late frame still must not change tag.
            legacySession.stop()
            try! await Task.sleep(for: .milliseconds(150))
            legacySession.send(videoFrame(3, keyFrame: true), surface: surfaceZero, priority: .normal)
            try! await Task.sleep(for: .milliseconds(100))
            expect(
                videoTags(legacyChannel).allSatisfy { $0 == 1 },
                "no path through teardown promotes a frame to tag 2"
            )
        }

        // A canvas request that is refused never produces an echo, so it never
        // unlocks tag 2 either -- and neither does a reconnect, which starts a
        // fresh session with a fresh gate.
        do {
            let refusedController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            )
            let refusedChannel = FakeHostByteChannel(scriptedMessages: [
                // Refused for geometry, before any surfaceID is echoed.
                .canvasRequest(logicalWidth: 1280, logicalHeight: 800, scale: 2, surfaceID: 0),
            ])
            let refusedSession = HostNetworkSession(connection: refusedChannel, controller: refusedController)
            refusedSession.attach(coordinator: HostSessionCoordinator(
                controller: refusedController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: refusedSession,
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
            ))
            refusedSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            expect(
                !refusedChannel.sentPackets.contains { if case .control(.canvasReady) = $0 { return true } else { return false } },
                "a refused canvas request is never answered with a canvasReady"
            )
            refusedSession.send(videoFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal)
            try! await Task.sleep(for: .milliseconds(100))
            expect(videoTags(refusedChannel) == [1], "a surfaceID that was never echoed does not unlock tag 2")

            // The reconnect: same peer, new connection, no canvasRequest yet.
            let reconnectController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            )
            let reconnectChannel = FakeHostByteChannel(scriptedMessages: [])
            let reconnectSession = HostNetworkSession(connection: reconnectChannel, controller: reconnectController)
            reconnectSession.start()
            try! await Task.sleep(for: .milliseconds(100))
            reconnectSession.send(videoFrame(1, keyFrame: true), surface: surfaceZero, priority: .normal)
            try! await Task.sleep(for: .milliseconds(100))
            expect(videoTags(reconnectChannel) == [1], "a reconnected session starts over on tag 1 until its own echo")
        }

        // A client that supplied surfaceID and got the echo receives tag 2,
        // carrying the surface each frame actually came from.
        do {
            let taggedAdapter = FakeVirtualDisplayAdapter()
            taggedAdapter.handleValuesToVend = [7, 8]
            let taggedGate = CanvasCreationGate()
            let taggedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in
                    VirtualDisplaySession(adapter: taggedAdapter, creationGate: taggedGate)
                },
                keyConfinement: .unconfined
            )
            let taggedMediaZero = FakeCanvasMedia()
            let taggedMediaOne = FakeCanvasMedia()
            let taggedChannel = FakeHostByteChannel(scriptedMessages: [
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1),
            ])
            let taggedSession = HostNetworkSession(connection: taggedChannel, controller: taggedController)
            taggedSession.attach(coordinator: HostSessionCoordinator(
                controller: taggedController,
                media: CanvasSurfaceSlots<any CanvasMediaStreaming>(
                    surface0: taggedMediaZero,
                    surface1: taggedMediaOne
                ),
                videoSink: taggedSession,
                workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
            ))
            taggedSession.start()
            try! await Task.sleep(for: .milliseconds(300))
            taggedMediaZero.emit(videoFrame(1, keyFrame: true))
            try! await Task.sleep(for: .milliseconds(100))
            taggedMediaOne.emit(videoFrame(2, keyFrame: true))
            try! await Task.sleep(for: .milliseconds(100))
            expect(videoTags(taggedChannel) == [2, 2], "a surface-aware client's frames go out on tag 2")
            let taggedSurfaces: [UInt32] = taggedChannel.sentPackets.compactMap {
                guard case let .videoForSurface(surfaceID, _) = $0 else { return nil }
                return surfaceID
            }
            expect(
                taggedSurfaces == [0, 1],
                "each frame carries the surfaceID of the canvas it was captured from"
            )
            let taggedSequences: [UInt64] = taggedChannel.sentPackets.compactMap {
                guard case let .videoForSurface(_, frame) = $0 else { return nil }
                return frame.sequence
            }
            expect(taggedSequences == [1, 2], "each surface's own frame is what it carries")

            // Both surfaces' queues feed one byte channel, so exactly one send
            // may be in flight on it at a time however the waiting slots are
            // partitioned.
            taggedChannel.sendDelay = .milliseconds(30)
            for sequence in 3...8 {
                taggedMediaZero.emit(videoFrame(UInt64(sequence)))
                taggedMediaOne.emit(videoFrame(UInt64(sequence)))
            }
            try! await Task.sleep(for: .milliseconds(400))
            expect(
                videoTags(taggedChannel).count >= 4,
                "the delayed burst really did put further sends on the channel, so the bound below is not vacuous"
            )
            expect(
                taggedChannel.peakConcurrentSends == 1,
                "one byte channel means one send in flight, never one per surface"
            )
        }

        // The focus signal: which canvas the viewer is actually looking at.
        // Absence of it is not "surface 0" -- a host that never hears one has
        // no focused surface at all, and schedules both canvases by fair
        // share.
        do {
            let focusSessions = CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) }
            let focusController = HostSessionController(
                sessions: focusSessions,
                inputInjector: FakeInputInjector(),
                keyConfinement: .unconfined
            )
            expect(
                focusController.focusedSurface == nil,
                "a session that has never received a focus report has no focused surface"
            )
            for surfaceID in [UInt32(0), UInt32(1)] {
                _ = try! focusController.handle(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: surfaceID)
                )
            }

            expect(
                try! focusController.handle(.viewerFocus(surfaceID: 1, hasViewerFocus: true)) == nil,
                "a focus report is answered with no message: it changes scheduling, not the conversation"
            )
            expect(
                focusController.focusedSurface == surfaceOne,
                "the reported surface becomes the focused one"
            )

            // The third state: the user is looking at a local app, so no
            // canvas is focused. It must not collapse into surface 0.
            _ = try! focusController.handle(.viewerFocus(surfaceID: nil, hasViewerFocus: false))
            expect(
                focusController.focusedSurface == nil,
                "no viewer focus at all clears the focused surface instead of naming canvas 0"
            )

            _ = try! focusController.handle(.viewerFocus(surfaceID: 1, hasViewerFocus: true))
            expectThrows(
                HostSessionControllerError.invalidViewerFocus,
                { _ = try focusController.handle(.viewerFocus(surfaceID: 2, hasViewerFocus: true)) },
                "a focus report naming a surface outside the two-canvas cap is refused"
            )
            expect(
                HostSessionControllerError.invalidViewerFocus.isSessionFatal == false,
                "a refused focus report never drops the session: it is a scheduling hint, not an identity claim"
            )
            expect(
                focusController.focusedSurface == surfaceOne,
                "a refused focus report leaves the last valid focus in place"
            )
            expect(focusSessions[surfaceZero].isActive, "a refused focus report leaves both canvases alive")
            expect(focusSessions[surfaceOne].isActive, "a refused focus report leaves both canvases alive")

            // Gated exactly like input and viewerDrawableSize: an
            // unauthenticated peer never gets to steer the host's encoder.
            let guardedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                requireAuthentication: true,
                keyConfinement: .unconfined
            )
            expectThrows(
                HostSessionControllerError.authenticationRequired,
                { _ = try guardedController.handle(.viewerFocus(surfaceID: 0, hasViewerFocus: true)) },
                "an unauthenticated peer's focus report is refused before it touches scheduling"
            )

            // A focus report for a canvas this connection never created is
            // refused rather than redirected to the other one.
            let singleSurfaceFocusController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                keyConfinement: .unconfined
            )
            _ = try! singleSurfaceFocusController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            expectThrows(
                HostSessionControllerError.inputSessionUnavailable,
                { _ = try singleSurfaceFocusController.handle(.viewerFocus(surfaceID: 1, hasViewerFocus: true)) },
                "focus on a canvas this connection never created is refused"
            )
            expect(
                singleSurfaceFocusController.focusedSurface == nil,
                "a refused focus report never sets focus on a canvas that does not exist"
            )

            // What an old host does with these exact bytes: its decoder does
            // not know the type, so it arrives as `.unrecognized` and is
            // skipped. The session keeps running and never learns of focus.
            let oldPeerController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                keyConfinement: .unconfined
            )
            _ = try! oldPeerController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            expect(
                try! oldPeerController.handle(.unrecognized(type: "viewerFocus")) == nil,
                "a host that predates the focus signal answers it with nothing"
            )
            expect(
                oldPeerController.focusedSurface == nil,
                "a host that predates the focus signal keeps no focus, so it keeps fair share"
            )
        }

        // Clipboard sync. Writing the peer's pasteboard onto the Mini is a
        // real side effect on the user's own machine, so the host gate is
        // authentication plus an active canvas -- never a pairing-only or
        // still-handshaking connection.
        do {
            let clipboardIdentity = try! DeviceIdentity.generate()
            let clipboardAdapter = FakeVirtualDisplayAdapter()
            let clipboardController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: clipboardAdapter) },
                approvedPublicKeys: [clipboardIdentity.publicKey],
                requireAuthentication: true,
                keyConfinement: .unconfined
            )
            let clipboardPasteboard = FakeClipboardPasteboard()
            let clipboardLog = DiagnosticsRecorder()
            let clipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: clipboardPasteboard, isEnabled: true),
                isSessionAdmissible: { clipboardController.isSessionAuthenticatedAndActive },
                log: { clipboardLog.record($0) }
            )
            let fromPeer = ClipboardContent.text("from the peer")

            expect(
                !clipboardController.isSessionAuthenticatedAndActive,
                "a connection that has not authenticated is not admissible for clipboard"
            )
            clipboard.receive(fromPeer)
            expect(clipboardPasteboard.writtenContents.isEmpty, "a clipboard arriving before authentication is never applied")
            expect(clipboard.poll() == nil, "and nothing is read off the pasteboard for it either")

            let clipboardTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: "Laptop",
                publicKey: clipboardIdentity.publicKey,
                hostCertificateHash: nil
            )
            _ = try! clipboardController.handle(.authenticatedHello(
                protocolVersion: 1,
                deviceName: "Laptop",
                publicKey: clipboardIdentity.publicKey,
                signature: try! clipboardIdentity.sign(clipboardTranscript)
            ))
            expect(
                !clipboardController.isSessionAuthenticatedAndActive,
                "authentication alone is not an active session"
            )
            clipboard.receive(fromPeer)
            expect(clipboardPasteboard.writtenContents.isEmpty, "a clipboard arriving before any canvas exists is never applied")

            _ = try! clipboardController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
            expect(
                clipboardController.isSessionAuthenticatedAndActive,
                "an authenticated session with an active canvas is admissible"
            )
            clipboard.receive(fromPeer)
            expect(
                clipboardPasteboard.writtenContents == [fromPeer],
                "the peer's clipboard reaches the Mini's pasteboard exactly once the session is admissible"
            )
            for _ in 0..<5 {
                expect(clipboard.poll() == nil, "an applied clipboard is never offered back to the peer")
            }

            expect(
                clipboardLog.messages.contains { $0.contains("clipboard applied: text, 13 bytes") },
                "the applied clipboard is logged by kind and size"
            )
            expect(
                clipboardLog.messages.contains { $0.contains("the session is not authenticated with an active canvas") },
                "and a refused one is logged with its reason"
            )
            expect(
                clipboardLog.messages.allSatisfy { !$0.contains("from the peer") },
                "no clipboard log line carries any of the content, at any level"
            )

            let copiedImage = ClipboardContent.image(format: .png, data: Data(repeating: 3, count: 900))
            clipboardPasteboard.stageLocalCopy(ClipboardReadout(content: copiedImage, isExcludedByType: false))
            expect(clipboard.poll() == .clipboard(copiedImage), "a copy made on the Mini is offered to the peer on tag 3")

            _ = try! clipboardController.handle(.goodbye(reason: "client-disconnected"))
            expect(
                !clipboardController.isSessionAuthenticatedAndActive,
                "a session whose canvas is released is no longer admissible"
            )
            clipboardPasteboard.stageLocalCopy(ClipboardReadout(content: .text("after the session"), isExcludedByType: false))
            expect(clipboard.poll() == nil, "and nothing is sent after the session ends")
        }

        // Inbound applies are floored the same way outbound polls are. Every
        // received clipboard writes the Mini's real pasteboard on the main
        // actor, so a peer streaming them back to back clobbers the user's
        // own clipboard continuously and queues that work ahead of the
        // workspace. The floor coalesces rather than drops: the peer only
        // sends on change, so a dropped clipboard is never re-offered, while
        // a coalesced one still lands the newest content the user copied.
        do {
            let burstPasteboard = FakeClipboardPasteboard()
            let burstLog = DiagnosticsRecorder()
            let burstClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: burstPasteboard, isEnabled: true),
                log: { burstLog.record($0) }
            )
            burstClipboard.receive(.text("first"))
            expect(
                burstPasteboard.writtenContents == [.text("first")],
                "the first received clipboard is applied immediately"
            )
            for index in 0..<2000 {
                burstClipboard.receive(.text("burst \(index)"))
            }
            expect(
                burstPasteboard.writtenContents == [.text("first")],
                "applies arriving inside the floor do not each reach the pasteboard"
            )
            try! await Task.sleep(for: .seconds(ClipboardPolicy.minimumApplyIntervalSeconds * 2))
            expect(
                burstPasteboard.writtenContents == [.text("first"), .text("burst 1999")],
                "one coalesced apply lands once the floor expires, carrying the newest content"
            )
            try! await Task.sleep(for: .seconds(ClipboardPolicy.minimumApplyIntervalSeconds * 3))
            expect(
                burstPasteboard.writtenContents.count == 2,
                "2000 packets leave nothing draining behind them: the deferred work is one slot, not a queue"
            )
            expect(
                burstLog.messages.count <= 4,
                "and a 2000-packet burst does not write a log line per packet either"
            )
            expect(
                burstLog.messages.allSatisfy { !$0.contains("first") && !$0.contains("burst") },
                "no clipboard log line carries any of the content, at any level"
            )
        }

        // The handshake window: the engine is built when the connection is
        // accepted, but nothing may be sent until the session is admissible,
        // and what was copied in between belongs to the machine rather than
        // to the session -- that window is exactly when someone copies a code
        // out of a password manager.
        do {
            let gate = ClipboardGateSwitch()
            let gatedPasteboard = FakeClipboardPasteboard()
            let gatedClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: gatedPasteboard, isEnabled: true),
                isSessionAdmissible: { gate.isOpen }
            )
            gatedPasteboard.stageLocalCopy(
                ClipboardReadout(content: .text("copied while handshaking"), isExcludedByType: false)
            )
            expect(gatedClipboard.poll() == nil, "nothing is polled off the pasteboard before the gate opens")
            gate.isOpen = true
            expect(
                gatedClipboard.poll() == nil,
                "what was copied before the session was admissible is not sent once the gate opens"
            )
            let duringSession = ClipboardContent.text("copied during the session")
            gatedPasteboard.stageLocalCopy(ClipboardReadout(content: duringSession, isExcludedByType: false))
            expect(
                gatedClipboard.poll() == .clipboard(duringSession),
                "a copy made after the gate opened is still sent"
            )

            // The same window with no refused poll in it at all: a handshake
            // that completes inside one poll interval means the first poll
            // this session ever runs already finds the gate open.
            let fastGate = ClipboardGateSwitch()
            let fastPasteboard = FakeClipboardPasteboard()
            let fastClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: fastPasteboard, isEnabled: true),
                isSessionAdmissible: { fastGate.isOpen }
            )
            fastPasteboard.stageLocalCopy(
                ClipboardReadout(content: .text("copied while handshaking"), isExcludedByType: false)
            )
            fastGate.isOpen = true
            expect(
                fastClipboard.poll() == nil,
                "a handshake faster than one poll interval still does not ship what predates the session"
            )
            let afterFastGate = ClipboardContent.text("copied after the fast handshake")
            fastPasteboard.stageLocalCopy(ClipboardReadout(content: afterFastGate, isExcludedByType: false))
            expect(
                fastClipboard.poll() == .clipboard(afterFastGate),
                "and that session still sends what is copied after it"
            )
        }

        // A host with no clipboard session -- an older build, or this one with
        // the flag off -- is handed a tag-3 frame and must ignore it, not die
        // on it.
        do {
            let ignoringController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            )
            let ignoringChannel = FakeHostByteChannel(scriptedPackets: [
                .clipboard(.text("copied on the Laptop")),
                .control(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)),
            ])
            let ignoringSession = HostNetworkSession(connection: ignoringChannel, controller: ignoringController)
            ignoringSession.attach(coordinator: HostSessionCoordinator(
                controller: ignoringController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: ignoringSession,
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
            ))
            ignoringSession.start()
            try! await Task.sleep(for: .milliseconds(250))
            expect(
                ignoringChannel.cancelCount == 0,
                "a clipboard frame reaching a host with no clipboard session never ends the connection"
            )
            expect(
                ignoringChannel.sentPackets.contains {
                    guard case .control(.canvasReady) = $0 else { return false }
                    return true
                },
                "and the session keeps serving every message that follows it"
            )
            ignoringSession.stop()
        }

        // The wired path: a clipboard frame off the real wire is applied, and
        // a local copy is polled off the pasteboard and written back as tag 3.
        do {
            let wiredController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            )
            let wiredPasteboard = FakeClipboardPasteboard()
            let wiredClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: wiredPasteboard, isEnabled: true),
                isSessionAdmissible: { wiredController.isSessionAuthenticatedAndActive }
            )
            let wiredChannel = FakeHostByteChannel(scriptedPackets: [
                .control(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)),
                .clipboard(.text("copied on the Laptop")),
            ])
            let wiredSession = HostNetworkSession(
                connection: wiredChannel,
                controller: wiredController,
                clipboard: wiredClipboard
            )
            wiredSession.attach(coordinator: HostSessionCoordinator(
                controller: wiredController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: wiredSession,
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
            ))
            wiredSession.start()
            try! await Task.sleep(for: .milliseconds(300))
            expect(
                wiredPasteboard.writtenContents == [.text("copied on the Laptop")],
                "a clipboard frame off the wire is applied to the host pasteboard"
            )
            let wiredCopy = ClipboardContent.text("copied on the Mini")
            wiredPasteboard.stageLocalCopy(ClipboardReadout(content: wiredCopy, isExcludedByType: false))
            try! await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds * 3))
            let clipboardPackets = wiredChannel.sentPackets.filter {
                guard case .clipboard = $0 else { return false }
                return true
            }
            expect(
                clipboardPackets == [.clipboard(wiredCopy)],
                "the host's own poll sends the local copy exactly once, and never echoes the applied one back"
            )
            wiredSession.stop()
            try! await Task.sleep(for: .milliseconds(150))
            wiredPasteboard.stageLocalCopy(ClipboardReadout(content: .text("after teardown"), isExcludedByType: false))
            try! await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds * 3))
            expect(
                wiredChannel.sentPackets.filter({
                    guard case .clipboard = $0 else { return false }
                    return true
                }).count == 1,
                "a stopped session stops polling the pasteboard"
            )
        }

        // clipboardSharing requires authentication, exactly like every
        // other state-changing message this controller admits -- an
        // unauthenticated peer must not be able to flip the host's own
        // clipboard sync state. Uses requireAuthentication: true and
        // never sends authenticatedHello, unlike the fixtures below,
        // which is what actually exercises this guard.
        do {
            final class ClipboardBox {
                var session: ClipboardSyncSession?
            }
            let clipboardBox = ClipboardBox()
            let authController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                requireAuthentication: true,
                onClipboardSharingChanged: { enabled in clipboardBox.session?.setEnabled(enabled) },
                keyConfinement: .unconfined
            )
            let authPasteboard = FakeClipboardPasteboard()
            let authClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: authPasteboard, isEnabled: true),
                isSessionAdmissible: { authController.isSessionAuthenticatedAndActive }
            )
            clipboardBox.session = authClipboard

            let authChannel = FakeHostByteChannel(scriptedPackets: [
                .control(.clipboardSharing(enabled: false)),
            ])
            let authSession = HostNetworkSession(
                connection: authChannel,
                controller: authController,
                clipboard: authClipboard
            )
            authSession.start()
            try! await Task.sleep(for: .milliseconds(200))
            expect(
                authChannel.cancelCount == 1,
                "an unauthenticated peer's clipboardSharing is fatal and closes the connection, the same as every other unauthenticated state-changing message"
            )
            expect(
                authClipboard.isEnabled,
                "the engine is left exactly as it was -- the connection closed before the requested state change could ever take effect"
            )
        }

        // clipboardSharing(enabled:) -- docs/ux-spec.md's live "Clipboard: on
        // or off," on the wire. false stops both directions at the host;
        // true resumes without replaying anything that changed while off.
        do {
            func clipboardPacketCount(_ channel: FakeHostByteChannel) -> Int {
                channel.sentPackets.filter {
                    guard case .clipboard = $0 else { return false }
                    return true
                }.count
            }

            final class ClipboardBox {
                var session: ClipboardSyncSession?
            }
            let sharingClipboardBox = ClipboardBox()
            let sharingController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                onClipboardSharingChanged: { enabled in sharingClipboardBox.session?.setEnabled(enabled) },
                keyConfinement: .unconfined
            )
            let sharingPasteboard = FakeClipboardPasteboard()
            let sharingClipboard = ClipboardSyncSession(
                engine: ClipboardSyncEngine(pasteboard: sharingPasteboard, isEnabled: true),
                isSessionAdmissible: { sharingController.isSessionAuthenticatedAndActive }
            )
            sharingClipboardBox.session = sharingClipboard
            let sharingChannel = FakeHostByteChannel(scriptedPackets: [
                .control(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)),
                .control(.clipboardSharing(enabled: false)),
                .clipboard(.text("arrived while off")),
            ])
            let sharingSession = HostNetworkSession(
                connection: sharingChannel,
                controller: sharingController,
                clipboard: sharingClipboard
            )
            sharingSession.attach(coordinator: HostSessionCoordinator(
                controller: sharingController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: sharingSession,
                workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
            ))
            sharingSession.start()
            // The scripted admission, the off toggle, and the clipboard
            // packet that arrives after it -- all three run before this
            // wait returns.
            try! await Task.sleep(for: .milliseconds(250))
            expect(
                sharingPasteboard.writtenContents.isEmpty,
                "a clipboard packet arriving after sharing turned off is never applied"
            )

            // A local change made while off must never be sent, however
            // many poll intervals pass.
            sharingPasteboard.stageLocalCopy(ClipboardReadout(content: .text("changed while off"), isExcludedByType: false))
            try! await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds * 3))
            expect(
                clipboardPacketCount(sharingChannel) == 0,
                "the host emits no clipboard packet while sharing is off, even though its own pasteboard changed"
            )

            // Turning sharing back on must not replay that stale change --
            // only a genuinely new one, made after re-enabling, is sent.
            sharingChannel.feed([.clipboardSharing(enabled: true)])
            try! await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds * 3))
            expect(
                clipboardPacketCount(sharingChannel) == 0,
                "turning sharing back on does not replay the change made while it was off"
            )

            let afterReenable = ClipboardContent.text("changed after re-enable")
            sharingPasteboard.stageLocalCopy(ClipboardReadout(content: afterReenable, isExcludedByType: false))
            try! await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds * 3))
            expect(
                sharingChannel.sentPackets.filter({ if case .clipboard = $0 { return true } else { return false } }) == [.clipboard(afterReenable)],
                "only a genuinely new change, made after re-enabling, is sent"
            )
            sharingSession.stop()
        }

        // End to end through the coordinator: a focus report the client sends
        // has to reach the two places that can act on it -- the send path's
        // per-frame priority, and the shared encode gate's -- or the signal is
        // just a field nothing reads.
        do {
            let focus = CanvasFocusTracker()
            let focusSessions = CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) }
            let focusController = HostSessionController(sessions: focusSessions, keyConfinement: .unconfined)
            let focusMedia = CanvasSurfaceSlots { _ in FakeCanvasMedia() }
            let focusSink = FakeVideoSink()
            let focusCoordinator = HostSessionCoordinator(
                controller: focusController,
                media: CanvasSurfaceSlots { surface -> any CanvasMediaStreaming in focusMedia[surface] },
                videoSink: focusSink,
                focus: focus
            )
            for surfaceID in [UInt32(0), UInt32(1)] {
                _ = try! await focusCoordinator.handleWritingResponse(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: surfaceID)
                )
            }

            expect(
                focus.sendPriority(for: surfaceZero) == .normal && focus.sendPriority(for: surfaceOne) == .normal,
                "before any focus report, no canvas is preferred on the send path"
            )
            expect(
                focus.encodePriority(for: surfaceZero) == .normal && focus.encodePriority(for: surfaceOne) == .normal,
                "before any focus report, no canvas is preferred at the encode gate"
            )
            focusMedia[surfaceZero].emit(videoFrame(1))
            focusMedia[surfaceOne].emit(videoFrame(2))
            expect(
                focusSink.sentPriorities == [.normal, .normal],
                "with nothing focused, every frame is sent at the same weight -- today's fair share"
            )

            _ = try! await focusCoordinator.handleWritingResponse(.viewerFocus(surfaceID: 1, hasViewerFocus: true))
            expect(
                focus.sendPriority(for: surfaceOne) == .elevated && focus.sendPriority(for: surfaceZero) == .normal,
                "the focused canvas is preferred on the send path"
            )
            expect(
                focus.encodePriority(for: surfaceOne) == .elevated && focus.encodePriority(for: surfaceZero) == .normal,
                "the focused canvas is preferred at the encode gate"
            )
            focusMedia[surfaceZero].emit(videoFrame(3))
            focusMedia[surfaceOne].emit(videoFrame(4))
            expect(
                focusSink.sentPriorities.suffix(2) == [.normal, .elevated],
                "the frame from the focused canvas reaches the wire with the elevated weight"
            )

            _ = try! await focusCoordinator.handleWritingResponse(.viewerFocus(surfaceID: nil, hasViewerFocus: false))
            focusMedia[surfaceZero].emit(videoFrame(5))
            focusMedia[surfaceOne].emit(videoFrame(6))
            expect(
                focusSink.sentPriorities.suffix(2) == [.normal, .normal],
                "when the viewer focuses a local app, neither canvas is preferred again"
            )

            _ = try! await focusCoordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))
            expect(
                focus.focusedSurface == nil,
                "a session that ends leaves no focus behind for the next one to inherit"
            )
        }

        expect(
            HostRunModeResolver.resolve(verb: "serve") == .interactive,
            "serve is the only host command that needs an AppKit event loop"
        )
        expect(
            HostRunModeResolver.resolve(verb: "pair") == .headless,
            "pair stays headless: it must never start an event loop or bounce a Dock icon"
        )
        expect(
            HostRunModeResolver.resolve(verb: "request-permissions") == .headless,
            "request-permissions stays headless"
        )
        expect(
            HostRunModeResolver.resolve(verb: nil) == .headless,
            "a missing subcommand stays headless"
        )
        expect(
            HostRunModeResolver.resolve(verb: "bogus") == .headless,
            "an unrecognized subcommand stays headless"
        )

        // A key event carries no location: macOS delivers it to whatever holds
        // the Mini's one process-wide keyboard focus, which both session
        // canvases share. Fronting the addressed surface's own workspace
        // window first is what keeps a paired client's typing inside its
        // canvas, and a key that cannot be confined is dropped rather than
        // posted into whatever is on a physical display.
        do {
            let confinementTimeline = DiagnosticsRecorder()
            let confinementInjector = FakeInputInjector()
            confinementInjector.onInject = { event in
                guard case let .key(keyCode, isDown, _) = event else {
                    confinementTimeline.record("pointer")
                    return
                }
                confinementTimeline.record("key \(keyCode) \(isDown ? "down" : "up")")
            }
            let workspaceZero = FakeCanvasWorkspace()
            let workspaceOne = FakeCanvasWorkspace()
            workspaceZero.onRaise = { confinementTimeline.record("raise 0 \($0)") }
            workspaceOne.onRaise = { confinementTimeline.record("raise 1 \($0)") }
            let confinementController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: confinementInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: workspaceZero,
                    surface1: workspaceOne
                ))
            )
            _ = try! confinementController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            _ = try! confinementController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)
            )
            // The coordinator, not the controller, installs each surface's
            // window once its canvas is ready; stand in for that here, under
            // the same token the controller fronts it with.
            let confinementOwner = confinementController.canvasOwner
            try! workspaceZero.start(canvasDisplayID: 7, owner: confinementOwner)

            _ = try! confinementController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: 0))
            expect(
                confinementTimeline.messages == ["raise 0 true", "key 12 down"],
                "a key event fronts its own surface's workspace window before the key is posted"
            )

            _ = try! confinementController.handle(.input(.key(keyCode: 12, isDown: false, modifiers: []), surfaceID: 0))
            _ = try! confinementController.handle(.input(.key(keyCode: 13, isDown: true, modifiers: []), surfaceID: 0))
            expect(
                workspaceZero.raiseCount == 1,
                "typing on into the same surface fronts that window exactly once, not once per key"
            )
            expect(
                confinementInjector.events.count == 3,
                "and every one of those keys was still posted"
            )

            try! workspaceOne.start(canvasDisplayID: 8, owner: confinementOwner)
            _ = try! confinementController.handle(.input(.key(keyCode: 14, isDown: true, modifiers: []), surfaceID: 1))
            expect(
                confinementTimeline.messages.suffix(2) == ["raise 1 true", "key 14 down"],
                "a key event for the other surface fronts that surface's window before posting"
            )
            _ = try! confinementController.handle(.input(.key(keyCode: 15, isDown: true, modifiers: []), surfaceID: 0))
            expect(
                workspaceZero.raiseCount == 2 && workspaceOne.raiseCount == 1,
                "switching back to the first surface fronts its window again"
            )

            // Fail closed. A surface whose window was never installed has
            // nowhere to put a keystroke, so the keystroke goes nowhere.
            let unplacedLog = DiagnosticsRecorder()
            let unplacedInjector = FakeInputInjector()
            let unplacedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: unplacedInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: FakeCanvasWorkspace(),
                    surface1: NoCanvasWorkspace()
                )),
                log: { unplacedLog.record($0) }
            )
            _ = try! unplacedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! unplacedController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                unplacedInjector.events.isEmpty,
                "a key event for a surface with no workspace window installed is not posted at all"
            )
            expect(
                unplacedController.keyConfinementDropCount == 1,
                "and is counted rather than dropped silently"
            )
            expect(
                unplacedLog.messages.contains { $0.contains("surface=0") },
                "and is reported as which surface could not take it"
            )
            expect(
                unplacedLog.messages.allSatisfy { !$0.contains("4242") },
                "and never as which key was dropped"
            )

            // Held-key consistency, modifiers included: a dropped key-down must
            // leave nothing behind for a later release to press up, and the
            // key-up that follows it must not be posted on its own -- a bare
            // Command-up landing on the Mini's own frontmost app is exactly
            // the confinement failure this exists to prevent.
            _ = try! unplacedController.handle(.input(.key(keyCode: 55, isDown: true, modifiers: [.command]), surfaceID: nil))
            _ = try! unplacedController.handle(.input(.key(keyCode: 55, isDown: false, modifiers: []), surfaceID: nil))
            expect(
                unplacedInjector.events.isEmpty,
                "a dropped modifier key-down is not followed by a bare key-up for a key that was never pressed"
            )
            expect(
                unplacedController.keyConfinementDropCount == 2,
                "a key-up for a key that was never pressed is suppressed, not counted as a confinement drop"
            )
            _ = try! unplacedController.handle(.input(.releaseAllInput, surfaceID: nil))
            expect(
                unplacedInjector.events.isEmpty && unplacedController.heldInputReleaseFailureCount == 0,
                "and the dropped key-down left no phantom held key for release to strand down"
            )

            // A window that is installed but will not come to the front is the
            // same refusal, and is retried rather than latched off.
            let failedRaiseInjector = FakeInputInjector()
            let failedRaiseWorkspace = FakeCanvasWorkspace()
            let failedRaiseController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: failedRaiseInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: failedRaiseWorkspace,
                    surface1: NoCanvasWorkspace()
                ))
            )
            try! failedRaiseWorkspace.start(canvasDisplayID: 7, owner: failedRaiseController.canvasOwner)
            failedRaiseWorkspace.raiseFailure = true
            _ = try! failedRaiseController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! failedRaiseController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                failedRaiseInjector.events.isEmpty && failedRaiseController.keyConfinementDropCount == 1,
                "a key whose window would not come to the front is dropped and counted, not posted"
            )
            failedRaiseWorkspace.raiseFailure = false
            _ = try! failedRaiseController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                failedRaiseInjector.events == [.key(keyCode: 4242, isDown: true, modifiers: [])],
                "a failed raise is retried on the next key instead of latching the surface off"
            )

            // A release reproduces exactly what was actually posted: nothing
            // for the surface whose key never went anywhere.
            let mixedInjector = FakeInputInjector()
            let mixedPlacedWorkspace = FakeCanvasWorkspace()
            let mixedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: mixedInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: mixedPlacedWorkspace,
                    surface1: FakeCanvasWorkspace()
                ))
            )
            try! mixedPlacedWorkspace.start(canvasDisplayID: 7, owner: mixedController.canvasOwner)
            _ = try! mixedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            _ = try! mixedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)
            )
            _ = try! mixedController.handle(.input(.key(keyCode: 55, isDown: true, modifiers: [.command]), surfaceID: 0))
            _ = try! mixedController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: 1))
            _ = try! mixedController.handle(.input(.pointerButton(button: .left, isDown: true, x: 30, y: 40), surfaceID: 0))
            _ = try! mixedController.handle(.input(.releaseAllInput, surfaceID: 0))
            expect(
                mixedInjector.events == [
                    .key(keyCode: 55, isDown: true, modifiers: [.command]),
                    .pointerButton(button: .left, isDown: true, x: 30, y: 40),
                    .pointerButton(button: .left, isDown: false, x: 30, y: 40),
                    .key(keyCode: 55, isDown: false, modifiers: [])
                ],
                "releasing a surface releases exactly the key and button that were actually posted on it"
            )
            _ = try! mixedController.handle(.input(.releaseAllInput, surfaceID: 1))
            expect(
                mixedInjector.events.count == 4,
                "and the surface whose key was dropped has nothing to release"
            )

            // Pointer input already carries its own location and is translated
            // through its own canvas's bounds, so it never fronts anything.
            let pointerInjector = FakeInputInjector()
            let pointerWorkspace = FakeCanvasWorkspace()
            let pointerController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: pointerInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: pointerWorkspace,
                    surface1: NoCanvasWorkspace()
                ))
            )
            try! pointerWorkspace.start(canvasDisplayID: 7, owner: pointerController.canvasOwner)
            _ = try! pointerController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! pointerController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil))
            _ = try! pointerController.handle(.input(.pointerButton(button: .left, isDown: true, x: 10, y: 20), surfaceID: nil))
            _ = try! pointerController.handle(.input(.scrolled(deltaX: -2, deltaY: 3, x: 10, y: 20, phase: nil, momentumPhase: nil), surfaceID: nil))
            expect(
                pointerWorkspace.raiseCount == 0 && pointerInjector.events.count == 3,
                "pointer and scroll input is posted exactly as before and never fronts a window"
            )

            // One canvas, one window: the same session as before, plus the one
            // raise that puts keyboard focus on it.
            let singleInjector = FakeInputInjector()
            let singleWorkspace = FakeCanvasWorkspace()
            let singleController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: singleInjector,
                keyConfinement: .confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                    surface0: singleWorkspace,
                    surface1: NoCanvasWorkspace()
                ))
            )
            try! singleWorkspace.start(canvasDisplayID: 7, owner: singleController.canvasOwner)
            _ = try! singleController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! singleController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: [.shift]), surfaceID: nil))
            _ = try! singleController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil))
            _ = try! singleController.handle(.input(.key(keyCode: 12, isDown: false, modifiers: []), surfaceID: nil))
            expect(
                singleInjector.events == [
                    .key(keyCode: 12, isDown: true, modifiers: [.shift]),
                    .pointerMoved(x: 10, y: 20),
                    .key(keyCode: 12, isDown: false, modifiers: [])
                ],
                "a single-canvas session posts exactly what it always did"
            )
            expect(
                singleWorkspace.raiseCount == 1 && singleController.keyConfinementDropCount == 0,
                "having fronted its one window exactly once, and dropped nothing"
            )
        }

        // Key confinement is a decision every caller states out loud. There is
        // no default to inherit by omission: a controller either confines keys
        // to the addressed surface's workspace window or is built
        // `.unconfined`, and the second is a word in the source.
        do {
            let unconfinedInjector = FakeInputInjector()
            let unconfinedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: unconfinedInjector,
                keyConfinement: .unconfined
            )
            _ = try! unconfinedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! unconfinedController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                unconfinedInjector.events == [.key(keyCode: 12, isDown: true, modifiers: [])]
                    && unconfinedController.keyConfinementDropCount == 0,
                "a controller built unconfined posts a key with no window to front, and says so at the call site"
            )

            // The wiring `sensoriumd` builds: the same controller with one
            // argument different, and a key goes nowhere until a window this
            // connection owns has been fronted for it.
            let confinedInjector = FakeInputInjector()
            let confinedWorkspace = FakeCanvasWorkspace()
            let confinedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: confinedInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(confinedWorkspace))
            )
            _ = try! confinedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! confinedController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                confinedInjector.events.isEmpty && confinedController.keyConfinementDropCount == 1,
                "the confined wiring drops that same key, because no window it owns is installed"
            )
        }

        // One token per connection covers both the canvas display and the
        // workspace window standing on it, so a connection can only front the
        // window it installed. Two separate tokens meant `raise` could not be
        // owner-checked at all.
        do {
            let ownershipWorkspace = FakeCanvasWorkspace()
            let ownershipInjector = FakeInputInjector()
            let ownershipController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: ownershipInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(ownershipWorkspace))
            )
            _ = try! ownershipController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            // Another connection's window, on the workspace both share.
            try! ownershipWorkspace.start(canvasDisplayID: 7, owner: CanvasOwnerToken())
            _ = try! ownershipController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                ownershipInjector.events.isEmpty && ownershipController.keyConfinementDropCount == 1,
                "a connection cannot front the workspace window another connection owns"
            )
            expect(
                ownershipWorkspace.installedWindowQueryCount == 1 && ownershipWorkspace.raiseCount == 0,
                "the refusal comes from the workspace itself, which was asked and declined, and cost no raise"
            )

            // The same workspace, taken over by this connection.
            try! ownershipWorkspace.start(canvasDisplayID: 7, owner: ownershipController.canvasOwner)
            _ = try! ownershipController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                ownershipInjector.events == [.key(keyCode: 12, isDown: true, modifiers: [])],
                "and fronts the one it does own"
            )
        }

        // The window a key was confined to can disappear between two keys. A
        // second connection takes the surface over and then tears down; the
        // first connection's socket failure has not surfaced yet, so its next
        // key arrives with no window of its own left to land in. Re-checked
        // per key rather than once per connection: a key posted here would go
        // to whatever holds the Mini's one keyboard focus, which can be a
        // physical display.
        do {
            let takeoverLog = DiagnosticsRecorder()
            let takeoverInjector = FakeInputInjector()
            let takeoverWorkspace = FakeCanvasWorkspace()
            let takeoverController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: takeoverInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(takeoverWorkspace)),
                log: { takeoverLog.record($0) }
            )
            _ = try! takeoverController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            try! takeoverWorkspace.start(canvasDisplayID: 7, owner: takeoverController.canvasOwner)
            _ = try! takeoverController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                takeoverInjector.events.count == 1 && takeoverWorkspace.raiseCount == 1,
                "the first key fronts this connection's own window and is posted"
            )

            // Another connection takes the surface over, then its teardown
            // closes the window it installed.
            let takeoverOwner = CanvasOwnerToken()
            try! takeoverWorkspace.start(canvasDisplayID: 7, owner: takeoverOwner)
            takeoverWorkspace.stop(owner: takeoverOwner)
            _ = try! takeoverController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                takeoverInjector.events.count == 1,
                "a key whose workspace window another connection's teardown closed is not posted"
            )
            expect(
                takeoverController.keyConfinementDropCount == 1,
                "and is counted rather than dropped silently"
            )
            expect(
                takeoverLog.messages.contains { $0.contains("surface=0") },
                "and is reported as which surface could not take it"
            )
            expect(
                takeoverLog.messages.allSatisfy { !$0.contains("4242") },
                "and never as which key was dropped"
            )

            // A live second connection is the same refusal: its window stands
            // on the surface, but it is not this connection's to type into.
            try! takeoverWorkspace.start(canvasDisplayID: 7, owner: CanvasOwnerToken())
            _ = try! takeoverController.handle(.input(.key(keyCode: 4243, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                takeoverInjector.events.count == 1 && takeoverController.keyConfinementDropCount == 2,
                "a key for a surface another connection now owns is dropped too"
            )

            // Taking the surface back installs a different window, so the key
            // that follows fronts that one rather than trusting the earlier
            // raise.
            try! takeoverWorkspace.start(canvasDisplayID: 7, owner: takeoverController.canvasOwner)
            _ = try! takeoverController.handle(.input(.key(keyCode: 15, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                takeoverInjector.events.count == 2 && takeoverWorkspace.raiseCount == 2,
                "and a window installed again for this connection is fronted once more before its next key"
            )
        }

        // Owning an installed window is not the same as holding the keyboard.
        // The Mini has one process-wide keyboard focus and every window on
        // every display competes for it, so a window this connection installed
        // and still owns can stop being where keys land without this
        // connection touching it: someone clicks a window on the built-in
        // display, or an app activates itself. A key posted then is typed onto
        // a physical display, which is exactly what the v1 core invariant
        // forbids -- so focus is re-checked per key alongside the window's
        // identity, and a raise is what tries to win it back.
        do {
            let focusLog = DiagnosticsRecorder()
            let focusInjector = FakeInputInjector()
            let focusWorkspace = FakeCanvasWorkspace()
            let focusController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: focusInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(focusWorkspace)),
                log: { focusLog.record($0) }
            )
            _ = try! focusController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            try! focusWorkspace.start(canvasDisplayID: 7, owner: focusController.canvasOwner)
            _ = try! focusController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 12, isDown: false, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 13, isDown: true, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 13, isDown: false, modifiers: []), surfaceID: nil))
            expect(
                focusInjector.events.count == 4 && focusWorkspace.raiseCount == 1,
                "typing into a window this connection owns and that holds the keyboard costs exactly one raise, not one per key"
            )

            // Something on the Mini takes the keyboard. The window is
            // untouched -- same window, same owner, still installed -- so
            // window identity alone still says yes.
            focusWorkspace.focus.takeElsewhere()
            // And AppKit has not granted the raise's focus change by the time
            // the raise returns, which is the case a key must not ride on.
            focusWorkspace.raiseGrantsFocus = false
            _ = try! focusController.handle(.input(.key(keyCode: 4242, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                focusInjector.events.count == 4,
                "a key for a window that no longer holds the keyboard is not posted, however plainly this connection still owns it"
            )
            expect(
                focusController.keyConfinementDropCount == 1,
                "and is counted rather than dropped silently"
            )
            expect(
                focusLog.messages.contains { $0.contains("surface=0") },
                "and is reported as which surface could not take it"
            )
            expect(
                focusLog.messages.allSatisfy { !$0.contains("4242") },
                "and never as which key was dropped"
            )

            // A dropped key-down leaves nothing held, so the key-up that
            // follows it has nothing to release and must not be posted on its
            // own -- a bare Command-up landing wherever the Mini's focus went
            // is the same confinement failure in the other direction.
            _ = try! focusController.handle(.input(.key(keyCode: 55, isDown: true, modifiers: [.command]), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 55, isDown: false, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.releaseAllInput, surfaceID: nil))
            expect(
                focusInjector.events.count == 4 && focusController.heldInputReleaseFailureCount == 0,
                "a key-down dropped for lost focus leaves no phantom held key and is never followed by a bare key-up"
            )
            expect(
                focusController.keyConfinementDropCount == 2,
                "and the key-up for a key that was never pressed is suppressed rather than counted a second time"
            )

            // The remedy is the raise that already existed, and it costs one
            // raise, not one per key: once it wins the keyboard back the key
            // it was attempted for is posted.
            let raisesBeforeRecovery = focusWorkspace.raiseCount
            focusWorkspace.raiseGrantsFocus = true
            _ = try! focusController.handle(.input(.key(keyCode: 14, isDown: true, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 14, isDown: false, modifiers: []), surfaceID: nil))
            _ = try! focusController.handle(.input(.key(keyCode: 15, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                focusInjector.events.count == 7 && focusWorkspace.raiseCount == raisesBeforeRecovery + 1,
                "a raise that wins the keyboard back posts its key and puts typing back on the flat one-raise path"
            )
        }

        // The same defect between two connections rather than against the
        // machine: a second connection installing its own window activates the
        // app onto that window, taking the keyboard from the first
        // connection's canvas without touching its window. The first
        // connection's next key must not be typed into the second's canvas.
        do {
            let sharedFocus = FakeKeyFocus()
            let workspaceA = FakeCanvasWorkspace(focus: sharedFocus)
            let workspaceB = FakeCanvasWorkspace(focus: sharedFocus)
            let slots = CanvasSurfaceSlots<any CanvasWorkspacePresenting>(
                surface0: workspaceA,
                surface1: workspaceB
            )
            let injectorA = FakeInputInjector()
            let controllerA = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: injectorA,
                keyConfinement: .confined(to: slots)
            )
            let controllerB = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: FakeInputInjector(),
                keyConfinement: .confined(to: slots)
            )
            _ = try! controllerA.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            try! workspaceA.start(canvasDisplayID: 7, owner: controllerA.canvasOwner)
            _ = try! controllerA.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: 0))
            _ = try! controllerA.handle(.input(.key(keyCode: 12, isDown: false, modifiers: []), surfaceID: 0))
            expect(
                injectorA.events.count == 2 && workspaceA.hasKeyFocus(owner: controllerA.canvasOwner),
                "the first connection types into its own canvas while it holds the keyboard"
            )

            // The second connection stands its window up on the other surface.
            try! workspaceB.start(canvasDisplayID: 8, owner: controllerB.canvasOwner)
            workspaceA.raiseGrantsFocus = false
            _ = try! controllerA.handle(.input(.key(keyCode: 13, isDown: true, modifiers: []), surfaceID: 0))
            expect(
                injectorA.events.count == 2 && controllerA.keyConfinementDropCount == 1,
                "the first connection's next key is not posted into the window the second connection took the keyboard with"
            )
            expect(
                sharedFocus.isHeld(by: workspaceB),
                "and the keyboard is still where the second connection put it, not silently typed through"
            )

            workspaceA.raiseGrantsFocus = true
            _ = try! controllerA.handle(.input(.key(keyCode: 13, isDown: true, modifiers: []), surfaceID: 0))
            expect(
                injectorA.events.count == 3 && workspaceA.hasKeyFocus(owner: controllerA.canvasOwner),
                "and the first connection posts again only once its own raise has taken the keyboard back"
            )

            // A connection that lost the keyboard has lost nothing else: the
            // window is still its own, and a connection that does not own it
            // still cannot close it.
            workspaceA.focus.takeElsewhere()
            workspaceA.stop(owner: controllerB.canvasOwner)
            expect(
                workspaceA.declinedStopCount == 1
                    && workspaceA.installedWindow(owner: controllerA.canvasOwner) != nil,
                "a non-owning connection's teardown still declines rather than closing the live connection's window"
            )

            // A controller built unconfined is unchanged by any of this: it
            // states at its call site that it presents no window, so there is
            // no focus for it to lose.
            let unconfinedFocusInjector = FakeInputInjector()
            let unconfinedFocusController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: unconfinedFocusInjector,
                keyConfinement: .unconfined
            )
            _ = try! unconfinedFocusController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! unconfinedFocusController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                unconfinedFocusInjector.events == [.key(keyCode: 12, isDown: true, modifiers: [])]
                    && unconfinedFocusController.keyConfinementDropCount == 0,
                "an unconfined controller posts its key with no window and no focus to check, exactly as before"
            )
        }

        // The axis of key confinement is not "is the focused window mine" but
        // "is the focused window on the owned canvas". A real application
        // launched onto the canvas holds the keyboard itself, and typing into
        // it is the whole point of launching it; a window anywhere else --
        // including one belonging to the same application -- is a physical
        // display, and a key posted there is the failure this guard exists for.
        do {
            let canvas = CGRect(x: 3840, y: 0, width: 1920, height: 1200)
            let onCanvas = ScannedWindow(
                processIdentifier: 900,
                bounds: CGRect(x: 3900, y: 100, width: 1200, height: 800)
            )
            let alsoOnCanvas = ScannedWindow(
                processIdentifier: 900,
                bounds: CGRect(x: 4000, y: 200, width: 300, height: 200)
            )
            let offCanvas = ScannedWindow(
                processIdentifier: 900,
                bounds: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            func scanOf(_ windows: [ScannedWindow], frontmost: pid_t? = 900) -> FrontmostWindowScan {
                FrontmostWindowScan(frontmostProcessIdentifier: frontmost, onScreenWindows: windows)
            }

            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf([onCanvas, alsoOnCanvas])
                ) == .allow,
                "a key may be posted when every window of the application holding the keyboard stands on the owned canvas"
            )
            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf([onCanvas, ScannedWindow(processIdentifier: 777, bounds: .zero)])
                ) == .allow,
                "and another application's window, wherever it is, is not what this key is confined against"
            )
            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf([onCanvas, offCanvas])
                ) == .rejectWindowOutsideCanvas,
                "one window of that application outside the canvas refuses the key, however many are inside"
            )
            // Vacuous truth is the trap: "no window outside the canvas" is
            // true of an application that has opened none yet, which is
            // exactly the moment it was activated.
            expect(
                CanvasKeyConfinement.decide(ownsWorkspace: true, canvasBounds: canvas, scan: scanOf([]))
                    == .rejectNoWindow,
                "an application with no window at all takes no key, rather than passing a check nothing can fail"
            )
            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf([onCanvas], frontmost: nil)
                ) == .rejectNoWindow,
                "and nothing frontmost at all is the same refusal"
            )
            // Containment, never intersection.
            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf([ScannedWindow(
                        processIdentifier: 900,
                        bounds: CGRect(x: 5560, y: 100, width: 400, height: 300)
                    )])
                ) == .rejectWindowOutsideCanvas,
                "a window straddling the canvas edge refuses the key: the part of it that is not on the canvas is a physical display"
            )
            // The per-connection owner check is a hard AND, not something
            // geometry replaces: it is the only thing that carries connection
            // identity, and a dying connection must not post into the window a
            // reconnect now owns.
            expect(
                CanvasKeyConfinement.decide(ownsWorkspace: false, canvasBounds: canvas, scan: scanOf([onCanvas]))
                    == .rejectUnownedWorkspace,
                "a connection that owns no workspace window here is refused even when the geometry is perfect"
            )
            expect(
                CanvasKeyConfinement.decide(ownsWorkspace: true, canvasBounds: nil, scan: scanOf([onCanvas]))
                    == .rejectUnownedWorkspace,
                "and so is a surface with no canvas rectangle to confine anything to"
            )

            // Every layer, no `kCGWindowLayer` filter. A floating panel sits
            // above layer 0; a layer-0-only scan would not see a keyed panel
            // standing on a physical display as outside the canvas, it would
            // not see it at all, and the key would be posted onto a monitor.
            let panelEntry: [String: Any] = [
                kCGWindowOwnerPID as String: NSNumber(value: 900),
                kCGWindowLayer as String: NSNumber(value: 3),
                kCGWindowBounds as String: CGRect(x: 40, y: 40, width: 300, height: 60).dictionaryRepresentation
            ]
            let parsedPanel = CanvasKeyConfinement.windows(from: [panelEntry])
            expect(
                parsedPanel == [ScannedWindow(
                    processIdentifier: 900,
                    bounds: CGRect(x: 40, y: 40, width: 300, height: 60)
                )],
                "the window list is parsed at every layer, so a floating panel is a window the check can see"
            )
            expect(
                CanvasKeyConfinement.decide(
                    ownsWorkspace: true,
                    canvasBounds: canvas,
                    scan: scanOf(parsedPanel + [onCanvas])
                ) == .rejectWindowOutsideCanvas,
                "and a panel of that application standing off the canvas refuses the key rather than going unenumerated"
            )
            expect(
                CanvasKeyConfinement.windows(from: [[kCGWindowOwnerPID as String: NSNumber(value: 900)]])
                    .first?.bounds.isNull == true,
                "an entry whose bounds cannot be read is kept as a rectangle no canvas contains, not dropped from the check"
            )

            // The same decision through the controller, which is where it
            // stops a keystroke.
            let launchedLog = DiagnosticsRecorder()
            let launchedInjector = FakeInputInjector()
            let launchedWorkspace = FakeCanvasWorkspace()
            launchedWorkspace.canvasRectangle = canvas
            let launchedScan = FakeFrontmostWindowScan()
            let launchedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: launchedInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(launchedWorkspace), scanning: launchedScan),
                log: { launchedLog.record($0) }
            )
            _ = try! launchedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            try! launchedWorkspace.start(canvasDisplayID: 7, owner: launchedController.canvasOwner)

            // The launched application activates itself and takes the keyboard
            // from the workspace window. Confining only to "is this window
            // mine" would end typing here: the first key would front the
            // workspace window back over it.
            launchedWorkspace.focus.takeElsewhere()
            launchedScan.result = scanOf([onCanvas])
            let raisesBeforeLaunch = launchedWorkspace.raiseCount
            _ = try! launchedController.handle(.input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil))
            _ = try! launchedController.handle(.input(.key(keyCode: 12, isDown: false, modifiers: []), surfaceID: nil))
            expect(
                launchedInjector.events.count == 2 && launchedWorkspace.raiseCount == raisesBeforeLaunch,
                "a key is posted into an application standing wholly on the owned canvas, without pulling the workspace window back over it"
            )
            expect(
                launchedController.keyConfinementDropCount == 0,
                "and nothing is dropped while it is the application on the canvas that holds the keyboard"
            )

            // Synchronous and per key. A cache of any lifetime is a leak
            // window: a window relocated off the canvas while still keyed
            // would keep taking posted keys until the cache expired.
            expect(
                launchedScan.scanCount == 2,
                "the machine's windows are scanned once per key, so a window that moves off the canvas is seen on the next keystroke"
            )

            // That very move: same application, same keyboard, window now on a
            // physical display.
            launchedScan.result = scanOf([offCanvas])
            launchedWorkspace.raiseGrantsFocus = false
            _ = try! launchedController.handle(.input(.key(keyCode: 13, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                launchedInjector.events.count == 2 && launchedController.keyConfinementDropCount == 1,
                "a key for an application whose window has left the canvas is dropped rather than typed onto a physical display"
            )
            expect(
                launchedWorkspace.raiseCount == raisesBeforeLaunch + 1,
                "and the remedy is unchanged: this connection's own workspace window is fronted"
            )
            expect(
                launchedLog.messages.contains { $0.contains("reason=window-outside-canvas") && $0.contains("surface=0") },
                "and the drop names which of the three checks refused it"
            )
            expect(
                launchedLog.messages.allSatisfy { !$0.contains("13") },
                "and never which key it was"
            )

            // The just-activated moment, which is the one an emptiness check
            // has to refuse.
            launchedScan.result = scanOf([])
            _ = try! launchedController.handle(.input(.key(keyCode: 14, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                launchedController.keyConfinementDropCount == 2
                    && launchedLog.messages.contains { $0.contains("reason=no-window-found") },
                "an application that holds the keyboard with no window yet takes no key, and says so"
            )

            // Our own workspace window taking the keyboard back is the path it
            // always was: window identity, one raise, and no scan at all.
            launchedWorkspace.raiseGrantsFocus = true
            _ = try! launchedController.handle(.input(.key(keyCode: 15, isDown: true, modifiers: []), surfaceID: nil))
            let scansAfterRecovery = launchedScan.scanCount
            let raisesAfterRecovery = launchedWorkspace.raiseCount
            _ = try! launchedController.handle(.input(.key(keyCode: 16, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                launchedInjector.events.count == 4
                    && launchedScan.scanCount == scansAfterRecovery
                    && launchedWorkspace.raiseCount == raisesAfterRecovery,
                "typing into our own window costs neither a scan nor a raise per key, exactly as before"
            )

            // Geometry never stands in for the owner check. A second
            // connection, with the same perfect geometry in front of it,
            // cannot post into a window it does not own.
            let strangerLog = DiagnosticsRecorder()
            let strangerInjector = FakeInputInjector()
            let strangerController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: strangerInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(launchedWorkspace), scanning: launchedScan),
                log: { strangerLog.record($0) }
            )
            _ = try! strangerController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            launchedScan.result = scanOf([onCanvas])
            _ = try! strangerController.handle(.input(.key(keyCode: 17, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                strangerInjector.events.isEmpty && strangerController.keyConfinementDropCount == 1,
                "a connection that owns no window on this surface is refused even while the canvas geometry is perfect"
            )
            expect(
                strangerLog.messages.contains { $0.contains("reason=unowned-workspace") },
                "and is refused by the owner check, named as such"
            )

            // A caller that states no scanner gets the strictest confinement
            // rather than a scan it did not ask for: keys reach its own
            // workspace window and nothing else.
            let unscannedWorkspace = FakeCanvasWorkspace()
            let unscannedInjector = FakeInputInjector()
            let unscannedController = HostSessionController(
                sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
                inputInjector: unscannedInjector,
                keyConfinement: .confined(to: onlyOnSurfaceZero(unscannedWorkspace))
            )
            _ = try! unscannedController.handle(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            try! unscannedWorkspace.start(canvasDisplayID: 7, owner: unscannedController.canvasOwner)
            unscannedWorkspace.focus.takeElsewhere()
            unscannedWorkspace.raiseGrantsFocus = false
            _ = try! unscannedController.handle(.input(.key(keyCode: 18, isDown: true, modifiers: []), surfaceID: nil))
            expect(
                unscannedInjector.events.isEmpty && unscannedController.keyConfinementDropCount == 1,
                "an unstated scanner refuses every window it cannot see, which costs typing into launched applications and never a key on a physical display"
            )
        }

        // End to end on the wiring `sensoriumd` builds: the coordinator
        // installs each surface's window under the very token the controller
        // fronts it with, so a real session's keys are confined rather than
        // dropped.
        do {
            let wiredWorkspace = FakeCanvasWorkspace()
            let wiredInjector = FakeInputInjector()
            let wiredWorkspaces = onlyOnSurfaceZero(wiredWorkspace)
            let wiredController = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                inputInjector: wiredInjector,
                keyConfinement: .confined(to: wiredWorkspaces)
            )
            let wiredCoordinator = HostSessionCoordinator(
                controller: wiredController,
                media: onlyOnSurfaceZero(FakeCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: wiredWorkspaces
            )
            _ = try! await wiredCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
            )
            _ = try! await wiredCoordinator.handleWritingResponse(
                .input(.key(keyCode: 12, isDown: true, modifiers: []), surfaceID: nil)
            )
            expect(
                wiredInjector.events == [.key(keyCode: 12, isDown: true, modifiers: [])]
                    && wiredController.keyConfinementDropCount == 0,
                "a key on the wiring sensoriumd builds lands in the window the coordinator installed"
            )
        }

        // There is one coordinator path, so every test that drives a
        // coordinator drives the ordering production depends on: the reply is
        // on the wire before that surface's capture starts.
        do {
            let orderingTimeline = DiagnosticsRecorder()
            let orderingCoordinator = HostSessionCoordinator(
                controller: HostSessionController(
                    sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                    keyConfinement: .unconfined
                ),
                media: onlyOnSurfaceZero(StartTimelineCanvasMedia { orderingTimeline.record("capture") }),
                videoSink: FakeVideoSink()
            )
            let orderingReply = try! await orderingCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
                onWrite: { _ in orderingTimeline.record("canvasReady") }
            )
            expect(
                orderingTimeline.messages == ["canvasReady", "capture"],
                "the coordinator writes the canvasReady before it starts that surface's capture"
            )
            var orderingWroteCanvasReady = false
            if case .canvasReady = orderingReply {
                orderingWroteCanvasReady = true
            }
            expect(
                orderingWroteCanvasReady,
                "and the reply it wrote is the canvasReady, handed back rather than written a second time"
            )
        }

        // EDID identity is what macOS keys arrangement, per-display settings and
        // colour profiles on, so the two canvases must never present the same
        // one, and each must present the same one on every reconnect.
        do {
            let identities = CanvasSurfaceID.allCases.map { CanvasDisplayIdentity(surface: $0) }
            expect(
                identities[0].serialNumber != identities[1].serialNumber,
                "the two surfaces never share a serial number"
            )
            expect(
                identities.allSatisfy { $0.vendorID == 0x434C && $0.productID == 1 },
                "both canvases stay one model from one vendor; only the serial number tells them apart"
            )
            let rederived = [CanvasDisplayIdentity(surface: surfaceZero), CanvasDisplayIdentity(surface: surfaceOne)]
            expect(
                identities == rederived,
                "a surface's identity is derived from its index alone, so it is the same across reconnects and host restarts"
            )
            expect(
                identities[0].serialNumber == 1,
                "surface 0 keeps the serial number the single-canvas host has always presented"
            )
        }
}
