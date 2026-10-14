import Foundation

/// The key frames one surface finished writing over one reporting window: how
/// many, the largest, and the slowest write. A write is timed from the moment
/// it starts to the moment it completes, so time a frame spent waiting behind
/// another one is not part of it. A write that failed put nothing on the wire
/// and is not counted.
public struct KeyFrameSendWindow: Equatable, Sendable {
    public private(set) var count = 0
    /// Payload plus codec configuration, the basis every other byte count of
    /// this host's video uses.
    public private(set) var largestBytes = 0
    public private(set) var slowestNanoseconds: Int64 = 0

    public init() {}

    public mutating func record(bytes: Int, nanoseconds: Int64) {
        count += 1
        largestBytes = max(largestBytes, bytes)
        slowestNanoseconds = max(slowestNanoseconds, nanoseconds)
    }
}

/// One `KeyFrameSendWindow` per surface, written as each write completes and
/// taken by whoever writes the window's log line, which starts the next one.
final class KeyFrameSendWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var windows = [KeyFrameSendWindow](repeating: KeyFrameSendWindow(), count: CanvasSurfaceID.capacity)

    func record(bytes: Int, nanoseconds: Int64, surface: CanvasSurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        windows[surface.index].record(bytes: bytes, nanoseconds: nanoseconds)
    }

    func take(for surface: CanvasSurfaceID) -> KeyFrameSendWindow {
        lock.lock()
        defer { lock.unlock() }
        let taken = windows[surface.index]
        windows[surface.index] = KeyFrameSendWindow()
        return taken
    }
}
