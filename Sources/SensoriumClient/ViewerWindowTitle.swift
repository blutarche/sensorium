import Foundation

/// What a session window is called, once the host has said who it is:
/// "{machine name} @ {tailnet name}" -- docs/ux-spec.md's own format -- so the
/// title names both the machine and the address it was reached at. AppKit-free
/// and pure, so the format is verified without a window.
public enum ViewerWindowTitle {
    /// `hostMachineName` is `canvasReady`'s optional field, `nil` from a host
    /// that predates it or has none configured -- either way this falls back
    /// to `fallback`, which is today's behaviour: the user's own name for the
    /// saved host, or the bare address when they gave none.
    public static func resolve(hostMachineName: String?, savedHost: String, fallback: String) -> String {
        guard let hostMachineName, !hostMachineName.isEmpty else {
            return fallback
        }
        return "\(hostMachineName) @ \(savedHost)"
    }

    /// The second session window's own title, docs/ux-spec.md's "Displays:
    /// 1 or 2" made concrete: the same title as the first window, naming
    /// which of the two this one is -- never "canvas" or "surface", the
    /// internal names for the thing the spec forbids on screen.
    public static func secondDisplayTitle(primaryTitle: String) -> String {
        "\(primaryTitle) \u{2014} Display 2"
    }
}
