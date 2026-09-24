import SensoriumClient
import SensoriumCore
import SensoriumHost
import Foundation

@MainActor
final class IntegrationFakeAdapter: VirtualDisplayAdapter {
    private(set) var releaseCount = 0
    private let displayID: UInt32

    init(displayID: UInt32 = 77) {
        self.displayID = displayID
    }

    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        VirtualDisplayHandle(rawValue: displayID)
    }

    func release(_ handle: VirtualDisplayHandle) {
        releaseCount += 1
    }
}

/// Carries the coordinator's written reply back out of its `@Sendable` writer.
final class WrittenResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var written: SensoriumMessage?

    func record(_ message: SensoriumMessage) {
        lock.lock()
        defer { lock.unlock() }
        written = message
    }

    var message: SensoriumMessage? {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

@MainActor
extension HostSessionCoordinator {
    /// Drives the coordinator exactly as `HostNetworkSession` does: the reply
    /// goes out through `writeResponse`, which is what puts a `canvasReady` on
    /// the wire ahead of that surface's capture start. Hands back whatever the
    /// coordinator produced, written or returned, so a test asserts on the one
    /// path production uses rather than on a parallel one.
    func handleWritingResponse(
        _ message: SensoriumMessage,
        onWrite: (@Sendable (SensoriumMessage) -> Void)? = nil
    ) async throws -> SensoriumMessage? {
        let written = WrittenResponseBox()
        let returned = try await handle(message) { reply in
            written.record(reply)
            onWrite?(reply)
        }
        return returned ?? written.message
    }
}

actor LoopbackTransport: SensoriumControlTransport {
    private let handler: @Sendable (SensoriumMessage) async throws -> SensoriumMessage?
    /// Whatever the host puts on the wire after answering a request — video,
    /// on a real host, because streaming for a surface starts inside the same
    /// `handle` that produced its `canvasReady`.
    private let afterReply: @Sendable (SensoriumMessage) -> [SensoriumTransportPacket]
    /// Mirrors `HostNetworkSession`'s own post-hello push (docs/host-screen-design.md §2.3): a
    /// real host offers its host-screen list unprompted, right after a
    /// successful `authenticatedHello`, before any other host-initiated
    /// message. `nil` for a scenario with no `HostSessionController` to ask.
    private let offerHostScreenList: (@Sendable () async throws -> SensoriumMessage)?
    private var responses: [SensoriumTransportPacket] = []
    let deferredPackets = DeferredPacketQueue()

    init(
        afterReply: @escaping @Sendable (SensoriumMessage) -> [SensoriumTransportPacket] = { _ in [] },
        offerHostScreenList: (@Sendable () async throws -> SensoriumMessage)? = nil,
        handler: @escaping @Sendable (SensoriumMessage) async throws -> SensoriumMessage?
    ) {
        self.handler = handler
        self.afterReply = afterReply
        self.offerHostScreenList = offerHostScreenList
    }

    func send(_ message: SensoriumMessage) async throws {
        if let response = try await handler(message) {
            responses.append(.control(response))
        }
        responses.append(contentsOf: afterReply(message))
        if case .authenticatedHello = message, let offerHostScreenList {
            responses.append(.control(try await offerHostScreenList()))
        }
    }

    func receiveWirePacket() throws -> SensoriumTransportPacket {
        guard !responses.isEmpty else {
            throw ControlChannelError.closed
        }
        return responses.removeFirst()
    }

    func close() async {}
}

@MainActor
final class IntegrationFakeInjector: InputInjecting {
    private(set) var events: [SensoriumInputEvent] = []

    func inject(_ event: SensoriumInputEvent) throws {
        events.append(event)
    }
}

enum IntegrationAdapterFailure: Error {
    case displayApiUnavailable
}

@MainActor
final class FailingVirtualDisplayAdapter: VirtualDisplayAdapter {
    private(set) var acquireAttempts = 0
    private(set) var releaseCount = 0
    var shouldFail = true

    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        acquireAttempts += 1
        if shouldFail {
            throw IntegrationAdapterFailure.displayApiUnavailable
        }
        return VirtualDisplayHandle(rawValue: 91)
    }

    func release(_ handle: VirtualDisplayHandle) {
        releaseCount += 1
    }
}

/// The host media path as far as the coordinator can see it: records the
/// resolutions it was actually rebuilt at.
@MainActor
final class IntegrationScalableMedia: CanvasMediaStreaming {
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var reconfiguredScales: [Double] = []
    private(set) var stopCount = 0
    private(set) var appliedFramesPerSecond: [Int] = []
    private(set) var appliedQualityScales: [Double] = []
    private(set) var keyFrameRequestCount = 0
    private(set) var stillRefreshCount = 0
    var currentStreamScale = StreamScalePolicy.defaultScale
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        startedDisplayIDs.append(canvasDisplayID)
    }

    func stop() async {
        stopCount += 1
    }

    func reconfigure(streamScale: Double) async throws {
        reconfiguredScales.append(streamScale)
        currentStreamScale = streamScale
    }

    func apply(framesPerSecond: Int) async throws {
        appliedFramesPerSecond.append(framesPerSecond)
        currentFramesPerSecond = framesPerSecond
    }

    func apply(qualityScale: Double) async throws {
        appliedQualityScales.append(qualityScale)
        currentQualityScale = qualityScale
    }

    func requestKeyFrame() async {
        keyFrameRequestCount += 1
    }

    func refreshStillPicture() async throws -> Int? {
        stillRefreshCount += 1
        return 1_900_000
    }
}

final class IntegrationVideoSink: CanvasVideoSending {
    func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool { true }
}

/// Equips only surface 0: every integration scenario here drives a single
/// canvas, and surface 1's slots exist only so the two-canvas host API can be
/// called with one.
@MainActor
func surfaceZeroOnly(_ session: VirtualDisplaySession) -> CanvasSurfaceSlots<VirtualDisplaySession> {
    CanvasSurfaceSlots(
        surface0: session,
        surface1: VirtualDisplaySession(adapter: IntegrationFakeAdapter())
    )
}

@MainActor
func onlyOnSurfaceZero(_ media: any CanvasMediaStreaming) -> CanvasSurfaceSlots<any CanvasMediaStreaming> {
    CanvasSurfaceSlots(surface0: media, surface1: IntegrationScalableMedia())
}

@main
@MainActor
struct SensoriumIntegrationTestRunner {
    static func main() async {
        let adapter = IntegrationFakeAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let identity = try! DeviceIdentity.generate()
        let injector = IntegrationFakeInjector()
        let hostController = HostSessionController(
            sessions: surfaceZeroOnly(session),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjector: injector,
            keyConfinement: .unconfined
        )
        let transport = LoopbackTransport(offerHostScreenList: {
            try await MainActor.run { try hostController.offerHostScreenList() }
        }) { message in
            try await MainActor.run {
                try hostController.handle(message)
            }
        }
        let client = ClientSessionController(transport: transport, identity: identity)
        let observedViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: client
        )
        await observedViewport.setViewportSize(width: 1920, height: 1200)
        await client.setCanvasObserver(observedViewport)
        let displayID = try! await client.connect(deviceName: "Laptop")
        guard await observedViewport.movePointer(x: 12, y: 12) == .delivered(CanvasInputPoint(x: 12, y: 12)) else {
            print("FAIL: connected session did not arm the viewport for input")
            Foundation.exit(1)
        }
        guard displayID == .canvas(displayID: 77, hostScreenOffer: []), session.isActive else {
            print("FAIL: authenticated loopback session did not create the owned canvas")
            Foundation.exit(1)
        }
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: client
        )
        await viewport.setViewportSize(width: 960, height: 600)
        let beforeReady = await viewport.movePointer(x: 480, y: 300)
        await viewport.canvasDidBecomeReady()
        let afterReady = await viewport.movePointer(x: 960, y: 600)
        guard beforeReady == .droppedNotConnected,
              afterReady == .delivered(CanvasInputPoint(x: 1920, y: 1200)),
              injector.events == [
                  .pointerMoved(x: 12, y: 12),
                  .pointerMoved(x: 1920, y: 1200)
              ] else {
            print("FAIL: viewport pointer motion did not reach the host injector as owned-canvas coordinates")
            Foundation.exit(1)
        }

        let surfaceRouter = CanvasSurfaceEventRouter(viewport: observedViewport)
        await surfaceRouter.route(.boundsChanged(width: 960, height: 600))
        let surfaceTopLeft = await surfaceRouter.route(.pointerMoved(x: 0, y: 600))
        guard surfaceTopLeft == .delivered(CanvasInputPoint(x: 0, y: 0)),
              injector.events.last == .pointerMoved(x: 0, y: 0) else {
            print("FAIL: AppKit-origin surface event did not reach the host as a top-left canvas point")
            Foundation.exit(1)
        }

        _ = try! await client.sendInput(.pointerButton(button: .left, isDown: true, x: 5, y: 5))
        await client.disconnect()
        await viewport.canvasDidEnd()
        guard !session.isActive, adapter.releaseCount == 1 else {
            print("FAIL: authenticated loopback disconnect did not release the canvas")
            Foundation.exit(1)
        }
        guard await viewport.movePointer(x: 10, y: 10) == .droppedNotConnected,
              await observedViewport.movePointer(x: 11, y: 11) == .droppedNotConnected,
              injector.events.suffix(2) == [
                  .pointerButton(button: .left, isDown: true, x: 5, y: 5),
                  .pointerButton(button: .left, isDown: false, x: 5, y: 5)
              ] else {
            print("FAIL: disconnect did not release a button still held on the owned canvas, and kept injecting input after the session ended")
            Foundation.exit(1)
        }
        let abruptAdapter = IntegrationFakeAdapter()
        let abruptSession = VirtualDisplaySession(adapter: abruptAdapter)
        let abruptController = HostSessionController(sessions: surfaceZeroOnly(abruptSession), keyConfinement: .unconfined)
        _ = try! abruptController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard abruptSession.isActive else {
            print("FAIL: abrupt-loss scenario did not create a canvas to lose")
            Foundation.exit(1)
        }
        _ = try! abruptController.handle(.goodbye(reason: "transport-closed"))
        guard !abruptSession.isActive, abruptAdapter.releaseCount == 1 else {
            print("FAIL: a client that vanished without a goodbye left the canvas behind")
            Foundation.exit(1)
        }
        _ = try! abruptController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard abruptSession.isActive else {
            print("FAIL: the host could not serve a session after an abrupt loss")
            Foundation.exit(1)
        }
        _ = try! abruptController.handle(.goodbye(reason: "client-disconnected"))
        guard abruptAdapter.releaseCount == 2 else {
            print("FAIL: reconnect after cleanup did not release its own canvas")
            Foundation.exit(1)
        }

        let failingAdapter = FailingVirtualDisplayAdapter()
        let failingSession = VirtualDisplaySession(adapter: failingAdapter)
        let failingController = HostSessionController(sessions: surfaceZeroOnly(failingSession), keyConfinement: .unconfined)
        do {
            _ = try failingController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
            print("FAIL: a failed virtual display creation was reported as success")
            Foundation.exit(1)
        } catch {
        }
        guard !failingSession.isActive, failingAdapter.releaseCount == 0 else {
            print("FAIL: a failed canvas creation left session state or released a handle it never held")
            Foundation.exit(1)
        }
        failingAdapter.shouldFail = false
        _ = try! failingController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard failingSession.isActive, failingAdapter.acquireAttempts == 2 else {
            print("FAIL: the host could not recover once the display API worked again")
            Foundation.exit(1)
        }
        _ = try! failingController.handle(.goodbye(reason: "client-disconnected"))
        guard !failingSession.isActive, failingAdapter.releaseCount == 1 else {
            print("FAIL: the recovered session did not release its canvas")
            Foundation.exit(1)
        }


        // The real host time-sync handler against the real client monitor. Both
        // run on this machine, so the true offset is zero and any end-to-end
        // sample must be small and positive rather than merely non-nil.
        let latencyAdapter = IntegrationFakeAdapter()
        let latencySession = VirtualDisplaySession(adapter: latencyAdapter)
        let latencyIdentity = try! DeviceIdentity.generate()
        let latencyController = HostSessionController(
            sessions: surfaceZeroOnly(latencySession),
            approvedPublicKeys: [latencyIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        _ = try! latencyController.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: latencyIdentity.publicKey,
            signature: try! latencyIdentity.sign(
                SensoriumFrameCodec.authenticatedHelloTranscript(
                    protocolVersion: 1,
                    deviceName: "Laptop",
                    publicKey: latencyIdentity.publicKey,
                    hostCertificateHash: nil
                )
            )
        ))

        let monitor = SessionLatencyMonitor()
        for _ in 0..<4 {
            let request = await monitor.makeClockRequest(atNanoseconds: MonotonicClock.nowNanoseconds())
            guard case let .timeSyncReply(echoed, hostTime)?? = Optional(try! latencyController.handle(request)) else {
                print("FAIL: the host answered a client time-sync request")
                Foundation.exit(1)
            }
            guard await monitor.receiveClockReply(
                clientTimeNanoseconds: echoed,
                hostTimeNanoseconds: hostTime,
                receivedAtNanoseconds: MonotonicClock.nowNanoseconds()
            ) else {
                print("FAIL: the client accepted the host's time-sync reply")
                Foundation.exit(1)
            }
        }

        let capturedAt = MonotonicClock.nowNanoseconds()
        let receivedAt = MonotonicClock.nowNanoseconds()
        let decodedAt = MonotonicClock.nowNanoseconds()
        guard await monitor.recordPresentedFrame(
            timing: FrameTiming(
                hostCapturedAtNanoseconds: capturedAt,
                receivedAtNanoseconds: receivedAt,
                decodedAtNanoseconds: decodedAt
            ),
            presentedAtNanoseconds: MonotonicClock.nowNanoseconds()
        ) else {
            print("FAIL: a synchronised session measured the frame it presented")
            Foundation.exit(1)
        }
        guard let endToEnd = await monitor.metrics().samples(for: .endToEnd).p50,
              endToEnd >= 0,
              endToEnd < 100_000_000 else {
            print("FAIL: end-to-end latency on this machine is positive and under 100ms")
            Foundation.exit(1)
        }
        guard let offset = await monitor.summaryLine(), offset.contains("clock offset 0.0ms") else {
            print("FAIL: two clocks on this machine synchronise to a zero offset")
            Foundation.exit(1)
        }


        // An enlarged viewer window changes the resolution the host actually
        // encodes: real client viewport, real protocol frames, real host
        // session controller, real coordinator debounce.
        let streamAdapter = IntegrationFakeAdapter()
        let streamSession = VirtualDisplaySession(adapter: streamAdapter)
        let streamIdentity = try! DeviceIdentity.generate()
        let streamHostController = HostSessionController(
            sessions: surfaceZeroOnly(streamSession),
            approvedPublicKeys: [streamIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        let streamMedia = IntegrationScalableMedia()
        let streamCoordinator = HostSessionCoordinator(
            controller: streamHostController,
            media: onlyOnSurfaceZero(streamMedia),
            videoSink: IntegrationVideoSink(),
            streamScaleSettleSeconds: 0.2
        )
        let streamTransport = LoopbackTransport(offerHostScreenList: {
            try await MainActor.run { [streamHostController] in try streamHostController.offerHostScreenList() }
        }) { message in
            try await MainActor.run { [streamCoordinator] in streamCoordinator }.handleWritingResponse(message)
        }
        let streamClient = ClientSessionController(transport: streamTransport, identity: streamIdentity)
        let streamViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: streamClient
        )
        await streamClient.setCanvasObserver(streamViewport)
        _ = try! await streamClient.connect(deviceName: "Laptop")
        let streamRouter = CanvasSurfaceEventRouter(viewport: streamViewport)

        // The default 960x600-point window on a 2x display: exactly the
        // resolution already being streamed, so nothing crosses the wire and
        // the encoder is never rebuilt.
        await streamRouter.route(.drawableSizeChanged(pixelWidth: 1920, pixelHeight: 1200))
        try! await Task.sleep(for: .milliseconds(200))
        guard streamMedia.reconfiguredScales.isEmpty else {
            print("FAIL: a default-sized viewer rebuilt the host encoder for no reason")
            Foundation.exit(1)
        }

        // A live window drag to full screen on a 2x display.
        for width in stride(from: 2000.0, through: 3840.0, by: 80.0) {
            await streamRouter.route(.drawableSizeChanged(pixelWidth: width, pixelHeight: width * 1200 / 1920))
        }
        guard streamMedia.reconfiguredScales.isEmpty else {
            print("FAIL: the host rebuilt its encoder while the viewer window was still being dragged")
            Foundation.exit(1)
        }
        try! await Task.sleep(for: .milliseconds(600))
        guard streamMedia.reconfiguredScales == [2.0], streamMedia.currentStreamScale == 2.0 else {
            print("FAIL: a settled viewer resize did not change the resolution the host encodes")
            Foundation.exit(1)
        }
        guard streamMedia.stopCount == 0, streamSession.isActive else {
            print("FAIL: changing the streamed resolution disturbed the session or its canvas")
            Foundation.exit(1)
        }

        // Shrinking back gives the pixels back.
        await streamRouter.route(.drawableSizeChanged(pixelWidth: 1920, pixelHeight: 1200))
        try! await Task.sleep(for: .milliseconds(600))
        guard streamMedia.reconfiguredScales == [2.0, 1.0] else {
            print("FAIL: shrinking the viewer did not release the resolution the host was encoding")
            Foundation.exit(1)
        }

        // A viewer that is already enlarged when it connects — a reconnect
        // behind the same window — must tell the fresh host session before the
        // user touches anything, or the picture silently stays soft.
        let enteredAdapter = IntegrationFakeAdapter()
        let enteredSession = VirtualDisplaySession(adapter: enteredAdapter)
        let enteredIdentity = try! DeviceIdentity.generate()
        let enteredMedia = IntegrationScalableMedia()
        let enteredHostController = HostSessionController(
            sessions: surfaceZeroOnly(enteredSession),
            approvedPublicKeys: [enteredIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        let enteredCoordinator = HostSessionCoordinator(
            controller: enteredHostController,
            media: onlyOnSurfaceZero(enteredMedia),
            videoSink: IntegrationVideoSink(),
            streamScaleSettleSeconds: 0.05
        )
        let enteredTransport = LoopbackTransport(offerHostScreenList: {
            try await MainActor.run { [enteredHostController] in try enteredHostController.offerHostScreenList() }
        }) { message in
            try await MainActor.run { [enteredCoordinator] in enteredCoordinator }.handleWritingResponse(message)
        }
        let enteredClient = ClientSessionController(transport: enteredTransport, identity: enteredIdentity)
        let enteredViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: enteredClient
        )
        await enteredClient.setCanvasObserver(enteredViewport)
        let enteredRouter = CanvasSurfaceEventRouter(viewport: enteredViewport)
        await enteredRouter.route(.drawableSizeChanged(pixelWidth: 3840, pixelHeight: 2400))
        _ = try! await enteredClient.connect(deviceName: "Laptop")
        try! await Task.sleep(for: .milliseconds(300))
        guard enteredMedia.reconfiguredScales == [2.0] else {
            print("FAIL: an already-enlarged viewer did not raise the resolution of the session it just entered")
            Foundation.exit(1)
        }

        // A host that is never told keeps the default streamed resolution:
        // the same session, driven only by messages an older client sends,
        // never reconfigures.
        let legacyMedia = IntegrationScalableMedia()
        let legacySession = VirtualDisplaySession(adapter: IntegrationFakeAdapter())
        let legacyCoordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(legacySession), keyConfinement: .unconfined),
            media: onlyOnSurfaceZero(legacyMedia),
            videoSink: IntegrationVideoSink(),
            streamScaleSettleSeconds: 0.05
        )
        _ = try! await legacyCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! await legacyCoordinator.handleWritingResponse(.timeSyncRequest(clientTimeNanoseconds: 1))
        try! await Task.sleep(for: .milliseconds(300))
        guard legacyMedia.reconfiguredScales.isEmpty,
              legacyMedia.currentStreamScale == StreamScalePolicy.defaultScale else {
            print("FAIL: a viewer that never reports a drawable size did not get the default streamed resolution")
            Foundation.exit(1)
        }
        _ = try! await legacyCoordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))

        // A dual-canvas connect against the real host controller, with video on
        // the wire between the two canvasReady replies. That is what the host
        // actually does — streaming for a surface starts inside the same
        // `handle` that produced its `canvasReady`, so surface 0 is already
        // producing frames while the client is still asking for surface 1.
        let dualPrimarySession = VirtualDisplaySession(adapter: IntegrationFakeAdapter(displayID: 101))
        let dualSecondarySession = VirtualDisplaySession(adapter: IntegrationFakeAdapter(displayID: 102))
        let dualHostController = HostSessionController(
            sessions: CanvasSurfaceSlots(surface0: dualPrimarySession, surface1: dualSecondarySession),
            keyConfinement: .unconfined
        )
        let dualSurfaceZeroKeyFrame = EncodedVideoFramePacket(
            sequence: 0,
            presentationTimeNanoseconds: 1,
            isKeyFrame: true,
            payload: Data([0xD0])
        )
        let dualTransport = LoopbackTransport { message in
            guard case let .canvasRequest(_, _, _, surfaceID) = message, surfaceID == 0 else {
                return []
            }
            return [.video(dualSurfaceZeroKeyFrame)]
        } handler: { message in
            try await MainActor.run {
                try dualHostController.handle(message)
            }
        }
        let dualCanvasClient = ClientSessionController(transport: dualTransport, requestSecondCanvas: true)
        let dualCanvasDisplayID = try? await dualCanvasClient.connect(deviceName: "Laptop")
        guard dualCanvasDisplayID == .canvas(displayID: 101, hostScreenOffer: []), await dualCanvasClient.didOpenSecondCanvas else {
            print("FAIL: a dual-canvas handshake did not survive the host's own video interleaving into it")
            Foundation.exit(1)
        }
        guard dualPrimarySession.isActive, dualSecondarySession.isActive else {
            print("FAIL: a dual-canvas handshake did not leave both host canvases owned")
            Foundation.exit(1)
        }
        // The frame the handshake stepped over is the next thing the media loop
        // reads, keyframe intact — surface 0 is decodable from its first frame.
        let dualDeferredPacket = try? await dualTransport.receivePacket()
        guard dualDeferredPacket == .video(dualSurfaceZeroKeyFrame) else {
            print("FAIL: surface 0's recovery keyframe did not survive the handshake that stepped over it")
            Foundation.exit(1)
        }

        await runStillRefreshDecodabilityTests()

        print("PASS: authenticated client-host loopback creates and destroys the session canvas")
        print("PASS: abrupt client loss releases the canvas and a later session still works")
        print("PASS: a failed canvas creation leaves no orphan and recovers when the API returns")
        print("PASS: session connect and disconnect arm and disarm the viewport automatically")
        print("PASS: AppKit-origin surface events reach the host as top-left canvas points")
        print("PASS: viewport pointer motion reaches the host injector only while the canvas is owned")
        print("PASS: host time sync and client latency monitor produce a real end-to-end sample")
        print("PASS: a settled viewer resize changes the resolution the host encodes, and a drag does not")
        print("PASS: an already-enlarged viewer raises the resolution of the session it enters")
        print("PASS: a viewer that never reports its drawable size keeps the default streamed resolution")
        print("PASS: a dual-canvas handshake opens both host canvases with the host's own video interleaved into it")
    }
}
