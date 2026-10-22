import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A VideoToolbox call on a live session goes through the encoder service,
/// and the encoder service can wait on a hardware encoder that has stopped
/// answering for minutes at a time. Host-screen input is injected on the main
/// actor, so any such call made there turns a stalled encoder into a host
/// that ignores every key the viewer types -- the lock screen included. These
/// tests stall the encoder's own calls and require the main actor to keep
/// injecting input until the stall ends.

/// Stands in for an encoder service that does not answer: the first call
/// through it waits until the test lets it go. Bounded, so a regression that
/// blocks the main actor on it fails the test rather than hanging the runner.
private final class StalledEncoderService: @unchecked Sendable {
    private static let stallLimitSeconds = 5.0

    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var hasStalled = false
    private var isStalled = false
    private var timedOut = false

    var isStalledNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStalled
    }

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasStalled
    }

    var endedByTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Waits for `letGo` the first time only; every later call passes.
    func stallOnce() {
        lock.lock()
        guard !hasStalled else {
            lock.unlock()
            return
        }
        hasStalled = true
        isStalled = true
        lock.unlock()
        let result = release.wait(timeout: .now() + Self.stallLimitSeconds)
        lock.lock()
        isStalled = false
        timedOut = result == .timedOut
        lock.unlock()
    }

    func letGo() {
        release.signal()
    }

    private var completeFramesCalls = 0

    /// How many sessions made through `calls` have been flushed for teardown.
    var completedFramesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completeFramesCalls
    }

    var calls: VideoToolboxSessionCalls {
        VideoToolboxSessionCalls(
            createSession: { [self] width, height, codecType, encoderSpecification, outputCallback, refcon in
                stallOnce()
                return VideoToolboxSessionCalls.liveCreateSession(
                    width, height, codecType, encoderSpecification, outputCallback, refcon
                )
            },
            setProperty: { [self] session, key, value in
                stallOnce()
                return VideoToolboxSessionCalls.live.setProperty(session, key, value)
            },
            completeFrames: { [self] session in
                stallOnce()
                lock.lock()
                completeFramesCalls += 1
                lock.unlock()
                VideoToolboxSessionCalls.live.completeFrames(session)
            }
        )
    }
}

@available(macOS 13.0, *)
@MainActor
private final class SilentFrameSource: HostFrameSource {
    private(set) var appliedFramesPerSecond: [Int] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws { startCount += 1 }
    func stop() async throws { stopCount += 1 }
    func apply(framesPerSecond: Int) async throws { appliedFramesPerSecond.append(framesPerSecond) }
}

@available(macOS 13.0, *)
@MainActor
private final class PipelineHolder {
    var pipeline: HostMediaPipeline?
}

/// A host-screen session that has been admitted, so a key it is handed goes
/// straight to the injector -- the path a viewer's typing takes, on the main
/// actor.
@MainActor
private func admittedHostScreenSession() -> (HostSessionController, FakeInputInjectorFactory)? {
    let identity = try! DeviceIdentity.generate()
    let display = DisplaySnapshot(
        id: 9,
        pixelWidth: 3840,
        pixelHeight: 2160,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 3840,
        modePixelHeight: 2160,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 41
    )
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Heron Laptop",
            armedAt: Date()
        )
    ])
    let injectorFactory = FakeInputInjectorFactory()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [identity.publicKey],
        requireAuthentication: true,
        inputInjectorFactory: injectorFactory,
        keyConfinement: .unconfined,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: EncoderStallIdleSignal()
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Heron Laptop", publicKey: identity.publicKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1,
        deviceName: "Heron Laptop",
        publicKey: identity.publicKey,
        signature: try! identity.sign(transcript)
    ))
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(),
          let entry = displays.first,
          case .hostScreenReady = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) else {
        return nil
    }
    return (controller, injectorFactory)
}

private final class EncoderStallIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@available(macOS 13.0, *)
@MainActor
private func makeStallablePipeline(source: SilentFrameSource) async -> HostMediaPipeline? {
    try? await makePipeline(source: source, sessionCalls: .live)
}

@available(macOS 13.0, *)
@MainActor
private func makePipeline(
    source: SilentFrameSource,
    sessionCalls: VideoToolboxSessionCalls,
    sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer> = SharedEncodeAdmissionGate<CMSampleBuffer>(
        capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
    )
) async throws -> HostMediaPipeline {
    try await HostMediaPipeline(
        surface: CanvasSurfaceID.allCases[0],
        configuration: .remoteDefault,
        sessionAdmissionGate: sessionAdmissionGate,
        frameSourceFactory: { _, _, _, _ in source },
        encoderSessionCalls: sessionCalls,
        encodedFrameHandler: { _ in true }
    )
}

/// Starts `operation`, waits for it to reach the stalled encoder, then types
/// one key through the host-screen session and requires it to be injected
/// while the encoder is still stalled. Lets the encoder go and returns once
/// `operation` has finished.
@available(macOS 13.0, *)
@MainActor
private func expectInputIsInjectedWhileTheEncoderStalls(
    during what: String,
    service: StalledEncoderService,
    operation: @escaping @MainActor () async throws -> Void
) async {
    guard let (controller, injectorFactory) = admittedHostScreenSession() else {
        expect(false, "the host-screen fixture is admitted, so a key can be injected (\(what))")
        return
    }
    let task = Task { @MainActor in
        try await operation()
    }
    let reached = await waitUntil(timeoutSeconds: 10) { service.hasEntered }
    expect(reached, "\(what) reaches the encoder service")

    let key = SensoriumInputEvent.key(keyCode: 0, isDown: true, modifiers: [])
    let reply = try! controller.handle(.input(key, surfaceID: nil, sequence: 1))
    let stalledWhenInjected = service.isStalledNow
    service.letGo()
    let outcome = await task.result

    expect(
        stalledWhenInjected && !service.endedByTimeout,
        "a viewer's key is injected on the main actor while \(what) waits on a stalled encoder; "
            + "the main actor instead waited out the stall"
    )
    expect(
        injectorFactory.injector.events == [key] && reply == .inputApplied(sequence: 1),
        "the key typed during the stall reached the injector and was acknowledged (\(what))"
    )
    if case .failure(let error) = outcome {
        expect(false, "\(what) completes once the encoder answers again, got \(error)")
    }
}

@available(macOS 13.0, *)
@MainActor
func runEncoderStallTests() async {
    do {
        let source = SilentFrameSource()
        guard let pipeline = await makeStallablePipeline(source: source) else {
            print("SKIP: this machine has no hardware H.264 encoder, so there is no encoder to stall")
            return
        }
        let service = StalledEncoderService()
        pipeline.streamEncoder.sessionCalls = service.calls
        await expectInputIsInjectedWhileTheEncoderStalls(during: "a frame-rate change", service: service) {
            try await pipeline.apply(framesPerSecond: 30)
        }
        expect(
            pipeline.streamEncoder.appliedFramesPerSecond == 30 && source.appliedFramesPerSecond == [30],
            "the stalled frame-rate change completes on both halves once the encoder answers, got encoder "
                + "\(pipeline.streamEncoder.appliedFramesPerSecond), capture \(source.appliedFramesPerSecond)"
        )
        try? await pipeline.stop()
        print("PASS: a frame-rate change stalled in the encoder leaves the main actor injecting input, and completes after")
    }

    do {
        let source = SilentFrameSource()
        guard let pipeline = await makeStallablePipeline(source: source) else {
            return
        }
        let service = StalledEncoderService()
        pipeline.streamEncoder.sessionCalls = service.calls
        await expectInputIsInjectedWhileTheEncoderStalls(during: "a quality change", service: service) {
            try await pipeline.apply(qualityScale: 0.5)
        }
        try? await pipeline.stop()
        print("PASS: a quality change stalled in the encoder leaves the main actor injecting input, and completes after")
    }

    do {
        let source = SilentFrameSource()
        guard let pipeline = await makeStallablePipeline(source: source) else {
            return
        }
        let service = StalledEncoderService()
        pipeline.streamEncoder.sessionCalls = service.calls
        await expectInputIsInjectedWhileTheEncoderStalls(during: "a key-frame interval change", service: service) {
            try await pipeline.apply(keyFrameIntervalSeconds: 10)
        }
        let bounds = pipeline.streamEncoder.sessionKeyFrameIntervalBounds()
        expect(
            bounds?.frames == 600 && bounds?.seconds == 10,
            "the stalled key-frame interval change reaches the session once the encoder answers, got \(String(describing: bounds))"
        )
        try? await pipeline.stop()
        print("PASS: a key-frame interval change stalled in the encoder leaves the main actor injecting input, and completes after")
    }

    do {
        let source = SilentFrameSource()
        let holder = PipelineHolder()
        holder.pipeline = await makeStallablePipeline(source: source)
        // Never bound to a local: the release below must drop the last
        // reference, or there is no teardown to stall.
        guard holder.pipeline != nil else {
            return
        }
        let service = StalledEncoderService()
        holder.pipeline?.streamEncoder.sessionCalls = service.calls
        await expectInputIsInjectedWhileTheEncoderStalls(during: "stopping and releasing a pipeline", service: service) {
            try await holder.pipeline?.stop()
            holder.pipeline = nil
        }
        print("PASS: an encoder flush stalled at teardown leaves the main actor injecting input")
    }
}

/// Starts `media` against a creation that stalls in the encoder service,
/// stops it while the creation is still waiting, then lets the creation
/// finish. The stop must win: the encoder that arrives late is shut down, its
/// pipeline is never installed, and no capture is started for it.
@available(macOS 13.0, *)
@MainActor
private func expectStopWinsOverAStalledCreation(
    of what: String,
    media: any CanvasMediaStreaming,
    source: SilentFrameSource,
    service: StalledEncoderService
) async {
    let starting = Task { @MainActor in
        try await media.start(canvasDisplayID: 42, onPacket: { _ in true })
    }
    let reached = await waitUntil(timeoutSeconds: 10) { service.hasEntered }
    expect(reached, "starting \(what) reaches the encoder service")
    await media.stop()
    let stalledWhenStopped = service.isStalledNow
    service.letGo()
    let outcome = await starting.result

    expect(
        stalledWhenStopped && !service.endedByTimeout,
        "\(what) is stopped while its encoder is still being created"
    )
    if case .failure(let error) = outcome {
        expect(false, "a start overtaken by a stop ends quietly, got \(error) (\(what))")
    }
    expect(
        service.completedFramesCount == 1,
        "the encoder that arrives after the stop is shut down, got \(service.completedFramesCount) flushes (\(what))"
    )
    expect(
        source.startCount == 0,
        "no capture is started for a pipeline the stop overtook, got \(source.startCount) starts (\(what))"
    )
    try? await media.apply(framesPerSecond: 15)
    let refreshed = try? await media.refreshStillPicture()
    expect(
        source.appliedFramesPerSecond.isEmpty && refreshed == nil,
        "the pipeline the stop overtook is never installed, got capture changes \(source.appliedFramesPerSecond) (\(what))"
    )
}

/// Creating a compression session is a round trip to the encoder service as
/// well, and on a locked machine it has waited minutes there. Every pipeline
/// is built from the main actor: a session's first capture, a rebuild at
/// another resolution, a display-mode change.
@available(macOS 13.0, *)
@MainActor
func runEncoderCreationStallTests() async {
    guard let probe = try? await VideoToolboxEncoder.make(frameOutcomeHandler: { _ in }) else {
        print("SKIP: this machine has no hardware H.264 encoder, so there is no encoder creation to stall")
        return
    }
    await probe.shutDown()

    do {
        let source = SilentFrameSource()
        let service = StalledEncoderService()
        let holder = PipelineHolder()
        await expectInputIsInjectedWhileTheEncoderStalls(during: "building a pipeline", service: service) {
            holder.pipeline = try await makePipeline(source: source, sessionCalls: service.calls)
        }
        expect(holder.pipeline != nil, "the pipeline whose encoder creation stalled is built once the encoder answers")
        try? await holder.pipeline?.stop()
        print("PASS: an encoder creation stalled in the encoder service leaves the main actor injecting input")
    }

    do {
        let source = SilentFrameSource()
        let service = StalledEncoderService()
        let media = HostScreenCaptureMedia(
            configuration: .remoteDefault,
            admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
                capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
            ),
            contentFilterProvider: { _ in SCContentFilter() },
            pipelineFactory: { _, _, _, _, gate, _, _, _, _, _, _ in
                try await makePipeline(source: source, sessionCalls: service.calls, sessionAdmissionGate: gate)
            }
        )
        await expectStopWinsOverAStalledCreation(of: "a host-screen capture", media: media, source: source, service: service)
        print("PASS: a host-screen capture stopped while its encoder is created discards the late encoder and starts no capture")
    }

    do {
        let source = SilentFrameSource()
        let service = StalledEncoderService()
        let media = ScreenCaptureCanvasMedia(
            surface: CanvasSurfaceID.allCases[0],
            admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
                capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
            ),
            pipelineFactory: { _, _, _, _, gate, _, _, _, _, _, _ in
                try await makePipeline(source: source, sessionCalls: service.calls, sessionAdmissionGate: gate)
            },
            contentFilterProvider: { _ in SCContentFilter() }
        )
        await expectStopWinsOverAStalledCreation(of: "a canvas capture", media: media, source: source, service: service)
        print("PASS: a canvas capture stopped while its encoder is created discards the late encoder and starts no capture")
    }
}
