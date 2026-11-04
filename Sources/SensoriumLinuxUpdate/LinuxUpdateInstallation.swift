import Foundation
import SensoriumCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LinuxUpdateNotUpdatableReason: Equatable, Sendable {
    /// The data root does not exist and could not be made.
    case dataRootUnavailable
    case dataRootNotADirectory
    case dataRootNotOwned
    case dataRootWritableByOthers
    case dataRootNotWritable
    /// `versions` is a link, not owned by this user, or writable by others.
    case versionsFolderUnsafe
    /// `current` exists and is not a symbolic link, so it cannot be switched.
    case currentNotALink
}

public enum LinuxUpdateInstallability: Equatable, Sendable {
    case updatable
    case notUpdatable(LinuxUpdateNotUpdatableReason)
}

/// A new version in place in `versions/<version>`, tested, not switched to
/// yet.
public struct LinuxStagedUpdate: Equatable, Sendable {
    public let version: LinuxUpdateVersion
    /// The archive's SHA-256, which keys any failure recorded against it.
    public let sha256: String
    public let executable: URL

    public init(version: LinuxUpdateVersion, sha256: String, executable: URL) {
        self.version = version
        self.sha256 = sha256
        self.executable = executable
    }
}

/// `update-pending.json`: a switch the new version has not confirmed yet.
public struct LinuxUpdatePendingSwitch: Codable, Equatable, Sendable {
    public let version: LinuxUpdateVersion
    public let sha256: String
    /// What `current` named before the switch. Nil for the first update of a
    /// viewer installed by the package, which had no `current`.
    public let previous: LinuxUpdateVersion?

    public init(version: LinuxUpdateVersion, sha256: String, previous: LinuxUpdateVersion?) {
        self.version = version
        self.sha256 = sha256
        self.previous = previous
    }
}

/// How this process was started, for `rollbackIfUnconfirmed(startup:)`.
public enum LinuxUpdateStartup: Equatable, Sendable {
    /// Any launch but the one below.
    case normal
    /// Started with `--replacing` by the old viewer, running this version.
    case replacing(LinuxUpdateVersion)
}

public enum LinuxUpdateRollback: Equatable, Sendable {
    case nothingPending
    /// This process is the new version the switch waits on. It calls
    /// `markConfirmed(version:)` once its window is up.
    case awaitingConfirmation(LinuxUpdatePendingSwitch)
    /// `current` names the previous version again, or is gone when there was
    /// none. The caller records `.readyLate` against the pending version.
    case rolledBack(LinuxUpdatePendingSwitch)
    /// `current` could not be switched back. The marker stays, so the next
    /// launch tries again.
    case failed(LinuxUpdatePendingSwitch)
}

public enum LinuxUpdateConfirmation: Equatable, Sendable {
    case confirmed
    case nothingPending
    /// The pending switch is for another version, or `current` no longer
    /// names it. Nothing changed.
    case notPending
}

/// Where the Linux viewer installs its own versions, as section 11.3 of
/// `docs/self-update-design.md` describes:
///
///     <data root>/versions/<version>/Sensorium
///     <data root>/current -> versions/<version>
///     <data root>/update-pending.json
///
/// `current` only ever changes by `rename(2)` of a new link over it, so a
/// reader always finds the old target or the new one. The pending marker is
/// on disk before `current` moves. The steps that change the layout hold an
/// exclusive lock on `.update.lock`, because the old and the new viewer both
/// touch it during a handoff.
public struct LinuxUpdateInstallation: Sendable {
    public static let versionsDirectoryName = "versions"
    public static let currentLinkName = "current"
    public static let pendingMarkerName = "update-pending.json"
    public static let executableName = LinuxUpdateArchive.binaryName
    /// Versions kept below the current one after a confirmed switch.
    public static let previousVersionsKept = 2

    static let lockName = ".update.lock"
    static let stagingPrefix = ".staging-"

    public let dataRoot: URL

    public init(dataRoot: URL = LinuxUpdateInstallation.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    /// `$XDG_DATA_HOME/sensorium`, or `~/.local/share/sensorium` where that
    /// variable is unset or empty: the folder the viewer keeps its own
    /// records in, resolved by the same rule.
    public static func defaultDataRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base: URL
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return base.appendingPathComponent("sensorium", isDirectory: true)
    }

    public var versionsDirectory: URL {
        dataRoot.appendingPathComponent(Self.versionsDirectoryName, isDirectory: true)
    }

    public var currentLink: URL {
        dataRoot.appendingPathComponent(Self.currentLinkName)
    }

    /// What the launcher entry runs.
    public var currentExecutable: URL {
        currentLink.appendingPathComponent(Self.executableName)
    }

    public var pendingMarker: URL {
        dataRoot.appendingPathComponent(Self.pendingMarkerName)
    }

    public func versionDirectory(for version: LinuxUpdateVersion) -> URL {
        versionsDirectory.appendingPathComponent(version.description, isDirectory: true)
    }

    // MARK: Installability

    /// Makes the data root, owner-only, if it does not exist yet, then
    /// checks that this user owns it and alone may write it, and the same of
    /// `versions` where it exists.
    public func installability(userID: uid_t = getuid()) -> LinuxUpdateInstallability {
        if lstatInfo(dataRoot.path) == nil {
            do {
                try makeOwnerOnlyDirectory(dataRoot)
            } catch {
                return .notUpdatable(.dataRootUnavailable)
            }
        }
        var root = stat()
        guard stat(dataRoot.path, &root) == 0 else {
            return .notUpdatable(.dataRootUnavailable)
        }
        guard root.st_mode & S_IFMT == S_IFDIR else {
            return .notUpdatable(.dataRootNotADirectory)
        }
        guard root.st_uid == userID else {
            return .notUpdatable(.dataRootNotOwned)
        }
        guard root.st_mode & 0o022 == 0 else {
            return .notUpdatable(.dataRootWritableByOthers)
        }
        guard access(dataRoot.path, W_OK | X_OK) == 0 else {
            return .notUpdatable(.dataRootNotWritable)
        }
        if let versions = lstatInfo(versionsDirectory.path) {
            guard versions.st_mode & S_IFMT == S_IFDIR, versions.st_uid == userID, versions.st_mode & 0o022 == 0 else {
                return .notUpdatable(.versionsFolderUnsafe)
            }
        }
        if let current = lstatInfo(currentLink.path), current.st_mode & S_IFMT != S_IFLNK {
            return .notUpdatable(.currentNotALink)
        }
        return .updatable
    }

    // MARK: Reading the layout

    /// The version `current` names, or nil when there is no `current` or it
    /// names anything but `versions/<version>`.
    public func currentVersion() -> LinuxUpdateVersion? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path) else {
            return nil
        }
        let prefix = Self.versionsDirectoryName + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return LinuxUpdateVersion(String(target.dropFirst(prefix.count)))
    }

    /// Every folder in `versions` named as a version, lowest first.
    public func installedVersions() -> [LinuxUpdateVersion] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory.path)) ?? []
        return names.compactMap { name in
            guard let version = LinuxUpdateVersion(name),
                  lstatInfo(versionDirectory(for: version).path).map({ $0.st_mode & S_IFMT == S_IFDIR }) == true else {
                return nil
            }
            return version
        }.sorted()
    }

    /// An unreadable marker reads as nil.
    public func pendingSwitch() -> LinuxUpdatePendingSwitch? {
        guard let data = try? Data(contentsOf: pendingMarker) else { return nil }
        return try? JSONDecoder().decode(LinuxUpdatePendingSwitch.self, from: data)
    }

    // MARK: Staging

    /// A new, empty, owner-only folder under `versions`, on the same
    /// filesystem as the versions, so moving it into place is one rename.
    public func makeStagingDirectory() throws -> URL {
        try makeOwnerOnlyDirectory(dataRoot)
        try makeOwnerOnlyDirectory(versionsDirectory)
        let directory = versionsDirectory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0, chmod(directory.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }

    /// Renames a tested staging folder to `versions/<version>`, replacing a
    /// folder of that version left by an earlier try. The version `current`
    /// names is never replaced.
    func moveIntoPlace(_ staging: URL, as version: LinuxUpdateVersion) -> URL? {
        withLock { () -> URL? in
            guard currentVersion() != version else { return nil }
            let destination = versionDirectory(for: version)
            if lstatInfo(destination.path) != nil {
                guard (try? FileManager.default.removeItem(at: destination)) != nil else { return nil }
            }
            guard rename(staging.path, destination.path) == 0 else { return nil }
            syncDirectory(versionsDirectory)
            return destination
        } ?? nil
    }

    // MARK: Switching

    /// Writes the pending marker, then points `current` at the staged
    /// version. Call right before starting the new version with
    /// `--replacing`: any other launch that finds the marker rolls the
    /// switch back.
    public func switchCurrent(to staged: LinuxStagedUpdate) -> LinuxUpdateFailure? {
        withLock { () -> LinuxUpdateFailure? in
            let executable = versionDirectory(for: staged.version).appendingPathComponent(Self.executableName)
            guard lstatInfo(executable.path).map({ $0.st_mode & S_IFMT == S_IFREG }) == true else {
                return .switchFailed
            }
            let pending = LinuxUpdatePendingSwitch(version: staged.version, sha256: staged.sha256, previous: currentVersion())
            do {
                try OwnerOnlyFileWrite.write(try JSONEncoder().encode(pending), to: pendingMarker)
            } catch {
                return .switchFailed
            }
            guard point(currentAt: staged.version) else {
                unlink(pendingMarker.path)
                syncDirectory(dataRoot)
                return .switchFailed
            }
            return nil
        } ?? .switchFailed
    }

    /// Called by the new version once its window is up: removes the pending
    /// marker, then removes every version but the current one and the
    /// `previousVersionsKept` highest below it.
    public func markConfirmed(version: LinuxUpdateVersion) -> LinuxUpdateConfirmation {
        withLock { () -> LinuxUpdateConfirmation in
            guard lstatInfo(pendingMarker.path) != nil else { return .nothingPending }
            guard let pending = pendingSwitch(), pending.version == version, currentVersion() == version else {
                return .notPending
            }
            guard unlink(pendingMarker.path) == 0 else { return .notPending }
            syncDirectory(dataRoot)
            prune(keeping: version)
            return .confirmed
        } ?? .notPending
    }

    /// Step 6 of section 11.4: before a window shows, a pending switch that
    /// this process is not the awaited version of was never confirmed, and
    /// is rolled back.
    public func rollbackIfUnconfirmed(startup: LinuxUpdateStartup) -> LinuxUpdateRollback {
        withLock { () -> LinuxUpdateRollback in
            guard lstatInfo(pendingMarker.path) != nil else { return .nothingPending }
            guard let pending = pendingSwitch() else {
                // The marker is written atomically, so this is not a switch
                // in progress; nothing says which version to go back to.
                unlink(pendingMarker.path)
                syncDirectory(dataRoot)
                return .nothingPending
            }
            if case let .replacing(running) = startup, running == pending.version {
                return .awaitingConfirmation(pending)
            }
            return switchBack(pending)
        } ?? .nothingPending
    }

    /// Step 5 of section 11.4: the old viewer's wait for the ready file ran
    /// out. Rolls back whatever switch is pending.
    public func rollBack() -> LinuxUpdateRollback {
        withLock { () -> LinuxUpdateRollback in
            guard let pending = pendingSwitch() else { return .nothingPending }
            return switchBack(pending)
        } ?? .nothingPending
    }

    /// `current` goes back first and the marker goes after, so an
    /// interruption between the two leaves a marker the next launch rolls
    /// back again, to the same place.
    private func switchBack(_ pending: LinuxUpdatePendingSwitch) -> LinuxUpdateRollback {
        let restored: Bool
        if let previous = pending.previous,
           lstatInfo(versionDirectory(for: previous).appendingPathComponent(Self.executableName).path) != nil {
            restored = point(currentAt: previous)
        } else {
            restored = unlink(currentLink.path) == 0 || errno == ENOENT
            syncDirectory(dataRoot)
        }
        guard restored else { return .failed(pending) }
        unlink(pendingMarker.path)
        syncDirectory(dataRoot)
        return .rolledBack(pending)
    }

    /// A new relative link renamed over `current`.
    private func point(currentAt version: LinuxUpdateVersion) -> Bool {
        let temporary = dataRoot.appendingPathComponent(".\(Self.currentLinkName)-\(UUID().uuidString)")
        guard symlink("\(Self.versionsDirectoryName)/\(version)", temporary.path) == 0 else { return false }
        guard rename(temporary.path, currentLink.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        syncDirectory(dataRoot)
        return true
    }

    private func prune(keeping current: LinuxUpdateVersion) {
        let below = installedVersions().filter { $0 < current }
        let kept = Set(below.suffix(Self.previousVersionsKept) + [current])
        for version in installedVersions() where !kept.contains(version) {
            try? FileManager.default.removeItem(at: versionDirectory(for: version))
        }
        syncDirectory(versionsDirectory)
    }

    // MARK: Helpers

    /// Nil when the lock cannot be taken.
    private func withLock<T>(_ body: () -> T) -> T? {
        guard (try? makeOwnerOnlyDirectory(dataRoot)) != nil else { return nil }
        let descriptor = open(dataRoot.appendingPathComponent(Self.lockName).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return nil }
        }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private func makeOwnerOnlyDirectory(_ url: URL) throws {
        if lstatInfo(url.path) == nil {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 {
            fsync(descriptor)
            close(descriptor)
        }
    }
}

func lstatInfo(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}
