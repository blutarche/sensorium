#if os(macOS)
import Foundation
import SensoriumCore

extension UpdateVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = UpdateVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a version"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// One release that failed to install, keyed by its version and its zip's
/// SHA-256.
public struct UpdateFailureRecord: Codable, Equatable, Sendable {
    public var version: UpdateVersion
    public var sha256: String
    public var kind: UpdateFailureKind
    public var tries: Int
    /// The last failure's `UpdateFailure.reason`, so the *Failed* line can
    /// name it after a relaunch.
    public var reason: String
}

/// What an app remembers between checks.
public struct UpdateState: Codable, Equatable, Sendable {
    /// A release that could pass on another try is tried this many times,
    /// then counts as bad.
    public static let maximumTries = 3

    /// The highest version this app has seen in a valid manifest.
    public var highestVersionSeen: UpdateVersion?
    public var lastCheck: Date?
    public var failures: [UpdateFailureRecord]

    public init(highestVersionSeen: UpdateVersion? = nil, lastCheck: Date? = nil, failures: [UpdateFailureRecord] = []) {
        self.highestVersionSeen = highestVersionSeen
        self.lastCheck = lastCheck
        self.failures = failures
    }

    public func failure(version: UpdateVersion, sha256: String) -> UpdateFailureRecord? {
        failures.first { $0.version == version && $0.sha256 == sha256 }
    }

    /// Whether this release may be downloaded and installed.
    public func mayTry(version: UpdateVersion, sha256: String) -> Bool {
        failure(version: version, sha256: sha256)?.kind != .badRelease
    }

    /// Whether the *Failed* line shows for this release: after a bad
    /// release, or after the last try. Between tries the *Waiting* line
    /// stays.
    public func hasGivenUp(on version: UpdateVersion, sha256: String) -> Bool {
        !mayTry(version: version, sha256: sha256)
    }

    public mutating func recordFailure(_ failure: UpdateFailure, version: UpdateVersion, sha256: String) {
        var record = self.failure(version: version, sha256: sha256)
            ?? UpdateFailureRecord(version: version, sha256: sha256, kind: failure.kind, tries: 0, reason: failure.reason)
        record.tries += 1
        record.reason = failure.reason
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

/// `<role>-update-state.json`, owner-only, written atomically. One file per
/// app, since a Mac with both apps installed shares one Application Support
/// folder between them.
public struct UpdateStateStore: Sendable {
    public static func fileName(for role: UpdateAppRole) -> String {
        "\(role.rawValue)-update-state.json"
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sensorium", isDirectory: true)
    }

    public let url: URL

    public init(role: UpdateAppRole, directory: URL = UpdateStateStore.defaultDirectory) {
        url = directory.appendingPathComponent(Self.fileName(for: role))
    }

    /// A missing or unreadable file reads as an empty state, so one bad
    /// write cannot stop every later check.
    public func load() -> UpdateState {
        OwnerOnlyFileWrite.removeStalePartialFiles(for: url)
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(UpdateState.self, from: data) else {
            return UpdateState()
        }
        return state
    }

    public func save(_ state: UpdateState) throws {
        try OwnerOnlyFileWrite.write(try Self.encoder.encode(state), to: url)
    }

    /// Reads, changes and writes the file.
    @discardableResult
    public func update(_ change: (inout UpdateState) -> Void) throws -> UpdateState {
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
#endif
