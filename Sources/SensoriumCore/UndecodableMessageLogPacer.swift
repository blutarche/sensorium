import Foundation

/// Paces the log line a live session writes when it drops a control message
/// it could not read. Input arrives at well over a hundred events a second,
/// and a newer peer sending one kind of message this build cannot read
/// would otherwise put a line in the log for every one of them.
///
/// One pacer belongs to one session's receive loop and is never shared.
public struct UndecodableMessageLogPacer: Sendable {
    /// At most one line in this long.
    public static let intervalNanoseconds: Int64 = 10_000_000_000

    private var lastLineAtNanoseconds: Int64?
    private var unreportedDrops = 0

    public init() {}

    /// Counts one dropped message, read off a monotonic clock in
    /// nanoseconds. Returns how many messages the line due now reports, this
    /// one and every drop since the last line included, or `nil` when the
    /// last line went out less than `intervalNanoseconds` ago.
    public mutating func noteDrop(atNanoseconds now: Int64) -> Int? {
        unreportedDrops += 1
        if let lastLineAtNanoseconds, now - lastLineAtNanoseconds < Self.intervalNanoseconds {
            return nil
        }
        lastLineAtNanoseconds = now
        defer { unreportedDrops = 0 }
        return unreportedDrops
    }
}
