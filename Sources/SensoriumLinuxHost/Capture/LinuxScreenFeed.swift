#if os(Linux)
import Foundation
import SensoriumCore

/// Where the granted monitor's pictures come from: the portal's PipeWire
/// stream, or a synthetic picture in a test. Frames and state changes arrive
/// on the source's own thread.
public protocol LinuxFrameSource: AnyObject, Sendable {
    func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws
    /// When this returns no callback is running or will run.
    func stop()
}

/// The portal's PipeWire stream for the granted monitor.
public final class PipeWireFrameSource: LinuxFrameSource, @unchecked Sendable {
    private let session: PortalSession
    private let stream: PortalStream
    private let lock = NSLock()
    private var capture: PipeWireCapture?
    private var isStopped = false

    public init(session: PortalSession, stream: PortalStream) {
        self.session = session
        self.stream = stream
    }

    public func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws {
        let descriptor = try await session.openPipeWireRemote()
        let capture = try PipeWireCapture(descriptor: descriptor, stream: stream, onFrame: onFrame, onState: onState)
        try lock.withLock {
            guard !isStopped else { throw PortalError.sessionClosed }
            try capture.start()
            self.capture = capture
        }
    }

    public func stop() {
        let taken = lock.withLock {
            isStopped = true
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
/// The host starts it with the grant and keeps it running: the display
/// inventory needs a frame before it can say the monitor's scale, and a new
/// session needs a first picture even when the screen is still and the
/// compositor sends nothing new. So the latest frame is kept and handed to
/// each new subscriber, stamped with the time it was handed over.
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

    /// Starts the source only under the grant it was made for.
    public func start() async throws {
        guard grantState.isCurrent(generation), lock.withLock({ !isStopped }) else {
            throw PortalError.sessionClosed
        }
        try await source.start(
            onFrame: { [weak self] frame in self?.deliver(frame) },
            onState: { [weak self] state in self?.report(state) }
        )
        guard grantState.isCurrent(generation), lock.withLock({ !isStopped }) else {
            source.stop()
            throw PortalError.sessionClosed
        }
    }

    /// Stops the source. Every subscriber is told the stream failed, so a
    /// session streaming from it ends rather than freezing.
    public func stop() {
        let listeners: [Subscriber] = lock.withLock {
            guard !isStopped else { return [] }
            isStopped = true
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
    /// latest frame and the current state.
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
        return Subscription { [weak self] in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
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

    private func deliver(_ captured: CapturedFrame) {
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
            guard !isStopped else { return nil }
            if case .failed = state { return nil }
            latest = frame
            return Array(subscribers.values)
        }
        guard let listeners else { return }
        grantState.recordFrame(nodeID: streamNodeID, generation: generation, width: frame.width, height: frame.height)
        for listener in listeners {
            listener.onFrame(frame)
        }
    }

    private func report(_ newState: CaptureState) {
        let listeners: [Subscriber] = lock.withLock {
            guard !isStopped else { return [] }
            if case .failed = state { return [] }
            state = newState
            if case .failed = newState { latest = nil }
            return Array(subscribers.values)
        }
        if case .failed = newState {
            grantState.failStream(nodeID: streamNodeID, generation: generation)
        }
        for listener in listeners {
            listener.onState(newState)
        }
    }
}
#endif
