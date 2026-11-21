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
    private let queue = DispatchQueue(label: "sensorium.test.synthetic-screen")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var count = 0
    private(set) var startCount = 0

    init(width: Int, height: Int, framesPerSecond: Double = 30) {
        self.width = width
        self.height = height
        interval = 1 / framesPerSecond
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
                        level = x < width / 2 ? Self.darkLevel : Self.brightLevel
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
    private let stream: PortalStream
    private let source: any LinuxFrameSource
    private let sink: any PortalInputSink
    private var failure: (any Error)?
    private var onClosed: (@Sendable () -> Void)?
    private(set) var openCount = 0
    private(set) var interactiveOpenCount = 0

    init(stream: PortalStream, source: any LinuxFrameSource, sink: any PortalInputSink, failure: (any Error)? = nil) {
        self.stream = stream
        self.source = source
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
            grant: liveGrant(streams: [stream]),
            input: sink,
            frameSource: source,
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
    ), bufferWidth: Int = 640, bufferHeight: Int = 360) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorium-runtime-\(UUID().uuidString)", isDirectory: true)
        self.stream = stream
        source = SyntheticScreenSource(width: bufferWidth, height: bufferHeight)
        opener = FakeGrantOpener(stream: stream, source: source, sink: sink)
        let logBox = RigLog()
        let platform = LinuxHostPlatform(
            grantOpener: opener,
            makeIndicator: { [pill, tray] in LinuxHostIndicator(pill: pill, tray: tray) },
            indicatorSupport: { nil },
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
        let presented = rig.pill.presented
        expect(presented == ["Kestrel Laptop"], "the indicator names the device, saw \(presented)")

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

func linuxHostRuntimeTests() -> [NamedTest] { [
    ("a paired viewer streams the granted monitor and drives input", testAPairedViewerStreamsTheGrantedMonitorAndDrivesInput)
] }
#endif
