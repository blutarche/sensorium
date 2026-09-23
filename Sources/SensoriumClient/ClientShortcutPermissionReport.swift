/// Renders the viewer's shortcut-forwarding state as testable, independent
/// lines, in the same spirit as the host's permission report: state plainly
/// what is missing and exactly what it blocks, never degrade silently.
///
/// The launch-time report matters more here than a per-event notice does.
/// Without Accessibility the viewer is never handed a Cmd-Tab at all, so
/// there is no event to complain about — the only honest moment to say
/// "Cmd-Tab will not be forwarded" is before the user presses it.
public enum ClientShortcutPermissionReport {
    public static func lines(
        mode: SystemShortcutMode,
        accessibilityGranted: Bool
    ) -> [String] {
        var lines = ["System shortcuts: \(describe(mode))"]
        lines.append("Escape back to this machine: \(escapeGestureDescription)")
        guard mode != .local else {
            // Nothing is forwarded, so the viewer needs no permission it did
            // not already have. Saying otherwise would ask for a TCC grant
            // this mode cannot use.
            return lines
        }
        if accessibilityGranted {
            lines.append(
                "Accessibility (System Settings > Privacy & Security > Accessibility): granted for Sensorium. " +
                "The shortcuts macOS reserves — \(tapRequiredNames) — can be forwarded."
            )
        } else {
            lines.append(
                "Accessibility (System Settings > Privacy & Security > Accessibility): not granted for Sensorium."
            )
            lines.append(
                "Blocked by that: \(tapRequiredNames). macOS gives these to the WindowServer before any app sees " +
                "them, so without Accessibility Sensorium cannot observe them and they act on this machine instead, " +
                "not the remote workstation. The viewer will ask for this permission once per run, at your first " +
                "session start; grant it there, or beforehand in System Settings > Privacy & Security > " +
                "Accessibility. Forwarding starts as soon as the grant is given — no reconnect needed."
            )
            lines.append(
                "Still forwarded without it: \(applicationLevelNames), and all ordinary typing. Cmd-Q and Cmd-H " +
                "are this viewer's own menu chords as well; a forwarding canvas takes them before the menu does, " +
                "so quit or hide the viewer itself from its menu."
            )
        }
        return lines
    }

    /// Used when a tap-required shortcut is observed but cannot be forwarded —
    /// the mid-session case, such as Accessibility being revoked while the
    /// viewer is running.
    public static func blockedLine(_ shortcut: SystemShortcut) -> String {
        "\(shortcut.name) was not forwarded: it needs Accessibility approval for Sensorium " +
        "(System Settings > Privacy & Security > Accessibility). It acted on this machine instead."
    }

    public static var escapeGestureDescription: String {
        "\(ViewerKeyNames.escapeGesture). It is never forwarded, in any mode."
    }

    private static func describe(_ mode: SystemShortcutMode) -> String {
        switch mode {
        case .local:
            "local — system shortcuts always act on this machine; nothing is forwarded."
        case .remoteWhenFocused:
            "remote-when-focused — forwarded whenever a viewer window has key focus."
        case .remoteInFullscreen:
            "remote-in-fullscreen — forwarded only while a viewer window is fullscreen."
        }
    }

    private static var tapRequiredNames: String {
        names(where: .eventTap)
    }

    private static var applicationLevelNames: String {
        names(where: .applicationView)
    }

    private static func names(where interception: SystemShortcutInterception) -> String {
        SystemShortcutCatalog.all
            .filter { $0.interception == interception }
            .map(\.name)
            .joined(separator: ", ")
    }
}
