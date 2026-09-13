import Foundation

public enum MonotonicClock {
    /// `CLOCK_UPTIME_RAW` is the same timebase ScreenCaptureKit and
    /// VideoToolbox stamp their sample buffers with, so a capture timestamp and
    /// a present timestamp taken on the same machine are directly comparable.
    public static func nowNanoseconds() -> Int64 {
        Int64(bitPattern: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }
}

public enum LatencyTraceWriterError: Error, Equatable {
    case directoryDoesNotExist(String)
    case cannotOpen(String)
}

/// Appends per-stage percentile lines as JSONL. Opt-in: nothing constructs one
/// unless the operator asked for a trace, and it never creates directories, so a
/// mistyped path fails loudly instead of scattering files.
public final class LatencyTraceWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let sessionLabel: String
    private let lock = NSLock()

    public init(url: URL, sessionLabel: String) throws {
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LatencyTraceWriterError.directoryDoesNotExist(parent.path)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw LatencyTraceWriterError.cannotOpen(url.path)
            }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw LatencyTraceWriterError.cannotOpen(url.path)
        }
        handle.seekToEndOfFile()
        self.handle = handle
        self.sessionLabel = sessionLabel
    }

    public func write(_ metrics: SessionMetrics) throws {
        let payload = metrics.traceLines(session: sessionLabel)
            .map { $0 + "\n" }
            .joined()
        guard !payload.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: Data(payload.utf8))
    }

    public func close() {
        try? handle.close()
    }
}
