#if os(Linux)
import Foundation
import SensoriumLinuxHost

struct HostAutostart {
    private static let executable = "/usr/bin/sensorium-host"
    private static let entry = """
        [Desktop Entry]
        Type=Application
        Name=Sensorium Host
        Exec=/usr/bin/sensorium-host --background
        TryExec=/usr/bin/sensorium-host
        """

    private let file: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let configRoot: URL
        if let configured = environment["XDG_CONFIG_HOME"], configured.hasPrefix("/") {
            configRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            configRoot = home.appendingPathComponent(".config", isDirectory: true)
        }
        file = configRoot.appendingPathComponent("autostart", isDirectory: true)
            .appendingPathComponent("com.sensorium.host.desktop")
    }

    var state: HostWindowState.OpenAtLogin {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { return .notAvailable }
        return FileManager.default.fileExists(atPath: file.path) ? .on : .off
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((Self.entry + "\n").utf8).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
#endif
