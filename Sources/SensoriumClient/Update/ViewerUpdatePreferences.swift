#if os(macOS)
import Foundation
import SensoriumCore

/// **Check for Updates Automatically**, from the Sensorium menu.
public struct ViewerUpdatePreferencesRecord: Codable, Equatable, Sendable {
    public let checksAutomatically: Bool

    public init(checksAutomatically: Bool) {
        self.checksAutomatically = checksAutomatically
    }
}

/// How the preference file is read and written, kept apart from the file
/// store so it is verified without writing anything. Automatic updates are
/// on by default, so a file that is absent or not this shape reads as on;
/// only a recorded off reads as off.
public enum ViewerUpdatePreferencesFileCoding {
    public static func decode(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(ViewerUpdatePreferencesRecord.self, from: data))?.checksAutomatically ?? true
    }

    public static func encode(_ checksAutomatically: Bool) -> Data? {
        try? JSONEncoder().encode(ViewerUpdatePreferencesRecord(checksAutomatically: checksAutomatically))
    }
}

public protocol ViewerUpdatePreferencesStoring: Sendable {
    func checksAutomatically() -> Bool
    func remember(checksAutomatically: Bool)
}

public final class InMemoryViewerUpdatePreferencesStore: ViewerUpdatePreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(checksAutomatically: Bool = true) {
        value = checksAutomatically
    }

    public func checksAutomatically() -> Bool {
        lock.withLock { value }
    }

    public func remember(checksAutomatically: Bool) {
        lock.withLock { value = checksAutomatically }
    }
}

/// One owner-only JSON file in the viewer's Application Support folder. The
/// host shares that folder, so the name says whose it is.
public final class FileViewerUpdatePreferencesStore: ViewerUpdatePreferencesStoring, @unchecked Sendable {
    public static let fileName = "viewer-update-preferences.json"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func checksAutomatically() -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        return ViewerUpdatePreferencesFileCoding.decode(data)
    }

    public func remember(checksAutomatically: Bool) {
        guard let data = ViewerUpdatePreferencesFileCoding.encode(checksAutomatically) else { return }
        try? OwnerOnlyFileWrite.write(data, to: url)
    }
}
#endif
