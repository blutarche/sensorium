import Foundation

/// Whether the shortcut strip's pin button is on, remembered across launches.
/// One record for the whole viewer, not one per machine: pinning is a habit
/// of the person at this machine, not a fact about any one host, so it
/// is not keyed by `hostPublicKey` the way `HostScreenModeMemoryRecord` is.
public struct ShortcutStripPinRecord: Codable, Equatable, Sendable {
    public let isPinned: Bool

    public init(isPinned: Bool) {
        self.isPinned = isPinned
    }
}

/// How the pin file is read and written -- the one decision that can lose a
/// remembered pin, kept apart from the file store itself so it is verified
/// without writing anything. A file that is not this shape at all -- corrupt,
/// or simply absent -- reads as unpinned, the same restraint
/// `HostScreenModeMemoryFileCoding` already takes with a mode-memory file
/// that fails to decode.
public enum ShortcutStripPinFileCoding {
    public static func decode(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(ShortcutStripPinRecord.self, from: data))?.isPinned ?? false
    }

    public static func encode(_ isPinned: Bool) -> Data? {
        try? JSONEncoder().encode(ShortcutStripPinRecord(isPinned: isPinned))
    }
}

/// Where the strip's pin state is kept, so pinning it once means it is still
/// pinned the next time this viewer opens a session.
public protocol ShortcutStripPinMemoryStoring: Sendable {
    func isPinned() -> Bool
    func remember(isPinned: Bool)
}

public final class InMemoryShortcutStripPinMemoryStore: ShortcutStripPinMemoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: Bool

    public init(isPinned: Bool = false) {
        self.pinned = isPinned
    }

    public func isPinned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinned
    }

    public func remember(isPinned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pinned = isPinned
    }
}

/// Writes one JSON file at an explicitly supplied URL, owner-only -- the same
/// posture `FileHostScreenModeMemoryStore` already takes for a file under
/// this viewer's own Application Support directory, even though a pin is not
/// a secret: nothing about it should be readable by another account on the
/// same machine. No test executes this: it would write outside the repository.
/// What an unreadable file means is `ShortcutStripPinFileCoding`'s decision,
/// which is verified.
public final class FileShortcutStripPinMemoryStore: ShortcutStripPinMemoryStoring, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func isPinned() -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return ShortcutStripPinFileCoding.decode(data)
    }

    public func remember(isPinned: Bool) {
        guard let data = ShortcutStripPinFileCoding.encode(isPinned) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
        // An atomic write replaces the file, so the permission is set on what
        // the write actually left behind rather than on whatever was there
        // before it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
