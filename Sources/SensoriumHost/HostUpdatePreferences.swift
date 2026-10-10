import Foundation
import SensoriumCore

/// **Install updates automatically**, under **Open at login**.
public struct HostUpdatePreferenceRecord: Codable, Equatable, Sendable {
    public let installsAutomatically: Bool

    public init(installsAutomatically: Bool) {
        self.installsAutomatically = installsAutomatically
    }
}

/// How the preference file is read and written. Automatic updates are on by
/// default, so a file that is absent or not this shape reads as on; only a
/// recorded off reads as off.
public enum HostUpdatePreferenceFileCoding {
    public static func decode(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(HostUpdatePreferenceRecord.self, from: data))?.installsAutomatically ?? true
    }

    public static func encode(_ installsAutomatically: Bool) -> Data? {
        try? JSONEncoder().encode(HostUpdatePreferenceRecord(installsAutomatically: installsAutomatically))
    }
}

public protocol HostUpdatePreferenceStoring: Sendable {
    func installsAutomatically() -> Bool
    func remember(installsAutomatically: Bool) throws
}

public final class InMemoryHostUpdatePreferenceStore: HostUpdatePreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(installsAutomatically: Bool = true) {
        value = installsAutomatically
    }

    public func installsAutomatically() -> Bool {
        lock.withLock { value }
    }

    public func remember(installsAutomatically: Bool) throws {
        lock.withLock { value = installsAutomatically }
    }
}

public enum HostUpdatePreferenceError: Error, Equatable {
    case couldNotEncode
}

/// One owner-only JSON file in the host's Application Support folder. The
/// viewer shares that folder, so the name says whose it is.
public final class FileHostUpdatePreferenceStore: HostUpdatePreferenceStoring, @unchecked Sendable {
    public static let fileName = "host-update-preferences.json"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func installsAutomatically() -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        return HostUpdatePreferenceFileCoding.decode(data)
    }

    public func remember(installsAutomatically: Bool) throws {
        guard let data = HostUpdatePreferenceFileCoding.encode(installsAutomatically) else {
            throw HostUpdatePreferenceError.couldNotEncode
        }
        try OwnerOnlyFileWrite.write(data, to: url)
    }
}
