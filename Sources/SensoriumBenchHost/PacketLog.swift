import Foundation

/// The lines of the stand-in's packet log, one JSON object each, keys sorted.
/// Every `t` is the host's monotonic clock in nanoseconds.
enum PacketLogLine {
    /// An encoded packet as the pipeline hands it to the send queue.
    /// `parameterSetHex` is the sequence parameter set a key frame carries,
    /// from which the size the encoder produced can be read back.
    static func packet(
        atNanoseconds time: Int64,
        sequence: UInt64,
        isKeyFrame: Bool,
        bytes: Int,
        parameterSetHex: String?
    ) -> String {
        var fields: [String: Any] = [
            "kind": "packet", "t": time, "seq": sequence, "key": isKeyFrame, "bytes": bytes
        ]
        fields["sps"] = parameterSetHex
        return line(fields)
    }

    /// What the viewer last reported about itself, as the host received it.
    /// A figure the viewer had not measured yet is `null`.
    static func viewer(
        atNanoseconds time: Int64,
        presentedFramesPerSecond: Double?,
        decodedFramesPerSecond: Double?,
        receivedBitsPerSecond: Double?
    ) -> String {
        line([
            "kind": "viewer", "t": time,
            "presentedFps": presentedFramesPerSecond ?? NSNull(),
            "decodedFps": decodedFramesPerSecond ?? NSNull(),
            "receivedBps": receivedBitsPerSecond ?? NSNull()
        ])
    }

    /// The sizes a stream is encoded at, written each time a pipeline comes
    /// up. `moving` is `nil` for a stream with no smaller size for motion.
    static func configuration(atNanoseconds time: Int64, settled: String, moving: String?) -> String {
        line(["kind": "config", "t": time, "settled": settled, "moving": moving ?? NSNull()])
    }

    private static func line(_ fields: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"kind":"error"}"#
        }
        return text
    }
}

/// An append-only file of `PacketLogLine`s. Packets arrive from the encoder's
/// own threads, so each write is made under a lock.
final class PacketLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}
