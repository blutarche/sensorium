#if os(Linux)
import Foundation
import SensoriumLinuxUpdate

/// **Open at login**: the host's own entry in the person's autostart
/// folder, `$XDG_CONFIG_HOME/autostart/com.sensorium.host.desktop`, which
/// starts the host with no window.
public struct HostAutostart {
    public static let packagedExecutable = URL(fileURLWithPath: "/usr/bin/sensorium-host")

    public let entryFile: URL
    private let installation: LinuxUpdateInstallation
    private let packagedExecutable: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataRoot: URL,
        packagedExecutable: URL = HostAutostart.packagedExecutable
    ) {
        let configRoot: URL
        if let configured = environment["XDG_CONFIG_HOME"], configured.hasPrefix("/") {
            configRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            configRoot = home.appendingPathComponent(".config", isDirectory: true)
        }
        entryFile = configRoot.appendingPathComponent("autostart", isDirectory: true)
            .appendingPathComponent("\(LinuxUpdateApp.host.desktopID).desktop")
        installation = LinuxUpdateInstallation(dataRoot: dataRoot, app: .host)
        self.packagedExecutable = packagedExecutable
    }

    /// The binary the entry runs: the version the host installed for
    /// itself once it has updated, otherwise the package's.
    public var executable: URL {
        let current = installation.currentExecutable
        return FileManager.default.isExecutableFile(atPath: current.path) ? current : packagedExecutable
    }

    public var state: HostWindowState.OpenAtLogin {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .notAvailable }
        return FileManager.default.fileExists(atPath: entryFile.path) ? .on : .off
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try write()
        } else if FileManager.default.fileExists(atPath: entryFile.path) {
            try FileManager.default.removeItem(at: entryFile)
        }
    }

    /// After an update: an entry that is on runs `executable` from now on.
    /// With Open at login off, no entry is written.
    public func repointIfEnabled() throws {
        guard FileManager.default.fileExists(atPath: entryFile.path) else { return }
        try write()
    }

    private func write() throws {
        let path = executable.path
        let entry = """
            [Desktop Entry]
            Type=Application
            Name=Sensorium Host
            Exec=\(try LinuxUpdateLauncherEntry.execArgument(for: path)) --background
            TryExec=\(path.replacingOccurrences(of: "\\", with: "\\\\"))

            """
        try FileManager.default.createDirectory(at: entryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(entry.utf8).write(to: entryFile, options: .atomic)
    }
}
#endif
