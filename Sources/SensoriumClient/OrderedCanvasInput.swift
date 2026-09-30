import Foundation

/// Surface events waiting to be handed to the router, oldest first.
///
/// Order is the point: a key release that overtakes its press, or a click that
/// lands before the move that aimed it, is a different input on the host.
/// Only pointer motion is allowed to give anything up, because a newer
/// position makes an older one queued behind it worthless. Buttons, scrolls,
/// keys and everything else are kept exactly as they arrived.
public struct CanvasInputBuffer: Sendable {
    private var events: [CanvasSurfaceEvent] = []
    private var head = 0

    public init() {}

    public var isEmpty: Bool { head == events.count }

    public mutating func push(_ event: CanvasSurfaceEvent) {
        if !isEmpty, let last = events.last {
            switch (last, event) {
            case (.pointerMoved, .pointerMoved):
                events[events.count - 1] = event
                return
            case let (
                .pointerMovedRelative(lastX, lastY),
                .pointerMovedRelative(deltaX, deltaY)
            ):
                // Relative motion is a distance, not a position: the newest
                // delta alone would lose the travel that came before it.
                events[events.count - 1] = .pointerMovedRelative(
                    deltaX: lastX + deltaX,
                    deltaY: lastY + deltaY
                )
                return
            default:
                break
            }
        }
        events.append(event)
    }

    public mutating func pop() -> CanvasSurfaceEvent? {
        guard head < events.count else { return nil }
        let event = events[head]
        head += 1
        if head == events.count {
            events.removeAll(keepingCapacity: true)
            head = 0
        }
        return event
    }
}

/// Carries a window's input to its router one event at a time, in the order it
/// happened.
///
/// One long-lived task consumes the queue, because separate tasks started per
/// event have no ordering guarantee against one another. While the consumer is suspended in a slow send, newer pointer
/// motion collapses in the buffer -- see `CanvasInputBuffer`.
public final class OrderedCanvasInputPipeline: @unchecked Sendable {
    private final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = CanvasInputBuffer()
        private var isFinished = false

        /// False once finished, so nothing is accepted after teardown.
        func push(_ event: CanvasSurfaceEvent) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return false }
            buffer.push(event)
            return true
        }

        func pop() -> CanvasSurfaceEvent? {
            lock.lock()
            defer { lock.unlock() }
            return buffer.pop()
        }

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let wasFinished = isFinished
            isFinished = true
            return !wasFinished
        }
    }

    private let queue = Queue()
    private let doorbell: AsyncStream<Void>.Continuation
    private let consumer: Task<Void, Never>

    public init(deliver: @escaping @Sendable (CanvasSurfaceEvent) async -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = queue
        doorbell = continuation
        consumer = Task {
            // A ring can stand for many events, so each one drains the queue.
            for await _ in stream {
                while let event = queue.pop() {
                    await deliver(event)
                }
            }
        }
    }

    deinit {
        finish()
    }

    public func submit(_ event: CanvasSurfaceEvent) {
        guard queue.push(event) else { return }
        doorbell.yield()
    }

    /// Stops accepting events. What was already queued is still delivered, so
    /// a key release or focus loss sent just before teardown is not lost.
    public func finish() {
        guard queue.finish() else { return }
        doorbell.yield()
        doorbell.finish()
    }

    /// Returns once everything queued before `finish()` has been delivered.
    public func waitUntilFinished() async {
        await consumer.value
    }
}
