/// Which command lines run with a Dock icon.
///
/// `serve` opens the session workspace window and must dispatch its
/// keyboard/pointer events, so it is the only interactive mode. Every other
/// command — `pair`, `request-permissions`, and anything unrecognized — must
/// stay headless: no Dock icon. Both modes still run an AppKit event loop:
/// even headless `pair` needs one to track its menu-bar item's menu.
public enum HostRunMode: Equatable, Sendable {
    case headless
    case interactive
}

public enum HostRunModeResolver {
    public static func resolve(verb: String?) -> HostRunMode {
        verb == "serve" ? .interactive : .headless
    }
}
