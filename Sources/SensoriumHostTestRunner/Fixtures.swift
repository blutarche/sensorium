import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Records exactly how macOS Accessibility was consulted, so a test can prove
/// the host never asked it to present its approval UI.
final class RecordingAccessibilityChecker: AccessibilityPermissionChecking {
    private(set) var promptArguments: [Bool] = []
    private let isTrusted: Bool

    init(isTrusted: Bool) {
        self.isTrusted = isTrusted
    }

    func check(prompt: Bool) -> Bool {
        promptArguments.append(prompt)
        return isTrusted
    }
}

@MainActor
final class FakeVirtualDisplayAdapter: VirtualDisplayAdapter {
    private(set) var acquiredConfigurations: [VirtualCanvasConfiguration] = []
    private(set) var releasedHandles: [VirtualDisplayHandle] = []
    /// Called synchronously from inside `acquire`, before it returns --
    /// mirrors the real run-loop pump inside `NativeCanvasWorkspace.start`'s
    /// readiness wait, which can dispatch a same-thread, reentrant release
    /// for a different connection's canvas while a creation sharing the same
    /// `CanvasCreationGate` is still in flight.
    var onAcquire: (() -> Void)?
    /// Called synchronously from inside `release`, so a test can record when
    /// the canvas display was actually released relative to other teardown
    /// steps (e.g. the workspace window disappearing).
    var onRelease: ((VirtualDisplayHandle) -> Void)?
    /// Display IDs handed to successive `acquire` calls; the last one repeats
    /// once the list is exhausted. A real allocator never returns the same ID
    /// for two live displays, so a test serving two canvases needs two.
    var handleValuesToVend: [UInt32] = [7]
    private var acquireCount = 0
    /// Set to make the next `acquire` fail the way the real bridge does on
    /// hardware it does not support -- a thrown error, never a crash.
    var acquireError: Error?

    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        if let acquireError {
            throw acquireError
        }
        acquiredConfigurations.append(configuration)
        let rawValue = handleValuesToVend[min(acquireCount, handleValuesToVend.count - 1)]
        acquireCount += 1
        onAcquire?()
        return VirtualDisplayHandle(rawValue: rawValue)
    }

    func release(_ handle: VirtualDisplayHandle) {
        releasedHandles.append(handle)
        onRelease?(handle)
    }
}

/// Stands in for the Objective-C bridge, so the identity fallback above it can
/// be exercised without creating a real display.
///
/// It refuses an identity for either reason macOS does: because a test named
/// it as taken, the way a canvas an earlier host left behind holds one, or
/// because a display this creator itself made is still presenting it. The
/// second is what keeps a test honest about order -- a sequence that creates
/// one identity twice over is not one this host could ever meet.
@MainActor
final class FakeVirtualDisplayCreator: VirtualDisplayCreating {
    var refusedSerials: Set<UInt32> = []
    /// How a refused identity fails. `creationFailed` is the leftover-canvas
    /// case; `runtimeUnavailable` is a machine with no virtual-display
    /// runtime at all, which no other identity can get past.
    var refusal: CoreGraphicsVirtualDisplayError = .creationFailed
    private(set) var attemptedIdentities: [CanvasDisplayIdentity] = []
    private(set) var destroyedHandles: [VirtualDisplayHandle] = []
    private var nextDisplayID: UInt32 = 91
    /// The serial each display this creator made is presenting, until it is
    /// destroyed.
    private var liveSerials: [UInt32: UInt32] = [:]

    func create(
        configuration: VirtualCanvasConfiguration,
        identity: CanvasDisplayIdentity
    ) throws -> VirtualDisplayHandle {
        attemptedIdentities.append(identity)
        if refusedSerials.contains(identity.serialNumber) {
            throw refusal
        }
        guard !liveSerials.values.contains(identity.serialNumber) else {
            throw CoreGraphicsVirtualDisplayError.creationFailed
        }
        defer { nextDisplayID += 1 }
        liveSerials[nextDisplayID] = identity.serialNumber
        return VirtualDisplayHandle(rawValue: nextDisplayID)
    }

    func destroy(_ handle: VirtualDisplayHandle) {
        destroyedHandles.append(handle)
        liveSerials.removeValue(forKey: handle.rawValue)
    }

    func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics {
        throw CoreGraphicsVirtualDisplayError.metricsUnavailable
    }
}

@MainActor
final class FakeInputInjector: InputInjecting {
    struct InjectionFailure: Error, Equatable {}

    private(set) var events: [SensoriumInputEvent] = []
    /// Events that should throw instead of being recorded, so a test can
    /// prove a genuinely failed injection is handled differently from a
    /// successful one rather than being indistinguishable bookkeeping.
    var failingEvents: [SensoriumInputEvent] = []
    /// Called for each event actually posted, so a test can order injection
    /// against something else that happened -- a workspace window being
    /// fronted, say -- rather than only observe that both occurred.
    var onInject: ((SensoriumInputEvent) -> Void)?

    func inject(_ event: SensoriumInputEvent) throws {
        if failingEvents.contains(event) {
            throw InjectionFailure()
        }
        events.append(event)
        onInject?(event)
    }
}

@MainActor
final class FakeInputInjectorFactory: InputInjectingFactory {
    struct MakeFailure: Error, Equatable {}

    private(set) var requestedDisplayIDs: [UInt32] = []
    private(set) var requestedSessionKinds: [InputSessionKind] = []
    let injector = FakeInputInjector()
    /// When true, `make` throws instead of handing back an injector, so a
    /// test can prove what a host-screen request's own bring-up failing --
    /// after admission, before a session ever starts -- does elsewhere.
    var shouldFailToMake = false

    func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        requestedDisplayIDs.append(canvasDisplayID)
        requestedSessionKinds.append(sessionKind)
        if shouldFailToMake {
            throw MakeFailure()
        }
        return injector
    }
}

final class FakeAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    private(set) var promptRequests: [Bool] = []
    var isTrusted = false

    func check(prompt: Bool) -> Bool {
        promptRequests.append(prompt)
        return isTrusted
    }
}

final class FakeScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    private(set) var promptRequests: [Bool] = []
    var isAuthorized = false

    func check(prompt: Bool) -> Bool {
        promptRequests.append(prompt)
        return isAuthorized
    }
}


/// Records reconfiguration requests so a test can prove a burst of viewer
/// sizes collapses to one encoder rebuild.
@MainActor
final class FakeScalableCanvasMedia: CanvasMediaStreaming {
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var stopCount = 0
    private(set) var reconfiguredScales: [Double] = []
    var currentStreamScale: Double = StreamScalePolicy.defaultScale
    /// `nil` reconfigures successfully; otherwise the error thrown instead.
    var reconfigurationFailure: (any Error)?
    /// `nil` starts successfully; otherwise the error thrown instead, which
    /// is what ScreenCaptureKit refusing to build capture against a display
    /// that is not actually there to draw -- still asleep, briefly off the
    /// bus -- looks like to a caller.
    var startFailure: (any Error)?
    /// Every frame rate and quality this media was asked to apply, in order,
    /// so a test can prove both which fidelity step was taken and that it was
    /// taken exactly once.
    private(set) var appliedFramesPerSecond: [Int] = []
    private(set) var appliedQualityScales: [Double] = []
    private(set) var keyFrameRequestCount = 0
    /// How many times this surface was asked to send its last captured frame
    /// again, and what to answer with.
    private(set) var stillRefreshCount = 0
    var stillRefreshOutcome: Result<Int?, any Error> = .success(1_900_000)
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    /// What a test wants a caller's pressure check to read as this surface's
    /// ground truth. Settable rather than counted, so a scenario states the
    /// capture and drop counts it is about instead of having to produce them.
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
    /// `nil` applies successfully; otherwise the error thrown instead, which
    /// is what a live encoder or capture stream refusing the change looks
    /// like to a caller.
    var fidelityFailure: (any Error)?

    /// Held so a test can put a frame through the caller's own packet path,
    /// which is where the periodic video line is written.
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?
    /// What `setCaptureStoppedHandler` was last given, so a test can fire it
    /// directly to simulate `SCStreamDelegate`'s own stream-stopped signal.
    private var captureStoppedHandler: (@Sendable () -> Void)?
    /// 1-based call number `start` should block on, until a test calls
    /// `releaseHeldStart()` -- `nil` never holds. Lets a test park a rebuild
    /// mid-flight at a chosen point in a longer sequence of starts, the way
    /// a real capture's own bring-up would still be suspended inside
    /// `SCStream.startCapture()` while another request arrives.
    var holdStartOnCall: Int?
    private(set) var isHoldingStart = false
    private var startCallCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    /// Run synchronously from inside `stop()`, before it returns -- lets a
    /// test fire `simulateCaptureStoppedOnItsOwn()` on this same instance
    /// while a deliberate stop is still underway, standing in for
    /// `SCStreamDelegate` reporting a stop of its own at the same moment.
    var stopSideEffect: (() -> Void)?

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        startCallCount += 1
        if let startFailure {
            throw startFailure
        }
        startedDisplayIDs.append(canvasDisplayID)
        packetHandler = onPacket
        if startCallCount == holdStartOnCall {
            isHoldingStart = true
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                startContinuation = k
            }
            isHoldingStart = false
        }
    }

    /// Lets a `start()` call parked by `holdStartOnCall` return.
    func releaseHeldStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func emit(_ packet: EncodedVideoFramePacket) {
        packetHandler?(packet)
    }

    func stop() async {
        stopCount += 1
        packetHandler = nil
        if let stopSideEffect {
            stopSideEffect()
            // `stopSideEffect` fires a `@Sendable () -> Void` handler that,
            // in production, is wired to spawn a new `Task { @MainActor in
            // ... }` -- not run synchronously. Yielding here, still inside
            // `stop()`, gives that spawned task a real chance to run before
            // this returns to its caller, the same way a genuinely
            // concurrent signal would reach the coordinator while this
            // capture's own deliberate stop is still in flight.
            for _ in 0..<10 {
                await Task.yield()
            }
        }
    }

    func reconfigure(streamScale: Double) async throws {
        reconfiguredScales.append(streamScale)
        if let reconfigurationFailure {
            throw reconfigurationFailure
        }
        currentStreamScale = streamScale
    }

    func apply(framesPerSecond: Int) async throws {
        appliedFramesPerSecond.append(framesPerSecond)
        if let fidelityFailure {
            throw fidelityFailure
        }
        currentFramesPerSecond = framesPerSecond
    }

    func apply(qualityScale: Double) async throws {
        appliedQualityScales.append(qualityScale)
        if let fidelityFailure {
            throw fidelityFailure
        }
        currentQualityScale = qualityScale
    }

    func refreshStillPicture() async throws -> Int? {
        stillRefreshCount += 1
        return try stillRefreshOutcome.get()
    }

    func requestKeyFrame() async {
        keyFrameRequestCount += 1
    }

    func setCaptureStoppedHandler(_ handler: (@Sendable () -> Void)?) {
        captureStoppedHandler = handler
    }

    /// Stands in for `SCStreamDelegate.stream(_:didStopWithError:)` firing:
    /// a capture stopping on its own, not a stop the caller asked for.
    func simulateCaptureStoppedOnItsOwn() {
        captureStoppedHandler?()
    }
}

/// Equips only surface 0, for the single-canvas tests: surface 1 gets a
/// display session whose adapter is never asked for anything, so a stray
/// second canvas request would be visible rather than sharing surface 0's.
@MainActor
func surfaceZeroOnly(_ session: VirtualDisplaySession) -> CanvasSurfaceSlots<VirtualDisplaySession> {
    CanvasSurfaceSlots(
        surface0: session,
        surface1: VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())
    )
}

@MainActor
func onlyOnSurfaceZero(_ media: any CanvasMediaStreaming) -> CanvasSurfaceSlots<any CanvasMediaStreaming> {
    CanvasSurfaceSlots(surface0: media, surface1: FakeCanvasMedia())
}

@MainActor
func onlyOnSurfaceZero(
    _ workspace: any CanvasWorkspacePresenting
) -> CanvasSurfaceSlots<any CanvasWorkspacePresenting> {
    CanvasSurfaceSlots(surface0: workspace, surface1: NoCanvasWorkspace())
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

    /// Like `handleWritingResponse`, but hands back the *first* message written
    /// rather than the last. Host-screen bring-up writes the ready reply first
    /// and then follows it with the mode list and the lock-state notice, so a
    /// test that only cares that the request was admitted reads the ready reply
    /// here without depending on how many notices trail it.
    func handleFirstResponse(_ message: SensoriumMessage) async throws -> SensoriumMessage? {
        let first = FirstWrittenResponseBox()
        let returned = try await handle(message) { reply in
            first.recordIfFirst(reply)
        }
        return returned ?? first.message
    }
}

final class FirstWrittenResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var written: SensoriumMessage?

    func recordIfFirst(_ message: SensoriumMessage) {
        lock.lock()
        defer { lock.unlock() }
        if written == nil {
            written = message
        }
    }

    var message: SensoriumMessage? {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

/// Stands in for `VideoToolboxEncoder` at the one seam `EncodeAdmissionGate`
/// uses it through, so a runner that may never create a real
/// `VTCompressionSession` can still drive both submission outcomes: accepted,
/// and refused synchronously.
final class FakeFrameEncoder: VideoFrameEncoding, @unchecked Sendable {
    private(set) var submissionCount = 0
    /// Non-nil makes every submission fail the way VideoToolbox refuses a
    /// frame outright, before any callback exists for it.
    var submissionFailureStatus: OSStatus?

    func encode(_ sampleBuffer: CMSampleBuffer) throws {
        submissionCount += 1
        if let submissionFailureStatus {
            throw VideoEncoderError.frameSubmissionFailed(submissionFailureStatus)
        }
    }
}

/// A minimal real `CMSampleBuffer` carrying an image buffer, which is all
/// `EncodeAdmissionGate` requires of a captured frame. Plain Core Media and
/// Core Video allocations: no capture, no display, no encoder.
func makeCaptureSampleBuffer(presentationTimeNanoseconds: Int64 = 0) -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else {
        fatalError("failed to allocate a test pixel buffer")
    }
    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr, let formatDescription else {
        fatalError("failed to describe a test pixel buffer")
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 16_000_000, timescale: 1_000_000_000),
        presentationTimeStamp: CMTime(value: presentationTimeNanoseconds, timescale: 1_000_000_000),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else {
        fatalError("failed to build a test sample buffer")
    }
    return sampleBuffer
}

/// Records the structured launch outcomes a launcher hands to its UI, which is
/// a different channel from the host's log line and has to be proved separately.
final class LaunchOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [(application: String, outcome: CanvasApplicationLaunchOutcome)] = []

    func record(application: String, outcome: CanvasApplicationLaunchOutcome) {
        lock.lock()
        outcomes.append((application, outcome))
        lock.unlock()
    }

    var recorded: [(application: String, outcome: CanvasApplicationLaunchOutcome)] {
        lock.lock()
        defer { lock.unlock() }
        return outcomes
    }
}

/// A `pairRequest` carrying the proof of possession the protocol requires:
/// `identity`'s own signature over the transcript of every value the request
/// asks the host to write.
func signedPairRequest(deviceName: String, identity: DeviceIdentity, code: String) -> SensoriumMessage {
    .pairRequest(
        deviceName: deviceName,
        publicKey: identity.publicKey,
        code: code,
        signature: try! identity.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: deviceName,
            clientPublicKey: identity.publicKey,
            code: code
        ))
    )
}

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        HostRunnerCompletionGuard.shared.recordFailureReported()
        // Both this line and the completion guard's own report go to stderr,
        // with everything printed so far flushed first, so a combined log
        // keeps all three in the order they happened.
        fflush(stdout)
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        Foundation.exit(1)
    }
}

/// Polls `condition` on a short interval until it is true or `timeoutSeconds`
/// elapses, rather than sleeping a guessed duration and hoping it lands on
/// the right side of some other timer. Bounded and fails loudly on expiry --
/// the caller still asserts with `expect`, so a timeout reads as an ordinary
/// failed expectation, not a hang.
@MainActor
func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition() {
        if Date() >= deadline {
            return condition()
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

func expectThrows<T: Error & Equatable>(_ expected: T, _ operation: () throws -> Void, _ message: String) {
    do {
        try operation()
        expect(false, message)
    } catch let error as T {
        expect(error == expected, message)
    } catch {
        expect(false, message)
    }
}

/// Guards the one ordering constraint this runner genuinely cannot remove.
///
/// A nested `RunLoop.main.run(mode:before:)` dispatches queued `@MainActor`
/// work -- which is what production's canvas-readiness pump relies on, and
/// what the two tests that model it rely on -- only from a stack that is not
/// already inside the main run loop's own servicing of the main dispatch
/// queue. Swift's async `main` starts that run loop the first time this
/// runner's main task actually suspends: one `await Task.sleep` anywhere
/// above is enough, and the loop never stops again. From then on CoreFoundation
/// refuses to service the main queue reentrantly, so the nested run returns
/// having dispatched nothing at all and a pump loop waits out its whole budget
/// for work that can never run.
///
/// Nothing can reset that, which is why it is asserted here rather than left
/// to a comment about where to paste new tests: a run-loop-pumped test that
/// ends up below a suspending one now fails naming its own cause, instead of
/// silently reporting that the code under test misbehaved.
@MainActor
func expectRunLoopPumpCanDispatchQueuedWork(_ testName: String) {
    expect(
        CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) == nil,
        "\(testName) ran after this runner's main task had already suspended, so the main run loop is running and a nested pump dispatches no queued @MainActor work. Move it above every `await Task.sleep` in main(); the run-loop-pumped tests are kept first for exactly this reason."
    )
}

@MainActor
final class FakeCanvasMedia: CanvasMediaStreaming {
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var stopCount = 0
    private var packetHandler: (@Sendable (EncodedVideoFramePacket) -> Bool)?

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        startedDisplayIDs.append(canvasDisplayID)
        packetHandler = onPacket
    }

    func stop() async {
        stopCount += 1
        packetHandler = nil
    }

    var currentStreamScale: Double { StreamScalePolicy.defaultScale }

    func reconfigure(streamScale: Double) async throws {}

    private(set) var appliedFramesPerSecond: [Int] = []
    private(set) var appliedQualityScales: [Double] = []
    private(set) var keyFrameRequestCount = 0
    /// How many times this surface was asked to send its last captured frame
    /// again, and what to answer with.
    private(set) var stillRefreshCount = 0
    var stillRefreshOutcome: Result<Int?, any Error> = .success(1_900_000)
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)

    func apply(framesPerSecond: Int) async throws {
        appliedFramesPerSecond.append(framesPerSecond)
        currentFramesPerSecond = framesPerSecond
    }

    func apply(qualityScale: Double) async throws {
        appliedQualityScales.append(qualityScale)
        currentQualityScale = qualityScale
    }

    func refreshStillPicture() async throws -> Int? {
        stillRefreshCount += 1
        return try stillRefreshOutcome.get()
    }

    func requestKeyFrame() async {
        keyFrameRequestCount += 1
    }

    func emit(_ packet: EncodedVideoFramePacket) {
        packetHandler?(packet)
    }
}

enum FakeMediaFailure: Error {
    case captureUnavailable
}

@MainActor
final class FailingCanvasMedia: CanvasMediaStreaming {
    private(set) var stopCount = 0

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        throw FakeMediaFailure.captureUnavailable
    }

    func stop() async {
        stopCount += 1
    }

    var currentStreamScale: Double { StreamScalePolicy.defaultScale }
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)

    func reconfigure(streamScale: Double) async throws {}

    func apply(framesPerSecond: Int) async throws {}

    func apply(qualityScale: Double) async throws {}

    func requestKeyFrame() async {}

    func refreshStillPicture() async throws -> Int? { nil }
}

/// Records what the session had already written to the transport at the moment
/// capture was asked to start, so a test can assert the client is told a
/// surface exists before that surface's frames begin.
@MainActor
final class SendOrderRecordingCanvasMedia: CanvasMediaStreaming {
    private let channel: FakeHostByteChannel
    private(set) var startCount = 0
    private(set) var packetsSentBeforeStart: [SensoriumTransportPacket] = []

    init(channel: FakeHostByteChannel) {
        self.channel = channel
    }

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        startCount += 1
        packetsSentBeforeStart = channel.sentPackets
    }

    func stop() async {}

    var currentStreamScale: Double { StreamScalePolicy.defaultScale }
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)

    func reconfigure(streamScale: Double) async throws {}

    func apply(framesPerSecond: Int) async throws {}

    func apply(qualityScale: Double) async throws {}

    func requestKeyFrame() async {}

    func refreshStillPicture() async throws -> Int? { nil }
}

/// Records the moment capture started, so a test can order it against
/// whatever the coordinator did before reaching it.
@MainActor
final class StartTimelineCanvasMedia: CanvasMediaStreaming {
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        onStart()
    }

    func stop() async {}

    var currentStreamScale: Double { StreamScalePolicy.defaultScale }
    var currentFramesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
    var currentQualityScale = 1.0
    var frameCounts = HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)

    func reconfigure(streamScale: Double) async throws {}

    func apply(framesPerSecond: Int) async throws {}

    func apply(qualityScale: Double) async throws {}

    func requestKeyFrame() async {}

    func refreshStillPicture() async throws -> Int? { nil }
}

func isCanvasReadyPacket(_ packet: SensoriumTransportPacket) -> Bool {
    if case .control(.canvasReady) = packet {
        return true
    }
    return false
}

/// The Mini's one process-wide keyboard focus, shared by every window on the
/// machine. Fakes that model two windows racing for it -- two surfaces, or two
/// connections -- share one of these; a fake given its own stands alone, which
/// is what a single-workspace test means.
///
/// It holds an identity, not a `Bool`, because the case that matters is focus
/// belonging to something *else*: another surface's window, or something on a
/// physical display that is not a Sensorium window at all.
@MainActor
final class FakeKeyFocus {
    private var holder: ObjectIdentifier?

    /// Focus moved to something outside Sensorium entirely -- a person
    /// clicking a window on the built-in display, or an app self-activating.
    func takeElsewhere() {
        holder = nil
    }

    func take(_ window: AnyObject) {
        holder = ObjectIdentifier(window)
    }

    func release(_ window: AnyObject) {
        guard holder == ObjectIdentifier(window) else {
            return
        }
        holder = nil
    }

    func isHeld(by window: AnyObject) -> Bool {
        holder == ObjectIdentifier(window)
    }
}

@MainActor
final class FakeCanvasWorkspace: CanvasWorkspacePresenting {
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var stopCount = 0
    /// Set to make placement fail, standing in for a workspace that could not
    /// be placed on the canvas it was handed.
    var startFailure: Error?
    /// Called synchronously from inside `stop`, so a test can record when the
    /// workspace window actually disappeared relative to other teardown
    /// steps (e.g. the canvas display being released).
    var onStop: (() -> Void)?
    /// Mirrors the real workspaces' ownership: whichever connection last
    /// started this workspace owns the window until another takes it over.
    private var owner: CanvasOwnerToken?
    /// `stop(owner:)` calls from a connection that no longer owns this
    /// workspace, so a test can tell "declined" from "never asked".
    private(set) var declinedStopCount = 0
    /// Every `raise` call, refused ones included.
    private(set) var raiseCount = 0
    /// Every `installedWindow` call, so a test can tell a refusal this
    /// workspace answered from its own state apart from one never asked for.
    private(set) var installedWindowQueryCount = 0
    /// Makes an installed window refuse to come to the front.
    var raiseFailure = false
    /// Called with each raise's outcome, for ordering against injection.
    var onRaise: ((Bool) -> Void)?

    /// Identifies the window this `start` stood up, so a caller that fronted
    /// one can tell it from the window a later `start` installed instead --
    /// exactly as the real workspaces do.
    private var windowToken: CanvasWorkspaceWindowToken?
    /// The keyboard focus this window competes for. Its own by default, so a
    /// test about one workspace is not implicitly about two.
    let focus: FakeKeyFocus
    /// The canvas rectangle this workspace's window stands on, in the global
    /// space `CGDisplayBounds` and `CGWindowListCopyWindowInfo` share. What a
    /// launched application's window has to be inside before a key may be
    /// posted while that application, not this workspace, holds the keyboard.
    var canvasRectangle = CGRect(x: 0, y: 0, width: 1920, height: 1200)
    /// Whether fronting this window is granted focus by the time `raise`
    /// returns. AppKit does not promise that -- `makeKeyAndOrderFront` and
    /// `activate(ignoringOtherApps:)` are resolved by AppKit on its own
    /// schedule -- so a test sets this false to model a raise whose focus
    /// change has not landed yet.
    var raiseGrantsFocus = true

    init(focus: FakeKeyFocus = FakeKeyFocus()) {
        self.focus = focus
    }

    func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        if let startFailure {
            throw startFailure
        }
        startedDisplayIDs.append(canvasDisplayID)
        self.owner = owner
        windowToken = CanvasWorkspaceWindowToken()
        // `installWindow` activates the app, so a freshly installed window
        // takes the machine's keyboard focus from whatever held it.
        focus.take(self)
    }

    func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken? {
        installedWindowQueryCount += 1
        guard self.owner == owner else {
            return nil
        }
        return windowToken
    }

    func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            declinedStopCount += 1
            return
        }
        stop()
    }

    func stop() {
        owner = nil
        windowToken = nil
        focus.release(self)
        stopCount += 1
        onStop?()
    }

    /// Gated exactly as the real workspaces gate it: an installed window,
    /// belonging to the connection now asking, or no rectangle at all.
    func canvasBounds(owner: CanvasOwnerToken) -> CGRect? {
        guard windowToken != nil, self.owner == owner else {
            return nil
        }
        return canvasRectangle
    }

    /// Models what the real workspaces answer from AppKit's focus state: only
    /// an installed window, belonging to the connection now asking, that holds
    /// the machine's one keyboard focus.
    func hasKeyFocus(owner: CanvasOwnerToken) -> Bool {
        guard windowToken != nil, self.owner == owner else {
            return false
        }
        return focus.isHeld(by: self)
    }

    /// Models the real workspaces: only a window a `start` installed, for the
    /// connection now asking, can be fronted; `raiseFailure` stands in for an
    /// installed window AppKit refused to front.
    func raise(owner: CanvasOwnerToken) -> Bool {
        raiseCount += 1
        guard self.owner == owner, !raiseFailure else {
            onRaise?(false)
            return false
        }
        if raiseGrantsFocus {
            focus.take(self)
        }
        onRaise?(true)
        return true
    }
}

/// Scripts what one look at the machine's windows saw, so the geometric half
/// of key confinement can be driven without asking WindowServer anything.
@MainActor
final class FakeFrontmostWindowScan: FrontmostWindowScanning {
    var result = FrontmostWindowScan(frontmostProcessIdentifier: nil, onScreenWindows: [])
    /// Every scan, so a test can prove the answer is taken per key rather than
    /// cached -- a cache is the one thing this design has no room for.
    private(set) var scanCount = 0

    func scan() -> FrontmostWindowScan {
        scanCount += 1
        return result
    }
}

/// Mirrors `NativeCanvasWorkspace.start`'s real shape: placement runs inside
/// the single-flight `CanvasCreationGate` shared with `VirtualDisplaySession`,
/// and the readiness wait it wraps pumps the run loop. `pump` stands in for
/// that pumped turn, letting a test dispatch a second connection's own
/// `.canvasRequest` handling from exactly where production code would.
@MainActor
final class InterleavingCanvasWorkspace: CanvasWorkspacePresenting {
    private let gate: CanvasCreationGate
    private(set) var startedDisplayIDs: [UInt32] = []
    var pump: (() -> Void)?
    /// Called synchronously from inside `stop`, so a test can record when this
    /// surface's window disappeared relative to its display being released.
    var onStop: (() -> Void)?

    init(gate: CanvasCreationGate) {
        self.gate = gate
    }

    private var owner: CanvasOwnerToken?
    private var windowToken: CanvasWorkspaceWindowToken?

    func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        try gate.run {
            pump?()
            startedDisplayIDs.append(canvasDisplayID)
            self.owner = owner
            windowToken = CanvasWorkspaceWindowToken()
        }
    }

    func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken? {
        self.owner == owner ? windowToken : nil
    }

    func hasKeyFocus(owner: CanvasOwnerToken) -> Bool {
        self.owner == owner && windowToken != nil
    }

    /// This workspace exists to model the creation gate, and resolves no
    /// placement, so it has no canvas rectangle to confine a key to.
    func canvasBounds(owner: CanvasOwnerToken) -> CGRect? {
        nil
    }

    func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            return
        }
        stop()
    }

    func stop() {
        owner = nil
        windowToken = nil
        onStop?()
    }

    func raise(owner: CanvasOwnerToken) -> Bool {
        self.owner == owner
    }
}

final class DiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(message)
    }
}

/// Scripts what the Accessibility API reports for a launched application, one
/// entry per poll, so the bounded wait can be driven without a real process.
/// The last entry repeats, which is how "never opens a window" is expressed.
final class FakeLaunchedWindowPlacer: LaunchedWindowPlacing, @unchecked Sendable {
    struct Recorded: Equatable {
        let processIdentifier: pid_t
        let windowIndex: Int
        let placement: CanvasWindowPlacement
    }

    private let framesByAttempt: [[CGRect]]
    private let accepts: Bool
    private let lock = NSLock()
    private var attempt = 0
    private var queries: [pid_t] = []
    private var recorded: [Recorded] = []

    init(framesByAttempt: [[CGRect]], accepts: Bool = true) {
        self.framesByAttempt = framesByAttempt
        self.accepts = accepts
    }

    var frameQueries: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    var placements: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func windowFrames(processIdentifier: pid_t) -> [CGRect] {
        lock.lock()
        defer { lock.unlock() }
        queries.append(processIdentifier)
        let frames = attempt < framesByAttempt.count ? framesByAttempt[attempt] : (framesByAttempt.last ?? [])
        attempt += 1
        return frames
    }

    func place(processIdentifier: pid_t, windowIndex: Int, placement: CanvasWindowPlacement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Recorded(processIdentifier: processIdentifier, windowIndex: windowIndex, placement: placement))
        return accepts
    }
}

/// Records how long the adoption poll asked to wait, so a test can prove the
/// wait is bounded without spending the real interval.
final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(interval)
    }
}

final class FakeCanvasApplicationOpener: CanvasApplicationOpening, @unchecked Sendable {
    private let result: Result<pid_t, CanvasApplicationOpenError>
    private let onOpen: @Sendable (LaunchableApplication) -> Void

    init(
        result: Result<pid_t, CanvasApplicationOpenError>,
        onOpen: @escaping @Sendable (LaunchableApplication) -> Void
    ) {
        self.result = result
        self.onOpen = onOpen
    }

    func open(
        _ application: LaunchableApplication,
        completion: @escaping @Sendable (Result<pid_t, CanvasApplicationOpenError>) -> Void
    ) {
        onOpen(application)
        completion(result)
    }
}

final class FakeVideoSink: CanvasVideoSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(surface: CanvasSurfaceID, packet: EncodedVideoFramePacket, priority: VideoSendPriority)] = []
    private var dropped = 0
    private var refuses = false

    /// The transport's running drop count, as a test wants it read: settable,
    /// cumulative, and never reset, exactly like the real one.
    var droppedVideoFrameCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return dropped
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            dropped = newValue
        }
    }

    func droppedVideoFrameCount(for surface: CanvasSurfaceID) -> Int {
        droppedVideoFrameCount
    }

    var packets: [EncodedVideoFramePacket] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.packet)
    }

    /// Which surface each frame was sent for, so a test can prove the sink is
    /// told the surface rather than inferring it.
    var sentSurfaces: [CanvasSurfaceID] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.surface)
    }

    /// The scheduling weight each frame was sent with, so a test can prove the
    /// focus signal reaches the send path rather than stopping at the session.
    var sentPriorities: [VideoSendPriority] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.priority)
    }

    /// Set to make every send answer `false`, standing in for a transport
    /// whose queue discarded the frame. A still-screen refresh is the one
    /// caller that must notice.
    var refusesEveryFrame: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return refuses
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            refuses = newValue
        }
    }

    func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sent.append((surface, packet, priority))
        return !refuses
    }
}

/// The host runner's own fake pasteboard: `ClipboardSyncSession` is driven
/// here through the real host gate, so it needs a pasteboard whose change
/// count moves exactly like `NSPasteboard`'s — only a write advances it.
final class FakeClipboardPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var writtenContents: [ClipboardContent] = []
    private var readout = ClipboardReadout(content: nil, isExcludedByType: false)

    func stageLocalCopy(_ readout: ClipboardReadout) {
        self.readout = readout
        changeCount += 1
    }

    func read() -> ClipboardReadout {
        readout
    }

    @discardableResult
    func write(_ content: ClipboardContent) -> Int {
        writtenContents.append(content)
        readout = ClipboardReadout(content: content, isExcludedByType: false)
        changeCount += 1
        return changeCount
    }
}

/// A clipboard admissibility gate a test can open at an exact moment,
/// standing in for the host's authenticated-and-active check.
@MainActor
final class ClipboardGateSwitch {
    var isOpen = false
}

/// A `HostByteChannel` fed by a fixed script of outgoing control messages,
/// so `HostNetworkSession.run()`'s own framing and dispatch run against real
/// wire bytes rather than being bypassed by calling the coordinator directly.
final class FakeHostByteChannel: HostByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: Data
    private var sent: [SensoriumTransportPacket] = []
    /// The exact bytes written, so a test can assert on the wire tag itself
    /// rather than on what the decoder made of it.
    private var sentFrameBytes: [Data] = []
    private var concurrentSends = 0
    private var peakSends = 0
    /// Simulates a link slower than the encoders, so a test can observe how
    /// many sends the session has in flight on the shared channel at once.
    var sendDelay: Duration?
    /// Simulates a write that never reached the wire -- a dropped connection,
    /// say. Thrown instead of accepting the bytes; `sent` and `sentFrameBytes`
    /// are left exactly as a real failed write would leave them.
    var sendBytesError: Error?
    private var cancels = 0
    /// What had already been written when `cancel()` first ran, so a test can
    /// assert a message reached the peer while the socket was still open
    /// rather than after it closed, where a real peer would never see it.
    private var sentWhenCancelled: [SensoriumTransportPacket] = []
    /// Set by `cancel()`, checked by `receiveBytes(count:)`'s own poll loop
    /// so a cancelled channel's loop actually stops instead of running for
    /// the rest of the process -- `HostNetworkSession.start()` launches
    /// `run()` in an untracked `Task`, so nothing else ever cancels it.
    private var cancelled = false
    /// How long `receiveBytes` waits before reporting closed once the script
    /// is exhausted. `nil` keeps the default "idle, not closed" hang used by
    /// most tests; a short delay lets a test put `HostNetworkSession.run()`'s
    /// own error-path teardown genuinely in flight at the same time as
    /// something else that also tears the session down.
    private let closeAfterScriptDelay: Duration?

    init(scriptedMessages: [SensoriumMessage], closeAfterScriptDelay: Duration? = nil) {
        var buffer = Data()
        for message in scriptedMessages {
            buffer.append(try! SensoriumTransportPacketCodec.encode(.control(message)))
        }
        incoming = buffer
        self.closeAfterScriptDelay = closeAfterScriptDelay
    }

    /// The same script at the transport-packet level, so a test can feed the
    /// session a tag other than control.
    init(scriptedPackets: [SensoriumTransportPacket], closeAfterScriptDelay: Duration? = nil) {
        var buffer = Data()
        for packet in scriptedPackets {
            buffer.append(try! SensoriumTransportPacketCodec.encode(packet))
        }
        incoming = buffer
        self.closeAfterScriptDelay = closeAfterScriptDelay
    }

    /// Appends more incoming bytes after construction, so a test can drive a
    /// session through a real gap in time -- staging a local pasteboard
    /// change and letting a poll interval or two pass, say -- before the
    /// next scripted message arrives, rather than pre-loading everything at
    /// once and losing the ability to observe what happens strictly between
    /// two messages.
    func feed(_ messages: [SensoriumMessage]) {
        withLock {
            for message in messages {
                incoming.append(try! SensoriumTransportPacketCodec.encode(.control(message)))
            }
        }
    }

    /// The same, at the transport-packet level -- see `feed(_:
    /// [SensoriumMessage])`.
    func feed(_ packets: [SensoriumTransportPacket]) {
        withLock {
            for packet in packets {
                incoming.append(try! SensoriumTransportPacketCodec.encode(packet))
            }
        }
    }

    /// `NSLock.lock`/`unlock` are unavailable from `async` function bodies, so
    /// every critical section runs inside this synchronous helper instead.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var sentPackets: [SensoriumTransportPacket] {
        withLock { sent }
    }

    var sentFrames: [Data] {
        withLock { sentFrameBytes }
    }

    var peakConcurrentSends: Int {
        withLock { peakSends }
    }

    var cancelCount: Int {
        withLock { cancels }
    }

    var packetsSentBeforeCancel: [SensoriumTransportPacket] {
        withLock { sentWhenCancelled }
    }

    func start() {}

    func cancel() {
        withLock {
            if cancels == 0 {
                sentWhenCancelled = sent
            }
            cancels += 1
            cancelled = true
        }
    }

    func sendBytes(_ data: Data) async throws {
        let (delay, failure): (Duration?, Error?) = withLock {
            concurrentSends += 1
            peakSends = max(peakSends, concurrentSends)
            return (sendDelay, sendBytesError)
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let failure {
            withLock { concurrentSends -= 1 }
            throw failure
        }
        let packet = try SensoriumTransportPacketCodec.decode(data)
        withLock {
            concurrentSends -= 1
            sent.append(packet)
            sentFrameBytes.append(data)
        }
    }

    /// Once the script is exhausted, waits rather than reporting end-of-stream:
    /// a real connection with nothing left to send is idle, not closed, and a
    /// premature EOF here would cancel the connection for a reason that has
    /// nothing to do with what a test is checking. Polls rather than
    /// committing to one long sleep, so bytes `feed(_:)` appends after this
    /// call is already waiting are still picked up -- `closeAfterScriptDelay`
    /// keeps its own meaning, the cumulative idle time before giving up, not
    /// how often this checks. Checked every iteration, not just at
    /// `closeAfterScriptDelay`'s own deadline: `Task.isCancelled` in case
    /// something ever does track and cancel `run()`'s own `Task`, and this
    /// channel's own `cancelled` flag for the actual, current case --
    /// `HostNetworkSession.stop()` only ever calls `cancel()`, and without
    /// this check the loop below would keep polling every 5ms for the rest
    /// of the process, for every session a test ever starts and stops.
    func receiveBytes(count: Int) async throws -> Data {
        var waited: Duration = .zero
        let pollInterval: Duration = .milliseconds(5)
        while true {
            if Task.isCancelled || withLock({ cancelled }) {
                throw HostNetworkSessionError.closed
            }
            let chunk: Data? = withLock {
                guard incoming.count >= count else {
                    return nil
                }
                let chunk = Data(incoming.prefix(count))
                incoming.removeFirst(count)
                return chunk
            }
            if let chunk {
                return chunk
            }
            if let closeAfterScriptDelay, waited >= closeAfterScriptDelay {
                throw HostNetworkSessionError.closed
            }
            try await Task.sleep(for: pollInterval)
            waited += pollInterval
        }
    }
}

/// `runCoreSessionTests` was one function too large for any one file's
/// type-checking cost to stay bounded (see docs/testing.md) and had to be
/// split across several files. Its assertions share a run of naked local
/// fixtures declared once and reused throughout -- exactly the kind of
/// top-level state a single function can hold implicitly and several
/// functions cannot -- so this box carries them explicitly between the
/// split parts instead. Every property is written exactly once, by the part
/// that already declared the fixture, and read back into a local of the
/// same name at the top of every part that still needs it; the assertions
/// themselves are unchanged.
@MainActor
final class CoreSessionSharedFixtures {
    var surfaceZero: CanvasSurfaceID!
    var surfaceOne: CanvasSurfaceID!
    var tlsIdentity: HostTLSIdentity!
}

/// Stands in for `CoreGraphicsHostScreenModeController`, which no test may
/// ever run: changing a real display's mode is exactly what verification
/// must not do. Behaves the way the real one is written to -- it remembers
/// what a display was on before the first successful `apply`, puts that back
/// on `restore`, and keeps remembering it until a restore actually takes --
/// and records every call, so a test can prove which display was touched and
/// that nothing was touched at all on a refusal.
@MainActor
final class FakeHostScreenModeController: HostScreenModeControlling {
    var modesByDisplay: [UInt32: [HostScreenModeEntry]] = [:]
    var currentModeIDByDisplay: [UInt32: String] = [:]
    /// Set false to make the display refuse the next mode it is handed.
    var applyResult = true
    var restoreResult = true
    /// How many of the next restores refuse before one takes -- what a
    /// display still reconfiguring from the change a moment earlier does.
    var restoreFailuresRemaining = 0
    private(set) var listedDisplayIDs: [UInt32] = []
    private(set) var applied: [(modeID: String, displayID: UInt32)] = []
    private(set) var restoredDisplayIDs: [UInt32] = []
    private var originalModeIDs: [UInt32: String] = [:]

    func modes(for displayID: UInt32) -> [HostScreenModeEntry] {
        listedDisplayIDs.append(displayID)
        return modesByDisplay[displayID] ?? []
    }

    func currentModeID(for displayID: UInt32) -> String? {
        currentModeIDByDisplay[displayID]
    }

    func apply(modeID: String, to displayID: UInt32) -> Bool {
        applied.append((modeID, displayID))
        guard applyResult else {
            return false
        }
        if originalModeIDs[displayID] == nil {
            originalModeIDs[displayID] = currentModeIDByDisplay[displayID]
        }
        currentModeIDByDisplay[displayID] = modeID
        return true
    }

    @discardableResult
    func restore(displayID: UInt32) -> Bool {
        restoredDisplayIDs.append(displayID)
        guard let original = originalModeIDs[displayID], restoreResult else {
            return false
        }
        if restoreFailuresRemaining > 0 {
            restoreFailuresRemaining -= 1
            return false
        }
        originalModeIDs[displayID] = nil
        currentModeIDByDisplay[displayID] = original
        return true
    }

    func restoreEverything() {
        for displayID in displaysAwaitingRestore {
            restore(displayID: displayID)
        }
    }

    var displaysAwaitingRestore: [UInt32] { originalModeIDs.keys.sorted() }
}
