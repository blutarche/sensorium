import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What a launch was asked to do. The viewer parses this before any other
/// argument, since an argument it does not know otherwise ends it with a
/// usage message.
public enum LinuxUpdateLaunchCommand: Equatable, Sendable {
    /// Run the self-test and exit with its status.
    case selfTest
    /// This is a new version replacing process `pid`: start normally, then
    /// write the ready report to `readyFile` once the window is up.
    case replacing(pid: pid_t, readyFile: URL)
    /// Anything else, untouched, for the viewer's own parsing.
    case normal([String])

    public static let replacingArgument = "--replacing"

    /// `arguments` excludes the program's own path.
    public static func parse(_ arguments: [String]) -> LinuxUpdateLaunchCommand {
        if arguments == [LinuxUpdateStaging.selfTestArgument] {
            return .selfTest
        }
        if arguments.count == 3,
           arguments[0] == replacingArgument,
           let pid = pid_t(arguments[1]), pid > 0,
           isReadyFilePath(arguments[2]) {
            return .replacing(pid: pid, readyFile: URL(fileURLWithPath: arguments[2]))
        }
        return .normal(arguments)
    }

    public static func replacingArguments(pid: pid_t, readyFile: URL) -> [String] {
        [replacingArgument, String(pid), readyFile.path]
    }

    /// An absolute path, in a folder below the root, whose last part is the
    /// ready file's name, and with no empty, `.` or `..` part, so the folder
    /// it names is the one it spells.
    private static func isReadyFilePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts.last == Substring(LinuxUpdateHandoff.readyFileName) else {
            return false
        }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// The new version's account of itself, written to the ready file once its
/// window is up.
public struct LinuxUpdateReadyReport: Codable, Equatable, Sendable {
    /// The process that wrote the report. The old viewer accepts it only
    /// from the process it started.
    public var processIdentifier: pid_t
    public var version: LinuxUpdateVersion

    public init(processIdentifier: pid_t, version: LinuxUpdateVersion) {
        self.processIdentifier = processIdentifier
        self.version = version
    }
}

/// Why `LinuxUpdateHandoff.reportReady` wrote no ready file.
public enum LinuxUpdateReadyFileError: Error, Equatable, Sendable {
    case folderMissing
    /// The path names a symbolic link or a file, not a folder.
    case notAFolder
    case notOwnedByThisUser
    /// The folder's mode is anything but 0700.
    case notOwnerOnly
    case couldNotWrite(errno: Int32)
}

/// Both sides of the ready file that ends a restart into a new version.
public enum LinuxUpdateHandoff {
    public static let readyFileName = "update-ready.json"
    static let folderPrefix = ".handoff-"
    /// The ready file is a few dozen bytes; anything far larger is not one.
    static let maximumReportSize = 64 * 1024

    /// A new, empty, owner-only folder in the data root for the new
    /// version's ready file. The old viewer removes it when the handoff
    /// ends either way.
    public static func makeFolder(in installation: LinuxUpdateInstallation) throws -> URL {
        let folder = installation.dataRoot.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0, chmod(folder.path, 0o700) == 0 else {
            throw LinuxUpdateReadyFileError.couldNotWrite(errno: errno)
        }
        return folder
    }

    /// The path arrives on the command line, so the file is written only
    /// into a folder that already exists, is owned by this user and has
    /// mode 0700. No folder is ever created or changed. The folder is
    /// opened once, checked through that descriptor, and the file is
    /// written relative to it, so a folder swapped in after the check is
    /// not the one written to.
    public static func reportReady(
        version: LinuxUpdateVersion,
        to readyFile: URL,
        processIdentifier: pid_t = getpid()
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LinuxUpdateReadyReport(processIdentifier: processIdentifier, version: version))
        try writeOwnerOnly(data, named: readyFile.lastPathComponent, into: readyFile.deletingLastPathComponent())
    }

    /// Nil when the file is missing, oversized, not a regular file, or not a
    /// report.
    public static func readReport(at readyFile: URL) -> LinuxUpdateReadyReport? {
        guard let info = lstatInfo(readyFile.path),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumReportSize,
              let data = try? Data(contentsOf: readyFile) else {
            return nil
        }
        return try? JSONDecoder().decode(LinuxUpdateReadyReport.self, from: data)
    }

    private static func writeOwnerOnly(_ data: Data, named name: String, into folder: URL) throws {
        let folderDescriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderDescriptor >= 0 else {
            switch errno {
            case ENOENT: throw LinuxUpdateReadyFileError.folderMissing
            case ELOOP, ENOTDIR: throw LinuxUpdateReadyFileError.notAFolder
            case let code: throw LinuxUpdateReadyFileError.couldNotWrite(errno: code)
            }
        }
        defer { close(folderDescriptor) }
        var info = stat()
        guard fstat(folderDescriptor, &info) == 0 else {
            throw LinuxUpdateReadyFileError.couldNotWrite(errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw LinuxUpdateReadyFileError.notAFolder
        }
        guard info.st_uid == geteuid() else {
            throw LinuxUpdateReadyFileError.notOwnedByThisUser
        }
        guard info.st_mode & 0o7777 == 0o700 else {
            throw LinuxUpdateReadyFileError.notOwnerOnly
        }

        let temporary = ".\(name).partial-\(UUID().uuidString)"
        let fileDescriptor = openat(folderDescriptor, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw LinuxUpdateReadyFileError.couldNotWrite(errno: errno)
        }
        do {
            try writeAll(data, to: fileDescriptor)
            guard fsync(fileDescriptor) == 0 else {
                throw LinuxUpdateReadyFileError.couldNotWrite(errno: errno)
            }
        } catch {
            close(fileDescriptor)
            unlinkat(folderDescriptor, temporary, 0)
            throw error
        }
        close(fileDescriptor)
        guard renameat(folderDescriptor, temporary, folderDescriptor, name) == 0 else {
            let code = errno
            unlinkat(folderDescriptor, temporary, 0)
            throw LinuxUpdateReadyFileError.couldNotWrite(errno: code)
        }
        fsync(folderDescriptor)
    }

    /// One `write` call can take fewer bytes than it was given, and can be
    /// interrupted by a signal without having failed.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                systemWrite(descriptor, buffer.baseAddress! + offset, data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw LinuxUpdateReadyFileError.couldNotWrite(errno: errno)
            }
            offset += written
        }
    }

    private static func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(descriptor, bytes, count)
        #else
        Glibc.write(descriptor, bytes, count)
        #endif
    }
}
