#if os(Linux)
import Foundation

/// The package's files a packaged host reads when it adopts its first
/// update, and where the person's own launcher entries go.
public enum LinuxHostLocations {
    /// The package's own launcher entry and icon theme folder. Never written.
    public static let packagedDesktopFile = URL(fileURLWithPath: "/usr/share/applications/com.sensorium.host.desktop")
    public static let packagedIconsFolder = URL(fileURLWithPath: "/usr/share/icons", isDirectory: true)

    /// `$XDG_DATA_HOME/applications` and `$XDG_DATA_HOME/icons`, under
    /// `~/.local/share` where that variable is unset or empty. Entries there
    /// take precedence over the package's ones of the same name.
    public static func launcherFolders(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (applications: URL, icons: URL) {
        let base: URL
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return (
            base.appendingPathComponent("applications", isDirectory: true),
            base.appendingPathComponent("icons", isDirectory: true)
        )
    }
}
#endif
