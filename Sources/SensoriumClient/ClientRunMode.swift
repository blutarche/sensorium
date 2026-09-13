/// Which command lines require a real AppKit event loop.
///
/// `enter` — explicit or implied by omitting the subcommand entirely — opens
/// the session canvas window and must dispatch its keyboard/pointer events,
/// so it is the only interactive mode. `pair` and anything unrecognized stay
/// headless: no event loop, no Dock icon.
public enum ClientRunMode: Equatable, Sendable {
    case headless
    case interactive
}

public enum ClientRunModeResolver {
    public static func resolve(verb: String?) -> ClientRunMode {
        switch verb {
        case "enter", nil:
            return .interactive
        default:
            return .headless
        }
    }
}
