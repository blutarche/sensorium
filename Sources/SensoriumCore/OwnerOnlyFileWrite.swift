import Foundation

public enum OwnerOnlyFileWriteError: Error, LocalizedError {
    case couldNotCreateTemporaryFile(String, errno: Int32)
    case couldNotWrite(String, errno: Int32)
    case couldNotReplace(String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case let .couldNotCreateTemporaryFile(path, code),
             let .couldNotWrite(path, code),
             let .couldNotReplace(path, code):
            return "\(path) could not be written (\(String(cString: strerror(code))))"
        }
    }
}

/// Writes a file so that its owner is the only account that can read it, and
/// so that a reader of the destination path sees either the whole previous
/// file or the whole new one.
///
/// The bytes go to a temporary file in the same directory, created with
/// owner-only permissions and flushed to the disk, which is then renamed
/// over the destination. `rename` replaces the destination in one step
/// within a filesystem, and carries the temporary file's own permissions
/// with it, so the file is never briefly world-readable and never briefly
/// half-written. A crash between the two can leave the temporary file
/// behind; `removeStalePartialFiles(for:)` clears those.
public enum OwnerOnlyFileWrite {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A directory another store created first may be looser than this
        // one needs, and `createDirectory` leaves an existing one alone.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporary = directory.appendingPathComponent(
            "\(partialPrefix(for: url))\(UUID().uuidString)"
        )
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw OwnerOnlyFileWriteError.couldNotCreateTemporaryFile(temporary.path, errno: errno)
        }

        do {
            try writeAll(data, to: descriptor, path: temporary.path)
            guard fsync(descriptor) == 0 else {
                throw OwnerOnlyFileWriteError.couldNotWrite(temporary.path, errno: errno)
            }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        close(descriptor)

        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw OwnerOnlyFileWriteError.couldNotReplace(url.path, errno: code)
        }

        // The rename itself is a change to the directory, and reaches the
        // disk only when the directory does.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Removes temporary files an interrupted write left beside `url`. Safe
    /// to call before every read: it matches only this writer's own names
    /// for this one destination.
    public static func removeStalePartialFiles(for url: URL) {
        let directory = url.deletingLastPathComponent()
        let prefix = partialPrefix(for: url)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func partialPrefix(for url: URL) -> String {
        ".\(url.lastPathComponent).partial-"
    }

    /// One `write` call can take fewer bytes than it was given, and can be
    /// interrupted by a signal without having failed.
    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                Darwin.write(descriptor, buffer.baseAddress! + offset, data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw OwnerOnlyFileWriteError.couldNotWrite(path, errno: errno)
            }
            offset += written
        }
    }
}
