import Foundation
import Network
import SensoriumCore

public enum HostNetworkSessionError: Error, Equatable {
    case closed
    case receiveFailed
    /// The viewer-silence watchdog concluded the link is dead after this much
    /// true silence and cancelled the channel itself, rather than the
    /// transport reporting a failure of its own. Carries the timeout this
    /// session was actually configured with, so the operator log names the
    /// value that fired rather than a hardcoded default.
    case viewerSilent(after: Duration)
}

/// The byte stream a host session runs over. NWConnection serves the QUIC
/// product transport; PosixByteChannel serves the TCP verification transport,
/// because this OS build's NWListener cannot hand out working accepted
/// connections when the listener pins its local endpoint.
public protocol HostByteChannel: AnyObject, Sendable {
    func start()
    func cancel()
    func sendBytes(_ data: Data) async throws
    func receiveBytes(count: Int) async throws -> Data
}

extension PosixByteChannel: HostByteChannel {
    public func start() {}

    public func sendBytes(_ data: Data) async throws {
        try await send(data)
    }

    public func receiveBytes(count: Int) async throws -> Data {
        try await receive(count: count)
    }
}

public final class NWByteChannel: HostByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.sensorium.host-nw-channel")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveBytes(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, isComplete, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: HostNetworkSessionError.closed)
                } else {
                    continuation.resume(throwing: HostNetworkSessionError.receiveFailed)
                }
            }
        }
    }
}

/// How often a live connection rereads this machine's lock state while a
/// host-screen session may be running. `HostSessionCoordinator.tickHostScreenLockState()`
/// itself decides whether that reading is worth telling the viewer.
private enum HostScreenLockWatchPolicy {
    static let pollIntervalSeconds: Double = 2
}

private final class LockedSurfaceVideoSendQueues: @unchecked Sendable {
    private let lock = NSLock()
    private var queues = SurfaceVideoSendQueues()

    func withLock<T>(_ body: (inout SurfaceVideoSendQueues) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&queues)
    }
}

/// Holds one cancellable background task for a session that is itself
/// `@unchecked Sendable`: `start()`, `stop()`, and the receive loop's error
/// path all reach it from different threads.
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func replace(with task: Task<Void, Never>) {
        lock.lock()
        let previous = self.task
        self.task = task
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

/// One surface's fidelity as the coordinator has it, read in a single
/// main-actor hop so the telemetry snapshot below can be assembled without
/// hopping actors once per field.
private struct SurfaceFidelityState: Sendable {
    let appliedScale: Double
    let sustainableScaleCeiling: Double?
    let clampedFromUserChoice: Double?
    let hostRequestedStreamScale: Double?
    let framesPerSecond: Int
    let qualityScale: Double
    let limitReason: String?
}

/// Work exactly one of two racing tasks may do. `claim()` is `true` for the
/// first caller and `false` for every one after it.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else {
            return false
        }
        claimed = true
        return true
    }
}

/// Whether this connection's viewer has proven it understands surface-tagged
/// video. Written on the send path and read from the encoder's own thread.
private final class SurfaceAwarePeerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

/// When bytes were last actually received, and whether the watchdog has
/// already fired -- read by the watchdog task and written by the receive
/// loop, both off the main actor. `markDetected()` is one-shot the same way
/// `OneShotFlag` is, since only the watchdog itself calls it and it must act
/// at most once.
private final class ViewerSilenceState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReceivedNanoseconds: Int64
    private var detected = false

    init(nowNanoseconds: Int64) {
        lastReceivedNanoseconds = nowNanoseconds
    }

    func noteReceived(atNanoseconds nanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        lastReceivedNanoseconds = nanoseconds
    }

    func silentNanoseconds(asOf nowNanoseconds: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return nowNanoseconds - lastReceivedNanoseconds
    }

    func markDetected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !detected else { return false }
        detected = true
        return true
    }

    var isDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return detected
    }
}

public final class HostNetworkSession: CanvasVideoSending, @unchecked Sendable {
    private let connection: any HostByteChannel
    private let controller: HostSessionController
    private var coordinator: HostSessionCoordinator?
    private let onEvent: (@Sendable (String) -> Void)?
    /// Told who the viewer is once this connection's authenticated hello has
    /// actually been accepted, and told again when the connection ends. Pure
    /// observation: the host's menu-bar item is the only thing that reads it,
    /// and nothing on this path behaves differently when it is nil.
    private let onPeerPresence: (@Sendable (HostPeerPresence) -> Void)?
    private let queue = DispatchQueue(label: "com.sensorium.host-session")
    /// Frames arrive from the encoder's own thread, so the queues are
    /// lock-guarded rather than actor-isolated: an await here would reintroduce
    /// the backlog.
    private let videoQueues = LockedSurfaceVideoSendQueues()
    /// Bytes actually written per surface, counted at send completion rather
    /// than at enqueue. A link the encoder outruns has its excess frames
    /// discarded by the queue above, and a fidelity decision comparing the
    /// viewer's reading against those discarded bytes would read every tick
    /// after the first drop as a starved link.
    private let sentBytes = SurfaceByteCounter()
    /// Set only once this connection has actually written a `canvasReady`
    /// carrying a surfaceID — which the controller echoes only for a request
    /// that supplied one. Until then every frame goes out on tag 1.
    private let isPeerSurfaceAware = SurfaceAwarePeerFlag()
    private let latencyRecorder: HostMediaLatencyRecorder?
    /// `nil` for a session built without clipboard sync, which neither polls
    /// the host pasteboard nor applies anything a viewer sends it. Turning
    /// sharing off is the engine's own state, not a `nil` here.
    private let clipboard: ClipboardSyncSession?
    private let clipboardPollTask = CancellableTaskBox()
    /// Started whenever there is a `latencyRecorder`, which is every
    /// production session.
    private let telemetryPollTask = CancellableTaskBox()
    /// Rereads this machine's lock state on `HostScreenLockWatchPolicy.pollIntervalSeconds`
    /// for as long as the connection lives, unconditionally -- like the polls
    /// above, the coordinator's own tick decides per call whether there is a
    /// live host-screen session and whether its lock state actually moved.
    private let hostScreenLockWatchPollTask = CancellableTaskBox()
    /// Silence tracked from this connection's own construction, in
    /// nanoseconds -- see `startViewerSilenceWatchdog()`.
    private let viewerSilenceState = ViewerSilenceState(nowNanoseconds: MonotonicClock.nowNanoseconds())
    private let viewerSilenceWatchdogTask = CancellableTaskBox()
    /// Kept alongside `viewerSilenceTimeoutNanoseconds` so the close reason
    /// can name the value this session actually ran with.
    private let viewerSilenceTimeout: Duration
    private let viewerSilenceTimeoutNanoseconds: Int64

    /// The viewer sends a clock-sync message roughly every ten seconds while
    /// a session is live, so this much true silence means the link is dead,
    /// not merely quiet. Not the transport's own idle timeout: that fires
    /// only once the OS itself gives up on the socket, which in the field
    /// can run far longer than this. Shorter than the viewer's own
    /// thirty-second silence watchdog, which redials right after it fires --
    /// the host has to have freed the slot by then, not merely be about to.
    public static let defaultViewerSilenceTimeout: Duration = .seconds(20)

    private static func nanoseconds(for duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }

    public init(
        connection: any HostByteChannel,
        controller: HostSessionController,
        coordinator: HostSessionCoordinator? = nil,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        clipboard: ClipboardSyncSession? = nil,
        viewerSilenceTimeout: Duration = HostNetworkSession.defaultViewerSilenceTimeout,
        onEvent: (@Sendable (String) -> Void)? = nil,
        onPeerPresence: (@Sendable (HostPeerPresence) -> Void)? = nil
    ) {
        self.connection = connection
        self.controller = controller
        self.coordinator = coordinator
        self.latencyRecorder = latencyRecorder
        self.clipboard = clipboard
        self.viewerSilenceTimeout = viewerSilenceTimeout
        self.viewerSilenceTimeoutNanoseconds = Self.nanoseconds(for: viewerSilenceTimeout)
        self.onEvent = onEvent
        self.onPeerPresence = onPeerPresence
    }

    public convenience init(
        connection: NWConnection,
        controller: HostSessionController,
        coordinator: HostSessionCoordinator? = nil,
        latencyRecorder: HostMediaLatencyRecorder? = nil,
        clipboard: ClipboardSyncSession? = nil,
        viewerSilenceTimeout: Duration = HostNetworkSession.defaultViewerSilenceTimeout,
        onEvent: (@Sendable (String) -> Void)? = nil,
        onPeerPresence: (@Sendable (HostPeerPresence) -> Void)? = nil
    ) {
        self.init(
            connection: NWByteChannel(connection: connection),
            controller: controller,
            coordinator: coordinator,
            latencyRecorder: latencyRecorder,
            clipboard: clipboard,
            viewerSilenceTimeout: viewerSilenceTimeout,
            onEvent: onEvent,
            onPeerPresence: onPeerPresence
        )
    }

    /// The coordinator needs this session as its video sink, so it is attached
    /// after construction rather than passed in.
    public func attach(coordinator: HostSessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Encoded canvas frames leave here, off the main actor.
    ///
    /// Bounded on purpose: spawning a task per frame lets a link slower than the
    /// encoder grow an unbounded backlog, which shows up as latency that never
    /// recovers. One frame in flight, one waiting, the rest dropped.
    ///
    /// `false` for a frame this session did not take, which is a frame the
    /// queue discarded because the link could not keep up with the encoder, or
    /// one belonging to a surface this viewer cannot be sent.
    @discardableResult
    public func send(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID, priority: VideoSendPriority) -> Bool {
        // Unreachable by construction: a viewer that never proved it understands
        // surfaces can only ever have created surface 0, because a canvasRequest
        // naming surface 1 is exactly what proves it. Refusing rather than
        // falling back to tag 1 keeps that an absent frame instead of surface
        // 1's picture silently corrupting surface 0's stream.
        guard isPeerSurfaceAware.isSet || surface == CanvasSurfaceID.allCases[0] else {
            return false
        }
        let admission = videoQueues.withLock { $0.enqueue(packet, surface: surface, priority: priority) }
        switch admission {
        case .sendNow:
            startVideoSend(packet, surface: surface)
            return true
        case .queued, .replacedStaleFrame:
            return true
        case .droppedIncoming:
            return false
        }
    }

    private func startVideoSend(_ packet: EncodedVideoFramePacket, surface: CanvasSurfaceID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(self.videoPacket(packet, on: surface))
                // Counted at send completion on the same basis the viewer
                // counts bytes received: a failed write put nothing on the
                // wire.
                self.sentBytes.record(
                    bytes: packet.payload.count + (packet.codecConfiguration?.count ?? 0),
                    surface: surface
                )
            } catch {
                // Nothing reached the wire; sentBytes stays where it was.
            }
            // Recorded at actual send completion, after any wait this packet
            // spent behind an in-flight send, so a link the encoder outruns
            // shows up here rather than being hidden behind a fast enqueue.
            self.latencyRecorder?.recordSendCompleted(
                surface: surface,
                presentationTimeNanoseconds: Int64(bitPattern: packet.presentationTimeNanoseconds),
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
            guard let next = self.videoQueues.withLock({ $0.completeSend() }) else {
                return
            }
            self.startVideoSend(next.frame, surface: next.surface)
        }
    }

    /// Which wire tag this frame goes out on. Resolved at the moment of the
    /// send, not at enqueue: sends are serialised, so a tag 2 frame can only be
    /// written after the `canvasReady` echo that authorised it.
    private func videoPacket(
        _ packet: EncodedVideoFramePacket,
        on surface: CanvasSurfaceID
    ) -> SensoriumTransportPacket {
        guard isPeerSurfaceAware.isSet else {
            return .video(packet)
        }
        return .videoForSurface(surfaceID: surface.wireValue, frame: packet)
    }

    /// Frames dropped so far, across both surfaces, because the link could not
    /// keep up with the encoders.
    public var droppedVideoFrameCount: Int {
        videoQueues.withLock { $0.droppedFrameCount }
    }

    public func droppedVideoFrameCount(for surface: CanvasSurfaceID) -> Int {
        videoQueues.withLock { $0.droppedFrameCount(for: surface) }
    }

    public func sentVideoByteCount(for surface: CanvasSurfaceID) -> Int? {
        sentBytes.total(for: surface)
    }

    public func start() {
        connection.start()
        Task { [weak self] in
            await self?.run()
        }
        startClipboardPolling()
        startTelemetryPolling()
        startViewerSilenceWatchdog()
        startHostScreenLockWatchPolling()
    }

    /// Watches for the viewer having gone silent, independently of the
    /// transport's own idle timeout -- see `defaultViewerSilenceTimeout`.
    /// Cancelling the channel is what actually ends the session: the pending
    /// `receiveBytes` in `run()` then throws, and the existing catch-block
    /// teardown runs unchanged.
    ///
    /// Gated on `isSessionAuthenticatedAndStreaming`, the same condition
    /// `startTelemetryPolling` uses: pairing a new device can sit idle for
    /// minutes while a person reads a code off the host and types it into
    /// the viewer, and none of that silence is evidence the viewer is gone.
    /// The clock only ever counts down once a session is actually live.
    private func startViewerSilenceWatchdog() {
        viewerSilenceWatchdogTask.replace(with: Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let isStreaming = await MainActor.run { [controller = self.controller] in
                    controller.isSessionAuthenticatedAndStreaming
                }
                guard isStreaming else {
                    // Not yet a live session -- still pairing, or authenticated
                    // but not yet given a surface -- so there is no silence to
                    // measure. Poll rather than sleep for the full timeout: the
                    // clock starts counting from the moment streaming is first
                    // observed, not from whenever this poll happens to land.
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    continue
                }
                let remaining = self.viewerSilenceTimeoutNanoseconds
                    - self.viewerSilenceState.silentNanoseconds(asOf: MonotonicClock.nowNanoseconds())
                guard remaining <= 0 else {
                    do {
                        try await Task.sleep(for: .nanoseconds(remaining))
                    } catch {
                        return
                    }
                    continue
                }
                guard self.viewerSilenceState.markDetected() else { return }
                self.connection.cancel()
                return
            }
        })
    }

    /// Sends one `telemetry` message per `TelemetryPolicy.sendIntervalSeconds`,
    /// gated on this connection being authenticated and streaming something,
    /// so nothing about this session is observable before that. A tick with
    /// nothing to report sends nothing.
    ///
    /// Gated on `isSessionAuthenticatedAndStreaming` rather than on the
    /// narrower pasteboard gate beside it, because either kind of surface has
    /// a picture to steer and to describe: a host-screen session opens no
    /// canvas of its own, and under the narrower gate would run no fidelity
    /// tick and send no figures for as long as it lasted.
    private func startTelemetryPolling() {
        guard let latencyRecorder else {
            return
        }
        telemetryPollTask.replace(with: Task { [weak self] in
            var builder = HostTelemetrySnapshotBuilder()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(TelemetryPolicy.sendIntervalSeconds))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                let isAuthenticatedAndStreaming = await MainActor.run { [controller = self.controller] in
                    controller.isSessionAuthenticatedAndStreaming
                }
                guard isAuthenticatedAndStreaming else {
                    continue
                }
                // One tick of adaptive fidelity per telemetry tick, ahead of
                // the snapshot below rather than on a timer of its own: the
                // numbers the viewer is shown are then the ones this
                // second's decision was actually made from.
                await self.coordinator?.tickFidelity()
                // Read in one main-actor hop rather than from inside the
                // snapshot closures: those run under `videoQueues`'s lock,
                // and the fidelity state lives on the coordinator's actor.
                let fidelity: CanvasSurfaceSlots<SurfaceFidelityState>? =
                    await MainActor.run { [coordinator = self.coordinator] in
                        guard let coordinator else { return nil }
                        return CanvasSurfaceSlots { surface in
                            SurfaceFidelityState(
                                appliedScale: coordinator.appliedStreamScale(for: surface),
                                sustainableScaleCeiling: coordinator.sustainableScaleCeiling(for: surface),
                                clampedFromUserChoice: coordinator.clampedStreamScaleFromUserChoice(for: surface),
                                hostRequestedStreamScale: coordinator.hostRequestedStreamScale(for: surface),
                                framesPerSecond: coordinator.appliedFramesPerSecond(for: surface),
                                qualityScale: coordinator.appliedQualityScale(for: surface),
                                limitReason: coordinator.fidelityLimitReason(for: surface)
                            )
                        }
                    }
                let surfaces = self.videoQueues.withLock { queues in
                    builder.snapshot(
                        metrics: { latencyRecorder.metrics(for: $0) },
                        frameCounts: { latencyRecorder.frameCounts(for: $0) },
                        sendQueueDropped: { queues.droppedFrameCount(for: $0) },
                        appliedStreamScale: { fidelity?[$0].appliedScale },
                        sustainableScaleCeiling: { fidelity?[$0].sustainableScaleCeiling },
                        clampedFromUserChoice: { fidelity?[$0].clampedFromUserChoice },
                        hostRequestedStreamScale: { fidelity?[$0].hostRequestedStreamScale },
                        appliedFramesPerSecond: { fidelity?[$0].framesPerSecond },
                        qualityScale: { fidelity?[$0].qualityScale },
                        fidelityLimitReason: { fidelity?[$0].limitReason },
                        atNanoseconds: MonotonicClock.nowNanoseconds()
                    )
                }
                guard !surfaces.isEmpty else {
                    continue
                }
                try? await self.send(.control(.telemetry(surfaces: surfaces)))
            }
        })
    }

    /// macOS has no pasteboard-change notification, so the host's own copies
    /// are found by polling `changeCount`; the engine behind
    /// `ClipboardSyncSession` decides whether anything actually changed.
    /// Nothing starts for a session built without clipboard sync.
    private func startClipboardPolling() {
        guard let clipboard else {
            return
        }
        clipboardPollTask.replace(with: Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(ClipboardPolicy.pollIntervalSeconds))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                guard let packet = await MainActor.run(body: { clipboard.poll() }) else {
                    continue
                }
                try? await self.send(packet)
            }
        })
    }

    /// Rereads this machine's lock state every `HostScreenLockWatchPolicy.pollIntervalSeconds`
    /// and sends `hostScreenLockState` only when the coordinator's tick
    /// reports a real change. Runs for the whole connection, unconditionally,
    /// the same as `startTelemetryPolling`: it is the tick, not this loop,
    /// that decides whether a live host-screen session exists to report on.
    private func startHostScreenLockWatchPolling() {
        hostScreenLockWatchPollTask.replace(with: Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(HostScreenLockWatchPolicy.pollIntervalSeconds))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                guard let message = await MainActor.run(body: { [coordinator = self.coordinator] in
                    coordinator?.tickHostScreenLockState()
                }) else {
                    continue
                }
                try? await self.send(message)
            }
        })
    }

    /// A person at this machine ended the session, so `stopped-by-host` is
    /// the reason everywhere: on the wire, so the viewer does not redial into
    /// what was just stopped, and through the teardown, which ends a
    /// host-screen grant with it. Teardown is scheduled before the farewell
    /// and independent of it, since a viewer that stops reading must not
    /// hold the workspace, the display, or held input open.
    public func stop() {
        clipboardPollTask.cancel()
        telemetryPollTask.cancel()
        viewerSilenceWatchdogTask.cancel()
        hostScreenLockWatchPollTask.cancel()
        onPeerPresence?(.closed(reason: nil))
        Task { @MainActor [controller, coordinator, clipboard] in
            // Set before the teardown below, which can stall (a slow capture
            // stop, say): a device this connection holds busy must not stay
            // marked busy for as long as that stall lasts, the same ordering
            // the transport-closed path in `run()` uses.
            controller.noteSessionEnding()
            clipboard?.cancelPendingApply()
            if let coordinator {
                await coordinator.sessionDidEnd(reason: GoodbyeReason.stoppedByHost)
            } else {
                _ = try? controller.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))
            }
        }
        let closing = OneShotFlag()
        let farewell = Task { [weak self, connection] in
            try? await self?.send(.goodbye(reason: GoodbyeReason.stoppedByHost))
            if closing.claim() {
                connection.cancel()
            }
        }
        Task { [connection] in
            // The socket closes on a deadline whatever the write is doing, so
            // a stalled viewer delays Stop by at most this and never defeats it.
            try? await Task.sleep(for: .seconds(Self.farewellWriteDeadlineSeconds))
            farewell.cancel()
            if closing.claim() {
                connection.cancel()
            }
        }
    }

    /// Long enough for one small write on a link that is still alive, short
    /// enough that a person watching Stop sees the connection go.
    private static let farewellWriteDeadlineSeconds = 1.0

    private func run() async {
        do {
            while true {
                let header = try await receiveBytes(count: 5)
                let payloadLength = header.withUnsafeBytes { bytes in
                    UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
                }
                guard payloadLength <= SensoriumTransportPacketCodec.maximumPayloadLength else {
                    throw SensoriumProtocolError.frameTooLarge
                }
                let payload = try await receiveBytes(count: Int(payloadLength))
                var packet = header
                packet.append(payload)
                let decoded = try SensoriumTransportPacketCodec.decode(packet)
                if case let .clipboard(content) = decoded {
                    // Applying it is gated inside the session on a granted
                    // session; a host built without clipboard sync has no
                    // session and drops it here.
                    if let clipboard {
                        await MainActor.run { clipboard.receive(content) }
                    }
                    continue
                }
                guard case let .control(message) = decoded else {
                    continue
                }
                let response: SensoriumMessage?
                do {
                    if let coordinator {
                        // The coordinator writes a `canvasReady` through this
                        // closure and returns nil for it, so the reply reaches
                        // the viewer before that surface's capture starts.
                        // Every other reply comes back to be written below.
                        response = try await MainActor.run { [coordinator] in coordinator }.handle(
                            message,
                            writeResponse: { [weak self] reply in
                                try await self?.send(.control(reply))
                            }
                        )
                    } else {
                        response = try await MainActor.run { [controller] in
                            try controller.handle(message)
                        }
                    }
                } catch let error as HostSessionControllerError {
                    guard error.isSessionFatal else {
                        onEvent?(error.operatorLogLine)
                        continue
                    }
                    throw error
                } catch is CanvasCreationGateError {
                    // Refused, not fatal: the gate rejected this request only.
                    // The viewer must still be told, since with no reply it
                    // waits out its canvas-creation timeout and drops the
                    // whole session, a working primary canvas included.
                    // Answered here so the coordinator's rejection, its
                    // workspace rejection, and a bare controller are all
                    // covered by one rule.
                    if case let .canvasRequest(_, _, _, surfaceID) = message {
                        try await send(.canvasRefused(
                            reason: CanvasRefusalReason.creationInProgress,
                            surfaceID: surfaceID
                        ))
                    }
                    continue
                } catch CoreGraphicsVirtualDisplayError.creationFailed {
                    // Fatal, unlike the refusal above: macOS refused every
                    // identity, so this connection has nothing to stream. The
                    // viewer is told first with a reason redialling cannot
                    // fix; a silent close looks like a sleeping machine and
                    // it would redial on backoff forever.
                    if case let .canvasRequest(_, _, _, surfaceID) = message {
                        try await send(.canvasRefused(
                            reason: CanvasRefusalReason.canvasUnavailable,
                            surfaceID: surfaceID
                        ))
                    }
                    throw CoreGraphicsVirtualDisplayError.creationFailed
                }
                // After the handling above, never before it: a hello that
                // failed verification or came from a device this host has not
                // paired with throws, and must not put a name on the menu bar.
                if case let .authenticatedHello(_, deviceName, _, _, _) = message {
                    onPeerPresence?(.identified(deviceName: deviceName))
                }
                if let response {
                    try await send(response)
                }
                // An armed device discovers arming by being
                // offered its screens unprompted, right after its hello, not
                // by asking. `offerHostScreenList()` never touches
                // `HostSessionController.connectionShape`, so a canvas
                // request that follows this offer is still admitted --
                // pushing the offer is not itself a shape a later
                // `canvasRequest` could be refused for mixing with.
                if case .authenticatedHello = message {
                    let offer = try await controller.offerHostScreenListWakingDisplays()
                    try await send(offer)
                }
                // Checked only for the message that could have tripped it, so
                // this costs nothing on the hot input/video path. The reply
                // above already told the viewer why; this is what actually
                // drops the socket.
                if case .pairRequest = message,
                   await MainActor.run(body: { [controller] in controller.pairingConnectionFailureCapReached }) {
                    throw HostSessionControllerError.pairingConnectionFailuresExceeded
                }
            }
        } catch {
            clipboardPollTask.cancel()
            telemetryPollTask.cancel()
            viewerSilenceWatchdogTask.cancel()
            hostScreenLockWatchPollTask.cancel()
            // A watchdog-triggered cancel reaches here as an ordinary
            // channel error; naming it explicitly is what lets the close
            // reason say why the link ended instead of just that it did.
            let closingError: any Error = viewerSilenceState.isDetected
                ? HostNetworkSessionError.viewerSilent(after: viewerSilenceTimeout)
                : error
            // The error that ended the read loop is the only place this
            // machine learns why a viewer went away, so it is named in the
            // close reason.
            onPeerPresence?(.closed(reason: HostOperatorLog.closeReason(for: closingError)))
            Task { @MainActor [controller, coordinator, clipboard] in
                // Set before the teardown below, which can stall (a slow
                // capture stop, say): a device this connection held busy
                // must not stay marked busy for as long as that stall lasts.
                controller.noteSessionEnding()
                clipboard?.cancelPendingApply()
                if let coordinator {
                    await coordinator.sessionDidEnd(reason: "transport-closed")
                } else {
                    _ = try? controller.handle(.goodbye(reason: "transport-closed"))
                }
            }
            connection.cancel()
        }
    }

    /// Tells the viewer that a clipboard was not shared, and why. A refusal
    /// that only describes the session, `syncDisabled` or
    /// `sessionNotActive`, is never sent: the second is exactly the case of a
    /// connection that has not been admitted. A send failure is left to the
    /// receive loop to report, as for a clipboard.
    public func reportClipboardRefusal(_ refusal: ClipboardRefusal) async {
        switch refusal {
        case .syncDisabled, .sessionNotActive:
            return
        case .excludedType, .tooLarge, .unsupportedContent:
            try? await send(.clipboardRefused(refusal))
        }
    }

    /// Every outgoing packet passes through here, which is what makes the
    /// surface-aware gate below cover every path: a tag 2 frame can only follow
    /// a `canvasReady` this same connection actually wrote.
    public func send(_ packet: SensoriumTransportPacket) async throws {
        try await sendRaw(SensoriumTransportPacketCodec.encode(packet))
        // Set after the write, not before: a viewer that never received the echo
        // never proved anything. A connection that never gets this far — an old
        // viewer that omits surfaceID, a pairing-only session, a refused canvas
        // request, a dropped transport — keeps tag 1 for its whole life, and a
        // reconnect starts over with a new session and a fresh flag.
        if case let .control(.canvasReady(_, _, _, _, surfaceID, _)) = packet, surfaceID != nil {
            isPeerSurfaceAware.set()
        }
    }

    private func send(_ message: SensoriumMessage) async throws {
        try await send(.control(message))
    }

    private func sendRaw(_ frame: Data) async throws {
        try await connection.sendBytes(frame)
    }

    private func receiveBytes(count: Int) async throws -> Data {
        let data = try await connection.receiveBytes(count: count)
        viewerSilenceState.noteReceived(atNanoseconds: MonotonicClock.nowNanoseconds())
        return data
    }
}
