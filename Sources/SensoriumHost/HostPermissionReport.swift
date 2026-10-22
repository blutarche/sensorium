/// Renders `sensoriumd request-permissions`' output as testable, independent
/// lines: the honest Screen Recording/Accessibility statuses, the
/// terminal-launch caveat, and a factual statement about Remote Desktop
/// (macOS 14+), which nothing in this repository can actually query. Kept
/// separate from `HostPermissionRequester` so the exact wording is verifiable
/// without a real terminal or process ancestry.
public enum HostPermissionReport {
    public static func lines(
        result: HostPermissionRequestResult,
        launchContext: HostPermissionLaunchContext
    ) -> [String] {
        var lines = [
            "Screen Recording: \(result.screenCapture == .granted ? "granted" : "approval required")",
            "Accessibility: \(result.accessibility == .granted ? "granted" : "approval required")"
        ]
        switch launchContext {
        case .terminalAttached:
            lines.append(
                "WARNING: this process is attached to a terminal. macOS attributes the statuses above to " +
                "the RESPONSIBLE parent process — this terminal — not to Sensorium Host itself: they can read " +
                "granted from the terminal\u{2019}s own approval even though the packaged app has neither. Launch " +
                "the host bundle through Launch Services (double-click Sensorium Host.app, or " +
                "\"open 'Sensorium Host.app'\") for a truthful reading."
            )
        case .notTerminalAttached:
            lines.append(
                "Note: this process is not attached to a terminal, consistent with a Launch Services launch, " +
                "but it cannot fully confirm how it was launched. If these statuses still look wrong, re-check " +
                "by opening Sensorium Host.app from Finder."
            )
        }
        lines.append(
            "Remote Desktop (System Settings > Privacy & Security > Remote Desktop; macOS 14+ requires it " +
            "for unattended access): status cannot be checked here — Apple exposes no public API for it. " +
            "Grant it yourself; this tool cannot verify it for you."
        )
        return lines
    }
}
