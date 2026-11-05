import Foundation

/// Where a Linux viewer keeps its files and what it calls the machine it runs
/// on. Both answers are pure functions of what the system reported, so both
/// are verified without a Linux desktop -- the same discipline every other
/// decision in this viewer follows.
public enum LinuxViewerLocations {
    /// What a machine that answers with no name at all is called. The same
    /// sentence the macOS viewer falls back to, so a host lists either
    /// platform's nameless machine identically.
    public static let unnamedMachine = "This machine"

    /// The XDG base directory rule: `$XDG_DATA_HOME/sensorium`, or
    /// `~/.local/share/sensorium` where that variable is unset or empty.
    /// These are the viewer's own records -- the saved machines, this
    /// machine's key -- not a cache and not a configuration a person edits.
    public static func applicationSupportDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        dataHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("sensorium", isDirectory: true)
    }

    /// The package's own launcher entry and icon theme folder, read when a
    /// packaged viewer adopts its first update. Never written.
    public static let packagedDesktopFile = URL(fileURLWithPath: "/usr/share/applications/com.sensorium.viewer.desktop")
    public static let packagedIconsFolder = URL(fileURLWithPath: "/usr/share/icons", isDirectory: true)

    /// Where the person's own launcher entries and icons go, by the same
    /// rule as `applicationSupportDirectory`. Entries there take precedence
    /// over the package's ones of the same name.
    public static func launcherFolders(
        environment: [String: String],
        homeDirectory: URL
    ) -> LinuxViewerLauncherFolders {
        let base = dataHome(environment: environment, homeDirectory: homeDirectory)
        return LinuxViewerLauncherFolders(
            applications: base.appendingPathComponent("applications", isDirectory: true),
            icons: base.appendingPathComponent("icons", isDirectory: true)
        )
    }

    private static func dataHome(environment: [String: String], homeDirectory: URL) -> URL {
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
    }

    /// The name the kernel reports, the one written down in `/etc/hostname`
    /// where the kernel has none, and `unnamedMachine` where neither answers.
    /// Both are trimmed: a hostname file ends in a newline that is not part of
    /// the name.
    public static func deviceName(hostname: String?, etcHostname: String?) -> String {
        for candidate in [hostname, etcHostname] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return trimmed
        }
        return unnamedMachine
    }
}

public struct LinuxViewerLauncherFolders: Equatable, Sendable {
    public let applications: URL
    public let icons: URL
}
