import Foundation
import SensoriumCore

/// Where one surface's encoded packets go once they are off the socket.
///
/// Separate from `CanvasSurfaceWindow` because it is reached from whatever
/// thread read the socket, never from the main actor. A window draws, handles
/// input and lays out its own chrome on the main actor; a packet that had to
/// wait for all of that would arrive in a burst with the frames behind it, and
/// a burst is exactly what makes a viewer give up a whole group of frames.
public protocol SurfaceVideoReceiving: AnyObject, Sendable {
    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws
}

/// One window's video entry point, held apart from the window so the socket
/// can reach the decoder without the main actor in between.
///
/// Holds the window's receipt ledger and whichever decode queue the window's
/// current decode session created. Both are safe to touch from any thread; the
/// only thing this adds is the pairing between them, behind a lock, so the
/// queue can be replaced by `startDecoding`/`stopDecoding` while packets are
/// arriving.
public final class SurfaceVideoSink: SurfaceVideoReceiving, @unchecked Sendable {
    /// Carries the viewer-side receive time to the decoder's own output
    /// callback. Owned here rather than by the window, because this is where
    /// the receipt is written and the window never touches it off the main
    /// actor.
    public let receipts = FrameReceiptLedger()

    private let lock = NSLock()
    private var queue: VideoDecodeQueue?

    public init() {}

    /// Points this sink at the decode queue a decode session just created, or
    /// at nothing once that session has stopped.
    public func attach(_ queue: VideoDecodeQueue?) {
        lock.lock()
        self.queue = queue
        lock.unlock()
    }

    /// Takes one packet and returns. A decode that failed on the decode queue's
    /// own thread is thrown here, at the next packet, which is the path a
    /// failing decode has always ended the session through.
    public func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {
        lock.lock()
        let queue = queue
        lock.unlock()
        if let failure = queue?.takeFailure() {
            throw failure
        }
        receipts.record(
            presentationTimeNanoseconds: Int64(bitPattern: packet.presentationTimeNanoseconds),
            receivedAtNanoseconds: receivedAtNanoseconds
        )
        queue?.submit(packet)
    }
}
