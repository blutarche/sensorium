import Foundation
import SensoriumCore

/// Decodes one surface's packets away from whoever is reading the socket.
///
/// Decoding on the read path makes reading and decoding one piece of work:
/// while a frame is being decoded nothing is being read, so the frames that
/// keep arriving pile up in the transport's own buffers instead. Nothing can
/// skip a frame while it sits there, and nothing measures it either, so the
/// picture ends up a whole buffer behind with no counter anywhere to say so.
/// `submit(_:)` therefore returns as soon as it has taken the packet.
///
/// The decode itself runs on this object's own serial queue. Serial because
/// every frame but a key frame is a difference from the frame before it, so the
/// order they are decoded in is not a choice. What gets given up when packets
/// arrive faster than they can be decoded is `UndecodedFrameBacklog`'s
/// decision, not this type's.
public final class VideoDecodeQueue: @unchecked Sendable {
    /// Handed one packet at a time, always from this object's serial queue.
    public typealias Decode = @Sendable (EncodedVideoFramePacket) throws -> Void

    private let lock = NSLock()
    private var backlog: UndecodedFrameBacklog
    private var isDecoding = false
    private var isStopped = false
    private var failure: Error?
    private let queue: DispatchQueue
    private let decode: Decode
    private let drops: ViewerFrameDropCounter?

    /// `queue` is injectable so a test can hand in a queue it also drives, and
    /// prove the decode really did happen off the submitting thread.
    public init(
        maximumPending: Int = UndecodedFrameBacklog.defaultMaximumPending,
        drops: ViewerFrameDropCounter? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.sensorium.viewer-decode", qos: .userInteractive),
        decode: @escaping Decode
    ) {
        backlog = UndecodedFrameBacklog(maximumPending: maximumPending)
        self.drops = drops
        self.queue = queue
        self.decode = decode
    }

    /// Takes one packet and returns. Whatever admitting it cost is counted
    /// here, not reported: a caller reading the socket has nothing useful to do
    /// about a frame this viewer chose to skip.
    public func submit(_ packet: EncodedVideoFramePacket) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        let dropped = backlog.admit(packet)
        let shouldStart = !isDecoding && backlog.count > 0
        if shouldStart {
            isDecoding = true
        }
        lock.unlock()
        drops?.recordDroppedBeforeDecode(dropped)
        guard shouldStart else { return }
        queue.async { [weak self] in
            self?.decodePending()
        }
    }

    /// The first decode failure since this was last read, and nothing
    /// afterwards. Decoding no longer happens on the read path, so a failure
    /// can no longer be thrown at whoever handed the packet over; the window
    /// reads this on its next receive and throws it there instead, which ends
    /// the session through the path it always ended through.
    public func takeFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        let taken = failure
        failure = nil
        return taken
    }

    /// Whether the last packets admitted cost their whole group of frames, so
    /// nothing new will be shown until the next key frame arrives.
    public var isAwaitingKeyFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backlog.isAwaitingKeyFrame
    }

    /// Gives up everything waiting and takes nothing further. A decode already
    /// running finishes: it holds the decoder's own lock, and whoever is about
    /// to reset that decoder waits on it.
    public func stop() {
        lock.lock()
        isStopped = true
        backlog.reset()
        failure = nil
        lock.unlock()
    }

    private func decodePending() {
        while true {
            lock.lock()
            guard !isStopped, let packet = backlog.takeNext() else {
                isDecoding = false
                lock.unlock()
                return
            }
            lock.unlock()
            do {
                try decode(packet)
            } catch {
                lock.lock()
                if failure == nil {
                    failure = error
                }
                lock.unlock()
            }
        }
    }
}
