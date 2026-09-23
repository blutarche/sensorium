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
        let base: URL
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = homeDirectory
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return base.appendingPathComponent("sensorium", isDirectory: true)
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
