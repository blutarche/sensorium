import Foundation
import SensoriumClient
import SensoriumCore
#if canImport(CoreVideo)
import CoreVideo
#else
/// Stands in for a decoded frame's platform image where none exists to
/// decode: pacing and coalescing tests only need identity and timing.
private final class TestFramePayload {}
#endif

/// Builds a `DecodedFrame` cheap enough for tests that only care about a
/// frame's timing and identity, not its real pixel data.
func makeTestDecodedFrame(width: Int = 64, height: Int = 64, timing: FrameTiming? = nil) -> DecodedFrame {
    #if canImport(CoreVideo)
    DecodedFrame(pixelBuffer: makeTestPixelBuffer(), timing: timing)
    #else
    DecodedFrame(payload: TestFramePayload(), width: width, height: height, timing: timing)
    #endif
}

actor FakeClientTransport: SensoriumControlTransport {
    private(set) var sent: [SensoriumMessage] = []
    let deferredPackets = DeferredPacketQueue()

    func send(_ message: SensoriumMessage) async throws {
        sent.append(message)
    }

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        .control(.canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil))
    }

    func close() async {}
}


/// An error that reads like one Network.framework hands back, so the copy
/// under test is measured against text somebody might be tempted to rewrite.
struct SystemStyleError: Error, CustomStringConvertible {
    var description: String { "POSIXErrorCode(rawValue: 61): Connection refused" }
}

/// Collects what the redial driver reports, from whatever context it reports
/// on.
final class RecordedReconnectEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClientReconnectEvent] = []

    func append(_ event: ClientReconnectEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [ClientReconnectEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Stands in for `NSPasteboard`: only a write advances the change count, just
/// like the real one.
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

final class ClientDiagnosticsRecorder {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

/// Records what the reconnect driver would have waited for, without waiting.
actor RecordedSleeps {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

actor SessionAttempts {
    private(set) var count = 0
    private let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    enum AttemptFailure: Error { case refused }

    func attempt() throws {
        count += 1
        if count <= failuresBeforeSuccess {
            throw AttemptFailure.refused
        }
    }
}

actor RecordingInputSink: CanvasInputSending {
    private(set) var events: [SensoriumInputEvent] = []
    private(set) var drawableSizes: [SensoriumMessage] = []
    private(set) var streamScalePreferences: [StreamScalePreference] = []
    private var failure: ClientSessionError?

    init(failure: ClientSessionError? = nil) {
        self.failure = failure
    }

    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws {
        if let failure {
            throw failure
        }
        drawableSizes.append(.viewerDrawableSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, surfaceID: nil, maximumScale: maximumScale))
    }

    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {
        if let failure {
            throw failure
        }
        streamScalePreferences.append(preference)
    }

    /// Every key event that reached the wire, in order.
    var keys: [SensoriumInputEvent] {
        events.filter { if case .key = $0 { return true } else { return false } }
    }

    var points: [CanvasInputPoint] {
        events.compactMap { event in
            guard case let .pointerMoved(x, y) = event else { return nil }
            return CanvasInputPoint(x: x, y: y)
        }
    }

    func sendInput(_ event: SensoriumInputEvent) async throws {
        if let failure {
            throw failure
        }
        events.append(event)
    }
}

actor RecordingFramePresenter: CanvasFramePresenting {
    private(set) var presentedCount = 0

    func present(_ frame: DecodedFrame) async {
        presentedCount += 1
    }
}

/// A `SessionCanvasWindow` that records what it was handed instead of
/// decoding it — `ClientCanvasWindowController` is the only production
/// conformer, and it cannot be built here (no window server connection), so
/// `SurfaceFrameRouter`'s dispatch and `ClientSessionRunner`'s own portable
/// routing are both proven against this instead.
final class RecordingSurfaceWindow: SessionCanvasWindow, @unchecked Sendable {
    let surfaceID: UInt32
    let videoSink = SurfaceVideoSink()
    private let lock = NSLock()
    private var receivedPayloads: [Data] = []
    private var stopDecodingCount = 0
    private var telemetryUpdates: [SessionHUDSnapshot] = []
    private var startDecodingCallCount = 0
    private let viewport: ClientViewportController
    var onDidBecomeKey: (() -> Void)?

    init(surfaceID: UInt32) {
        self.surfaceID = surfaceID
        viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: RecordingInputSink()
        )
    }

    func startDecoding(
        latency: SessionLatencyMonitor? = nil,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? = nil
    ) throws {
        lock.lock()
        startDecodingCallCount += 1
        lock.unlock()
    }

    func canvasObserver() -> ClientViewportController {
        viewport
    }

    var startDecodingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startDecodingCallCount
    }

    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        lock.lock()
        receivedPayloads.append(packet.payload)
        lock.unlock()
    }

    func stopDecoding() {
        lock.lock()
        stopDecodingCount += 1
        lock.unlock()
    }

    func updateSessionHUD(_ snapshot: SessionHUDSnapshot) {
        lock.lock()
        telemetryUpdates.append(snapshot)
        lock.unlock()
    }

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return receivedPayloads
    }

    var stopDecodingCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopDecodingCount
    }

    var lastTelemetryUpdate: SessionHUDSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return telemetryUpdates.last
    }

    var telemetryUpdateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return telemetryUpdates.count
    }
}

actor GatedPointerSink: CanvasInputSending {
    private(set) var events: [SensoriumInputEvent] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var isGateOpen = false
    private var hasEnteredFirstSend = false

    var points: [CanvasInputPoint] {
        events.compactMap { event in
            guard case let .pointerMoved(x, y) = event else { return nil }
            return CanvasInputPoint(x: x, y: y)
        }
    }

    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws {}

    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {}

    func sendInput(_ event: SensoriumInputEvent) async {
        events.append(event)
        guard events.count == 1 else { return }
        hasEnteredFirstSend = true
        for waiter in entryWaiters {
            waiter.resume()
        }
        entryWaiters = []
        guard !isGateOpen else { return }
        await withCheckedContinuation { gate = $0 }
    }

    func waitUntilFirstSendEntered() async {
        guard !hasEnteredFirstSend else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func openGate() {
        isGateOpen = true
        gate?.resume()
        gate = nil
    }
}

/// Suspends `sendViewerDrawableSize` until `openGate()` releases it -- the
/// real network round trip `canvasDidBecomeReady()` suspends inside, held
/// open so a test can prove what a concurrent call sees while that
/// suspension is still live.
actor GatedDrawableSizeSink: CanvasInputSending {
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var isGateOpen = false
    private var hasEntered = false

    func sendViewerDrawableSize(pixelWidth: Double, pixelHeight: Double, maximumScale: Double?) async throws {
        hasEntered = true
        for waiter in entryWaiters {
            waiter.resume()
        }
        entryWaiters = []
        guard !isGateOpen else { return }
        await withCheckedContinuation { gate = $0 }
    }

    func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {}

    func sendInput(_ event: SensoriumInputEvent) async throws {}

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func openGate() {
        isGateOpen = true
        gate?.resume()
        gate = nil
    }
}

/// Accepts sends and never answers, like a host that wedged mid-creation.
actor SilentClientTransport: SensoriumControlTransport {
    private(set) var closeCount = 0
    let deferredPackets = DeferredPacketQueue()

    func send(_ message: SensoriumMessage) async throws {}

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        try await Task.sleep(for: .seconds(60))
        throw ControlChannelError.closed
    }

    func close() async {
        closeCount += 1
    }
}

/// Scripts the wire, not just the control channel: a host puts video on the
/// same socket as its control replies, so a transport that could only script
/// `SensoriumMessage` made an interleaved video packet unrepresentable — which
/// is precisely why a handshake that failed on one went unnoticed.
actor ScriptedClientTransport: SensoriumControlTransport {
    private(set) var sent: [SensoriumMessage] = []
    private(set) var closeCount = 0
    private var responses: [SensoriumTransportPacket]
    let deferredPackets = DeferredPacketQueue()
    /// What a real dial would have pinned for this link, so a test can see
    /// what the hello binds itself to. `nil` is the unpinned pairing dial.
    nonisolated let pinnedHostCertificateHash: Data?

    init(responses: [SensoriumMessage], pinnedHostCertificateHash: Data? = nil) {
        self.responses = responses.map { .control($0) }
        self.pinnedHostCertificateHash = pinnedHostCertificateHash
    }

    init(packets: [SensoriumTransportPacket]) {
        responses = packets
        pinnedHostCertificateHash = nil
    }

    func send(_ message: SensoriumMessage) async throws {
        sent.append(message)
    }

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        guard !responses.isEmpty else {
            throw ControlChannelError.closed
        }
        return responses.removeFirst()
    }

    func close() async {
        closeCount += 1
    }
}

/// Scripts the wire like `ScriptedClientTransport`, but makes every reply
/// wait `delay` first -- a host slow to answer because it is waiting on a
/// person, not a host that never answers at all.
actor DelayedClientTransport: SensoriumControlTransport {
    private(set) var sent: [SensoriumMessage] = []
    private(set) var closeCount = 0
    private var responses: [SensoriumTransportPacket]
    private let delay: Duration
    let deferredPackets = DeferredPacketQueue()

    init(responses: [SensoriumMessage], delay: Duration) {
        self.responses = responses.map { .control($0) }
        self.delay = delay
    }

    func send(_ message: SensoriumMessage) async throws {
        sent.append(message)
    }

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        guard !responses.isEmpty else {
            throw ControlChannelError.closed
        }
        try await Task.sleep(for: delay)
        return responses.removeFirst()
    }

    func close() async {
        closeCount += 1
    }
}

/// A minimal `ClientControlConnection` fake for `ClientSessionRunner`'s own
/// portable routing test: scripts the wire exactly as `ScriptedClientTransport`
/// does, and no-ops the dial and silence-watch calls the runner needs a
/// `ClientControlConnection` (rather than a bare `SensoriumControlTransport`)
/// for.
actor ScriptedControlConnection: ClientControlConnection {
    let deferredPackets = DeferredPacketQueue()
    private var responses: [SensoriumTransportPacket]
    private(set) var sentMessages: [SensoriumMessage] = []
    private(set) var sentPackets: [SensoriumTransportPacket] = []

    init(responses: [SensoriumTransportPacket]) {
        self.responses = responses
    }

    func start(timeout: TimeInterval) async throws {}
    nonisolated func beginHostSilenceWatch() {}
    nonisolated func endHostSilenceWatch() {}
    nonisolated func enqueue(_ packet: SensoriumTransportPacket) {}

    func send(_ message: SensoriumMessage) async throws {
        sentMessages.append(message)
    }

    func send(_ packet: SensoriumTransportPacket) async throws {
        sentPackets.append(packet)
    }

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        guard !responses.isEmpty else {
            throw ControlChannelError.closed
        }
        return responses.removeFirst()
    }

    func close() async {}
}

final class UncheckedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flag = newValue
    }
}

struct ForwardedShortcut: Equatable {
    let keyCode: UInt16
    let isDown: Bool
    let modifiers: CanvasModifierFlags
}

/// A viewer window as `SystemShortcutForwarder` sees it. The real conformer is
/// `ClientCanvasWindowController`, which cannot be built here (no window server
/// connection), so shortcut dispatch is proven against this instead.
@MainActor
final class RecordingShortcutTarget: ShortcutForwardingTarget {
    var viewerWindowState: ViewerWindowState
    private(set) var forwarded: [ForwardedShortcut] = []
    private(set) var releaseCount = 0

    init(state: ViewerWindowState) {
        viewerWindowState = state
    }

    func forwardShortcut(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags) {
        forwarded.append(ForwardedShortcut(keyCode: keyCode, isDown: isDown, modifiers: modifiers))
    }

    func releaseToLocalMachine() {
        releaseCount += 1
    }
}

/// Stands in for macOS's own Accessibility trust and its approval dialog,
/// without ever presenting one. `requestAccessibility()` counts its calls so
/// a test can assert a forwarder never prompts more than once, and can be
/// told to grant on request, standing in for the person clicking Allow.
final class FakeAccessibilityAuthorization: ClientAccessibilityAuthorization, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    /// Whether a prompt should grant, standing in for the person clicking
    /// Allow (`true`) or Don't Allow / dismissing the dialog (`false`).
    var grantsOnPrompt: Bool

    private(set) var promptCount = 0

    init(granted: Bool = false, grantsOnPrompt: Bool = false) {
        self.granted = granted
        self.grantsOnPrompt = grantsOnPrompt
    }

    var isAccessibilityGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    func requestAccessibility() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        promptCount += 1
        if grantsOnPrompt {
            granted = true
        }
        return granted
    }

    /// Simulates the person granting the permission after the dialog was
    /// already dismissed — the asynchronous case a real prompt always takes,
    /// discovered later by a poll rather than by this fake's own prompt call.
    func grantNow() {
        lock.lock()
        defer { lock.unlock() }
        granted = true
    }
}

/// Stands in for `DispatchQueue.main.asyncAfter` in `SystemShortcutForwarder`:
/// captures each scheduled grant check instead of waiting on a real timer, so
/// a test can fire one deterministically and see whether it reschedules.
@MainActor
final class FakeGrantCheckScheduler {
    private(set) var scheduledChecks: [@MainActor () -> Void] = []

    var schedule: (@escaping @MainActor () -> Void) -> Void {
        { [weak self] check in
            self?.scheduledChecks.append(check)
        }
    }

    /// Fires and removes the oldest still-pending check, standing in for its
    /// timer elapsing.
    func fireOldest() {
        guard !scheduledChecks.isEmpty else { return }
        scheduledChecks.removeFirst()()
    }
}

/// Stands in for the CGEventTap: `deliver` plays the part macOS would, without
/// a tap, a TCC grant, or a run loop.
@MainActor
final class FakeShortcutInterceptor: SystemShortcutInterceptor {
    var failure: SystemShortcutInterceptorError?
    private var claim: ((KeyChord, Bool) -> Bool)?
    private var onDegraded: ((String) -> Void)?
    /// Counts real installs, so a test can tell "restarted after a genuine
    /// stop" apart from "stacked a second tap behind the first".
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var isRunning: Bool { claim != nil }

    func start(_ handler: @escaping (KeyChord, Bool) -> Bool, onDegraded: @escaping (String) -> Void) throws {
        if let failure {
            throw failure
        }
        startCount += 1
        claim = handler
        self.onDegraded = onDegraded
    }

    func stop() {
        stopCount += 1
        claim = nil
        onDegraded = nil
    }

    func deliver(_ chord: KeyChord, isDown: Bool) -> Bool {
        claim?(chord, isDown) ?? false
    }

    /// Stands in for the real tap deciding to give up on itself and telling
    /// whoever called `start` — proves the forwarder wires its `log` closure
    /// all the way to the interceptor's report path, without a real tap ever
    /// having to actually get disabled.
    @discardableResult
    func simulateDegraded(_ message: String) -> Bool {
        guard let onDegraded else { return false }
        onDegraded(message)
        return true
    }
}

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}

/// Records the order two queued pieces of work actually ran in.
actor RecordedOrder {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}


/// A runner that reads the host's report that its screen is locked, then an
/// unlock answer, then the link closing. Returns everything the runner put on
/// the wire and the reason it gave for ending.
@MainActor
func runnerAfterLockedHostReport() async -> (sent: [SensoriumMessage], endedReason: String?) {
    final class Reason: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        func set(_ reason: String) {
            lock.lock()
            stored = reason
            lock.unlock()
        }
    }

    let connection = ScriptedControlConnection(responses: [
        .control(.hostScreenLockState(locked: true)),
        .control(.hostScreenUnlockResult(.wrongPassword)),
    ])
    let runner = ClientSessionRunner(
        connection: connection,
        session: ClientSessionController(transport: FakeClientTransport()),
        window: RecordingSurfaceWindow(surfaceID: 0)
    )
    let reason = Reason()
    try! runner.start(onEnded: { reason.set($0) })
    for _ in 0..<200 where reason.value == nil {
        try? await Task.sleep(for: .milliseconds(10))
    }
    runner.stop()
    let packets = await connection.sentPackets.compactMap { packet -> SensoriumMessage? in
        guard case let .control(message) = packet else { return nil }
        return message
    }
    return (await connection.sentMessages + packets, reason.value)
}
