import Foundation
import SensoriumCore

/// One release that failed to install, keyed by its version and its
/// archive's SHA-256.
public struct LinuxUpdateFailureRecord: Codable, Equatable, Sendable {
    public var version: LinuxUpdateVersion
    public var sha256: String
    public var kind: LinuxUpdateFailureKind
    public var tries: Int
    /// The last failure's `LinuxUpdateFailure.reason`, so the *Failed* line
    /// can name it after a relaunch.
    public var reason: String
    public var lastFailed: Date?
}

/// What the viewer remembers between checks.
public struct LinuxUpdateState: Codable, Equatable, Sendable {
    /// A release that could pass on another try is tried this many times,
    /// then counts as bad.
    public static let maximumTries = 3

    /// The viewer checks at launch and this often while it runs. A retry
    /// waits this long after its last failure, so a relaunch does not retry
    /// at once.
    public static let checkInterval: TimeInterval = 6 * 60 * 60

    /// The highest version this viewer has seen in a valid manifest.
    public var highestVersionSeen: LinuxUpdateVersion?
    public var lastCheck: Date?
    public var failures: [LinuxUpdateFailureRecord]

    public init(highestVersionSeen: LinuxUpdateVersion? = nil, lastCheck: Date? = nil, failures: [LinuxUpdateFailureRecord] = []) {
        self.highestVersionSeen = highestVersionSeen
        self.lastCheck = lastCheck
        self.failures = failures
    }

    public func failure(version: LinuxUpdateVersion, sha256: String) -> LinuxUpdateFailureRecord? {
        failures.first { $0.version == version && $0.sha256 == sha256 }
    }

    /// Whether this release may be downloaded and installed.
    public func mayTry(version: LinuxUpdateVersion, sha256: String) -> Bool {
        failure(version: version, sha256: sha256)?.kind != .badRelease
    }

    /// Whether the *Failed* line shows for this release: after a bad
    /// release, or after the last try. Between tries the *Waiting* line
    /// stays.
    public func hasGivenUp(on version: LinuxUpdateVersion, sha256: String) -> Bool {
        !mayTry(version: version, sha256: sha256)
    }

    /// Whether a release that could pass on another try still waits for the
    /// next scheduled check.
    public func isHeldBack(version: LinuxUpdateVersion, sha256: String, now: Date) -> Bool {
        guard let record = failure(version: version, sha256: sha256),
              record.kind == .couldPassOnAnotherTry,
              let lastFailed = record.lastFailed else {
            return false
        }
        return now.timeIntervalSince(lastFailed) < Self.checkInterval
    }

    public mutating func recordFailure(_ failure: LinuxUpdateFailure, version: LinuxUpdateVersion, sha256: String, now: Date = Date()) {
        var record = self.failure(version: version, sha256: sha256)
            ?? LinuxUpdateFailureRecord(version: version, sha256: sha256, kind: failure.kind, tries: 0, reason: failure.reason)
        record.tries += 1
        record.reason = failure.reason
        record.lastFailed = now
        if failure.kind == .badRelease || record.tries >= Self.maximumTries {
            record.kind = .badRelease
        }
        failures.removeAll { $0.version == version && $0.sha256 == sha256 }
        failures.append(record)
    }

    /// **Check for Updates…** forgets every recorded failure.
    public mutating func clearFailures() {
        failures.removeAll()
    }
}

/// `viewer-update-state.json` in the data root: owner-only, written
/// atomically.
public struct LinuxUpdateStateStore: Sendable {
    public static let fileName = "viewer-update-state.json"

    public let url: URL

    public init(dataRoot: URL) {
        url = dataRoot.appendingPathComponent(Self.fileName)
    }

    /// A missing or unreadable file reads as an empty state, so one bad
    /// write cannot stop every later check.
    public func load() -> LinuxUpdateState {
        OwnerOnlyFileWrite.removeStalePartialFiles(for: url)
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(LinuxUpdateState.self, from: data) else {
            return LinuxUpdateState()
        }
        return state
    }

    public func save(_ state: LinuxUpdateState) throws {
        try OwnerOnlyFileWrite.write(try Self.encoder.encode(state), to: url)
    }

    /// Reads, changes and writes the file.
    @discardableResult
    public func update(_ change: (inout LinuxUpdateState) -> Void) throws -> LinuxUpdateState {
        var state = load()
        change(&state)
        try save(state)
        return state
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
