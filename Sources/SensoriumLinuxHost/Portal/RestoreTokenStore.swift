#if os(Linux)

import Foundation
import SensoriumCore

/// Where the host keeps the portal's restore token.
///
/// Every successful portal `Start` returns a new token and retires the old
/// one, so the newest token is the only one that matters and writing it is
/// the first thing done with a granted session. The file is replaced in one
/// step and readable by its owner alone. The token is a bearer grant: any
/// program running as this user can read it and restore screen capture and
/// input without a dialog. See `docs/threat-model.md`.
public struct RestoreTokenStore: Sendable {
    public static let fileName = "portal-restore-token.json"

    public let fileURL: URL

    public init(dataRoot: URL = RestoreTokenStore.defaultDataRoot()) {
        fileURL = dataRoot.appendingPathComponent(Self.fileName)
    }

    /// `$XDG_DATA_HOME/sensorium-host`, or `~/.local/share/sensorium-host`
    /// where that variable is unset or empty.
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
        return base.appendingPathComponent("sensorium-host", isDirectory: true)
    }

    struct Record: Codable {
        let restoreToken: String
        let allowsMultipleMonitors: Bool?
    }

    /// The saved token, or nil when there is none, the file cannot be read,
    /// or the token in it is empty. A bad file must not stop a host from
    /// asking for a fresh grant.
    public func load() -> String? {
        loadRecord()?.restoreToken
    }

    func loadRecord() -> Record? {
        OwnerOnlyFileWrite.removeStalePartialFiles(for: fileURL)
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              !record.restoreToken.isEmpty else {
            return nil
        }
        return record
    }

    /// Replaces the saved token atomically with an owner-only file.
    public func save(_ token: String) throws {
        try save(token, allowsMultipleMonitors: nil)
    }

    func save(_ token: String, allowsMultipleMonitors: Bool?) throws {
        let data = try JSONEncoder().encode(Record(restoreToken: token, allowsMultipleMonitors: allowsMultipleMonitors))
        try OwnerOnlyFileWrite.write(data, to: fileURL)
    }

    /// Forgets the token, as when the portal no longer accepts it.
    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
    }
}

#endif
