#if os(Linux)
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

/// A monitor's picture as the portal would deliver it, made up: the top half
/// dark on the left and bright on the right, the bottom half a gray that
/// changes every frame so the encoder always has something new.
final class SyntheticScreenSource: LinuxFrameSource, @unchecked Sendable {
    static let darkLevel: UInt8 = 30
    static let brightLevel: UInt8 = 220

    let width: Int
    let height: Int
    private let interval: TimeInterval
    private let invertedPattern: Bool
    private let queue = DispatchQueue(label: "sensorium.test.synthetic-screen")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var count = 0
    private(set) var startCount = 0

    init(width: Int, height: Int, framesPerSecond: Double = 30, invertedPattern: Bool = false) {
        self.width = width
        self.height = height
        interval = 1 / framesPerSecond
        self.invertedPattern = invertedPattern
    }

    func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            onFrame(self.nextFrame())
        }
        lock.withLock {
            self.timer = timer
            startCount += 1
        }
        onState(.streaming)
        timer.resume()
    }

    func stop() {
        let stopped = lock.withLock {
            defer { timer = nil }
            return timer
        }
        stopped?.cancel()
        queue.sync {}
    }

    private func nextFrame() -> CapturedFrame {
        count += 1
        let stride = width * 4
        var pixels = Data(count: stride * height)
        let band = UInt8(60 + (count * 9) % 120)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let level: UInt8
                    if y < height / 2 {
                        let dark = (x < width / 2) != invertedPattern
                        level = dark ? Self.darkLevel : Self.brightLevel
                    } else {
                        level = band
                    }
                    let offset = y * stride + x * 4
                    bytes[offset] = level
                    bytes[offset + 1] = level
                    bytes[offset + 2] = level
                    bytes[offset + 3] = 0
                }
            }
        }
        return CapturedFrame(
            pixels: pixels,
            width: width,
            height: height,
            stride: stride,
            format: .bgrx,
            presentationTimeNanoseconds: nil,
            cursor: nil
        )
    }
}

/// Hands the runtime a portal grant without a portal.
final class FakeGrantOpener: LinuxScreenGrantOpening, @unchecked Sendable {
    private let lock = NSLock()
    private let streams: [PortalStream]
    private let frameSources: [UInt32: any LinuxFrameSource]
    private let sink: any PortalInputSink
    private var failure: (any Error)?
    private var onClosed: (@Sendable () -> Void)?
    private(set) var openCount = 0
    private(set) var interactiveOpenCount = 0

    init(
        stream: PortalStream, source: any LinuxFrameSource, sink: any PortalInputSink,
        failure: (any Error)? = nil, additionalStream: PortalStream? = nil
    ) {
        self.streams = [stream, additionalStream].compactMap { $0 }
        var frameSources: [UInt32: any LinuxFrameSource] = [stream.nodeID: source]
        if let additionalStream, let size = additionalStream.size {
            frameSources[additionalStream.nodeID] = SyntheticScreenSource(
                width: Int(size.width), height: Int(size.height), invertedPattern: true
            )
        }
        self.frameSources = frameSources
        self.sink = sink
        self.failure = failure
    }

    func setFailure(_ failure: (any Error)?) {
        lock.withLock { self.failure = failure }
    }

    func open(interactive: Bool, onClosed: @escaping @Sendable () -> Void) async throws -> LinuxScreenGrant {
        let failure: (any Error)? = lock.withLock {
            openCount += 1
            if interactive { interactiveOpenCount += 1 }
            return self.failure
        }
        if let failure { throw failure }
        lock.withLock { self.onClosed = onClosed }
        return LinuxScreenGrant(
            grant: liveGrant(streams: streams),
            input: sink,
            frameSources: frameSources,
            close: {}
        )
    }

    /// The portal ending the session, as when the person revokes it.
    func closeFromPortal() {
        let handler = lock.withLock {
            defer { onClosed = nil }
            return onClosed
        }
        handler?()
    }
}

final class FakeLockState: ScreenLockStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    func set(_ value: Bool) { lock.withLock { locked = value } }
    func isScreenLocked() -> Bool { lock.withLock { locked } }
}

final class FakeActivity: HostLocalActivitySignal, @unchecked Sendable {
    private let lock = NSLock()
    private var idle: TimeInterval = 3_600
    func set(idleSeconds: TimeInterval) { lock.withLock { idle = idleSeconds } }
    func currentReading() -> HostLocalActivityReading { .idleFor(lock.withLock { idle }) }
}

final class FakeRelocker: HostScreenRelocking, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var relockCount: Int { lock.withLock { count } }
    func relock() -> Bool {
        lock.withLock { count += 1 }
        return true
    }
}

/// One runtime on loopback with every desktop seam replaced.
@MainActor
final class RuntimeRig {
    let folder: URL
    let stream: PortalStream
    let source: SyntheticScreenSource
    let sink = RecordingSink()
    let opener: FakeGrantOpener
    let pill = StubIndicatorSurface()
    let tray = StubIndicatorSurface()
    let lockState = FakeLockState()
    let activity = FakeActivity()
    let relocker = FakeRelocker()
    var askFirstOutcome: AskFirstOutcome = .denied
    private(set) var askFirstQuestions: [AskFirstPromptContent] = []
    private(set) var log: [String] = []
    private(set) var runtime: LinuxHostRuntime!

    init(stream: PortalStream = PortalStream(
        nodeID: 61,
        id: "monitor-b",
        position: PortalPoint(x: 0, y: 0),
        size: PortalSize(width: 320, height: 180)
    ), bufferWidth: Int = 640, bufferHeight: Int = 360,
    indicatorSupport: @escaping @MainActor () -> IndicatorError? = { nil },
    additionalStream: PortalStream? = nil) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorium-runtime-\(UUID().uuidString)", isDirectory: true)
        self.stream = stream
        source = SyntheticScreenSource(width: bufferWidth, height: bufferHeight)
        opener = FakeGrantOpener(stream: stream, source: source, sink: sink, additionalStream: additionalStream)
        let logBox = RigLog()
        let platform = LinuxHostPlatform(
            grantOpener: opener,
            makeIndicator: { [pill, tray] in LinuxHostIndicator(pill: pill, tray: tray) },
            indicatorSupport: indicatorSupport,
            lockState: lockState,
            localActivity: activity,
            relocker: relocker,
            sessionAge: { nil },
            askFirst: { [weak self] content in
                guard let self else { return .denied }
                self.askFirstQuestions.append(content)
                return self.askFirstOutcome
            },
            encoderBackend: .openH264
        )
        runtime = LinuxHostRuntime(
            dataFolder: folder,
            platform: platform,
            listen: .testOnly(address: "127.0.0.1", port: 0),
            log: { logBox.append($0) }
        )
        _ = logBox
    }

    func start() async {
        await runtime.start()
        await expectEventually("the grant opens and the first frame arrives") {
            self.runtime.state.grant == .allowed && self.runtime.offersHostScreen
        }
    }

    func finish() async {
        await runtime.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    var port: UInt16 { runtime.boundPort ?? 0 }

    var sessionRecords: [HostScreenSessionRecord] {
        HostScreenSessionLogStore(url: folder.appendingPathComponent("host-screen-sessions.log")).records()
    }

    /// Shows a code on the host and pairs a new viewer identity with it.
    func pairViewer(named name: String) async throws -> PairedViewer {
        runtime.showPairingCode()
        guard case let .showing(code, _, _) = runtime.state.pairing else {
            throw CheckFailure("the host shows no pairing code after asking for one")
        }
        let identity = try DeviceIdentity.generate()
        let connection = OpenSSLQUICConnection(host: "127.0.0.1", port: port, tlsCertificateHash: nil)
        try await connection.start(timeout: 10)
        let client = ClientSessionController(transport: connection, identity: identity)
        let approval = try await client.pair(deviceName: name, code: code)
        await connection.close()
        return PairedViewer(
            name: name,
            identity: identity,
            hostPublicKey: approval.hostPublicKey,
            pin: approval.tlsCertificateHash ?? Data()
        )
    }
}

final class RigLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

struct PairedViewer {
    let name: String
    let identity: DeviceIdentity
    let hostPublicKey: Data
    let pin: Data
}

/// A viewer connection made with the viewer's own session controller.
struct ViewerLink {
    let connection: OpenSSLQUICConnection
    let client: ClientSessionController
}

func connectViewer(_ viewer: PairedViewer, port: UInt16) async throws -> ViewerLink {
    let connection = OpenSSLQUICConnection(host: "127.0.0.1", port: port, tlsCertificateHash: viewer.pin)
    try await connection.start(timeout: 10)
    let client = ClientSessionController(
        transport: connection,
        identity: viewer.identity,
        pinnedHostPublicKey: viewer.hostPublicKey
    )
    return ViewerLink(connection: connection, client: client)
}

/// Reads packets for up to `seconds`, decoding video with the viewer's
/// decoder, until `frames` pictures have been decoded.
func collectPictures(
    from connection: OpenSSLQUICConnection,
    frames: Int,
    seconds: TimeInterval
) async throws -> (pictures: [DecodedFrame], control: [SensoriumMessage]) {
    let decoded = DecodedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil, outputHandler: { decoded.append($0) })
    var control: [SensoriumMessage] = []
    let deadline = Date().addingTimeInterval(seconds)
    while decoded.frames.count < frames, Date() < deadline {
        let remaining = max(0.1, deadline.timeIntervalSinceNow)
        let packet = try await withDeadline(remaining, "the next packet") { try await connection.receivePacket() }
        switch packet {
        case let .video(frame), let .videoForSurface(_, frame):
            try decoder.decode(frame)
        case let .control(message):
            control.append(message)
        default:
            break
        }
    }
    return (decoded.frames, control)
}

/// The mean luma of a rectangle of a decoded picture.
func meanLuma(_ picture: DecodedFrame, x: Range<Int>, y: Range<Int>) -> Double? {
    guard let plane = lumaPlane(of: picture) else { return nil }
    var total = 0
    for row in y {
        for column in x {
            total += Int(plane[row * picture.width + column])
        }
    }
    return Double(total) / Double(x.count * y.count)
}

@MainActor
private func testAPairedViewerStreamsTheGrantedMonitorAndDrivesInput() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let link = try await connectViewer(viewer, port: rig.port)
        let outcome = try await link.client.connect(
            deviceName: viewer.name,
            target: .offeredHostScreen(preferredDisplayIdentity: nil)
        )
        guard case let .hostScreen(geometry, _, offer) = outcome else {
            expect(false, "the viewer was given the host screen, got \(outcome)")
            return
        }
        expect(offer.count == 1, "the one granted monitor is offered, saw \(offer.count)")
        expect(
            geometry.logicalWidth == 320 && geometry.logicalHeight == 180 && geometry.backingScale == 2,
            "the screen is offered at its logical size and the buffer's scale, saw \(geometry)"
        )
        // The host says the screen is ready before it builds the media that
        // shows the indicator, so the pill can come up just after.
        await expectEventually("the indicator names the device") { rig.pill.presented == ["Kestrel Laptop"] }

        let (pictures, _) = try await collectPictures(from: link.connection, frames: 30, seconds: 20)
        expect(pictures.count >= 30, "thirty pictures decoded, saw \(pictures.count)")
        for picture in pictures {
            expect(picture.width == 320 && picture.height == 180, "a picture is \(picture.width)x\(picture.height)")
        }
        if let last = pictures.last,
           let dark = meanLuma(last, x: 10..<150, y: 10..<80),
           let bright = meanLuma(last, x: 170..<310, y: 10..<80) {
            expect(dark < 70 && bright > 170, "the picture shows the monitor's content, dark \(dark) bright \(bright)")
        } else {
            expect(false, "a decoded picture has a luma plane")
        }

        try await link.client.sendInput(.pointerMoved(x: 160, y: 90))
        try await link.client.sendInput(.key(keyCode: 0, isDown: true, modifiers: []))
        try await link.client.sendInput(.key(keyCode: 0, isDown: false, modifiers: []))
        var applied: [UInt64] = []
        let deadline = Date().addingTimeInterval(10)
        while applied.count < 3, Date() < deadline {
            let packet = try await withDeadline(5, "an input echo") { try await link.connection.receivePacket() }
            if case let .control(.inputApplied(sequence)) = packet {
                applied.append(sequence)
            }
        }
        expect(applied.count == 3, "every input was echoed as applied, saw \(applied)")
        let events = rig.sink.events
        expect(events.contains(.absolute(stream: 61, x: 160, y: 90)), "the pointer moved on the granted stream, saw \(events)")
        expect(events.contains(.key(30, true)) && events.contains(.key(30, false)), "A went down and up as evdev 30, saw \(events)")

        await link.client.disconnect()
        await expectEventually("the session ends on the host") { rig.runtime.state.status == .waiting }
        let dismissals = rig.pill.dismissals
        expect(dismissals >= 1, "the indicator came down")
        let record = HostScreenSessionLogStore(url: rig.folder.appendingPathComponent("host-screen-sessions.log")).lastRecord
        expect(record?.deviceName == "Kestrel Laptop", "the session record names the device, saw \(String(describing: record))")
        expect(record?.displayLabel.isEmpty == false, "and the display")
        expect(record?.outcome != nil, "and when it ended")
    } catch {
        expect(false, "the session ran end to end, threw \(error)")
    }
    await rig.finish()
}

/// Everything a raw viewer connection receives, read by one task so no two
/// reads ever overlap.
final class PacketTap: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [SensoriumTransportPacket] = []
    private var ended = false
    private var task: Task<Void, Never>?

    init(_ connection: OpenSSLQUICConnection) {
        task = Task { [weak self] in
            while true {
                guard let packet = try? await connection.receiveWirePacket() else {
                    self?.lock.withLock { self?.ended = true }
                    return
                }
                self?.lock.withLock { self?.received.append(packet) }
            }
        }
    }

    /// Whether the host closed the connection.
    var hasEnded: Bool { lock.withLock { ended } }

    var packets: [SensoriumTransportPacket] { lock.withLock { received } }

    var control: [SensoriumMessage] {
        packets.compactMap { if case let .control(message) = $0 { message } else { nil } }
    }

    var videoCount: Int {
        packets.filter {
            switch $0 {
            case .video, .videoForSurface: true
            default: false
            }
        }.count
    }

    func firstControl(where matches: (SensoriumMessage) -> Bool) -> SensoriumMessage? {
        control.first(where: matches)
    }
}

/// A viewer that speaks the wire by hand, so a refusal can be followed by a
/// look at everything else the host sent.
struct RawViewer {
    let connection: OpenSSLQUICConnection
    let tap: PacketTap

    static func connect(_ viewer: PairedViewer, port: UInt16) async throws -> RawViewer {
        let connection = OpenSSLQUICConnection(host: "127.0.0.1", port: port, tlsCertificateHash: viewer.pin)
        try await connection.start(timeout: 10)
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: viewer.name,
            publicKey: viewer.identity.publicKey,
            hostCertificateHash: viewer.pin
        )
        try await connection.send(.authenticatedHello(
            protocolVersion: 1,
            deviceName: viewer.name,
            publicKey: viewer.identity.publicKey,
            hostCertificateHash: viewer.pin,
            signature: try viewer.identity.sign(transcript)
        ))
        return RawViewer(connection: connection, tap: PacketTap(connection))
    }

    /// The host's first word after the hello: its host-screen offer.
    @MainActor
    func offer() async -> SensoriumMessage? {
        _ = await eventually(10) { tap.firstControl(where: Self.isOffer) != nil }
        return tap.firstControl(where: Self.isOffer)
    }

    func request(_ entry: HostScreenListEntry) async throws {
        try await connection.send(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil))
    }

    /// The host's answer to the request.
    @MainActor
    func answer() async -> SensoriumMessage? {
        _ = await eventually(15) { tap.firstControl(where: Self.isAnswer) != nil }
        return tap.firstControl(where: Self.isAnswer)
    }

    private static func isOffer(_ message: SensoriumMessage) -> Bool {
        switch message {
        case .hostScreenList, .hostScreenRefused: true
        default: false
        }
    }

    private static func isAnswer(_ message: SensoriumMessage) -> Bool {
        switch message {
        case .hostScreenReady, .hostScreenRefused: true
        default: false
        }
    }

    func close() async {
        await connection.close()
    }
}

/// Requests the offered host screen over a raw connection and returns the
/// answer once two quiet seconds have passed, with every video packet the
/// host sent counted.
@MainActor
func requestOverRawConnection(
    _ rig: RuntimeRig,
    _ viewer: PairedViewer,
    beforeRequest: @MainActor () async -> Void = {}
) async throws -> (answer: SensoriumMessage?, videoPackets: Int, control: [SensoriumMessage], ended: Bool) {
    let raw = try await RawViewer.connect(viewer, port: rig.port)
    guard case let .hostScreenList(displays, _)? = await raw.offer(), let entry = displays.first else {
        await raw.close()
        throw CheckFailure("the host offered no screen to request")
    }
    await beforeRequest()
    try await raw.request(entry)
    let answer = await raw.answer()
    try? await Task.sleep(for: .seconds(2))
    let videoPackets = raw.tap.videoCount
    let control = raw.tap.control
    let ended = raw.tap.hasEnded
    await raw.close()
    return (answer, videoPackets, control, ended)
}

func isRefusal(_ message: SensoriumMessage?) -> Bool {
    if case .hostScreenRefused? = message { return true }
    return false
}

@MainActor
private func testADisarmedDeviceIsRefusedWithNoFrame() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let machineID = viewer.identity.publicKey.base64EncodedString()
        expect(rig.runtime.state.machines.first?.isArmed == true, "pairing armed the device")
        rig.runtime.setSharing(machineID: machineID, isOn: false)
        expect(rig.runtime.state.machines.first?.isArmed == false, "the person at the host turned it off")
        let raw = try await RawViewer.connect(viewer, port: rig.port)
        let offer = await raw.offer()
        expect(isRefusal(offer), "a disarmed device is offered nothing, saw \(String(describing: offer))")
        try? await Task.sleep(for: .seconds(2))
        let videoPackets = raw.tap.videoCount
        expect(videoPackets == 0, "and sent no frame, saw \(videoPackets)")
        await raw.close()
        let presented = rig.pill.presented
        expect(presented.isEmpty, "no indicator was shown")
        expect(rig.sessionRecords.isEmpty, "and no session was recorded")
    } catch {
        expect(false, "the refusal ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAnIndicatorThatCannotShowRefusesWithNoFrame() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        rig.pill.failure = .surfaceRefused
        let (answer, videoPackets, control, ended) = try await requestOverRawConnection(rig, viewer)
        // The shared bring-up tells the viewer the screen is ready before it
        // builds the media, and the indicator is shown as the media is
        // built; a failure there ends the session and closes the connection.
        if case .hostScreenReady? = answer {
            expect(ended, "the session ends when the indicator fails, saw \(control)")
        } else {
            expect(isRefusal(answer), "the session is refused when the indicator fails, saw \(control)")
        }
        expect(videoPackets == 0, "and no frame was sent, saw \(videoPackets)")
        let records = rig.sessionRecords
        expect(records.count == 1 && records[0].outcome != nil, "the record it opened is closed, saw \(records)")
        expect(rig.runtime.state.status == .waiting, "the host is not sharing")
    } catch {
        expect(false, "the refusal ran, threw \(error)")
    }
    await rig.finish()
}

/// A desktop the launch probe found unable to show the indicator, such as
/// one whose compositor has no layer shell, offers no host screen at all,
/// even with the grant open and frames arriving.
@MainActor
private func testADesktopThatCannotShowTheIndicatorOffersNoHostScreen() async {
    let rig = RuntimeRig(indicatorSupport: { .layerShellUnavailable })
    await rig.runtime.start()
    await expectEventually("the grant opens") { rig.runtime.state.grant == .allowed }
    try? await Task.sleep(for: .seconds(1))
    expect(rig.runtime.state.desktop == .unsupported, "the host says this desktop cannot show the host screen")
    expect(!rig.runtime.offersHostScreen, "and offers none")
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let raw = try await RawViewer.connect(viewer, port: rig.port)
        let offer = await raw.offer()
        let offersNothing: Bool
        switch offer {
        case let .hostScreenList(displays, _)?: offersNothing = displays.isEmpty
        case .hostScreenRefused?: offersNothing = true
        default: offersNothing = false
        }
        expect(offersNothing, "a paired, armed device is offered no screen, saw \(String(describing: offer))")
        try? await Task.sleep(for: .seconds(2))
        let control = raw.tap.control
        let ready = control.contains { if case .hostScreenReady = $0 { true } else { false } }
        expect(!ready, "the host never says a screen is ready, saw \(control)")
        let videoPackets = raw.tap.videoCount
        expect(videoPackets == 0, "and sends no frame, saw \(videoPackets)")
        await raw.close()
        let presented = rig.pill.presented
        expect(presented.isEmpty, "no indicator was shown")
        expect(rig.sessionRecords.isEmpty, "and no session was recorded")
    } catch {
        expect(false, "the unsupported desktop ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAWithdrawnGrantRefusesWithNoFrame() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        // The grant ends after the screen was offered and before it is
        // asked for, as when the person at the host revokes it.
        let (answer, videoPackets, _, _) = try await requestOverRawConnection(rig, viewer, beforeRequest: {
            rig.opener.closeFromPortal()
            await expectEventually("the host sees the grant end") { rig.runtime.state.grant == .needed }
        })
        expect(isRefusal(answer), "a request without a grant is refused, saw \(String(describing: answer))")
        expect(videoPackets == 0, "and no frame was sent, saw \(videoPackets)")
        let presented = rig.pill.presented
        expect(presented.isEmpty, "no indicator was shown")
        expect(rig.sessionRecords.isEmpty, "and no session was recorded")
        let raw = try await RawViewer.connect(viewer, port: rig.port)
        let offer = await raw.offer()
        if case let .hostScreenList(displays, _)? = offer {
            expect(displays.isEmpty, "a new viewer is offered no screen while there is no grant")
        } else {
            expect(isRefusal(offer), "a new viewer is offered no screen while there is no grant, saw \(String(describing: offer))")
        }
        await raw.close()
    } catch {
        expect(false, "the refusal ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAskFirstWithRecentUseAndADenialRefusesWithNoFrame() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        rig.runtime.setAsksFirst(machineID: viewer.identity.publicKey.base64EncodedString(), isOn: true)
        expect(rig.runtime.state.machines.first?.asksFirst == true, "asking first is on for the device")
        rig.activity.set(idleSeconds: 5)
        rig.askFirstOutcome = .denied
        let (answer, videoPackets, _, _) = try await requestOverRawConnection(rig, viewer)
        expect(isRefusal(answer), "a denied request is refused, saw \(String(describing: answer))")
        expect(videoPackets == 0, "and no frame was sent, saw \(videoPackets)")
        let questions = rig.askFirstQuestions
        expect(questions.map(\.deviceName) == ["Kestrel Laptop"], "the person at the host was asked, naming the device, saw \(questions)")
        let presented = rig.pill.presented
        expect(presented.isEmpty, "no indicator was shown")
        expect(rig.sessionRecords.isEmpty, "and no session was recorded")
    } catch {
        expect(false, "the refusal ran, threw \(error)")
    }
    await rig.finish()
}

/// Waits for pictures until one of `width` by `height` decodes.
func waitForPicture(
    from connection: OpenSSLQUICConnection,
    width: Int,
    height: Int,
    seconds: TimeInterval
) async throws -> [String] {
    let decoded = DecodedFrames()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil, outputHandler: { decoded.append($0) })
    let deadline = Date().addingTimeInterval(seconds)
    var sawKeyFrame = false
    while Date() < deadline {
        if decoded.frames.contains(where: { $0.width == width && $0.height == height }) { break }
        let packet = try await withDeadline(max(0.1, deadline.timeIntervalSinceNow), "the next packet") {
            try await connection.receivePacket()
        }
        if case let .video(frame) = packet {
            // A decoder joining a running stream can start only at a key
            // frame that carries its parameter sets.
            sawKeyFrame = sawKeyFrame || (frame.isKeyFrame && frame.codecConfiguration != nil)
            guard sawKeyFrame else { continue }
            try decoder.decode(frame)
        }
    }
    return decoded.frames.map { "\($0.width)x\($0.height)" }
}

/// Reads until a control message matching `matches` arrives.
func waitForControl(
    from connection: OpenSSLQUICConnection,
    seconds: TimeInterval,
    _ matches: @Sendable (SensoriumMessage) -> Bool
) async throws -> SensoriumMessage? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let packet = try await withDeadline(max(0.1, deadline.timeIntervalSinceNow), "the next packet") {
            try await connection.receivePacket()
        }
        if case let .control(message) = packet, matches(message) {
            return message
        }
    }
    return nil
}

@MainActor
private func testAFractionallyScaledMonitorStreamsAtItsLogicalSize() async {
    // A 2560x1440 monitor at 150% is 1707x960 points.
    let rig = RuntimeRig(
        stream: PortalStream(
            nodeID: 62,
            id: "monitor-c",
            position: PortalPoint(x: 0, y: 0),
            size: PortalSize(width: 1707, height: 960)
        ),
        bufferWidth: 2560,
        bufferHeight: 1440
    )
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let link = try await connectViewer(viewer, port: rig.port)
        let outcome = try await link.client.connect(deviceName: viewer.name, target: .offeredHostScreen(preferredDisplayIdentity: nil))
        guard case let .hostScreen(geometry, _, _) = outcome else {
            expect(false, "the viewer was given the host screen, got \(outcome)")
            return
        }
        expect(
            geometry.logicalWidth == 1707 && geometry.logicalHeight == 960 && abs(geometry.backingScale - 1.5) < 0.01,
            "a 150% monitor is offered at 1707x960 points at 1.5, saw \(geometry)"
        )
        let (pictures, _) = try await collectPictures(from: link.connection, frames: 10, seconds: 30)
        expect(pictures.count >= 10, "pictures decoded, saw \(pictures.count)")
        let sizes = Set(pictures.map { "\($0.width)x\($0.height)" })
        expect(sizes == ["1706x960"], "the odd logical width is encoded one pixel narrower, saw \(sizes)")
        if let last = pictures.last,
           let dark = meanLuma(last, x: 40..<800, y: 40..<440),
           let bright = meanLuma(last, x: 900..<1660, y: 40..<440) {
            expect(dark < 70 && bright > 170, "the scaled picture keeps the monitor's content, dark \(dark) bright \(bright)")
        }
        try await link.client.sendInput(.pointerMoved(x: 853.5, y: 480))
        _ = try await waitForControl(from: link.connection, seconds: 5) { if case .inputApplied = $0 { true } else { false } }
        let events = rig.sink.events
        expect(events.contains(.absolute(stream: 62, x: 853.5, y: 480)), "the pointer lands in points, saw \(events)")
        await link.client.disconnect()
    } catch {
        expect(false, "the fractional session ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testALiveSessionHearsTheLockStateAndAHeldKeyIsReleasedAtDisconnect() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let link = try await connectViewer(viewer, port: rig.port)
        _ = try await link.client.connect(deviceName: viewer.name, target: .offeredHostScreen(preferredDisplayIdentity: nil))
        rig.lockState.set(true)
        let locked = try await waitForControl(from: link.connection, seconds: 10) {
            $0 == .hostScreenLockState(locked: true)
        }
        expect(locked != nil, "the viewer is told the host locked")
        rig.lockState.set(false)
        let unlocked = try await waitForControl(from: link.connection, seconds: 10) {
            $0 == .hostScreenLockState(locked: false)
        }
        expect(unlocked != nil, "and that it unlocked")

        try await link.client.sendInput(.key(keyCode: 0, isDown: true, modifiers: []))
        _ = try await waitForControl(from: link.connection, seconds: 5) { if case .inputApplied = $0 { true } else { false } }
        expect(rig.sink.events.last == .key(30, true), "A is held on the host")
        await link.client.disconnect()
        await expectEventually("the held key is released when the viewer leaves") {
            rig.sink.events.last == .key(30, false)
        }
    } catch {
        expect(false, "the live session ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAStreamScaleChangeRebuildsTheStreamAtTheNewSize() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let link = try await connectViewer(viewer, port: rig.port)
        _ = try await link.client.connect(deviceName: viewer.name, target: .offeredHostScreen(preferredDisplayIdentity: nil))
        let before = try await waitForPicture(from: link.connection, width: 320, height: 180, seconds: 10)
        expect(before.contains("320x180"), "the stream starts at the logical size, saw \(Set(before))")
        try await link.client.sendStreamScalePreference(.fixed(2))
        let after = try await waitForPicture(from: link.connection, width: 640, height: 360, seconds: 15)
        expect(after.contains("640x360"), "double scale streams at the buffer's full size, saw \(Set(after))")
        await link.client.disconnect()
    } catch {
        expect(false, "the scale change ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAViewerSwitchesBetweenGrantedMonitorsWithoutCrossingTheirVideoOrInput() async {
    let secondMonitor = PortalStream(
        nodeID: 62,
        id: "monitor-c",
        position: PortalPoint(x: 320, y: 0),
        size: PortalSize(width: 480, height: 270)
    )
    let rig = RuntimeRig(additionalStream: secondMonitor)
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let first = try await connectViewer(viewer, port: rig.port)
        let firstOutcome = try await first.client.connect(
            deviceName: viewer.name,
            target: .offeredHostScreen(preferredDisplayIdentity: nil)
        )
        guard case let .hostScreen(firstGeometry, _, offer) = firstOutcome, offer.count == 2 else {
            expect(false, "the host offered both granted monitors, saw \(firstOutcome)")
            return
        }
        expect(firstGeometry.logicalWidth == 320 && firstGeometry.backingScale == 2, "the first monitor kept its scale")
        let (firstPictures, _) = try await collectPictures(from: first.connection, frames: 3, seconds: 6)
        guard let firstPicture = firstPictures.last,
              firstPicture.width == 320, firstPicture.height == 180,
              let firstDark = meanLuma(firstPicture, x: 20..<100, y: 20..<60),
              let firstBright = meanLuma(firstPicture, x: 220..<300, y: 20..<60) else {
            expect(false, "the first monitor delivered its picture")
            return
        }
        expect(firstDark < 70 && firstBright > 170, "the first monitor was dark on the left")
        try await first.client.sendInput(.pointerMoved(x: 90, y: 70))
        await expectEventually("the first monitor got its own pointer coordinates") {
            rig.sink.events.contains(.absolute(stream: 61, x: 90, y: 70))
        }
        await first.client.disconnect()
        await expectEventually("the first monitor's session ended") { rig.runtime.state.status == .waiting }

        let second = try await connectViewer(viewer, port: rig.port)
        let secondOutcome = try await second.client.connect(
            deviceName: viewer.name,
            target: .hostScreen(displayIdentity: offer[1].displayIdentity)
        )
        guard case let .hostScreen(secondGeometry, _, _) = secondOutcome else {
            expect(false, "the viewer switched to the second monitor, saw \(secondOutcome)")
            return
        }
        expect(secondGeometry.logicalWidth == 480 && secondGeometry.backingScale == 1, "the second monitor kept its scale")
        let (secondPictures, _) = try await collectPictures(from: second.connection, frames: 3, seconds: 6)
        guard let secondPicture = secondPictures.last,
              secondPicture.width == 480, secondPicture.height == 270,
              let secondBright = meanLuma(secondPicture, x: 20..<200, y: 20..<100),
              let secondDark = meanLuma(secondPicture, x: 280..<460, y: 20..<100) else {
            expect(false, "the second monitor delivered its picture")
            return
        }
        expect(secondBright > 170 && secondDark < 70, "the second monitor was bright on the left")
        try await second.client.sendInput(.pointerMoved(x: 390, y: 240))
        await expectEventually("the second monitor got its own pointer coordinates") {
            rig.sink.events.contains(.absolute(stream: 62, x: 390, y: 240))
        }
        await second.client.disconnect()
        await expectEventually("the second monitor's session ended") { rig.runtime.state.status == .waiting }

        let ungranted = try await connectViewer(viewer, port: rig.port)
        do {
            _ = try await ungranted.client.connect(
                deviceName: viewer.name,
                target: .hostScreen(displayIdentity: "ungranted-monitor")
            )
            expect(false, "an ungranted monitor must never fall back to a granted one")
        } catch ClientSessionError.hostScreenRefused {}
        await ungranted.connection.close()
    } catch {
        expect(false, "the switch ran end to end, threw \(error)")
    }
    await rig.finish()
}

func linuxHostRuntimeTests() -> [NamedTest] { [
    ("a paired viewer streams the granted monitor and drives input", testAPairedViewerStreamsTheGrantedMonitorAndDrivesInput),
    ("a viewer switches between granted monitors without crossing video or input", testAViewerSwitchesBetweenGrantedMonitorsWithoutCrossingTheirVideoOrInput),
    ("a disarmed device is refused with no frame", testADisarmedDeviceIsRefusedWithNoFrame),
    ("an indicator that cannot show refuses with no frame", testAnIndicatorThatCannotShowRefusesWithNoFrame),
    ("a desktop that cannot show the indicator offers no host screen", testADesktopThatCannotShowTheIndicatorOffersNoHostScreen),
    ("a withdrawn grant refuses with no frame", testAWithdrawnGrantRefusesWithNoFrame),
    ("ask first with recent use and a denial refuses with no frame", testAskFirstWithRecentUseAndADenialRefusesWithNoFrame),
    ("a fractionally scaled monitor streams at its logical size", testAFractionallyScaledMonitorStreamsAtItsLogicalSize),
    ("a live session hears the lock state and a held key is released at disconnect", testALiveSessionHearsTheLockStateAndAHeldKeyIsReleasedAtDisconnect),
    ("a stream scale change rebuilds the stream at the new size", testAStreamScaleChangeRebuildsTheStreamAtTheNewSize)
] }
#endif
