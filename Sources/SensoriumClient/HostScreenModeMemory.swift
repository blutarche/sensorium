import Foundation
import SensoriumCore

/// One host screen's resolution, remembered across sessions -- never a
/// `HostScreenModeEntry.modeID`, which `docs/host-screen-design.md` §5.4 states is "opaque to the
/// viewer and stable only for the session it was offered in." A mode ID
/// minted for one connection cannot be echoed into a later one; what
/// survives is the mode's own shape, matched afresh against whatever list
/// the next session offers (`HostScreenModeMatching`).
public struct RememberedHostScreenMode: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let isHiDPI: Bool

    public init(width: Int, height: Int, isHiDPI: Bool) {
        self.width = width
        self.height = height
        self.isHiDPI = isHiDPI
    }

    public init(_ entry: HostScreenModeEntry) {
        self.init(width: entry.width, height: entry.height, isHiDPI: entry.isHiDPI)
    }
}

/// Matches a remembered shape back against a live offer -- the same lookup
/// on both ends of the round trip: `HostScreenModeRestoreDecision` uses it to
/// find the mode ID a remembered shape now has, and `HostScreenModeMemoryUpdate`
/// uses the same modeID lookup in the other direction.
public enum HostScreenModeMatching {
    public static func entry(
        for mode: RememberedHostScreenMode, in modes: [HostScreenModeEntry]
    ) -> HostScreenModeEntry? {
        modes.first { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI == mode.isHiDPI }
    }
}

/// One saved machine's one host screen, and the resolution last chosen for
/// it -- the join key a memory is looked up and written by. `hostPublicKey`
/// is the same pinned key `SavedHostStoring` already keys a machine by;
/// `displayIdentity` is `HostScreenListEntry.displayIdentity`, the one field
/// that stays the same value for the same physical display on every offer
/// this host ever makes, including across a restart -- the mode ID that
/// offer also carries is not, which is why this record does not hold one.
public struct HostScreenModeMemoryRecord: Codable, Equatable, Sendable {
    public let hostPublicKey: Data
    public let displayIdentity: String
    public let mode: RememberedHostScreenMode

    public init(hostPublicKey: Data, displayIdentity: String, mode: RememberedHostScreenMode) {
        self.hostPublicKey = hostPublicKey
        self.displayIdentity = displayIdentity
        self.mode = mode
    }
}

/// The list rule this store's records share: one remembered mode per
/// (machine, host screen) pair. Pure, the same reason `SavedHostList` is --
/// verified without a file.
public enum HostScreenModeMemoryList {
    public static func upserting(
        _ record: HostScreenModeMemoryRecord, into records: [HostScreenModeMemoryRecord]
    ) -> [HostScreenModeMemoryRecord] {
        var result = records
        if let existing = result.firstIndex(where: {
            $0.hostPublicKey == record.hostPublicKey && $0.displayIdentity == record.displayIdentity
        }) {
            result[existing] = record
        } else {
            result.append(record)
        }
        return result
    }
}

/// How the mode-memory file is read and written -- the one decision that can
/// lose a remembered choice, kept apart from the file store itself so it is
/// verified without writing anything. A file that is not this shape at all
/// -- corrupted, or simply absent -- reads as no remembered modes, the same
/// restraint `SavedHostFileCoding` already takes with a saved-machines file
/// that fails to decode.
public enum HostScreenModeMemoryFileCoding {
    public static func decode(_ data: Data) -> [HostScreenModeMemoryRecord] {
        (try? JSONDecoder().decode([HostScreenModeMemoryRecord].self, from: data)) ?? []
    }

    public static func encode(_ records: [HostScreenModeMemoryRecord]) -> Data? {
        try? JSONEncoder().encode(records)
    }
}

/// Where a person's last-chosen host-screen resolution is kept, so choosing
/// it once means never choosing it again for that machine's that screen.
public protocol HostScreenModeMemoryStoring: Sendable {
    func remembered(hostPublicKey: Data, displayIdentity: String) -> RememberedHostScreenMode?
    func remember(hostPublicKey: Data, displayIdentity: String, mode: RememberedHostScreenMode)
}

public final class InMemoryHostScreenModeMemoryStore: HostScreenModeMemoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [HostScreenModeMemoryRecord]

    public init(records: [HostScreenModeMemoryRecord] = []) {
        self.records = records
    }

    public func remembered(hostPublicKey: Data, displayIdentity: String) -> RememberedHostScreenMode? {
        lock.lock()
        defer { lock.unlock() }
        return records.first {
            $0.hostPublicKey == hostPublicKey && $0.displayIdentity == displayIdentity
        }?.mode
    }

    public func remember(hostPublicKey: Data, displayIdentity: String, mode: RememberedHostScreenMode) {
        lock.lock()
        defer { lock.unlock() }
        records = HostScreenModeMemoryList.upserting(
            HostScreenModeMemoryRecord(hostPublicKey: hostPublicKey, displayIdentity: displayIdentity, mode: mode),
            into: records
        )
    }
}

/// Writes one JSON file at an explicitly supplied URL, owner-only -- the
/// same posture `PresenceCredentialRecordStore` and
/// `FileDeviceIdentityStore` already take for a file under this viewer's own
/// Application Support directory, even though a remembered resolution is not
/// a secret: it is still this person's own record of a machine they use, and
/// nothing about it should be readable by another account on the same Mac.
/// No test executes this: it would write outside the repository. What an
/// unreadable file means is `HostScreenModeMemoryFileCoding`'s decision,
/// which is verified.
public final class FileHostScreenModeMemoryStore: HostScreenModeMemoryStoring, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func remembered(hostPublicKey: Data, displayIdentity: String) -> RememberedHostScreenMode? {
        stored().first {
            $0.hostPublicKey == hostPublicKey && $0.displayIdentity == displayIdentity
        }?.mode
    }

    public func remember(hostPublicKey: Data, displayIdentity: String, mode: RememberedHostScreenMode) {
        let updated = HostScreenModeMemoryList.upserting(
            HostScreenModeMemoryRecord(hostPublicKey: hostPublicKey, displayIdentity: displayIdentity, mode: mode),
            into: stored()
        )
        guard let data = HostScreenModeMemoryFileCoding.encode(updated) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
        // An atomic write replaces the file, so the mode is set on what the
        // write actually left behind rather than on whatever was there
        // before it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func stored() -> [HostScreenModeMemoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return HostScreenModeMemoryFileCoding.decode(data)
    }
}
