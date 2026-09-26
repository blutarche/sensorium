import Foundation
import SensoriumCore

/// Whether this host offers a private desktop: a session canvas, the virtual
/// display a viewer can open instead of one of this machine's own screens.
/// Off unless the person at this machine turned it on.
public struct HostPrivateDesktopSetting: Codable, Equatable, Sendable {
    public var offersPrivateDesktop: Bool
    public init(offersPrivateDesktop: Bool = false) {
        self.offersPrivateDesktop = offersPrivateDesktop
    }
}

/// Where the setting is read and written, in this machine's own files only.
/// A missing file is a machine that never turned it on, and an unreadable one
/// reads as off too: off creates nothing, so it is the safe way to be wrong.
public final class HostPrivateDesktopSettingStore {
    private let url: URL
    private let log: (String) -> Void
    private var reportedUnreadableFile = false

    public init(url: URL, log: @escaping (String) -> Void = { print("Sensorium host: \($0)") }) {
        self.url = url
        self.log = log
    }

    public func load() -> HostPrivateDesktopSetting {
        guard let data = try? Data(contentsOf: url) else {
            return HostPrivateDesktopSetting()
        }
        guard let setting = try? JSONDecoder().decode(HostPrivateDesktopSetting.self, from: data) else {
            if !reportedUnreadableFile {
                reportedUnreadableFile = true
                log("the private desktop setting at \(url.path) could not be read. Treating it as off.")
            }
            return HostPrivateDesktopSetting()
        }
        return setting
    }

    public func save(_ setting: HostPrivateDesktopSetting) throws {
        let data = try JSONEncoder().encode(setting)
        try OwnerOnlyFileWrite.write(data, to: url)
    }
}
