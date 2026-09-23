#if canImport(AppKit)
import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testSurfaceRoutingAndSessionSetupTests() async {

        let orderedSink = GatedPointerSink()
        let orderedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: orderedSink
        )
        await orderedViewport.canvasDidBecomeReady()
        await orderedViewport.setViewportSize(width: 1920, height: 1200)
        let motionInFlight = Task { await orderedViewport.movePointer(x: 100, y: 100) }
        await orderedSink.waitUntilFirstSendEntered()
        let buttonBehindMotion = Task {
            await orderedViewport.sendButton(button: .left, isDown: true, x: 200, y: 200)
        }
        await orderedSink.openGate()
        _ = await motionInFlight.value
        guard await buttonBehindMotion.value == .delivered(CanvasInputPoint(x: 200, y: 200)),
              await orderedSink.events.contains(.pointerButton(button: .left, isDown: true, x: 200, y: 200)) else {
            print("FAIL: a button press was coalesced away behind in-flight pointer motion")
            Foundation.exit(1)
        }

        guard CanvasModifierFlags(appKitFlags: [.command, .shift]) == [.command, .shift],
              CanvasModifierFlags(appKitFlags: [.control, .option]) == [.control, .option],
              CanvasModifierFlags(appKitFlags: [.capsLock, .function, .numericPad]) == [],
              CanvasModifierFlags(appKitFlags: [.command, .capsLock]) == [.command] else {
            print("FAIL: AppKit modifier translation did not keep exactly the four forwarded modifiers")
            Foundation.exit(1)
        }

        let hostIdentity = try! DeviceIdentity.generate()
        let hostKey = hostIdentity.publicKey
        let pairingIdentity = try! DeviceIdentity.generate()
        let pairSignature = try! hostIdentity.sign(SensoriumFrameCodec.pairApprovalTranscript(
            deviceName: "Laptop",
            clientPublicKey: pairingIdentity.publicKey,
            tlsCertificateHash: nil
        ))
        let approvingTransport = ScriptedClientTransport(responses: [
            .pairApproved(hostPublicKey: hostKey, tlsCertificateHash: nil, signature: pairSignature)
        ])
        let pairingClient = ClientSessionController(transport: approvingTransport, identity: pairingIdentity)
        let pairingApproval = try! await pairingClient.pair(deviceName: "Laptop", code: "424242")
        // The request carries a proof that this machine holds the identity
        // key it names, verified rather than compared byte for byte: the
        // host refuses to rewrite an already-paired machine's own record
        // without one.
        guard case let .pairRequest(sentName, sentKey, sentCode, sentSignature) =
                await approvingTransport.sent.first,
              await approvingTransport.sent.count == 1,
              pairingApproval.hostPublicKey == hostKey,
              pairingApproval.tlsCertificateHash == nil,
              sentName == "Laptop",
              sentKey == pairingIdentity.publicKey,
              sentCode == "424242",
              DeviceIdentity.verify(
                signature: sentSignature,
                message: SensoriumFrameCodec.pairRequestTranscript(
                    deviceName: "Laptop",
                    clientPublicKey: pairingIdentity.publicKey,
                    code: "424242"
                ),
                publicKey: pairingIdentity.publicKey
              ) else {
            print("FAIL: client pairing did not send the request, prove it holds its own key, or pin the returned host key")
            Foundation.exit(1)
        }

        let rejectingTransport = ScriptedClientTransport(responses: [.pairRejected(reason: "invalid-code")])
        let rejectedClient = ClientSessionController(transport: rejectingTransport, identity: pairingIdentity)
        do {
            _ = try await rejectedClient.pair(deviceName: "Laptop", code: "000000")
            print("FAIL: client treated a rejected pairing as success")
            Foundation.exit(1)
        } catch ClientSessionError.pairingRejected(let reason) {
            guard reason == "invalid-code" else {
                print("FAIL: client lost the pairing rejection reason")
                Foundation.exit(1)
            }
        } catch {
            print("FAIL: client reported the wrong error for a rejected pairing")
            Foundation.exit(1)
        }

        // The session loop tolerates an unrecognized message type from a
        // newer peer; the one-time pairing ceremony must not inherit that
        // tolerance -- pairing is where trust is established, so an
        // unexpected message there stays a hard rejection.
        let unrecognizedDuringPairingTransport = ScriptedClientTransport(responses: [
            .unrecognized(type: "futureFocusSignal")
        ])
        let unrecognizedDuringPairingClient = ClientSessionController(
            transport: unrecognizedDuringPairingTransport,
            identity: pairingIdentity
        )
        do {
            _ = try await unrecognizedDuringPairingClient.pair(deviceName: "Laptop", code: "424242")
            print("FAIL: pairing accepted an unrecognized message instead of rejecting it")
            Foundation.exit(1)
        } catch ClientSessionError.unexpectedMessage {
        } catch {
            print("FAIL: pairing reported the wrong error for an unrecognized message")
            Foundation.exit(1)
        }

        let impostorTransport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed"),
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let pinningClient = ClientSessionController(
            transport: impostorTransport,
            identity: pairingIdentity,
            pinnedHostPublicKey: hostKey
        )
        do {
            _ = try await pinningClient.connect(deviceName: "Laptop")
            print("FAIL: client accepted a canvas from a host that did not prove its identity")
            Foundation.exit(1)
        } catch ClientSessionError.hostKeyMismatch {
        } catch {
            print("FAIL: client reported the wrong error for an unproven host")
            Foundation.exit(1)
        }

        // An authenticated connect always reads the host-screen offer
        // (`hostScreenList` or `hostScreenRefused`) before `canvasRequest`
        // goes out; a host that skips straight to `canvasReady` is not
        // understood, never treated as an offer-less canvas.
        let offerSkippingTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let offerSkippingClient = ClientSessionController(
            transport: offerSkippingTransport,
            identity: pairingIdentity
        )
        do {
            _ = try await offerSkippingClient.connect(deviceName: "Laptop")
            print("FAIL: an authenticated canvas connect accepted canvasReady in place of the host-screen offer")
            Foundation.exit(1)
        } catch ClientSessionError.unexpectedMessage {
        } catch {
            print("FAIL: an authenticated canvas connect reported the wrong error for a host that skips the offer")
            Foundation.exit(1)
        }

        // The client always requests surfaceID 0 (the only canvas that
        // exists). A host that echoes it back understands the field; a host
        // that omits it entirely predates it; anything else is untrustworthy.
        let matchingSurfaceTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)
        ])
        let matchingSurfaceClient = ClientSessionController(transport: matchingSurfaceTransport)
        _ = try! await matchingSurfaceClient.connect(deviceName: "Laptop")
        guard await matchingSurfaceClient.hostSupportsSurfaceIDs else {
            print("FAIL: client did not record surfaceID capability when the host echoed exactly what was sent")
            Foundation.exit(1)
        }

        let absentSurfaceTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let absentSurfaceClient = ClientSessionController(transport: absentSurfaceTransport)
        _ = try! await absentSurfaceClient.connect(deviceName: "Laptop")
        guard await absentSurfaceClient.hostSupportsSurfaceIDs == false else {
            print("FAIL: client recorded surfaceID capability from a host that never echoed it")
            Foundation.exit(1)
        }

        // `canvasReady.hostName` becomes the window title -- see
        // `ViewerWindowTitle`. Absent (an old host) leaves it nil, never a
        // fabricated name.
        let namedHostTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil, hostName: "Studio")
        ])
        let namedHostClient = ClientSessionController(transport: namedHostTransport)
        _ = try! await namedHostClient.connect(deviceName: "Laptop")
        expect(
            await namedHostClient.hostMachineName == "Studio",
            "the client records the host's own name from canvasReady"
        )

        let unnamedHostTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let unnamedHostClient = ClientSessionController(transport: unnamedHostTransport)
        _ = try! await unnamedHostClient.connect(deviceName: "Laptop")
        expect(
            await unnamedHostClient.hostMachineName == nil,
            "an old host that never sends hostName leaves it nil rather than inventing one"
        )

        let mismatchedSurfaceTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 7)
        ])
        let mismatchedSurfaceClient = ClientSessionController(transport: mismatchedSurfaceTransport)
        do {
            _ = try await mismatchedSurfaceClient.connect(deviceName: "Laptop")
            print("FAIL: client silently accepted a canvasReady whose surfaceID did not match what it sent")
            Foundation.exit(1)
        } catch ClientSessionError.surfaceIDMismatch {
        } catch {
            print("FAIL: client reported the wrong error for a mismatched surfaceID echo")
            Foundation.exit(1)
        }
        guard await mismatchedSurfaceClient.hostSupportsSurfaceIDs == false else {
            print("FAIL: a rejected mismatched echo must not be recorded as capability")
            Foundation.exit(1)
        }
        do {
            try await mismatchedSurfaceClient.sendPointer(CanvasInputPoint(x: 10, y: 20))
            print("FAIL: a client whose connect failed on a surfaceID mismatch must not be treated as connected")
            Foundation.exit(1)
        } catch ClientSessionError.notConnected {
        } catch {
            print("FAIL: client reported the wrong error for input sent after a failed connect")
            Foundation.exit(1)
        }

        let savedHost = SavedHost(
            displayName: "Studio",
            host: "mini.example-tailnet.ts.net",
            port: 7777,
            hostPublicKey: hostKey
        )
        guard let matchingEntry = SensoriumEntryURL(string: "sensorium://enter/mini.example-tailnet.ts.net"),
              let differentEntry = SensoriumEntryURL(string: "sensorium://enter/other.example-tailnet.ts.net") else {
            print("FAIL: entry URL fixtures did not parse")
            Foundation.exit(1)
        }
        expect(savedHost.matches(matchingEntry), "an enter URL can select its already-paired host")
        expect(!savedHost.matches(differentEntry), "an enter URL cannot select a different unpaired host")

        let certificateDER = Data("test-certificate".utf8)
        let certificatePin = HostTLSIdentity.certificateHash(for: certificateDER)
        expect(
            NetworkControlConnection.certificatePinMatches(
                certificateDER: certificateDER,
                expectedHash: certificatePin
            ),
            "a reconnect accepts exactly its paired TLS certificate"
        )
        expect(
            !NetworkControlConnection.certificatePinMatches(
                certificateDER: Data("different-certificate".utf8),
                expectedHash: certificatePin
            ),
            "a reconnect rejects a different self-signed TLS certificate"
        )
        expect(SavedHost.remoteCanvasPreset.logicalWidth == 1920, "the saved preset is 1920 wide")
        expect(SavedHost.remoteCanvasPreset.logicalHeight == 1200, "the saved preset is 1200 tall")
        expect(SavedHost.remoteCanvasPreset.scale == 2, "the saved preset is a 2x HiDPI canvas")
        expect(SavedHost.remoteCanvasPreset.framesPerSecond == 60, "the saved preset targets 60 fps")

        let store = InMemorySavedHostStore()
        expect(store.loadAll().isEmpty, "a fresh client has no saved host")
        store.save(savedHost)
        expect(
            store.load(hostPublicKey: savedHost.hostPublicKey) == savedHost,
            "the saved host round-trips through the store"
        )
        let encoded = try! JSONEncoder().encode(savedHost)
        expect(
            try! JSONDecoder().decode(SavedHost.self, from: encoded) == savedHost,
            "a saved host survives being written and read back"
        )
        store.clear()
        expect(store.loadAll().isEmpty, "clearing the store forgets the host")

        expect(
            SessionTimeouts.remoteDefault.canvasCreation > SessionTimeouts.remoteDefault.handshake,
            "a canvas is allowed longer than a handshake"
        )
        let silentTransport = SilentClientTransport()
        let wedgedClient = ClientSessionController(
            transport: silentTransport,
            identity: try! DeviceIdentity.generate()
        )
        let started = Date()
        do {
            _ = try await wedgedClient.connect(deviceName: "Laptop", timeout: 0.05)
            print("FAIL: client waited forever on a host that never answered")
            Foundation.exit(1)
        } catch ClientSessionError.timedOut {
        } catch {
            print("FAIL: client reported the wrong error for a wedged host")
            Foundation.exit(1)
        }
        expect(Date().timeIntervalSince(started) < 5, "the client gave up promptly rather than hanging")
        expect(await silentTransport.closeCount == 1, "a timed-out connect closes its transport")

        let quitTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 51, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let quitting = ClientSessionController(transport: quitTransport)
        _ = try! await quitting.connect(deviceName: "Laptop")
        await quitting.disconnect(reason: "user-quit")
        await quitting.disconnect(reason: "user-quit")
        let goodbyes = await quitTransport.sent.filter {
            if case .goodbye = $0 { return true } else { return false }
        }
        expect(goodbyes.count == 1, "quitting twice says goodbye once, so cleanup is not duplicated")
        expect(
            await quitTransport.sent.contains(.input(.releaseAllInput, surfaceID: nil)),
            "quitting releases held input before saying goodbye"
        )


        let ledger = FrameReceiptLedger()
        ledger.record(presentationTimeNanoseconds: 100, receivedAtNanoseconds: 1_000)
        ledger.record(presentationTimeNanoseconds: 200, receivedAtNanoseconds: 1_100)
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 100) == 1_000,
            "a frame's receipt time is returned for its own presentation timestamp"
        )
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 100) == nil,
            "a receipt is consumed once so a repeated callback cannot double-count it"
        )
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 999) == nil,
            "a presentation timestamp that was never recorded has no receipt"
        )
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 200) == 1_100,
            "an unrelated lookup does not disturb other outstanding receipts"
        )

        // A decoder that drops frames must not let the ledger grow without bound.
        for tick in 0..<(FrameReceiptLedger.maximumOutstanding + 10) {
            ledger.record(
                presentationTimeNanoseconds: Int64(10_000 + tick),
                receivedAtNanoseconds: Int64(20_000 + tick)
            )
        }
        expect(
            ledger.outstandingCount == FrameReceiptLedger.maximumOutstanding,
            "the ledger is bounded when callbacks never arrive"
        )
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 10_000) == nil,
            "the oldest receipt is the one evicted"
        )
        expect(
            ledger.takeReceipt(
                forPresentationTimeNanoseconds: Int64(10_000 + FrameReceiptLedger.maximumOutstanding + 9)
            ) == Int64(20_000 + FrameReceiptLedger.maximumOutstanding + 9),
            "the newest receipt survives eviction"
        )

        // Two displays sampled off the same host clock can land on the same
        // presentation timestamp. `ClientCanvasWindowController` keeps them
        // apart by giving each window its own ledger instance, not by a key
        // -- this proves that isolation holds: two independently-constructed
        // ledgers sharing a timestamp never observe each other's receipts.
        let windowOneLedger = FrameReceiptLedger()
        let windowTwoLedger = FrameReceiptLedger()
        windowOneLedger.record(presentationTimeNanoseconds: 500, receivedAtNanoseconds: 1)
        windowTwoLedger.record(presentationTimeNanoseconds: 500, receivedAtNanoseconds: 2)
        expect(
            windowOneLedger.takeReceipt(forPresentationTimeNanoseconds: 500) == 1,
            "one window's ledger is unaffected by another window sharing its presentation timestamp"
        )
        expect(
            windowTwoLedger.takeReceipt(forPresentationTimeNanoseconds: 500) == 2,
            "the other window's ledger keeps its own receipt regardless of what the first window recorded"
        )
        expect(
            windowOneLedger.takeReceipt(forPresentationTimeNanoseconds: 500) == nil,
            "consuming one window's receipt does not disturb the other's, and does not resurrect its own"
        )

        // Each host-side surface packetizes independently and starts its own
        // sequencer at 0. Fed into one shared ingress this would drop about
        // half of every stream as stale; per-surface ingress delivers both.
        let surfaceIngress = SurfaceVideoIngress()
        await surfaceIngress.receive(surfaceID: 0, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 10, isKeyFrame: true, payload: Data([0])
        ))
        await surfaceIngress.receive(surfaceID: 1, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 10, isKeyFrame: true, payload: Data([1])
        ))
        await surfaceIngress.receive(surfaceID: 0, frame: EncodedVideoFramePacket(
            sequence: 1, presentationTimeNanoseconds: 20, isKeyFrame: false, payload: Data([2])
        ))
        await surfaceIngress.receive(surfaceID: 1, frame: EncodedVideoFramePacket(
            sequence: 1, presentationTimeNanoseconds: 20, isKeyFrame: false, payload: Data([3])
        ))
        expect(
            await surfaceIngress.takeNewest(surfaceID: 0)?.payload == Data([2]),
            "surface 0's frame is delivered even though surface 1 shares its sequence numbers"
        )
        expect(
            await surfaceIngress.takeNewest(surfaceID: 1)?.payload == Data([3]),
            "surface 1's frame is delivered even though surface 0 shares its sequence numbers"
        )

        // hasRecoveryKeyFrame is per-surface: a keyframe on surface 0 must not
        // wrongly unblock surface 1's undecodable deltas.
        let gateIngress = SurfaceVideoIngress()
        await gateIngress.receive(surfaceID: 0, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([9])
        ))
        await gateIngress.receive(surfaceID: 1, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: false, payload: Data([8])
        ))
        expect(
            await gateIngress.takeNewest(surfaceID: 1) == nil,
            "surface 1's delta is not admitted just because surface 0 already has a recovery keyframe"
        )

        // A tag-1-only stream (no surfaceID on the wire) behaves exactly as
        // before: it lands on surface 0 and never leaks into surface 1.
        let legacyIngress = SurfaceVideoIngress()
        await legacyIngress.receive(surfaceID: 0, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 5, isKeyFrame: true, payload: Data([7])
        ))
        expect(
            await legacyIngress.takeNewest(surfaceID: 0)?.payload == Data([7]),
            "a tag-1-only stream is still delivered on the default surface"
        )
        expect(
            await legacyIngress.takeNewest(surfaceID: 1) == nil,
            "a tag-1 frame never leaks into surface 1's ingress"
        )
}
#endif
