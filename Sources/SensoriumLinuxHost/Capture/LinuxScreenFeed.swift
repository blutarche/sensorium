#if os(Linux)
import Foundation
import SensoriumCore

/// Where the granted monitor's pictures come from: the portal's PipeWire
/// stream, or a synthetic picture in a test. Frames and state changes arrive
/// on the source's own thread. A stopped source can be started again.
public protocol LinuxFrameSource: AnyObject, Sendable {
    func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws
    /// When this returns no callback is running or will run.
    func stop()
}

/// The portal's PipeWire stream for the granted monitor. Each start opens a
/// fresh connection to the portal's remote, so the source can be stopped and
/// started again for as long as the portal session lasts.
public final class PipeWireFrameSource: LinuxFrameSource, @unchecked Sendable {
    private let session: PortalSession
    private let stream: PortalStream
    private let lock = NSLock()
    private var capture: PipeWireCapture?
    /// Counts stops, so a start still waiting on the portal when the source
    /// is stopped never begins capturing.
    private var stops: UInt64 = 0

    public init(session: PortalSession, stream: PortalStream) {
        self.session = session
        self.stream = stream
    }

    public func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws {
        let stopsBefore = lock.withLock { stops }
        let descriptor = try await session.openPipeWireRemote()
        let capture = try PipeWireCapture(descriptor: descriptor, stream: stream, onFrame: onFrame, onState: onState)
        try lock.withLock {
            guard stops == stopsBefore, self.capture == nil else { throw PortalError.sessionClosed }
            try capture.start()
            self.capture = capture
        }
    }

    public func stop() {
        let taken = lock.withLock {
            stops += 1
            defer { capture = nil }
            return capture
        }
        taken?.stop()
    }
}

/// One picture of the host screen as the encoder takes it, stamped on the
/// host's monotonic clock when it arrived.
public struct ScreenFeedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixels: Data
    public let presentationTimeNanoseconds: Int64
}

/// The granted monitor's one capture, shared by every session on it.
///
/// The capture runs only while a session watches the monitor: a running
/// screencast has the compositor render and copy out a picture on every
/// change, whether anyone looks or not. At the grant the source runs just
/// long enough for its first frame, which tells the display inventory the
/// monitor's size, and stops again. The first subscriber starts it, and a
/// screencast stream opens with the picture on screen, so a new session has
/// a first picture even when the screen is still. The last subscriber
/// leaving stops it and drops the latest frame.
///
/// A capture whose pictures were dropped while it ran, after the probe or
/// after the last subscriber left, is never reused: a subscriber arriving
/// before it stops gets a fresh one, which opens with the picture on screen.
///
/// Frames are stamped on the host's monotonic clock as they arrive, never
/// with PipeWire's own time: the latency recorder and the encoder's key-frame
/// interval both read the host's clock, and a replayed frame must not carry
/// a time from the past.
///
/// The cursor is not drawn into the frame. The macOS host leaves it out of
/// a host-screen stream too, because the viewer draws its own.
public final class LinuxScreenFeed: @unchecked Sendable {
    public final class Subscription: @unchecked Sendable {
        private let onCancel: @Sendable () -> Void

        init(onCancel: @escaping @Sendable () -> Void) {
            self.onCancel = onCancel
        }

        public func cancel() {
            onCancel()
        }
    }

    private struct Subscriber {
        let onFrame: @Sendable (ScreenFeedFrame) -> Void
        let onState: @Sendable (CaptureState) -> Void
    }

    private enum SourceStep {
        case start(run: UInt64)
        case stop
        case settled
    }

    private let source: any LinuxFrameSource
    private let grantState: PortalGrantState
    private let streamNodeID: UInt32
    private let generation: UInt64
    private let nowNanoseconds: @Sendable () -> Int64
    private let lock = NSLock()
    private var latest: ScreenFeedFrame?
    private var state: CaptureState = .connecting
    private var subscribers: [UUID: Subscriber] = [:]
    private var isStopped = false
    /// True from `start()` until the first frame has been recorded.
    private var isProbing = false
    /// Whether the source was last started rather than stopped.
    private var isSourceRunning = false
    /// The running capture's pictures were dropped; it must be stopped.
    private var isRunSpent = false
    /// Names the current run of the source. A callback carrying any other
    /// run comes from a capture that was stopped or is about to be.
    private var run: UInt64 = 0
    /// Only one caller starts and stops the source at a time.
    private var isSettlingSource = false

    public init(
        source: any LinuxFrameSource,
        grantState: PortalGrantState,
        streamNodeID: UInt32,
        generation: UInt64,
        nowNanoseconds: @escaping @Sendable () -> Int64 = MonotonicClock.nowNanoseconds
    ) {
        self.source = source
        self.grantState = grantState
        self.streamNodeID = streamNodeID
        self.generation = generation
        self.nowNanoseconds = nowNanoseconds
    }

    /// The stream's state as last reported.
    public var currentState: CaptureState {
        lock.withLock { state }
    }

    /// Starts the source to learn the monitor's size, only under the grant
    /// it was made for. Throws when the source cannot start.
    public func start() async throws {
        let mayStart = lock.withLock {
            guard grantState.isCurrent(generation), !isStopped else { return false }
            isProbing = true
            return true
        }
        guard mayStart else { throw PortalError.sessionClosed }
        if let error = await settleSource() {
            throw error
        }
        guard grantState.isCurrent(generation), lock.withLock({ !isStopped }) else {
            stop()
            throw PortalError.sessionClosed
        }
    }

    /// Stops the source for good. Every subscriber is told the stream failed,
    /// so a session streaming from it ends rather than freezing.
    public func stop() {
        let listeners: [Subscriber] = lock.withLock {
            guard !isStopped else { return [] }
            isStopped = true
            isProbing = false
            run += 1
            latest = nil
            state = .failed("the screen sharing session ended")
            return Array(subscribers.values)
        }
        source.stop()
        for listener in listeners {
            listener.onState(.failed("the screen sharing session ended"))
        }
    }

    /// Delivers frames and state changes to the handlers, starting with the
    /// current state and, when the capture is running, the latest frame.
    public func subscribe(
        onFrame: @escaping @Sendable (ScreenFeedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) -> Subscription {
        let id = UUID()
        let (replay, currentState): (ScreenFeedFrame?, CaptureState) = lock.withLock {
            subscribers[id] = Subscriber(onFrame: onFrame, onState: onState)
            return (latest.map(restamped), state)
        }
        onState(currentState)
        if let replay {
            onFrame(replay)
        }
        scheduleSourceSettling()
        return Subscription { [weak self] in
            self?.unsubscribe(id)
        }
    }

    private func unsubscribe(_ id: UUID) {
        let wasLast = lock.withLock {
            guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty, !isStopped else { return false }
            spendRun()
            return true
        }
        if wasLast {
            scheduleSourceSettling()
        }
    }

    /// Drops the running capture's pictures and marks it to be stopped.
    /// Called with the lock held and nobody subscribed.
    private func spendRun() {
        latest = nil
        guard isSourceRunning else { return }
        isRunSpent = true
        run += 1
        if !hasFailed {
            state = .connecting
        }
    }

    private var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func scheduleSourceSettling() {
        Task.detached { [weak self] in
            await self?.settleSource()
        }
    }

    /// Starts or stops the source until it matches what the feed needs: it
    /// runs while the probe waits for a frame or anyone subscribes, unless
    /// the feed stopped or the stream failed. Returns the error of a start
    /// that failed on the way.
    @discardableResult
    private func settleSource() async -> (any Error)? {
        let claimed = lock.withLock {
            guard !isSettlingSource else { return false }
            isSettlingSource = true
            return true
        }
        guard claimed else { return nil }
        var startError: (any Error)?
        while true {
            let step: SourceStep = lock.withLock {
                let wanted = !isStopped && !hasFailed && (isProbing || !subscribers.isEmpty)
                if isSourceRunning, !wanted || isRunSpent {
                    isSourceRunning = false
                    isRunSpent = false
                    run += 1
                    latest = nil
                    if !hasFailed {
                        state = .connecting
                    }
                    return .stop
                }
                if !isSourceRunning, wanted {
                    isSourceRunning = true
                    run += 1
                    return .start(run: run)
                }
                isSettlingSource = false
                return .settled
            }
            switch step {
            case .settled:
                return startError
            case .stop:
                source.stop()
            case let .start(run):
                do {
                    try await source.start(
                        onFrame: { [weak self] frame in self?.deliver(frame, run: run) },
                        onState: { [weak self] state in self?.report(state, run: run) }
                    )
                } catch {
                    startError = error
                    lock.withLock {
                        isSourceRunning = false
                        isRunSpent = false
                    }
                    report(.failed("the screen could not be captured: \(error)"), run: run)
                }
            }
        }
    }

    private func restamped(_ frame: ScreenFeedFrame) -> ScreenFeedFrame {
        ScreenFeedFrame(
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            pixels: frame.pixels,
            presentationTimeNanoseconds: nowNanoseconds()
        )
    }

    private func deliver(_ captured: CapturedFrame, run frameRun: UInt64) {
        guard grantState.isCurrent(generation), let pixels = captured.pixels, captured.width > 0, captured.height > 0,
              captured.stride >= captured.width * 4,
              pixels.count >= captured.stride * (captured.height - 1) + captured.width * 4 else {
            return
        }
        let frame = ScreenFeedFrame(
            width: captured.width,
            height: captured.height,
            bytesPerRow: captured.stride,
            pixels: pixels,
            presentationTimeNanoseconds: nowNanoseconds()
        )
        let listeners: [Subscriber]? = lock.withLock {
            guard !isStopped, frameRun == run, !hasFailed else { return nil }
            isProbing = false
            if subscribers.isEmpty {
                spendRun()
                return []
            }
            latest = frame
            return Array(subscribers.values)
        }
        guard let listeners else { return }
        grantState.recordFrame(nodeID: streamNodeID, generation: generation, width: frame.width, height: frame.height)
        if listeners.isEmpty {
            scheduleSourceSettling()
        }
        for listener in listeners {
            listener.onFrame(frame)
        }
    }

    private func report(_ newState: CaptureState, run stateRun: UInt64) {
        let listeners: [Subscriber]? = lock.withLock {
            guard !isStopped, stateRun == run, !hasFailed else { return nil }
            state = newState
            if case .failed = newState {
                latest = nil
                isProbing = false
            }
            return Array(subscribers.values)
        }
        guard let listeners else { return }
        if case .failed = newState {
            grantState.failStream(nodeID: streamNodeID, generation: generation)
            scheduleSourceSettling()
        }
        for listener in listeners {
            listener.onState(newState)
        }
    }
}
#endif
