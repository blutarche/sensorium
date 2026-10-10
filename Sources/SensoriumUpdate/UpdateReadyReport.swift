#if os(macOS)
import Foundation
import ServiceManagement

/// The new instance's own account of itself, written to the ready file once
/// it serves (host) or its window is up (viewer). The old instance builds
/// the same report from its own running state as the baseline to compare.
public struct UpdateReadyReport: Codable, Equatable, Sendable {
    /// What the host serves with. Every value must be unchanged.
    public struct Host: Codable, Equatable, Sendable {
        public var identityFingerprint: String
        public var pairedMachinesDigest: String
        public var tailnetAddress: String
        public var port: UInt16
        /// Nil when the listener is not scoped to one interface.
        public var interfaceName: String?
        public var allowsLocalNetwork: Bool

        public init(
            identityFingerprint: String,
            pairedMachinesDigest: String,
            tailnetAddress: String,
            port: UInt16,
            interfaceName: String?,
            allowsLocalNetwork: Bool
        ) {
            self.identityFingerprint = identityFingerprint
            self.pairedMachinesDigest = pairedMachinesDigest
            self.tailnetAddress = tailnetAddress
            self.port = port
            self.interfaceName = interfaceName
            self.allowsLocalNetwork = allowsLocalNetwork
        }
    }

    /// The names `SMAppService.Status` reports, as `loginItemStatus` holds
    /// them.
    public enum LoginItemStatus {
        public static let enabled = "enabled"
        public static let notRegistered = "notRegistered"
        public static let requiresApproval = "requiresApproval"
        public static let notFound = "notFound"

        public static func name(of status: SMAppService.Status) -> String {
            switch status {
            case .enabled: enabled
            case .notRegistered: notRegistered
            case .requiresApproval: requiresApproval
            case .notFound: notFound
            @unknown default: notFound
            }
        }

        /// This app's own login item status. Reads it only; registers
        /// nothing.
        public static func current() -> String {
            name(of: SMAppService.mainApp.status)
        }
    }

    /// The ready file is a few hundred bytes; anything far larger is not one.
    static let maximumFileSize = 64 * 1024

    public var version: UpdateVersion
    /// Nil where the app does not track the permission, as in the viewer.
    public var screenRecordingGranted: Bool?
    public var accessibilityGranted: Bool?
    public var loginItemStatus: String
    /// Present for the host alone.
    public var host: Host?
    /// The process that wrote the report. `UpdateHandoff.reportReady` fills
    /// it in, and the old instance accepts the report only from the process
    /// it launched.
    public var processIdentifier: pid_t?

    public init(
        version: UpdateVersion,
        screenRecordingGranted: Bool?,
        accessibilityGranted: Bool?,
        loginItemStatus: String,
        host: Host?,
        processIdentifier: pid_t? = nil
    ) {
        self.version = version
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
        self.loginItemStatus = loginItemStatus
        self.host = host
        self.processIdentifier = processIdentifier
    }

    /// Nil when this report may replace `baseline`: it comes from
    /// `expectedVersion`, no permission went from granted to anything else,
    /// an enabled login item is still enabled, and the host values are
    /// unchanged. Otherwise names what differs.
    public func mismatch(comparedWith baseline: UpdateReadyReport, expectedVersion: UpdateVersion) -> String? {
        if version != expectedVersion {
            return "version"
        }
        if baseline.screenRecordingGranted == true, screenRecordingGranted != true {
            return "Screen Recording"
        }
        if baseline.accessibilityGranted == true, accessibilityGranted != true {
            return "Accessibility"
        }
        if baseline.loginItemStatus == LoginItemStatus.enabled, loginItemStatus != LoginItemStatus.enabled {
            return "Open at login"
        }
        if host != baseline.host {
            return "host"
        }
        return nil
    }

    /// Nil when the file is missing, oversized, not a regular file, or not a
    /// report.
    public static func read(from url: URL) -> UpdateReadyReport? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumFileSize,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(UpdateReadyReport.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.writeOwnerOnly(try encoder.encode(self), named: url.lastPathComponent, into: url.deletingLastPathComponent())
    }

    /// Writes `data` as `name` in `folder`, which must already be a folder
    /// owned by this user with mode 0700; it is never created or changed.
    /// The folder is opened once, checked through that descriptor, and the
    /// file is written relative to it, so a folder swapped in after the
    /// check is not the one written to. The bytes go to an owner-only
    /// temporary file first, renamed over `name` in one step.
    private static func writeOwnerOnly(_ data: Data, named name: String, into folder: URL) throws {
        let folderDescriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderDescriptor >= 0 else {
            switch errno {
            case ENOENT: throw UpdateReadyFileError.folderMissing
            case ELOOP, ENOTDIR: throw UpdateReadyFileError.notAFolder
            case let code: throw UpdateReadyFileError.couldNotWrite(errno: code)
            }
        }
        defer { close(folderDescriptor) }
        var info = stat()
        guard fstat(folderDescriptor, &info) == 0 else {
            throw UpdateReadyFileError.couldNotWrite(errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw UpdateReadyFileError.notAFolder
        }
        guard info.st_uid == geteuid() else {
            throw UpdateReadyFileError.notOwnedByThisUser
        }
        guard info.st_mode & 0o7777 == 0o700 else {
            throw UpdateReadyFileError.notOwnerOnly
        }

        let temporary = ".\(name).partial-\(UUID().uuidString)"
        let fileDescriptor = openat(folderDescriptor, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw UpdateReadyFileError.couldNotWrite(errno: errno)
        }
        do {
            try writeAll(data, to: fileDescriptor)
            guard fsync(fileDescriptor) == 0 else {
                throw UpdateReadyFileError.couldNotWrite(errno: errno)
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
            throw UpdateReadyFileError.couldNotWrite(errno: code)
        }
        fsync(folderDescriptor)
    }

    /// One `write` call can take fewer bytes than it was given, and can be
    /// interrupted by a signal without having failed.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + offset, data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw UpdateReadyFileError.couldNotWrite(errno: errno)
            }
            offset += written
        }
    }
}
#endif
